import Foundation

// MARK: - 坐标与单位约定（整个 Fusion 模块通用）
//
// 【单位】公开 API 一律用厘米（与仓库其他部分、StoreMap / Point2 一致）；
//        引擎内部状态用米和弧度，只在 updateFix / setInitialPosition / FusionOutput 边界换算。
//
// 【地图系】Point2 的 x 向右、y 向下（见 Models/Geometry.swift）。
//
// 【航向 headingRad】
//   - 0 表示朝向地图 +y 轴；
//   - dx = L·sin θ，dy = L·cos θ（θ = 90° 即朝向地图 +x 轴）；
//   - 因为地图 y 轴向下，这个旋转方向在真实世界俯视图里是「逆时针」，
//     所以 θ̇ = +ω_up（ω_up 为角速度在竖直向上方向的分量，右手系逆时针为正）；
//   - 与罗盘方位角 ψ（正北起顺时针为正）的关系：θ = declination − ψ。
//
// 【magneticDeclinationDeg】定义为「地图 +y 轴的磁罗盘方位角（度，顺时针）」。
//   例如门店地图的 +y 指向磁北偏东 30°，就填 30。调用方负责提供。
//
// 【输出范围】headingRad ∈ [0, 2π)，headingDeg ∈ [0, 360)。

/// 一条归一化后的 IMU 样本。列定义与 `docs/data-format.md` 的 `imu.csv` 完全一致
/// （Android 传感器约定：手机屏幕朝上平放时 az ≈ +9.81；陀螺 rad/s 右手系；磁场 µT 已校准）。
public struct IMUSample {
    /// Unix 毫秒（UTC）。
    public var tMs: Int64
    /// 加速度 m/s²，含重力。
    public var ax, ay, az: Double
    /// 角速度 rad/s。
    public var gx, gy, gz: Double
    /// 磁场 µT。
    public var mx, my, mz: Double

    public init(tMs: Int64,
                ax: Double, ay: Double, az: Double,
                gx: Double, gy: Double, gz: Double,
                mx: Double, my: Double, mz: Double) {
        self.tMs = tMs
        self.ax = ax; self.ay = ay; self.az = az
        self.gx = gx; self.gy = gy; self.gz = gz
        self.mx = mx; self.my = my; self.mz = mz
    }
}

/// 融合引擎的外部可调参数。单位见各字段注释。
public struct FusionConfig {
    /// 地图 +y 轴相对磁北的方位角（度，顺时针为正）。由调用方提供。
    public var magneticDeclinationDeg: Double = 0
    /// 通道约束时在通道边缘内侧预留的安全距离（cm）。
    public var corridorMarginCm: Double = 30
    /// 是否启用通道约束。
    public var useCorridorConstraint: Bool = true
    /// confidence = 1 时单次定位结果的 1σ 误差（cm）。
    public var fixNoiseCm: Double = 200
    /// 单步步长上限（m）。
    public var maxStepLengthM: Double = 1.0
    /// 两步之间的最小时间间隔（ms）。250 ms → 最高 4 步/s，高于人类正常步频上限。
    public var minStepIntervalMs: Int64 = 250
    /// 输出节拍（ms）。340 ms ≈ 3 Hz。
    public var outputIntervalMs: Int64 = 340

    public init() {}
}

/// 一帧融合输出。
public struct FusionOutput {
    /// 产生这帧输出的 IMU 样本时间戳（Unix ms）。
    public var tMs: Int64
    /// 位置，单位 **厘米**，地图系。
    public var position: Point2
    /// 航向，弧度，地图系，0 = +y 轴（详见本文件顶部的约定说明）。范围 [0, 2π)。
    public var headingRad: Double
    /// 同上，单位度，范围 [0, 360)。
    public var headingDeg: Double
    /// 距上一帧输出以来是否检出过脚步（输出 3 Hz 低于步频，所以是「区间内有无」）。
    public var stepDetected: Bool
    /// 最近一步的平滑步长（m）；还没检出过步时为 0。
    public var stepLengthM: Double
    /// 累计步数。
    public var stepCount: Int
    /// 位置 1σ 不确定度（cm），取 EKF 位置协方差两个对角元的均方根。
    public var uncertaintyCm: Double
    /// 本帧通道约束是否真的移动了点。
    public var wasConstrained: Bool
    /// 运动检测结果（加速度动态分量在 1 s 窗内的方差超阈值）。
    public var isMoving: Bool

