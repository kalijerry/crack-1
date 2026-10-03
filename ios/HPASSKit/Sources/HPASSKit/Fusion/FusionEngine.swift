import Foundation

/// 行人航位推算（PDR）+ 多源融合定位引擎。
///
/// 数据流：
/// ```
/// IMUSample(50 Hz) ─┬─> FusionAttitudeFilter  （互补滤波：重力方向 + 倾斜补偿磁罗盘 → 地图航向）
///                   └─> FusionStepDetector    （带通 + 峰谷状态机 → 脚步；Weinberg → 步长；方差 → 运动）
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

    // MARK: - 组件与状态

    /// 外部可调参数。**必须在引擎所属的串行队列上读写。**
    public var config: FusionConfig

    private let corridors: FusionCorridorMap
    private let attitude = FusionAttitudeFilter()
    private let stepper = FusionStepDetector()
    private var ekf = FusionEKFState()

    private var hasPosition = false
    private var headingSeeded = false
    private var initialHeadingHint: Double?
    /// 上一次与姿态滤波同步时的姿态航向，用于取增量。
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

    // MARK: - 构造

    public init(corridors: [CrossSegment], config: FusionConfig = .init()) {
        self.corridors = FusionCorridorMap(corridors)
        self.config = config
        ekf.reset(posSigmaM: FusionEngine.initPosSigmaM, headSigmaRad: FusionEngine.initHeadSigmaAuto)
    }

    public convenience init(map: StoreMap, config: FusionConfig = .init()) {
        self.init(corridors: map.crosses, config: config)
    }

    // MARK: - 公开接口

    /// 位置已知且航向已完成绝对初始化。`process` 在此之前返回 nil。
    public var isInitialized: Bool { hasPosition && attitude.headingReady }

    public var lastOutput: FusionOutput? { lastOutputValue }

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
            attitudeRef = attitude.theta
            headingSeeded = true
        }
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
                            fallbackHeading: initialHeadingHint)
        }

        // --- 步伐检测（与是否初始化无关，先把滤波器状态推起来）---
        let event = stepper.update(sample: s,
                                   dt: max(dt, 1e-3),
                                   minStepIntervalMs: config.minStepIntervalMs,
                                   maxStepLengthM: config.maxStepLengthM)

        guard isInitialized else { return nil }

        if !headingSeeded {
            // 位置先到、航向靠磁罗盘自动初始化的情况
            ekf.setHeading(attitude.theta, sigmaRad: FusionEngine.initHeadSigmaAuto)
            attitudeRef = attitude.theta
            headingSeeded = true
        }

        // --- 步间内插（要求 7）：两步之间按上一步的步长/步频匀速推进，输出不冻结 ---
        if dt > 0 { interpolate(dt: dt, tMs: s.tMs) }

        // --- 检出脚步 → EKF 步进推算 ---
        if let event = event {
            syncHeading()
            stepCountValue += 1
            lastStepLengthM = event.lengthM
            let remaining = FusionMath.clamp(event.lengthM - carriedM, 0.0, event.lengthM)
            ekf.propagateStep(lengthApplied: remaining,
                              lengthForNoise: event.lengthM,
                              sigmaLenRel: FusionEngine.stepLenSigmaRel,
                              sigmaHeadStep: FusionEngine.stepHeadSigma)
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

        // 航向伪观测：把 EKF 航向锚定到互补滤波航向
        ekf.updateHeading(z: attitude.theta, r: FusionEngine.headPseudoSigma * FusionEngine.headPseudoSigma)

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
                               isMoving: stepper.isMoving)
        pendingStep = false
        lastOutputValue = out
        return out
    }

    /// 清空全部状态（换楼层、重新定位时用）。`config` 保持不变。
    public func reset() {
        attitude.reset()
        stepper.reset()
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
    }

    // MARK: - 内部

    /// 把姿态滤波的航向增量搬进 EKF 状态。
    /// 这样 EKF 航向能 1:1 跟上转弯（增量传播），而绝对值仍可被定位观测与航向伪观测微调。
    private func syncHeading() {
        guard headingSeeded else { return }
        let d = FusionMath.wrapPi(attitude.theta - attitudeRef)
        attitudeRef = attitude.theta
        ekf.addHeadingDelta(d)
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
