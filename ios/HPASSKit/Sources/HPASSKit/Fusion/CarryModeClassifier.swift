import Foundation

/// 携带模式分类器的阈值。**全部是占位值：待自采 iPhone 双机数据标定**（tools 侧用小决策树离线学，再回写这里）。
/// 特征全部在重力系里算，所以阈值和手机的航向无关。
public struct CarryModeThresholds {
    /// 特征窗口（s）和切换滞回（s）。
    public var windowS = 2.0
    public var hysteresisS = 1.5
    /// 没有重力列时「向上」方向的加速度低通时间常数（s）。
    public var gravityTauS = 0.4

    // 静止：线加速度标准差（m/s²）和陀螺 RMS（rad/s）都低于此
    public var stillAccelStd = 0.25
    public var stillGyroRms = 0.15

    // 几何（度）。tiltZ = 屏幕法线与向上的夹角（0 平放朝上、90 竖直、180 反扣）；tiltY = 长轴 +y 与向上的夹角（0 顶朝上、180 顶朝下）
    /// 屏幕法线倾角小于此 = 看屏（含平端）
    public var textingTiltZMax = 65.0
    /// 屏幕竖直的范围
    public var verticalTiltZMin = 65.0
    public var verticalTiltZMax = 120.0
    /// 竖持（顶朝上）：长轴与竖直的夹角上限
    public var uprightTiltYMax = 30.0
    /// 通话：长轴倾斜 30～75°（顶朝后上方）。近距离传感器说「贴着」时不看几何
    public var callingTiltYMin = 30.0
    public var callingTiltYMax = 75.0
    /// 「吊着」（顶朝下）：口袋 / 摆臂的典型姿态
    public var hangingTiltYMin = 110.0

    // 动态
    /// 陀螺 RMS（rad/s）达到此值才算「转得多」（口袋 / 摆臂 / 包里晃；手持时陀螺 RMS 一般 < 0.9）
    public var movingGyroRms = 0.9
    /// 口袋：大腿每步幅摆 ±20～30°，陀螺 RMS 很少低于此值；包里晃一般到不了
    public var pocketGyroRms = 1.3
    /// 摆臂：陀螺 RMS 很大
    public var swingGyroRms = 1.6
    /// 口袋：大腿运动近似平面，陀螺能量集中在单一轴上的占比
    public var pocketAxisConcentration = 0.8
    /// 偏航率在步幅频率（1×）与步频（2×）上的能量比超过此值也支持摆臂
    public var swingStrideRatio = 3.0
    /// 手持（看屏 / 竖持 / 通话）陀螺 RMS 上限，超过且不像口袋 / 摆臂 → 包里晃
    public var handheldGyroRmsMax = 0.9
    /// 线加速度标准差超过此值（m/s²）而陀螺不大：包里颠
    public var bagAccelStdMin = 3.0

    // 「操作手机」事件：1 s 内陀螺峰值（rad/s）超过且向上方向转过的角度（度）超过
    public var handledGyroPeak = 2.5
    public var handledTiltChangeDeg = 40.0
    public var handledWindowS = 1.0
    public var handledCooldownS = 1.5
    /// 事件之后认为手还在动的时长（s）：这段里不更新候选（陀螺突增会被误判成摆臂），结束时清掉窗口只看之后的样本
    public var handlingS = 1.2
    /// 手停下来之后的快速重判期（s）：窗口攒够 fastWindowS 就判、滞回缩到 fastHysteresisS，模式切换的延迟从 ~4 s 缩到 ~2.5 s
    public var fastDecideS = 4.0
    public var fastWindowS = 1.0
    public var fastHysteresisS = 0.5

    public init() {}
}

/// 分类器用的窗口特征（公开给离线拟合 / 调试写日志）。
public struct CarryFeatures {
    public var tiltZDeg = 0.0
    public var tiltYDeg = 0.0
    public var tiltYStdDeg = 0.0
    public var gyroRms = 0.0
    public var yawRateRms = 0.0
    /// 陀螺能量在最强的单一设备轴上的占比（0.33 均匀 … 1 单轴）
    public var axisConcentration = 0.0
    public var accelStd = 0.0
    public var vertAccelStd = 0.0
    public var horizAccelStd = 0.0
    /// 偏航率在 f_step/2 与 f_step 上的能量比（无步频估计时 0）
    public var strideRatio = 0.0
    public var stepFreqHz = 0.0
    public var proximityNear: Bool?
}

