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
//   例如场地地图的 +y 指向磁北偏东 30°，就填 30。调用方负责提供。
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
    /// 格式 v4 的 `gvx,gvy,gvz`：系统（陀螺辅助）给出的重力方向，m/s²，**Android 约定**（平放屏幕朝上 ≈ (0, 0, +9.81)，
    /// 即和静止时的加速度读数同向；iOS 端 CoreMotion 的 gravity 要取负）。老数据没有这几列时为 nil，
    /// 姿态滤波 / 地磁特征退回加速度低通。
    public var gravity: (x: Double, y: Double, z: Double)?
    /// 格式 v4 的 `qw,qx,qy,qz`：姿态四元数，设备系 → 世界系（世界 z 向上，偏航任意），Android `TYPE_ROTATION_VECTOR` 约定。
    /// 只在 v4 文件里才当真（v3 的实时定位页写的是占位 1,0,0,0）。目前只用来在没有重力列时推「向上」方向，
    /// 偏航一律不用（iOS 的参考系换算还没在真机上核对过）。
    public var attitude: (w: Double, x: Double, y: Double, z: Double)?

    public init(tMs: Int64,
                ax: Double, ay: Double, az: Double,
                gx: Double, gy: Double, gz: Double,
                mx: Double, my: Double, mz: Double) {
        self.tMs = tMs
        self.ax = ax; self.ay = ay; self.az = az
        self.gx = gx; self.gy = gy; self.gz = gz
        self.mx = mx; self.my = my; self.mz = mz
        self.gravity = nil
        self.attitude = nil
    }

    public init(tMs: Int64,
                ax: Double, ay: Double, az: Double,
                gx: Double, gy: Double, gz: Double,
                mx: Double, my: Double, mz: Double,
                gravity: (x: Double, y: Double, z: Double)?,
                attitude: (w: Double, x: Double, y: Double, z: Double)? = nil) {
        self.init(tMs: tMs, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz, mx: mx, my: my, mz: mz)
        self.gravity = gravity
        self.attitude = attitude
    }

    /// 读 `imu.csv` 的一行（已按逗号切开，含表头顺序 `t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg[,gvx,gvy,gvz]`）。
    /// 列数 ≥ 19 视为格式 v4：重力列模长在 5～15 m/s² 之间才用（0 = 当时不可用），四元数模长接近 1 才用；
    /// v3（16 列）的四元数是占位值，不读。前 10 列不全时返回 nil。
    public static func fromCSV<S: StringProtocol>(_ r: [S]) -> IMUSample? {
        guard r.count >= 10, let t = Int64(r[0]) else { return nil }
        let v = r[1...9].map { Double($0) ?? 0 }
        var s = IMUSample(tMs: t, ax: v[0], ay: v[1], az: v[2], gx: v[3], gy: v[4], gz: v[5], mx: v[6], my: v[7], mz: v[8])
        guard r.count >= 19 else { return s }
        if let gx = Double(r[16]), let gy = Double(r[17]), let gz = Double(r[18]) {
            let n = (gx * gx + gy * gy + gz * gz).squareRoot()
            if n.isFinite, n > 5, n < 15 { s.gravity = (gx, gy, gz) }
        }
        if let w = Double(r[11]), let x = Double(r[12]), let y = Double(r[13]), let z = Double(r[14]) {
            let n = (w * w + x * x + y * y + z * z).squareRoot()
            if n.isFinite, abs(n - 1) < 0.1 { s.attitude = (w / n, x / n, y / n, z / n) }
        }
        return s
    }

    /// 「向上」在设备系中的单位向量：优先重力列，其次四元数，都没有则 nil（调用方退回加速度低通）。
    var upFromSample: FusionVec3? {
        if let g = gravity {
            let v = FusionVec3(g.x, g.y, g.z)
            if v.norm > 1 { return v.normalized }
        }
        if let q = attitude { return FusionMath.upFromQuaternion(w: q.w, x: q.x, y: q.y, z: q.z) }
        return nil
    }
}

/// 融合引擎的外部可调参数。单位见各字段注释。
public struct FusionConfig {
    /// 地图 +y 轴相对磁北的方位角（度，顺时针为正）。由调用方提供。
    public var magneticDeclinationDeg: Double = 0
    /// 通道约束时在通道边缘内侧预留的安全距离（cm）。
    public var corridorMarginCm: Double = 30
    /// 是否用磁罗盘持续修正航向。室内钢结构附近罗盘常偏几十度，手动设航向时建议关闭，只靠陀螺。
    public var useMagneticHeading: Bool = true
    /// 步长整体缩放（默认 1）。用计步器的距离校正步长时，由调用方调整。
    public var stepLengthScale: Double = 1
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
    /// 携带无关的运动模型（携带模式分类、分模式步长 / 航向噪声、摆臂步幅平均、重力列）。
    /// 默认 `enabled = false`：引擎行为和以前完全一样。见 `CarryMotionConfig`。
    public var motion = CarryMotionConfig()

    public init() {}
}

