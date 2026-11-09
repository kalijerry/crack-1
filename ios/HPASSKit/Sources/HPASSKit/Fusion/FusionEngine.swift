import Foundation

/// 行人航位推算（PDR）+ 多源融合定位引擎。
///
/// 数据流：
/// ```
/// IMUSample(50 Hz) ─┬─> FusionAttitudeFilter  （互补滤波：重力方向 + 倾斜补偿磁罗盘 → 地图航向）
///                   ├─> FusionStepDetector    （带通 + 峰谷状态机 → 脚步；Weinberg → 步长；方差 → 运动）
///                   └─> CarryModeClassifier   （可选：携带模式 → 分模式 K / 航向噪声 / 步幅平均；切换事件给粒子滤波）
///                              │
///                              ▼
/// 位置定位(≈1 Hz) ──────> FusionEKFState [x, y, θ]  （步进推算 + 卡方门限的定位观测 + 航向伪观测）
///                              │
///                              ▼
///                      FusionCorridorMap        （越界则投影回通道胶囊内侧）
///                              │
///                              ▼
///                      FusionOutput (≈3 Hz)
/// ```
///
/// ## 单位
/// 公开 API 全部用 **厘米**（与 `Point2` / `StoreMap` 一致）；内部状态用米，只在
/// `setInitialPosition` / `updateFix` / 构造 `FusionOutput` 这三处边界做 ×100 / ÷100 换算。
///
/// ## 航向约定
/// `headingRad` = 0 指向地图 +y 轴，dx = L·sinθ、dy = L·cosθ。详见 `FusionTypes.swift` 顶部。
///
/// ## 携带无关的运动模型（`FusionConfig.motion.enabled`，默认关）
/// 引擎报的航向始终是**手机前向轴**（+y，竖持时 −z，切换时按几何精确补偿）的方位角，由陀螺在「向上」方向的分量积分。
/// 行走方向 = 前向轴方位角 + 手机-行走夹角 δ：看屏 / 竖持时 δ ≈ 0（几何上已知）；通话 δ ≈ ±90°；口袋 / 包 / 摆臂 δ 未知。
/// δ 不在这里估，由粒子滤波每个粒子的航向偏差吸收；携带模式一变就发 `CarryMotionEvent`，粒子滤波按新模式的先验重撒
/// （`MagneticLocalizer.apply`）。摆臂 / 口袋的航向按一个步幅周期做圆平均再推步，不在步事件瞬间采样（会采到摆动相位）。
/// 步长 K、步内航向噪声按模式表（`CarryMotionTable`，占位值）取；K 还可以由粒子滤波学到的步长比例在线回写。
///
/// ## 线程约定
/// **本类不是线程安全的，内部没有任何锁。** 请把 `process` / `updateFix` /
/// `setInitialPosition` / `reset` / `config` 的全部读写放在**同一个串行 DispatchQueue**
/// （或同一线程）上。典型用法：IMU 回调与 BLE 定位回调都 `queue.async { ... }` 到同一条队列。
/// 之所以不加锁：50 Hz 的 `process` 每次只做几十次浮点运算，加锁的开销和优先级反转风险
/// 都大于收益；而调用方本来就需要一条队列来串行化两路传感器。
public final class FusionEngine {

    // MARK: - 可调常量（每个都注明取值理由）

    /// 位置随机游走强度（m/√s）。0.15 → 10 s 无定位时额外增长约 0.47 m 的 1σ。
    /// 注意：静止时也照样增长。宁可保守地让不确定度单调上升，也不要因为「静止判据」判错而虚报精度。
    private static let posQRate: Double = 0.15
    /// 卡住时放大后的位置随机游走强度（m/√s）。0.75 = 5×，
    /// 对应「明显在走但检不出步」时每秒丢掉 0.75 m 的把握度，让定位观测迅速主导。
    private static let stuckPosQRate: Double = 0.75
    /// 航向随机游走强度（rad/√s）≈ 2°/√s。对应 100 s 无磁场修正时 20° 的 1σ，
    /// 与消费级 MEMS 陀螺 + 互补滤波的实测漂移量级一致。
    private static let headQRate: Double = 2.0 * Double.pi / 180.0