/// 分类器的一帧输出。
public struct CarryState {
    /// 当前判定（含 still / unknown）。
    public var mode: CarryMode
    /// 最近一次的携带姿态（不含 still / unknown）；站着不动时沿用。
    public var activeMode: CarryMode
    /// 本样本触发了「操作手机」事件。
    public var handled: Bool
    /// 屏幕法线与竖直的夹角（度）。
    public var tiltDeg: Double
    public var features: CarryFeatures
    /// 当前 `mode` 是什么时候定下来的（Unix ms）。「操作手机」之后哪怕判回同一个模式也会重新定一次，
    /// FusionEngine 据此知道分类器已经在事件之后重判过了。
    public var decidedAtMs: Int64 = 0
}

/// 携带模式分类器：重力系特征 + 可配置阈值的规则（占位，待数据学），1.5 s 滞回，外加「操作手机」事件。
///
/// 为什么是规则而不是模型：现在一条自采数据都没有，规则的每个阈值都能解释、能单测，
/// 等自采数据到了换成离线学出来的阈值表（同一个 `CarryModeThresholds`）即可。
/// 非线程安全，由 FusionEngine / App 在同一串行队列上驱动。
public final class CarryModeClassifier {
    public var thresholds: CarryModeThresholds
    /// App 侧可选：近距离传感器（贴耳 / 口袋时为 true）。nil = 没有。
    public var proximityNear: Bool?

    public private(set) var state = CarryState(mode: .unknown, activeMode: .unknown, handled: false, tiltDeg: 0,
                                               features: CarryFeatures())
    public var mode: CarryMode { state.mode }
    public var activeMode: CarryMode { state.activeMode }
    public var tiltDeg: Double { state.tiltDeg }
    public var features: CarryFeatures { state.features }
    /// 「向上」在设备系中的单位向量（重力列 / 加速度低通）。
    private(set) var up = FusionVec3(0, 0, 1)
    private var hasUp = false

    // 样本环形缓冲（50 Hz × windowS）
    private struct Row { var t: Int64; var tiltZ: Double; var tiltY: Double; var w: FusionVec3; var yaw: Double; var aLin: Double; var aV: Double; var aH: Double; var upv: FusionVec3 }
    private var rows: [Row] = []
    private var lastT: Int64?
    private var sinceEval = 0
    private var candidate: CarryMode = .unknown
    private var candidateSince: Int64 = 0
    private var lastHandledT: Int64 = Int64.min / 2
    /// 操作手机中（到这个时刻之前不更新候选）；结束时清窗口、进入快速重判期（到 fastUntil）
    private var handlingUntil: Int64 = Int64.min / 2
    private var handlingActive = false
    private var fastUntil: Int64 = Int64.min / 2
    private var needsRedecision = false
    private var decidedAt: Int64 = 0
    private var current: CarryMode = .unknown
    private var active: CarryMode = .unknown

    public init(thresholds: CarryModeThresholds = CarryModeThresholds()) {
        self.thresholds = thresholds
    }

    public func reset() {
        state = CarryState(mode: .unknown, activeMode: .unknown, handled: false, tiltDeg: 0, features: CarryFeatures())
        up = FusionVec3(0, 0, 1); hasUp = false
        rows.removeAll(keepingCapacity: true)
        lastT = nil; sinceEval = 0
        candidate = .unknown; candidateSince = 0
        lastHandledT = Int64.min / 2
        handlingUntil = Int64.min / 2; handlingActive = false; fastUntil = Int64.min / 2
        needsRedecision = false; decidedAt = 0
        current = .unknown; active = .unknown
    }

