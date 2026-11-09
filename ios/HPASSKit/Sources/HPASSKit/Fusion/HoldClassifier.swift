import Foundation

/// 手机是怎么拿的（界面显示用）。真正驱动流水线的是 `CarryMode`；这里是它到界面文案的映射。
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
    /// 贴耳通话
    case calling
    /// 裤兜
    case pocket
    /// 包里
    case bag
    /// 反扣、倒置等
    case other

    public var title: String {
        switch self {
        case .unknown: return "未知"
        case .flat: return "平端"
        case .reading: return "斜拿看屏"
        case .upright: return "竖直拿着"
        case .swinging: return "摆臂"
        case .calling: return "贴耳通话"
        case .pocket: return "口袋"
        case .bag: return "包里"
        case .other: return "反扣 / 口袋"
        }
    }

    /// 视觉里程计（摄像头朝前）能不能正常工作。
    public var suitsCamera: Bool { self == .upright || self == .reading }

    /// 携带模式 → 持握姿态。still / unknown 时按屏幕倾角分（原有行为：< 25° 平端、< 70° 斜拿、≤ 115° 竖直、否则反扣）。
    public init(carry: CarryMode, tiltDeg: Double) {
        switch carry {
        case .texting: self = tiltDeg < 25 ? .flat : .reading
        case .upright: self = .upright
        case .calling: self = .calling
        case .swinging: self = .swinging
        case .pocket: self = .pocket
        case .bag: self = .bag
        case .still, .unknown:
            if tiltDeg < 25 { self = .flat }
            else if tiltDeg < 70 { self = .reading }
            else if tiltDeg <= 115 { self = .upright }
            else { self = .other }
        }
    }
}

/// 持握姿态分类（界面用）：现在是 `CarryModeClassifier` 的映射壳，公开接口（`process` / `reset` / `tiltDeg`）不变。
/// 静止时沿用按倾角分的老规则；走动时按携带模式映射。切换带分类器的 1.5 s 滞回。
public final class HoldClassifier {
    /// 底下的携带模式分类器（App 可以直接读 `mode` / `features`，或设 `proximityNear`）。
    public let classifier: CarryModeClassifier
    private var current: HoldPosture = .unknown

    public init(thresholds: CarryModeThresholds = CarryModeThresholds()) {
        classifier = CarryModeClassifier(thresholds: thresholds)
    }

    public func reset() {
        classifier.reset()
        current = .unknown
        tiltDeg = 0
    }

    /// 屏幕法线与竖直方向的夹角（度）。0 = 平放朝上，90 = 竖直，180 = 反扣。
    public private(set) var tiltDeg: Double = 0

    /// 当前携带模式（含 still / unknown）。
    public var carryMode: CarryMode { classifier.mode }
    /// 最近一次的携带姿态（站着不动时沿用）。
    public var activeCarryMode: CarryMode { classifier.activeMode }
    /// App 侧可选的近距离传感器（贴耳 / 口袋时 true），用来把通话和竖持分开。
    public var proximityNear: Bool? {
        get { classifier.proximityNear }
        set { classifier.proximityNear = newValue }
    }

    public func process(_ s: IMUSample) -> HoldPosture {
        let a = FusionVec3(s.ax, s.ay, s.az)
        guard a.norm > 1 || s.gravity != nil else { return current }
        let st = classifier.process(s)
        tiltDeg = st.tiltDeg
        guard st.mode != .unknown || current == .unknown else { return current }
        current = HoldPosture(carry: st.mode, tiltDeg: tiltDeg)
        return current
    }
}