/// 携带无关运动模型的开关和参数。全部默认关 / 占位，打开后才改变引擎行为。
public struct CarryMotionConfig {
    /// 总开关。false = 原有行为（前向轴航向、单一 K、固定计步阈值、不跑分类器、不用重力列）。
    public var enabled = false
    /// 样本里有重力列（格式 v4）时，姿态滤波和「向上」方向直接用它（CoreMotion 的 gravity 是陀螺辅助的，
    /// 摆臂时比加速度低通稳得多）；没有时照旧互补滤波。
    public var useSampleGravity = true
    /// 引擎内部跑 `CarryModeClassifier`。false = 携带模式由外部（App 带近距离传感器的分类）用 `FusionEngine.setCarryMode` 给。
    public var internalClassifier = true
    /// 分类器阈值（占位，待自采 iPhone 双机数据标定）。
    public var thresholds = CarryModeThresholds()
    /// 分模式参数表（占位，待自采 iPhone 双机数据标定）。
    public var table = CarryMotionTable.placeholder
    /// 计步：自适应阈值 + 步频锁（`StepDetectorTuning`）。false = 原有固定阈值。
    public var adaptiveStepDetection = true
    public var stepTuning = StepDetectorTuning()
    /// 表里标了 `strideAverageHeading` 的模式（摆臂 / 口袋）用一个步幅周期的滑动圆平均航向推步，而不是步事件瞬间的航向。
    public var strideAverageHeading = true
    /// 「操作手机」事件（陀螺突增 + 倾角大变）也上报：粒子滤波立刻把航向偏差撒开 `handledSpreadDeg`（nil = 整圆）。
    /// 默认整圆：手机被大幅转过之后夹角 δ 就是未知的（陀螺偏航积分对大幅翻转不保几何，实测 texting→pocket 之后引擎航向
    /// 偏了 90° 而不是口袋几何的 35°），只撒 30° 的话等分类器 2～3 s 后判出新模式时粒子已经全走偏、顶在墙上，
    /// 这时再整圆重撒位置已经错了几米，磁场在走廊里分不出「落后几米」和「走反」。整圆撒开让一部分粒子一直跟着真位置走，
    /// 其余被墙 / 磁场淘汰；分类器判出新模式后再按该模式的先验重撒一次（texting / upright 收紧到 15°）。
    public var reportHandledEvents = true
    public var handledSpreadDeg: Double? = nil

    public init() {}
}

/// 携带模式事件（`FusionEngine.onCarryEvent`）。`MagneticLocalizer.apply(_:)` 直接吃它。
public struct CarryMotionEvent {
    public enum Kind {
        /// 第一次判出携带姿态：只切分模式参数，不重撒（起点先验还有效）
        case initial
        /// 携带姿态变了：按新模式的先验重撒航向偏差 / 步长比例
        case changed
        /// 「操作手机」（1 s 内陀螺突增且倾角变化很大）：在当前偏差附近撒开
        case handled
    }
    public var tMs: Int64
    public var kind: Kind
    /// 事件前后的「携带姿态」（不含 still / unknown）。
    public var from: CarryMode
    public var to: CarryMode
    /// 粒子航向偏差该怎么重撒：1σ（度，nil = 整圆均匀）、先验中心（度，多个 = 多峰）、是否保留原偏差只在附近撒开。
    public var headingSpreadDeg: Double?
    public var headingCentersDeg: [Double]
    public var keepBias: Bool
    public var initialScaleSigma: Double
    /// 重撒之后走这么远（cm）不判丢
    public var lostSuppressCm: Double
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
    /// 当前携带模式（`FusionConfig.motion.enabled` 时才有，否则 `.unknown`）。
    public var carryMode: CarryMode

    public init(tMs: Int64, position: Point2, headingRad: Double, headingDeg: Double,
                stepDetected: Bool, stepLengthM: Double, stepCount: Int,
                uncertaintyCm: Double, wasConstrained: Bool, isMoving: Bool,
                carryMode: CarryMode = .unknown) {
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
        self.carryMode = carryMode
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

    /// 与另一个向量的夹角（rad，0…π）；任一为零向量时返回 0。
    func angle(to b: FusionVec3) -> Double {
        let d = norm * b.norm
        guard d > 1e-12 else { return 0 }
        return acos(FusionMath.clamp(dot(b) / d, -1, 1))
    }

    /// 去掉沿单位向量 `up` 的分量（投影到与 up 垂直的平面）。
    func horizontal(up: FusionVec3) -> FusionVec3 { self - up * dot(up) }
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

    /// 绕 `up` 从 a 的水平投影转到 b 的水平投影的有向夹角（rad，逆时针为正，与 θ 同向）。
    /// 任一投影太短（接近竖直）时返回 nil。
    static func horizontalAngle(from a: FusionVec3, to b: FusionVec3, up: FusionVec3, minHoriz: Double = 0.2) -> Double? {
        let ah = a.horizontal(up: up), bh = b.horizontal(up: up)
        guard ah.norm > minHoriz, bh.norm > minHoriz else { return nil }
        let v = atan2(ah.cross(bh).dot(up), ah.dot(bh))
        return v.isFinite ? v : nil
    }

    /// 世界「向上」(0,0,1) 在设备系中的方向。四元数 q 为设备系 → 世界系（v_world = q·v_dev·q*，Android 旋转向量约定），
    /// 那么 v_dev = Rᵀ·(0,0,1) = R 的第三行。
    static func upFromQuaternion(w: Double, x: Double, y: Double, z: Double) -> FusionVec3? {
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        guard n.isFinite, n > 1e-6 else { return nil }
        let (w, x, y, z) = (w / n, x / n, y / n, z / n)
        let v = FusionVec3(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y))
        return v.norm > 0.5 ? v.normalized : nil
    }

    /// 一组角度（rad）的加权圆平均；权重和为 0 时返回 nil。
    static func circularMean(_ angles: [Double], weights: [Double]? = nil) -> Double? {
        var s = 0.0, c = 0.0, w = 0.0
        for (i, a) in angles.enumerated() {
            let wi = weights.map { i < $0.count ? $0[i] : 0 } ?? 1
            s += wi * sin(a); c += wi * cos(a); w += wi
        }
        guard w > 0, (s * s + c * c).squareRoot() > 1e-9 * w else { return nil }
        return wrapTwoPi(atan2(s, c))
    }
}
