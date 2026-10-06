import Foundation

/// 姿态 / 航向估计：Mahony 风格互补滤波，但只维护真正需要的两个自由度。
///
/// 技术组成（均为公开发表的标准做法）：
/// 1. **重力方向互补滤波**：维护「世界竖直向上」在机体系中的单位向量 `up`。
///    陀螺预测用世界固定向量在旋转机体系中的运动学 `u̇ = −ω × u`；
///    加速度计给出观测 `â`（本仓库约定：平放时 a ≈ (0,0,+9.81)，即加速度方向即世界向上），
///    按增益 `kpGravity` 做一阶互补混合。等价于 Mahony 滤波限制在 roll/pitch 两个自由度上。
/// 2. **倾斜补偿磁罗盘**：用 `up` 把磁场和「前向轴」都投影到水平面，
///    两者在水平面内的有向夹角即罗盘方位角 ψ（正北起顺时针为正）。
///    全部在机体系内闭式计算，不需要先知道偏航角，避免了循环依赖。
/// 3. **偏航角互补滤波**：θ̇ = ω·up（角速度的竖直分量）积分，叠加向磁罗盘目标值的慢速牵引。
/// 4. **静止期陀螺零偏估计**：静止判据成立时对原始陀螺做慢 EMA。
///
/// 为什么不用四元数 Madgwick：这里只需要「重力方向 + 偏航」，
/// 这个分解形式让偏航修正天然只作用在偏航上（磁干扰不会污染 roll/pitch），而且数值上更难写错。
///
/// 线程约定：非线程安全，由 FusionEngine 在同一串行队列上驱动。
final class FusionAttitudeFilter {

    // MARK: - 可调常量（每个都注明取值理由）

    /// 重力方向互补滤波增益（1/s）。1.0 → 时间常数约 1 s：
    /// 快到能跟上手持姿态变化，慢到能平掉单步落地冲击（冲击持续约 0.1 s）。
    private let kpGravity: Double = 1.0
    /// 加速度模长相对 g 的允许偏差。超过 25% 说明处于明显动态加速，
    /// 此时加速度不再近似重力方向，跳过修正（经典 "accelerometer gating"）。
    private let accelGateRel: Double = 0.25

    /// 磁航向互补滤波增益（1/s）。0.1 → 时间常数 10 s：
    /// 慢到店内铁货架造成的局部畸变（通常持续 1–3 s）带不偏航向，
    /// 快到能压住 MEMS 陀螺 ~1°/s 的残余漂移（平衡误差 ≈ 漂移率 × 10 s）。
    private let kpMag: Double = 0.1
    /// 转弯期间的磁航向增益（1/s）。转弯时磁场读数相位滞后 + 形变最大，几乎只信陀螺。
    private let kpMagTurning: Double = 0.005
    /// 「正在转弯」的竖直角速度阈值（rad/s）≈ 20°/s。正常直行时竖直角速度通常 < 10°/s。
    private let turnRateThresh: Double = 0.35

    /// 磁场模长可信区间（µT）。地球磁场 25–65 µT，上界放到 70 留余量；
    /// 越界即判为硬铁/强干扰（金属货架、电机、磁扣），直接丢弃该次磁观测。
    private let magMinUT: Double = 25.0
    private let magMaxUT: Double = 70.0
    /// 磁场水平分量下限（µT）。太小说明接近「磁场竖直」的奇异姿态，方位角无意义。
    private let magHorizMinUT: Double = 2.0

    /// 前向轴水平投影模长下限。低于此值该轴接近竖直，方位角无意义。
    private let forwardHorizMin: Double = 0.2
    /// 机体 +y 轴与竖直方向夹角小于 30°（|y·up| > cos30° = 0.866）时，
    /// 改用 −z（屏幕法线的反向）作为前向轴 —— 对应「竖持手机」的姿态。
    private let uprightDot: Double = 0.866