    /// 推进一个样本。`useSampleGravity`：样本有重力列时直接用它当「向上」。
    @discardableResult
    public func process(_ s: IMUSample, useSampleGravity: Bool = true) -> CarryState {
        let a = FusionVec3(s.ax, s.ay, s.az)
        let g = FusionVec3(s.gx, s.gy, s.gz)
        guard a.norm.isFinite, g.norm.isFinite else { return state }
        var dt = 0.0
        if let l = lastT { dt = Double(s.tMs - l) / 1000 }
        lastT = s.tMs
        if dt <= 0 || dt > 1 {
            // 第一次 / 时间倒退 / 断档：重新开始
            rows.removeAll(keepingCapacity: true)
            hasUp = false
            dt = 0
        }
        // 向上方向
        if useSampleGravity, let u = s.upFromSample {
            up = u; hasUp = true
        } else if a.norm > 1 {
            if !hasUp { up = a.normalized; hasUp = true }
            else {
                let al = FusionMath.lpfAlpha(dt: dt, tau: thresholds.gravityTauS)
                let mixed = up * (1 - al) + a.normalized * al
                if mixed.norm > 1e-6 { up = mixed.normalized }
            }
        }
        guard hasUp else { return state }
        let tiltZ = FusionMath.degrees(FusionVec3(0, 0, 1).angle(to: up))
        let tiltY = FusionMath.degrees(FusionVec3(0, 1, 0).angle(to: up))
        // 线加速度（去重力）：有重力列就减它，否则减 g·up
        let grav = s.gravity.map { FusionVec3($0.x, $0.y, $0.z) } ?? up * FusionMath.gravity
        let lin = a - grav
        let aV = lin.dot(up)
        let aH = lin.horizontal(up: up).norm
        rows.append(Row(t: s.tMs, tiltZ: tiltZ, tiltY: tiltY, w: g, yaw: g.dot(up), aLin: lin.norm, aV: aV, aH: aH, upv: up))
        let winMs = Int64(thresholds.windowS * 1000)
        while let f = rows.first, s.tMs - f.t > winMs { rows.removeFirst() }

        var handled = false
        // 「操作手机」事件：每个样本都查（事件要及时）
        if s.tMs - lastHandledT >= Int64(thresholds.handledCooldownS * 1000) {
            let hw = Int64(thresholds.handledWindowS * 1000)
            var peak = 0.0
            var oldUp: FusionVec3?
            for r in rows where s.tMs - r.t <= hw {
                peak = max(peak, r.w.norm)
                if oldUp == nil { oldUp = r.upv }
            }
            if let ou = oldUp, peak >= thresholds.handledGyroPeak,
               FusionMath.degrees(ou.angle(to: up)) >= thresholds.handledTiltChangeDeg {
                handled = true
                lastHandledT = s.tMs
                handlingUntil = s.tMs + Int64(thresholds.handlingS * 1000)
                handlingActive = true
                fastUntil = handlingUntil + Int64(thresholds.fastDecideS * 1000)
            }
        }
        if handlingActive, s.tMs >= handlingUntil {
            // 手停下来了：窗口里只留之后的样本，快速重判
            rows.removeAll { $0.t < handlingUntil }
            handlingActive = false
            needsRedecision = true
            candidate = .unknown
            candidateSince = s.tMs
        }

        // 窗口统计每 5 个样本（10 Hz）算一次，够用也省电
        sinceEval += 1
        var feats = state.features
        if sinceEval >= 5 || rows.count < 5 {
            sinceEval = 0
            feats = computeFeatures(now: s.tMs)
            if !handlingActive {
                let fast = s.tMs < fastUntil
                let minSpan = fast ? thresholds.fastWindowS : thresholds.windowS * 0.9
                let filled = rows.count >= 2, span = rows.count >= 2 ? Double(s.tMs - rows[0].t) / 1000 : 0
                let now = filled && span >= minSpan ? classify(feats) : .unknown
                if now != candidate { candidate = now; candidateSince = s.tMs }
                let hold = Int64((fast ? thresholds.fastHysteresisS : thresholds.hysteresisS) * 1000)
                let settled = now == candidate && s.tMs - candidateSince >= hold && now != .unknown
                if (current == .unknown && now != .unknown) || (settled && (current != candidate || needsRedecision)) {
                    current = candidate
                    decidedAt = s.tMs
                    needsRedecision = false
                    if current.isCarryPosture { active = current }
                }
            }
        }
        feats.proximityNear = proximityNear
        state = CarryState(mode: current, activeMode: active, handled: handled, tiltDeg: tiltZ, features: feats, decidedAtMs: decidedAt)
        return state
    }

    // MARK: - 特征