    /// 步长相对误差（1σ）。Weinberg 模型在同一人身上的典型残差 10–20%，取 15%。
    private static let stepLenSigmaRel: Double = 0.15
    /// 单步内的航向误差（1σ，rad）≈ 3°。手持摆动 + 身体朝向与手机朝向的失配。
    /// 携带模式路径打开时按模式表取（口袋 6°、包 8°、摆臂 / 通话 10°，占位）。
    private static let stepHeadSigma: Double = 3.0 * Double.pi / 180.0
    /// 航向伪观测的噪声（1σ，rad）≈ 10°。
    /// 作用是把 EKF 航向锚定在互补滤波航向附近，防止定位修正通过位置-航向相关性
    /// 把航向越拉越偏；取得足够大（10°），所以正常情况下几乎不干预。
    private static let headPseudoSigma: Double = 10.0 * Double.pi / 180.0

    /// 定位野点门限：2 自由度卡方分布的 99% 分位 = 9.21。
    /// 选 99% 而不是 95%：BLE 指纹的误差分布尾巴重，95% 会把太多正常偏大的定位也拒掉。
    private static let gateChi2: Double = 9.21
    /// 连续被拒多少次之后强制接受最新定位。5 次 ≈ 5 s：
    /// 连续 5 次都对不上，更可能是自己的航位推算已经跑飞，而不是定位连错 5 次。
    private static let maxRejectStreak: Int = 5

    /// 通道投影的最大合理距离（cm）。超过 3 m 说明滤波点已经跑到别的通道/货架深处，
    /// 硬投影过去很可能投到错误的通道上，此时宁可保留上一个合法点并放大协方差，等定位来救。
    private static let maxProjectionCm: Double = 300.0
    /// 投影被判为不合理时注入的位置方差（m²）。1 m² → 1σ 增加 1 m，让下一次定位权重明显上升。
    private static let implausibleInflateM2: Double = 1.0

    /// 初始位置 1σ（m）。3 m：没有先验时与一次 BLE 定位的误差量级相当。
    private static let initPosSigmaM: Double = 3.0
    /// 调用方给了初始航向时的 1σ（rad）≈ 10°。
    private static let initHeadSigmaHint: Double = 10.0 * Double.pi / 180.0
    /// 航向由磁罗盘自行初始化时的 1σ（rad）≈ 30°（店内磁环境差，给宽一些）。
    private static let initHeadSigmaAuto: Double = 30.0 * Double.pi / 180.0

    /// 「明显在动却检不出步」的判定时长（ms）。
    private static let stuckMs: Int64 = 2000
    /// 卡住超过这个时长（ms）且有新鲜定位 → 直接吸附到定位点。
    private static let stuckSnapMs: Int64 = 5000
    /// 定位「新鲜」的时效（ms）。
    private static let fixFreshMs: Int64 = 3000

    /// 两步之间内插推进的距离上限占步长的比例。0.95：
    /// 留 5% 给真正检出脚步时的落地修正，保证「内插 + 落地」加起来恰好是一步。
    private static let maxCarryFrac: Double = 0.95
    /// 距上一步超过这个时长（ms）就停止内插（人可能已经停下）。
    private static let stepRecencyMs: Int64 = 2000
    /// 内插用的步伐周期限幅（s）：0.3 s = 3.3 步/s（极快），1.2 s = 0.83 步/s（极慢）。
    private static let minStepPeriodS: Double = 0.3
    private static let maxStepPeriodS: Double = 1.2
    /// 还没测到步频时的默认步伐周期（s）。
    private static let defaultStepPeriodS: Double = 0.6

    /// 单样本 dt 限幅（s）。0.2 s = 5 Hz；更大的间隔说明丢数据，按 0.2 s 处理避免一次积分跳太多。
    private static let maxSampleDtS: Double = 0.2
    /// 时间推进 dt 限幅（s）。
    private static let maxPropDtS: Double = 2.0
    /// 航向历史保留时长（ms）：步幅平均最多用两步周期（≤ 2.4 s）。
    private static let headingHistoryMs: Int64 = 3000
    /// 携带事件记录保留条数（诊断 / 测试）。
    private static let maxCarryEvents = 64

    // MARK: - 组件与状态

    /// 外部可调参数。**必须在引擎所属的串行队列上读写。**
    public var config: FusionConfig

    private let corridors: FusionCorridorMap
    private let attitude = FusionAttitudeFilter()
    private let stepper = FusionStepDetector()
    private let classifier: CarryModeClassifier
    private var ekf = FusionEKFState()

    private var hasPosition = false
    private var headingSeeded = false
    private var initialHeadingHint: Double?
    /// 上一次与姿态滤波同步时的（推步用）航向，用于取增量。
    private var attitudeRef: Double = 0

