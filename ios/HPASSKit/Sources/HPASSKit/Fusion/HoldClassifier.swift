import Foundation

/// 手机是怎么拿的。
public enum HoldPosture: String {
    case unknown
    /// 平端着看屏幕（屏幕接近水平朝上）
    case flat
    /// 斜着看屏幕（常见的走路看手机姿势）
    case reading
    /// 竖直拿着，摄像头朝前（AR 姿势）
    case upright
    /// 手臂摆动
    case swinging
    /// 反扣、口袋、倒置等
    case other

    public var title: String {
        switch self {
        case .unknown: return "未知"
        case .flat: return "平端"
        case .reading: return "斜拿看屏"
        case .upright: return "竖直拿着"
        case .swinging: return "摆臂"
        case .other: return "反扣 / 口袋"
        }
    }

    /// 视觉里程计（摄像头朝前）能不能正常工作。
    public var suitsCamera: Bool { self == .upright || self == .reading }
}

/// 由重力方向和角速度判断持握姿态。输出带 0.6 s 的滞回，避免来回跳。
public final class HoldClassifier {
    private var up: FusionVec3?
    private var lastT: Int64?
    private var gyroEnergy = 0.0
    private var current: HoldPosture = .unknown
    private var candidate: HoldPosture = .unknown
    private var candidateSince: Int64 = 0

    public init() {}

    public func reset() {
        up = nil
        lastT = nil
        gyroEnergy = 0
        current = .unknown
        candidate = .unknown
    }

    /// 屏幕法线与竖直方向的夹角（度）。0 = 平放朝上，90 = 竖直，180 = 反扣。
    public private(set) var tiltDeg: Double = 0

    public func process(_ s: IMUSample) -> HoldPosture {
        let a = FusionVec3(s.ax, s.ay, s.az)
        guard a.norm > 1 else { return current }
        var dt = 0.0
        if let l = lastT { dt = Double(s.tMs - l) / 1000 }
        lastT = s.tMs
        if dt <= 0 || dt > 1 { up = a; dt = 0 }
        let al = FusionMath.lpfAlpha(dt: dt, tau: 0.4)
        let u = up.map { $0 * (1 - al) + a * al } ?? a
        up = u
        let un = u.normalized
        guard un.norm > 0.5 else { return current }
        tiltDeg = FusionMath.degrees(acos(FusionMath.clamp(un.z, -1, 1)))

        let w = (s.gx * s.gx + s.gy * s.gy + s.gz * s.gz).squareRoot()
        gyroEnergy += (w * w - gyroEnergy) * FusionMath.lpfAlpha(dt: dt, tau: 1.0)
        let gyroRms = gyroEnergy.squareRoot()

        let now: HoldPosture
        if tiltDeg > 130 {
            now = .other
        } else if gyroRms > 2.0 {
            now = .swinging
        } else if tiltDeg < 25 {
            now = .flat
        } else if tiltDeg < 70 {
            now = .reading
        } else if tiltDeg <= 115 {
            now = .upright
        } else {
            now = .other
        }
        if now != candidate { candidate = now; candidateSince = s.tMs }
        if current == .unknown || (now == candidate && s.tMs - candidateSince >= 600) { current = candidate }
        return current
    }
}