    private func computeFeatures(now: Int64) -> CarryFeatures {
        var f = CarryFeatures()
        let n = Double(rows.count)
        guard rows.count >= 2 else { return f }
        var sz = 0.0, sy = 0.0, sy2 = 0.0, sw2 = 0.0, syaw2 = 0.0, sa = 0.0, sa2 = 0.0, sv = 0.0, sv2 = 0.0, sh = 0.0, sh2 = 0.0
        var ax2 = 0.0, ay2 = 0.0, az2 = 0.0
        for r in rows {
            sz += r.tiltZ; sy += r.tiltY; sy2 += r.tiltY * r.tiltY
            sw2 += r.w.dot(r.w); syaw2 += r.yaw * r.yaw
            ax2 += r.w.x * r.w.x; ay2 += r.w.y * r.w.y; az2 += r.w.z * r.w.z
            sa += r.aLin; sa2 += r.aLin * r.aLin
            sv += r.aV; sv2 += r.aV * r.aV
            sh += r.aH; sh2 += r.aH * r.aH
        }
        func sd(_ s: Double, _ s2: Double) -> Double { max(s2 / n - (s / n) * (s / n), 0).squareRoot() }
        f.tiltZDeg = sz / n
        f.tiltYDeg = sy / n
        f.tiltYStdDeg = sd(sy, sy2)
        f.gyroRms = (sw2 / n).squareRoot()
        f.yawRateRms = (syaw2 / n).squareRoot()
        f.axisConcentration = sw2 > 1e-9 ? max(ax2, ay2, az2) / sw2 : 0
        f.accelStd = sd(sa, sa2)
        f.vertAccelStd = sd(sv, sv2)
        f.horizAccelStd = sd(sh, sh2)
        // 步频：竖直线加速度的正向过零次数
        var crossings = 0
        for i in 1..<rows.count where rows[i - 1].aV < 0 && rows[i].aV >= 0 { crossings += 1 }
        let span = Double(rows[rows.count - 1].t - rows[0].t) / 1000
        if span > 0.5, f.vertAccelStd > 0.5 {
            let fs = Double(crossings) / span
            if fs >= 1.0, fs <= 3.5 {
                f.stepFreqHz = fs
                // 两点 DFT：偏航率在 fs/2 与 fs 上的能量比
                func energy(_ hz: Double) -> Double {
                    var re = 0.0, im = 0.0
                    for r in rows {
                        let ph = 2 * Double.pi * hz * Double(r.t - rows[0].t) / 1000
                        re += r.yaw * cos(ph); im += r.yaw * sin(ph)
                    }
                    return re * re + im * im
                }
                let e1 = energy(fs / 2), e2 = energy(fs)
                f.strideRatio = e1 / max(e2, 1e-9)
            }
        }
        return f
    }

    // MARK: - 规则（占位，待数据学）

    func classify(_ f: CarryFeatures) -> CarryMode {
        let t = thresholds
        if f.accelStd < t.stillAccelStd && f.gyroRms < t.stillGyroRms { return .still }
        let vertical = f.tiltZDeg >= t.verticalTiltZMin && f.tiltZDeg <= t.verticalTiltZMax
        let hanging = f.tiltYDeg >= t.hangingTiltYMin
        if f.gyroRms >= t.movingGyroRms {
            // 转得多：口袋（大、单轴、吊着 / 竖着）、摆臂（很大、多轴）、否则包里晃
            let pocketLike = f.gyroRms >= t.pocketGyroRms && f.axisConcentration >= t.pocketAxisConcentration && (hanging || vertical)
            if pocketLike { return .pocket }
            if f.gyroRms >= t.swingGyroRms { return .swinging }
            if hanging && f.strideRatio >= t.swingStrideRatio { return .swinging }
            return .bag
        }
        // 转得少：手持几何，或者包里颠
        if f.accelStd >= t.bagAccelStdMin { return .bag }
        if f.tiltZDeg < t.textingTiltZMax { return .texting }
        if vertical {
            // 竖持（AR 姿势，δ ≈ 0）和贴耳通话（δ ≈ ±90°）在重力系里只差长轴倾斜，分错的代价不对称
            // （把通话当竖持会用 δ ≈ 0 的紧先验，错 90°），所以近距离传感器说「贴着」一律算通话，
            // 没有近距离传感器时靠长轴倾斜的占位阈值
            if proximityNear == true { return .calling }
            if f.tiltYDeg <= t.uprightTiltYMax { return .upright }
            if f.tiltYDeg >= t.callingTiltYMin && f.tiltYDeg <= t.callingTiltYMax && proximityNear != false { return .calling }
            return .bag
        }
        return .bag
    }
}
