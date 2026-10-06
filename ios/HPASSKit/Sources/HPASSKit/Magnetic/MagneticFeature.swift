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

    static func * (a: MagneticFeature, k: Double) -> MagneticFeature {
        MagneticFeature(total: a.total * k, vertical: a.vertical * k, horizontal: a.horizontal * k)
    }
}

/// 从 IMU 样本提取旋转不变的磁场特征。
///
/// 「向上」方向取加速度（含重力，Android 约定下静止时指向上方）的低通方向，
/// 所以 Bz 只依赖倾角，不依赖航向。输出再做一次低通，压掉走路时的抖动。
/// 非线程安全，与其他 HPASSKit 对象一样要在同一串行队列上使用。
public final class MagneticFeatureExtractor {
    /// 重力方向低通时间常数（s）。
    public var gravityTauS: Double = 0.5
    /// 特征低通时间常数（s）。太大会让读数滞后（0.25 s 在 1.1 m/s 下就是 30 cm），建图是不滞后的，两边对不上。
    public var featureTauS: Double = 0.1

    private var up: FusionVec3?
    private var smoothed: MagneticFeature?
    private var lastTMs: Int64?

    public init() {}

    public func reset() {
        up = nil
        smoothed = nil
        lastTMs = nil
    }

    public func process(_ s: IMUSample) -> MagneticFeature? {
        let a = FusionVec3(s.ax, s.ay, s.az)
        let m = FusionVec3(s.mx, s.my, s.mz)
        guard a.norm.isFinite, m.norm.isFinite, a.norm > 1.0, m.norm > 1.0 else { return smoothed }

        var dt = 0.0
        if let last = lastTMs { dt = Double(s.tMs - last) / 1000.0 }
        lastTMs = s.tMs
        if dt <= 0 || dt > 1.0 {         // 第一次、时间回退、或长时间断档：重新开始平滑
            up = a
            smoothed = nil
            dt = 0
        }

        let ag = FusionMath.lpfAlpha(dt: dt, tau: gravityTauS)
        let u = up.map { $0 * (1 - ag) + a * ag } ?? a
        up = u
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