    /// 初始航向估计窗口（样本数）。50 Hz 下 20 个样本 = 0.4 s，
    /// 足够平掉磁计噪声，又不至于让用户等太久才出第一帧定位。
    private let initSamples: Int = 20
    /// 初始化超时（样本数）。150 ≈ 3 s；磁场一直不可信就用兜底航向，避免永远不初始化。
    private let initTimeoutSamples: Int = 150

    /// 静止判据：|a| 与 g 的偏差上限（m/s²）和陀螺模长上限（rad/s）。
    /// 0.35 / 0.08 是手持静置时的典型噪声上包络。
    private let stillAccelTol: Double = 0.35
    private let stillGyroTol: Double = 0.08
    /// 连续满足静止判据的样本数（25 = 0.5 s）才开始更新零偏，避免步间短暂静止被误用。
    private let stillSamplesForBias: Int = 25
    /// 零偏 EMA 系数。0.02 @50 Hz → 时间常数 1 s（在已经确认静止的前提下可以快一些）。
    private let biasBeta: Double = 0.02

    // MARK: - 状态

    /// 世界竖直向上方向在机体系中的单位向量。
    private(set) var up = FusionVec3(0, 0, 1)
    /// 陀螺零偏（rad/s，机体系）。
    private(set) var gyroBias = FusionVec3.zero
    /// 地图航向（rad，[0, 2π)，0 = 地图 +y）。
    private(set) var theta: Double = 0
    /// 航向是否已经完成绝对初始化。
    private(set) var headingReady: Bool = false
    /// 最近一次的竖直角速度（rad/s，逆时针为正）。
    private(set) var omegaUp: Double = 0
    /// 最近一次的磁罗盘方位角（rad）；不可用时为 nil。
    private(set) var lastMagBearing: Double?

    private var hasUp = false
    private var usingYForward = true
    private var sampleCount = 0
    private var stillCount = 0
    /// 初始化窗口里对 ψ 的单位向量累加（避免 ±π 处的环绕问题）。
    private var initCos: Double = 0
    private var initSin: Double = 0
    private var initCount = 0

    // MARK: - 接口

    /// 由调用方直接给定航向（setInitialPosition 带 headingRad 时），立即视为已初始化。
    func setHeading(_ h: Double) {
        theta = FusionMath.wrapTwoPi(h)
        headingReady = true
    }

    func reset() {
        up = FusionVec3(0, 0, 1)
        gyroBias = .zero
        theta = 0
        headingReady = false
        omegaUp = 0
        lastMagBearing = nil
        hasUp = false
        usingYForward = true
        sampleCount = 0
        stillCount = 0
        initCos = 0
        initSin = 0
        initCount = 0
    }