    private var lastSampleTMs: Int64 = 0
    private var hasLastSample = false
    private var startTMs: Int64 = 0
    private var hasStartTime = false
    private var lastPropTMs: Int64 = 0
    private var hasPropTime = false
    private var lastOutputTMs: Int64 = 0
    private var hasOutput = false

    private var stepCountValue = 0
    private var lastStepLengthM: Double = 0
    private var lastStepTMs: Int64 = 0
    private var hasStep = false
    private var stepPeriodS: Double = FusionEngine.defaultStepPeriodS
    private var pendingStep = false
    /// 两步之间已经内插推进的距离（m）。
    private var carriedM: Double = 0

    private var lastFixPos: Point2?
    private var lastFixTMs: Int64 = 0
    private var lastFixSigmaM: Double = FusionEngine.initPosSigmaM
    private var rejectStreak = 0

    /// 最近一次确认落在通道内的位置（m），用于投影不合理时回退。
    private var lastInsideM: Point2?

    private var lastOutputValue: FusionOutput?

    // 携带模式路径
    private var carryModeValue: CarryMode = .unknown
    private var activeCarry: CarryMode = .unknown
    private var externalCarry: CarryMode?
    /// 最近一次「操作手机」事件的时刻；分类器在它之后重判出携带姿态（哪怕同一个）就发一次 changed，按新模式先验收紧
    private var handledPendingT: Int64?
    private var lastHandledEventT: Int64 = Int64.min / 2
    private static let postHandledWindowMs: Int64 = 8000
    private var stepHeadSigmaCurrent: Double = FusionEngine.stepHeadSigma
    private var useStrideAverage = false
    /// 最近 3 s 的姿态航向（rad）；摆臂 / 口袋模式按一个步幅周期做圆平均。
    private var headingHist: [(t: Int64, th: Double)] = []
    /// 携带模式事件回调（`MagneticLocalizer.apply(_:)` 直接吃）。在引擎的串行队列上同步调用。
    public var onCarryEvent: ((CarryMotionEvent) -> Void)?
    /// 最近的携带模式事件（诊断 / 测试）。
    public private(set) var carryEvents: [CarryMotionEvent] = []
    /// 在线标定学到的分模式步长比例（乘在模式表的 K 上）。可持久化，用 `setLearnedStepScales` 恢复。
    public private(set) var learnedStepScales: [CarryMode: Double] = [:]
    /// 学到新的步长比例时回调（持久化用）。
    public var onStepScaleLearned: ((CarryMode, Double) -> Void)?

    // MARK: - 构造

    public init(corridors: [CrossSegment], config: FusionConfig = .init()) {
        self.corridors = FusionCorridorMap(corridors)
        self.config = config
        self.classifier = CarryModeClassifier(thresholds: config.motion.thresholds)
        ekf.reset(posSigmaM: FusionEngine.initPosSigmaM, headSigmaRad: FusionEngine.initHeadSigmaAuto)
    }

    public convenience init(map: StoreMap, config: FusionConfig = .init()) {
        self.init(corridors: map.crosses, config: config)
    }

    // MARK: - 公开接口

    /// 位置已知且航向已完成绝对初始化。`process` 在此之前返回 nil。
    public var isInitialized: Bool { hasPosition && attitude.headingReady }

    public var lastOutput: FusionOutput? { lastOutputValue }

    /// 当前携带模式（含 still / unknown；`config.motion.enabled` 关着时恒为 unknown）。
    public var carryMode: CarryMode { carryModeValue }
    /// 最近一次的携带姿态（站着不动时沿用）。
    public var activeCarryMode: CarryMode { activeCarry }
    /// 分类器的窗口特征（诊断 / 写日志）。
    public var carryFeatures: CarryFeatures { classifier.features }
    /// 姿态滤波的「向上」方向（设备系单位向量）。地磁特征提取要和这里用同一个 up（`MagneticFeatureExtractor.setUp`）。
    public var currentUp: (Double, Double, Double) { (attitude.up.x, attitude.up.y, attitude.up.z) }
    /// 当前生效的 Weinberg K（模式表 × 在线学到的比例）。
    public var effectiveStepLengthK: Double { stepper.weinbergK }
    /// App 侧近距离传感器（贴耳 / 口袋时 true），交给内部分类器区分通话和竖持。
    public var proximityNear: Bool? {
        get { classifier.proximityNear }
        set { classifier.proximityNear = newValue }
    }

