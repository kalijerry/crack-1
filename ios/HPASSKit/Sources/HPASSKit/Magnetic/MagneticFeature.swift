import Foundation

/// 与手机朝向、航向无关的三个磁场特征（单位 µT）。
public struct MagneticFeature: Equatable {
    /// 总强度 |B|。
    public var total: Double
    /// 沿重力方向（向上）的分量 Bz。
    public var vertical: Double
    /// 水平分量大小 Bh = √(|B|² − Bz²)。
    public var horizontal: Double

    public init(total: Double, vertical: Double, horizontal: Double) {
        self.total = total
        self.vertical = vertical
        self.horizontal = horizontal
    }

    static func + (a: MagneticFeature, b: MagneticFeature) -> MagneticFeature {
        MagneticFeature(total: a.total + b.total, vertical: a.vertical + b.vertical, horizontal: a.horizontal + b.horizontal)
    }

    static func - (a: MagneticFeature, b: MagneticFeature) -> MagneticFeature {
        MagneticFeature(total: a.total - b.total, vertical: a.vertical - b.vertical, horizontal: a.horizontal - b.horizontal)
    }

    static func * (a: MagneticFeature, k: Double) -> MagneticFeature {
        MagneticFeature(total: a.total * k, vertical: a.vertical * k, horizontal: a.horizontal * k)
    }
}

/// 从 IMU 样本提取旋转不变的磁场特征。
///
/// 「向上」方向：
/// - 样本带重力列 / 四元数（格式 v4，`useSampleGravity`）时直接用它。CoreMotion 的 gravity 是陀螺辅助的，摆臂时手的
///   离心加速度不会把它带偏（加速度低通会偏几十度，Bz 差 10～20 µT，而 Bz 是跟踪档权重最高的特征）；
/// - 外部（FusionEngine 的姿态滤波）给的 `setUp`；
/// - 都没有时退回加速度（含重力，Android 约定下静止时指向上方）的低通方向，和以前一样。
/// 所以 Bz 只依赖倾角，不依赖航向。输出再做一次低通，压掉走路时的抖动。
/// 非线程安全，与其他 HPASSKit 对象一样要在同一串行队列上使用。
public final class MagneticFeatureExtractor {
    /// 重力方向低通时间常数（s）（只在退回加速度时用）。
    public var gravityTauS: Double = 0.5
    /// 特征低通时间常数（s）。太大会让读数滞后（0.25 s 在 1.1 m/s 下就是 30 cm），建图是不滞后的，两边对不上。
    public var featureTauS: Double = 0.1
    /// 样本自带重力列 / 四元数时直接用它当「向上」（没有这几列的老数据不受影响）。
    public var useSampleGravity = true

    private var up: FusionVec3?
    private var smoothed: MagneticFeature?
    private var lastTMs: Int64?
    /// 最近一次「向上」是不是外部 / 样本给的（不是加速度低通）。
    public private(set) var upIsExternal = false

    public init() {}

    public func reset() {
        up = nil
        smoothed = nil
        lastTMs = nil
        gravityT = nil
        upIsExternal = false
    }

    /// 外部给「向上」方向（设备系，任意模长；例如 FusionEngine 姿态滤波的 up），之后的特征都用它，直到下一次 setUp /
    /// 样本重力列覆盖。和实时定位页 raw 模式一样：磁场按原始磁力计的时刻送进来，向上方向用最近一次的。
    public func setUp(_ u: (Double, Double, Double), tMs: Int64) {
        let v = FusionVec3(u.0, u.1, u.2)
        guard v.norm > 1e-6, v.norm.isFinite else { return }
        up = v.normalized
        upIsExternal = true
        gravityT = tMs
    }

    /// 只更新重力方向（用加速度，或样本自带的重力列），不出特征。磁场来自别处（比如原始磁力计）时，先用它更新「向上」方向。
    public func updateGravity(_ s: IMUSample) {
        if useSampleGravity, let su = s.upFromSample {
            up = su
            upIsExternal = true
            gravityT = s.tMs
            return
        }
        let a = FusionVec3(s.ax, s.ay, s.az)
        guard a.norm.isFinite, a.norm > 1.0 else { return }
        var dt = 0.0
        if let last = gravityT { dt = Double(s.tMs - last) / 1000.0 }
        gravityT = s.tMs
        if dt <= 0 || dt > 1.0 || upIsExternal { up = a; upIsExternal = false; return }
        let ag = FusionMath.lpfAlpha(dt: dt, tau: gravityTauS)
        up = up.map { $0 * (1 - ag) + a * ag } ?? a
    }
    private var gravityT: Int64?

    /// 用当前的重力方向，把一个磁场读数（设备坐标系，µT）变成特征。要先调用过 `updateGravity` / `setUp`。
    public func process(magnetic m3: (Double, Double, Double), tMs: Int64) -> MagneticFeature? {
        let m = FusionVec3(m3.0, m3.1, m3.2)
        guard let u = up, m.norm.isFinite, m.norm > 1.0 else { return smoothed }
        let un = u.normalized
        guard un.norm > 0.5 else { return smoothed }
        var dt = 0.0
        if let last = lastTMs { dt = Double(tMs - last) / 1000.0 }
        lastTMs = tMs
        let b = m.norm
        let bz = m.dot(un)
        let raw = MagneticFeature(total: b, vertical: bz, horizontal: (max(b * b - bz * bz, 0)).squareRoot())
        if let prev = smoothed, dt > 0, dt <= 1.0 {
            let af = FusionMath.lpfAlpha(dt: dt, tau: featureTauS)
            smoothed = prev * (1 - af) + raw * af
        } else {
            smoothed = raw
        }
        return smoothed
    }

    public func process(_ s: IMUSample) -> MagneticFeature? {
        let a = FusionVec3(s.ax, s.ay, s.az)
        let m = FusionVec3(s.mx, s.my, s.mz)
        let sampleUp = useSampleGravity ? s.upFromSample : nil
        guard m.norm.isFinite, m.norm > 1.0, sampleUp != nil || (a.norm.isFinite && a.norm > 1.0) else { return smoothed }

        var dt = 0.0
        if let last = lastTMs { dt = Double(s.tMs - last) / 1000.0 }
        lastTMs = s.tMs
        if dt <= 0 || dt > 1.0 {         // 第一次、时间回退、或长时间断档：重新开始平滑
            up = sampleUp ?? a
            smoothed = nil
            dt = 0
        }

        let u: FusionVec3
        if let su = sampleUp {
            u = su
            upIsExternal = true
        } else {
            let ag = FusionMath.lpfAlpha(dt: dt, tau: gravityTauS)
            u = upIsExternal ? a : (up.map { $0 * (1 - ag) + a * ag } ?? a)
            upIsExternal = false
        }
        up = u
        gravityT = s.tMs
        let un = u.normalized
        guard un.norm > 0.5 else { return smoothed }

        let b = m.norm
        let bz = m.dot(un)
        let bh = (max(b * b - bz * bz, 0)).squareRoot()
        let raw = MagneticFeature(total: b, vertical: bz, horizontal: bh)

        if let prev = smoothed {
            let af = FusionMath.lpfAlpha(dt: dt, tau: featureTauS)
            smoothed = prev * (1 - af) + raw * af
        } else {
            smoothed = raw
        }
        return smoothed
    }
}