    /// 推进一个样本。
    /// - Parameters:
    ///   - dt: 距上一样本的时间（s），已由调用方限幅。
    ///   - declinationRad: 地图 +y 轴的磁罗盘方位角（rad）。
    ///   - fallbackHeading: 磁场长期不可信时的兜底航向（rad）；nil 则用 0。
    ///   - useMagnetic: false 时航向只靠陀螺积分，罗盘只用于「尚未初始化」时的自动初始化。
    func update(sample s: IMUSample, dt: Double, declinationRad: Double, fallbackHeading: Double?,
                useMagnetic: Bool = true) {
        let a = FusionVec3(s.ax, s.ay, s.az)
        let m = FusionVec3(s.mx, s.my, s.mz)
        let gRaw = FusionVec3(s.gx, s.gy, s.gz)
        sampleCount += 1

        let aNorm = a.norm
        if !hasUp {
            up = aNorm > 1.0 ? a.normalized : FusionVec3(0, 0, 1)
            hasUp = true
        }

        // --- 1) 静止期陀螺零偏估计 ---
        let stationary = abs(aNorm - FusionMath.gravity) < stillAccelTol && gRaw.norm < stillGyroTol
        stillCount = stationary ? stillCount + 1 : 0
        if stillCount >= stillSamplesForBias {
            gyroBias = gyroBias * (1.0 - biasBeta) + gRaw * biasBeta
        }
        let w = gRaw - gyroBias

        // --- 2) 重力方向互补滤波 ---
        // 陀螺预测：世界固定向量在机体系中 u̇ = −ω × u
        var u = up - w.cross(up) * dt
        u = u.norm > 1e-9 ? u.normalized : up
        // 加速度修正（带动态门限）
        if aNorm > 1e-6 && abs(aNorm - FusionMath.gravity) / FusionMath.gravity < accelGateRel {
            let gain = min(kpGravity * dt, 0.5)
            let mixed = u * (1.0 - gain) + a.normalized * gain
            if mixed.norm > 1e-9 { u = mixed.normalized }
        }
        up = u

        // --- 3) 前向轴选择（姿态自适应）---
        let yAxis = FusionVec3(0, 1, 0)
        let zBack = FusionVec3(0, 0, -1)
        let wantY = abs(yAxis.dot(up)) < uprightDot
        if wantY != usingYForward {
            // 切换前向轴会带来一个确定的方位角跳变，用几何关系精确补偿，不依赖磁场。
            let oldH = horizontalPart(usingYForward ? yAxis : zBack)
            let newH = horizontalPart(wantY ? yAxis : zBack)
            if oldH.norm > forwardHorizMin && newH.norm > forwardHorizMin {
                // oldH → newH 绕 up 的逆时针夹角；θ 以逆时针为正，直接相加。
                theta = FusionMath.wrapTwoPi(theta + atan2(oldH.cross(newH).dot(up), oldH.dot(newH)))
            }
            usingYForward = wantY
        }
        let forward = usingYForward ? yAxis : zBack

        // --- 4) 偏航角：陀螺竖直分量积分 ---
        omegaUp = w.dot(up)
        theta = FusionMath.wrapTwoPi(theta + omegaUp * dt)

        // --- 5) 倾斜补偿磁罗盘修正 ---
        let psi = magneticBearing(m: m, forward: forward)
        lastMagBearing = psi
        if let psi = psi {
            if headingReady {
                if useMagnetic {
                    let target = declinationRad - psi
                    let kp = abs(omegaUp) > turnRateThresh ? kpMagTurning : kpMag
                    let err = FusionMath.wrapPi(target - theta)
                    theta = FusionMath.wrapTwoPi(theta + min(kp * dt, 0.5) * err)
                }
            } else {
                initCos += cos(psi)
                initSin += sin(psi)
                initCount += 1
                if initCount >= initSamples {
                    let psiMean = atan2(initSin, initCos)
                    theta = FusionMath.wrapTwoPi(declinationRad - psiMean)
                    headingReady = true
                }
            }
        }

        if !headingReady && sampleCount >= initTimeoutSamples {
            // 磁场长期不可信：退化为「相对航向」，绝对基准由调用方兜底。
            theta = FusionMath.wrapTwoPi(fallbackHeading ?? 0)
            headingReady = true
        }
    }

    // MARK: - 内部

    /// 把机体系向量去掉竖直分量（投影到水平面），结果仍在机体系中表示。
    private func horizontalPart(_ v: FusionVec3) -> FusionVec3 {
        v - up * v.dot(up)
    }

    /// 倾斜补偿罗盘方位角 ψ：前向轴相对磁北的夹角，正北起**顺时针**为正。
    /// 不可信（硬铁/干扰/奇异姿态）时返回 nil。
    private func magneticBearing(m: FusionVec3, forward: FusionVec3) -> Double? {
        let mn = m.norm
        guard mn >= magMinUT && mn <= magMaxUT else { return nil }
        let mh = horizontalPart(m)
        guard mh.norm > magHorizMinUT else { return nil }
        let fh = horizontalPart(forward)
        guard fh.norm > forwardHorizMin else { return nil }
        // mh → fh 绕 up 的逆时针夹角；罗盘方位角顺时针为正，取反。
        let ccw = atan2(mh.cross(fh).dot(up), mh.dot(fh))
        guard ccw.isFinite else { return nil }
        return -ccw
    }
}