    /// 携带模式由外部给（`config.motion.internalClassifier = false` 时；例如 App 带近距离传感器的分类）。
    /// 下一个样本生效；still / unknown 不改变携带姿态。
    public func setCarryMode(_ m: CarryMode) { externalCarry = m }

    /// 恢复持久化的分模式步长比例（0.6～1.7 以外的值不要）。
    public func setLearnedStepScales(_ s: [CarryMode: Double]) {
        learnedStepScales = s.filter { $0.value.isFinite && $0.value >= 0.6 && $0.value <= 1.7 }
        applyCarryParameters()
    }

    /// 在线标定：粒子滤波收敛后走了一段（设计上 50 m），把粒子步长比例的中位数回写到该模式的 K（相乘、按 alpha 只吸收一部分、
    /// 限幅 0.6～1.7）。返回实际吸收进 K 的比例；调用方随后应把粒子的步长比例除以同一个比例
    /// （`MagneticLocalizer.absorbStepScale`），净位移不变。离谱的比例（< 0.5 或 > 2）不吸收，返回 1。
    @discardableResult
    public func applyLearnedStepScale(_ scale: Double, for mode: CarryMode, alpha: Double = 0.5) -> Double {
        guard config.motion.enabled, mode.isCarryPosture, scale.isFinite, scale > 0.5, scale < 2 else { return 1 }
        let factor = 1 + (scale - 1) * FusionMath.clamp(alpha, 0, 1)
        let cur = learnedStepScales[mode] ?? 1
        let next = FusionMath.clamp(cur * factor, 0.6, 1.7)
        let applied = next / cur
        learnedStepScales[mode] = next
        applyCarryParameters()
        onStepScaleLearned?(mode, next)
        return applied
    }

    /// 设定初始位置（**厘米**）。`headingRad` 为 nil 时由磁罗盘自行初始化航向。
    public func setInitialPosition(_ p: Point2, headingRad: Double?) {
        ekf.setPosition(p.x / 100.0, p.y / 100.0, sigmaM: FusionEngine.initPosSigmaM)
        hasPosition = true
        carriedM = 0
        lastInsideM = nil
        if let h = headingRad, h.isFinite {
            initialHeadingHint = h
            attitude.setHeading(h)
            ekf.setHeading(h, sigmaRad: FusionEngine.initHeadSigmaHint)
            headingHist.removeAll()
            attitudeRef = attitude.theta
            headingSeeded = true
        }
    }

    /// 手动设定当前航向（弧度，地图系，0 = +y 轴）。
    ///
    /// 同时用当前罗盘读数反推 `magneticDeclinationDeg`，让之后的罗盘修正与手动航向一致；
    /// 罗盘读数不可用时磁偏角保持不变。可在运行中随时调用。
    public func setHeading(_ h: Double) {
        guard h.isFinite else { return }
        let hh = FusionMath.wrapTwoPi(h)
        if let psi = attitude.lastMagBearing {
            config.magneticDeclinationDeg = FusionMath.degrees(FusionMath.wrapTwoPi(hh + psi))
        }
        initialHeadingHint = hh
        attitude.setHeading(hh)
        ekf.setHeading(hh, sigmaRad: FusionEngine.initHeadSigmaHint)
        headingHist.removeAll()
        attitudeRef = attitude.theta
        headingSeeded = true
    }

    /// 送入一次外部绝对定位（**厘米**，confidence 0...1）。
    /// 噪声 1σ = `fixNoiseCm / max(confidence, 0.1)`，即置信度越低越不被信任（最多放大 10 倍）。
    public func updateFix(position: Point2, confidence: Double, tMs: Int64) {
        guard position.x.isFinite && position.y.isFinite else { return }
        let conf = FusionMath.clamp(confidence.isFinite ? confidence : 0, 0.0, 1.0)
        let sigma = max(config.fixNoiseCm, 1.0) / 100.0 / max(conf, 0.1)
        let zx = position.x / 100.0
        let zy = position.y / 100.0

        // 不管是否被采纳都记下来：卡住策略需要「最新收到的」定位作为救援点。
        lastFixPos = position
        lastFixTMs = tMs
        lastFixSigmaM = sigma

        if !hasPosition {
            ekf.setPosition(zx, zy, sigmaM: sigma)
            hasPosition = true
            if !hasPropTime {
                lastPropTMs = tMs
                hasPropTime = true
            }
            return
        }

        propagateTime(to: tMs, stuck: false)

        // 马氏/卡方新息门限：一次离谱的定位不能把轨迹拽走
        let d2 = ekf.positionMahalanobis(zx: zx, zy: zy, r: sigma * sigma)
        if d2 > FusionEngine.gateChi2 {
            rejectStreak += 1
            if rejectStreak >= FusionEngine.maxRejectStreak {
                // 连续被拒太多次 → 认为自身轨迹已失效，强制重置到最新定位（协方差给 2σ）
                ekf.setPosition(zx, zy, sigmaM: sigma * 2.0)
                rejectStreak = 0
                carriedM = 0
            }
            return
        }
        rejectStreak = 0
        ekf.updatePosition(zx: zx, zy: zy, r: sigma * sigma)
    }