    public init(tMs: Int64, position: Point2, headingRad: Double, headingDeg: Double,
                stepDetected: Bool, stepLengthM: Double, stepCount: Int,
                uncertaintyCm: Double, wasConstrained: Bool, isMoving: Bool) {
        self.tMs = tMs
        self.position = position
        self.headingRad = headingRad
        self.headingDeg = headingDeg
        self.stepDetected = stepDetected
        self.stepLengthM = stepLengthM
        self.stepCount = stepCount
        self.uncertaintyCm = uncertaintyCm
        self.wasConstrained = wasConstrained
        self.isMoving = isMoving
    }
}

// MARK: - 内部数学工具

/// 三维向量。不用 simd，纯 Double。
struct FusionVec3 {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    static let zero = FusionVec3(0, 0, 0)

    static func + (a: FusionVec3, b: FusionVec3) -> FusionVec3 {
        FusionVec3(a.x + b.x, a.y + b.y, a.z + b.z)
    }
    static func - (a: FusionVec3, b: FusionVec3) -> FusionVec3 {
        FusionVec3(a.x - b.x, a.y - b.y, a.z - b.z)
    }
    static func * (a: FusionVec3, k: Double) -> FusionVec3 {
        FusionVec3(a.x * k, a.y * k, a.z * k)
    }

    var norm: Double { (x * x + y * y + z * z).squareRoot() }

    func dot(_ b: FusionVec3) -> Double { x * b.x + y * b.y + z * b.z }

    func cross(_ b: FusionVec3) -> FusionVec3 {
        FusionVec3(y * b.z - z * b.y,
                   z * b.x - x * b.z,
                   x * b.y - y * b.x)
    }

    /// 单位化；模长过小时返回零向量（不崩、不产生 NaN）。
    var normalized: FusionVec3 {
        let n = norm
        return n > 1e-12 ? self * (1.0 / n) : FusionVec3.zero
    }
}

/// 角度/数值工具。模块内不允许自由函数，统一挂在这个 enum 上。
enum FusionMath {
    static let gravity: Double = 9.80665

    /// 规范化到 (−π, π]。
    static func wrapPi(_ a: Double) -> Double {
        guard a.isFinite else { return 0 }
        let twoPi = 2.0 * Double.pi
        var x = a.remainder(dividingBy: twoPi)   // [−π, π]
        if x > Double.pi { x -= twoPi }
        if x <= -Double.pi { x += twoPi }
        return x
    }

    /// 规范化到 [0, 2π)。
    static func wrapTwoPi(_ a: Double) -> Double {
        guard a.isFinite else { return 0 }
        let twoPi = 2.0 * Double.pi
        var x = a.truncatingRemainder(dividingBy: twoPi)
        if x < 0 { x += twoPi }
        if x >= twoPi { x -= twoPi }
        return x
    }

    static func degrees(_ r: Double) -> Double { r * 180.0 / Double.pi }
    static func radians(_ d: Double) -> Double { d * Double.pi / 180.0 }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        if v < lo { return lo }
        if v > hi { return hi }
        return v
    }

    /// 单极点低通的一步系数：alpha = dt / (tau + dt)。
    static func lpfAlpha(dt: Double, tau: Double) -> Double {
        let d = max(dt, 0.0)
        let t = max(tau, 1e-6)
        return d / (t + d)
    }
}