    /// 送入一个 IMU 样本。返回 nil 表示：还没初始化，或还没到输出节拍。
    public func process(_ s: IMUSample) -> FusionOutput? {
        guard s.ax.isFinite && s.ay.isFinite && s.az.isFinite else { return nil }
        let motionOn = config.motion.enabled

        // --- dt ---
        var dt = 0.02
        if hasLastSample {
            dt = FusionMath.clamp(Double(s.tMs - lastSampleTMs) / 1000.0, 0.0, FusionEngine.maxSampleDtS)
        }
        lastSampleTMs = s.tMs
        hasLastSample = true
        if !hasStartTime { startTMs = s.tMs; hasStartTime = true }
        if !hasPropTime { lastPropTMs = s.tMs; hasPropTime = true }

        // --- 姿态 / 航向 ---
        if dt > 0 {
            attitude.update(sample: s,
                            dt: dt,
                            declinationRad: FusionMath.radians(config.magneticDeclinationDeg),
                            fallbackHeading: initialHeadingHint,
                            useMagnetic: config.useMagneticHeading,
                            useSampleGravity: motionOn && config.motion.useSampleGravity)
        }

        // --- 携带模式（可选）---
        if motionOn {
            headingHist.append((s.tMs, attitude.theta))
            while let f = headingHist.first, s.tMs - f.t > FusionEngine.headingHistoryMs { headingHist.removeFirst() }
            if config.motion.internalClassifier {
                classifier.thresholds = config.motion.thresholds
                let st = classifier.process(s, useSampleGravity: config.motion.useSampleGravity)
                updateCarry(mode: st.mode, handled: st.handled, decidedAt: st.decidedAtMs, tMs: s.tMs)
            } else if let m = externalCarry {
                updateCarry(mode: m, handled: false, decidedAt: s.tMs, tMs: s.tMs)
            }
            stepper.adaptive = config.motion.adaptiveStepDetection
            stepper.tuning = config.motion.stepTuning
        } else if stepper.adaptive {
            stepper.adaptive = false
        }

        // --- 步伐检测（与是否初始化无关，先把滤波器状态推起来）---
        var event = stepper.update(sample: s,
                                   dt: max(dt, 1e-3),
                                   minStepIntervalMs: config.minStepIntervalMs,
                                   maxStepLengthM: config.maxStepLengthM)

        guard isInitialized else { return nil }

        if !headingSeeded {
            // 位置先到、航向靠磁罗盘自动初始化的情况
            ekf.setHeading(attitude.theta, sigmaRad: FusionEngine.initHeadSigmaAuto)
            attitudeRef = headingSource()
            headingSeeded = true
        }

        // --- 步间内插（要求 7）：两步之间按上一步的步长/步频匀速推进，输出不冻结 ---
        if dt > 0 { interpolate(dt: dt, tMs: s.tMs) }

        // --- 检出脚步 → EKF 步进推算 ---
        if var e = event, abs(config.stepLengthScale - 1) > 1e-9 {
            e.lengthM = FusionMath.clamp(e.lengthM * config.stepLengthScale, 0.2, config.maxStepLengthM * 1.5)
            event = e
        }
        if let event = event {
            syncHeading()
            stepCountValue += 1
            lastStepLengthM = event.lengthM
            let remaining = FusionMath.clamp(event.lengthM - carriedM, 0.0, event.lengthM)
            ekf.propagateStep(lengthApplied: remaining,
                              lengthForNoise: event.lengthM,
                              sigmaLenRel: FusionEngine.stepLenSigmaRel,
                              sigmaHeadStep: motionOn ? stepHeadSigmaCurrent : FusionEngine.stepHeadSigma)
            carriedM = 0
            if hasStep {
                stepPeriodS = FusionMath.clamp(Double(event.tMs - lastStepTMs) / 1000.0,
                                               FusionEngine.minStepPeriodS,
                                               FusionEngine.maxStepPeriodS)
            }
            lastStepTMs = event.tMs
            hasStep = true
            pendingStep = true
        }

        // --- 输出节拍 ---
        let interval = max(config.outputIntervalMs, 0)
        if hasOutput && (s.tMs - lastOutputTMs) < interval { return nil }
        lastOutputTMs = s.tMs
        hasOutput = true

        syncHeading()

        // --- 卡住 / 失效处理（要求 6）---
        // 策略：运动检测说「在动」但 ≥2 s 没检出脚步 → 放大位置过程噪声（5×），
        // 让随后的定位观测迅速主导；若持续 ≥5 s 且有 3 s 内的新鲜定位 → 直接吸附到该定位点。
        // 典型触发场景：手机被放进口袋/手推车，或推着购物车走（竖向加速度被车架吸收）。
        let sinceStepMs = hasStep ? (s.tMs - lastStepTMs) : (s.tMs - startTMs)
        let stuck = stepper.isMoving && sinceStepMs >= FusionEngine.stuckMs
        propagateTime(to: s.tMs, stuck: stuck)

        // 航向伪观测：把 EKF 航向锚定到互补滤波航向（摆臂时是步幅平均后的航向）
        ekf.updateHeading(z: headingSource(), r: FusionEngine.headPseudoSigma * FusionEngine.headPseudoSigma)

        if stuck && sinceStepMs >= FusionEngine.stuckSnapMs,
           let fx = lastFixPos, (s.tMs - lastFixTMs) <= FusionEngine.fixFreshMs {
            ekf.setPosition(fx.x / 100.0, fx.y / 100.0, sigmaM: lastFixSigmaM)
            carriedM = 0
        }

        // --- 通道约束（要求 5）---
        var constrained = false
        if config.useCorridorConstraint && !corridors.isEmpty {
            let pCm = Point2(ekf.x * 100.0, ekf.y * 100.0)
            if let proj = corridors.project(pCm, marginCm: config.corridorMarginCm) {
                if proj.distanceCm <= FusionEngine.maxProjectionCm {
                    ekf.x = proj.point.x / 100.0
                    ekf.y = proj.point.y / 100.0
                    lastInsideM = Point2(ekf.x, ekf.y)
                    constrained = true
                } else if let prev = lastInsideM {
                    // 投影距离不合理：保留上一个合法点，放大协方差等定位来救
                    ekf.x = prev.x
                    ekf.y = prev.y
                    ekf.inflatePosition(addVarM2: FusionEngine.implausibleInflateM2)
                    constrained = true
                } else {
                    // 连一个合法点都还没有过（例如初始位置就在通道外）：
                    // 不动点、只放大协方差，避免把轨迹硬拽到可能错误的通道上。
                    ekf.inflatePosition(addVarM2: FusionEngine.implausibleInflateM2)
                }
            } else {
                lastInsideM = Point2(ekf.x, ekf.y)
            }
        }

        let th = FusionMath.wrapTwoPi(ekf.th)
        let out = FusionOutput(tMs: s.tMs,
                               position: Point2(ekf.x * 100.0, ekf.y * 100.0),
                               headingRad: th,
                               headingDeg: FusionMath.degrees(th),
                               stepDetected: pendingStep,
                               stepLengthM: lastStepLengthM,
                               stepCount: stepCountValue,
                               uncertaintyCm: ekf.posSigmaM * 100.0,
                               wasConstrained: constrained,
                               isMoving: stepper.isMoving,
                               carryMode: motionOn ? carryModeValue : .unknown)
        pendingStep = false
        lastOutputValue = out
        return out
    }

    /// 清空全部状态（换楼层、重新定位时用）。`config` 和学到的步长比例保持不变。
    public func reset() {
        attitude.reset()
        stepper.reset()
        classifier.reset()
        ekf = FusionEKFState()
        ekf.reset(posSigmaM: FusionEngine.initPosSigmaM, headSigmaRad: FusionEngine.initHeadSigmaAuto)
        hasPosition = false
        headingSeeded = false
        initialHeadingHint = nil
        attitudeRef = 0
        lastSampleTMs = 0; hasLastSample = false
        startTMs = 0; hasStartTime = false
        lastPropTMs = 0; hasPropTime = false
        lastOutputTMs = 0; hasOutput = false
        stepCountValue = 0
        lastStepLengthM = 0
        lastStepTMs = 0; hasStep = false
        stepPeriodS = FusionEngine.defaultStepPeriodS
        pendingStep = false
        carriedM = 0
        lastFixPos = nil
        lastFixTMs = 0
        lastFixSigmaM = FusionEngine.initPosSigmaM
        rejectStreak = 0
        lastInsideM = nil
        lastOutputValue = nil
        carryModeValue = .unknown
        activeCarry = .unknown
        externalCarry = nil
        handledPendingT = nil
        lastHandledEventT = Int64.min / 2
        stepHeadSigmaCurrent = FusionEngine.stepHeadSigma
        useStrideAverage = false
        headingHist.removeAll()
        carryEvents.removeAll()
        stepper.weinbergK = CarryMotionTable.fallback.stepLengthK
    }

    // MARK: - 内部

    /// 推步用的航向：摆臂 / 口袋模式是一个步幅周期（两步）的圆平均，其余是姿态滤波的瞬时航向。
    private func headingSource() -> Double {
        guard useStrideAverage, let last = headingHist.last else { return attitude.theta }
        let win = Int64(FusionMath.clamp(2 * stepPeriodS, 0.6, 2.4) * 1000)
        var s = 0.0, c = 0.0
        for h in headingHist.reversed() {
            if last.t - h.t > win { break }
            s += sin(h.th); c += cos(h.th)
        }
        guard s * s + c * c > 1e-12 else { return attitude.theta }
        return FusionMath.wrapTwoPi(atan2(s, c))
    }

    /// 把推步航向的增量搬进 EKF 状态。
    /// 这样 EKF 航向能 1:1 跟上转弯（增量传播），而绝对值仍可被定位观测与航向伪观测微调。
    private func syncHeading() {
        guard headingSeeded else { return }
        let cur = headingSource()
        let d = FusionMath.wrapPi(cur - attitudeRef)
        attitudeRef = cur
        ekf.addHeadingDelta(d)
    }

    /// 分类器 / 外部给的携带模式进来：更新携带姿态、分模式参数，必要时发事件。
    /// - 携带姿态变了 → changed（第一次 → initial）；
    /// - 「操作手机」→ handled（立刻撒开），之后分类器重判出携带姿态（`decidedAt` 晚于事件，哪怕同一个模式）→ 再发一次
    ///   changed，让粒子滤波按该模式的先验收紧（texting / upright 的 δ 几何上已知）。
    private func updateCarry(mode: CarryMode, handled: Bool, decidedAt: Int64, tMs: Int64) {
        carryModeValue = mode
        let prev = activeCarry
        if mode.isCarryPosture { activeCarry = mode }
        // 「操作手机」之后几秒内（重判可能先过一个中间模式，例如摆臂）判出的模式都按「操作之后」处理
        let afterHandled = handledPendingT != nil || tMs - lastHandledEventT <= FusionEngine.postHandledWindowMs
        if activeCarry != prev {
            applyCarryParameters()
            emit(kind: prev.isCarryPosture ? .changed : .initial, from: prev, to: activeCarry, tMs: tMs,
                 afterHandled: afterHandled && prev.isCarryPosture)
            if prev.isCarryPosture { handledPendingT = nil }
        } else if let hp = handledPendingT, mode.isCarryPosture, decidedAt > hp {
            handledPendingT = nil
            emit(kind: .changed, from: prev, to: activeCarry, tMs: tMs, afterHandled: true)
        }
        if handled, config.motion.reportHandledEvents, activeCarry.isCarryPosture {
            handledPendingT = tMs
            lastHandledEventT = tMs
            emit(kind: .handled, from: activeCarry, to: activeCarry, tMs: tMs)
        }
    }

    /// 按当前携带姿态取模式表：K（× 在线学到的比例）、步内航向噪声、步幅平均。
    private func applyCarryParameters() {
        let p = config.motion.table[activeCarry]
        stepper.weinbergK = p.stepLengthK * (learnedStepScales[activeCarry] ?? 1)
        stepHeadSigmaCurrent = FusionMath.radians(p.stepHeadingSigmaDeg)
        let want = config.motion.strideAverageHeading && p.strideAverageHeading
        if want != useStrideAverage {
            useStrideAverage = want
            // 换航向来源：参考点跟着换，不然瞬时值和平均值的差会被当成一次转向
            attitudeRef = headingSource()
        }
    }

    /// - afterHandled: 这次 changed 紧跟在「操作手机」之后。引擎航向是 ω·up 积出来的，大幅翻转手机后它和前向轴方位角
    ///   不再一致（合成数据：看屏 → 口袋留下 90° 而不是几何上的 35°），所以即使新模式是 texting / upright，也不能按
    ///   δ≈0 的紧先验重撒：保留 handled 撒开的偏差，只在附近再撒 `postHandledSpreadDeg`（nil = 整圆），交给地磁去挑。
    private func emit(kind: CarryMotionEvent.Kind, from: CarryMode, to: CarryMode, tMs: Int64, afterHandled: Bool = false) {
        let p = config.motion.table[to]
        let ev: CarryMotionEvent
        switch kind {
        case .handled:
            ev = CarryMotionEvent(tMs: tMs, kind: .handled, from: from, to: to,
                                  headingSpreadDeg: config.motion.handledSpreadDeg, headingCentersDeg: [0],
                                  keepBias: config.motion.handledSpreadDeg != nil,
                                  initialScaleSigma: p.initialScaleSigma, lostSuppressCm: max(p.lostSuppressCm, 1500))
        case .changed where afterHandled && p.headingSpreadDeg != nil:
            ev = CarryMotionEvent(tMs: tMs, kind: kind, from: from, to: to,
                                  headingSpreadDeg: config.motion.postHandledSpreadDeg, headingCentersDeg: [0],
                                  keepBias: config.motion.postHandledSpreadDeg != nil,
                                  initialScaleSigma: p.initialScaleSigma, lostSuppressCm: max(p.lostSuppressCm, 1500))
        case .changed where !afterHandled && config.motion.respreadOnlyAfterHandled && config.motion.internalClassifier
                            && config.motion.reportHandledEvents:
            // 没有「操作手机」的模式变化：手机相对身体没被大幅转过，δ 没变，只是分类器的看法变了（真实手持数据里
            // 看屏 ↔ 包里 / 摆臂来回判是常事）。只切分模式参数，偏差保留、只撒一点，不进保护期。
            // 外部给模式（没有操作手机事件）时不适用：那时模式变化就是唯一的信号
            ev = CarryMotionEvent(tMs: tMs, kind: kind, from: from, to: to,
                                  headingSpreadDeg: config.motion.unhandledChangeSpreadDeg, headingCentersDeg: [0], keepBias: true,
                                  initialScaleSigma: 0, lostSuppressCm: 0)
        case .changed, .initial:
            ev = CarryMotionEvent(tMs: tMs, kind: kind, from: from, to: to,
                                  headingSpreadDeg: p.headingSpreadDeg, headingCentersDeg: p.headingCentersDeg, keepBias: false,
                                  initialScaleSigma: p.initialScaleSigma, lostSuppressCm: p.lostSuppressCm)
        }
        carryEvents.append(ev)
        if carryEvents.count > FusionEngine.maxCarryEvents { carryEvents.removeFirst(carryEvents.count - FusionEngine.maxCarryEvents) }
        onCarryEvent?(ev)
    }

    private func propagateTime(to t: Int64, stuck: Bool) {
        if !hasPropTime {
            lastPropTMs = t
            hasPropTime = true
            return
        }
        let d = Double(t - lastPropTMs) / 1000.0
        if d <= 0 { return }        // 乱序/重复时间戳：不倒推
        lastPropTMs = t
        ekf.propagateTime(dt: min(d, FusionEngine.maxPropDtS),
                          posRate: stuck ? FusionEngine.stuckPosQRate : FusionEngine.posQRate,
                          headRate: FusionEngine.headQRate)
    }

    /// 步间匀速内插。累计推进量上限为 0.95×步长，所以即使步伐检测突然失效，
    /// 位置最多多走半步左右就停住，然后由不断增长的不确定度 + 定位观测接管。
    private func interpolate(dt: Double, tMs: Int64) {
        guard stepper.isMoving, hasStep, lastStepLengthM > 0,
              (tMs - lastStepTMs) <= FusionEngine.stepRecencyMs else { return }
        let cap = lastStepLengthM * FusionEngine.maxCarryFrac
        guard carriedM < cap else { return }
        let v = lastStepLengthM / max(stepPeriodS, FusionEngine.minStepPeriodS)
        let adv = min(v * dt, cap - carriedM)
        guard adv > 0 else { return }
        ekf.x += adv * sin(ekf.th)
        ekf.y += adv * cos(ekf.th)
        carriedM += adv
    }
}
