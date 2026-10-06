import Foundation

/// 把视觉里程计（ARKit）的位姿对齐到门店地图坐标。
///
/// ARKit 世界系：重力对齐，水平面两个轴任意朝向，且只在一次会话内保持一致。
/// 俯视（从 +y 往下看）时，(x, z) 与地图 (x, y) 手性相同，所以只差一个平面旋转 φ 和一个平移：
///
///     map = pRef + R(φ) · (a − aRef)        a = ARKit 的 (x, z)，单位 cm
///
/// 锚点（pRef, aRef）是「我在这里」的那一刻。φ 在走出 `alignDistanceCm` 之后，
/// 用「已知行进方向」求出，行进方向来自：用户设的朝向，或之后惯导给出的朝向。
///
/// 跟踪状态变差、再恢复时不能假设坐标系没变（ARKit 重置会让原点和航向都变），
/// 所以恢复后重新锚定并重新对齐，期间调用方用惯导位移顶上。
/// 非线程安全。
public final class VisualOdometryAligner {

    public enum Output: Equatable {
        /// 还没对齐（刚锚定、没走够距离，或跟踪丢了）。调用方用别的运动模型顶上。
        case unaligned(progress: Double)
        /// 已对齐：地图坐标和自上一次输出以来的位移（cm）。
        case aligned(position: Point2, delta: Point2)
    }

    public var alignDistanceCm: Double = 150
    /// 恢复跟踪后，ARKit 位置比上一帧跳得比这个远（cm）就当作坐标系已重置。
    public var jumpCm: Double = 300

    private(set) var aRef = Point2.zero
    private(set) var pRef = Point2.zero
    private(set) var phi: Double?
    private var headingHint: Double?
    private var lastMap: Point2?
    private var lastA: Point2?
    private var wasNormal = true

    public init() {}

    public var isAligned: Bool { phi != nil }
    public var rotationRad: Double? { phi }

    /// 在「我在地图 p、ARKit 在 a」处锚定。`headingRad` 是此刻行进方向（地图系，0 = +y），
    /// 没有就只能等调用方稍后用 `setHeadingHint` 补上。
    public func anchor(map p: Point2, ar a: Point2, headingRad: Double?) {
        pRef = p
        aRef = a
        headingHint = headingRad
        phi = nil
        lastMap = p
        lastA = a
        wasNormal = true
    }

    public func setHeadingHint(_ h: Double) { headingHint = h }

    /// 保持旋转不变、只把位置拉到 p（长按修正位置）。
    public func reanchorKeepingRotation(map p: Point2, ar a: Point2) {
        pRef = p
        aRef = a
        lastMap = p
        lastA = a
    }

    /// 送入一帧 ARKit 位姿。
    /// - Parameters:
    ///   - headingHint: 此刻惯导估计的行进方向（地图系），坐标系重置后用它重新对齐。
    ///   - currentMap: 调用方此刻对自己位置的最好估计（跟踪丢失期间由惯导顶上），重新锚定时用它。
    public func process(ar a: Point2, trackingNormal: Bool, headingHint hint: Double? = nil,
                        currentMap: Point2? = nil) -> Output {
        defer { lastA = a }
        if !trackingNormal {
            if wasNormal { rotationBeforeLoss = phi }
            wasNormal = false
            return .unaligned(progress: 0)
        }
        if !wasNormal {
            wasNormal = true
            let jumped = lastA.map { $0.distance(to: a) > jumpCm } ?? true
            if jumped || rotationBeforeLoss == nil {
                // 坐标系可能已经重置：不信旧的旋转，在当前位置重新锚定并重新对齐
                anchor(map: currentMap ?? lastMap ?? pRef, ar: a, headingRad: hint ?? headingHint)
            }
            // 没跳：ARKit 坐标系没变，旧锚点和旋转继续有效，位置会自然包含丢失期间走过的距离
            rotationBeforeLoss = nil
        }

        if phi == nil {
            let d = a - aRef
            let len = d.length
            guard len >= alignDistanceCm, let h = headingHint else {
                return .unaligned(progress: min(len / alignDistanceCm, 1))
            }
            let hm = Point2(sin(h), cos(h))
            phi = atan2(hm.y, hm.x) - atan2(d.y, d.x)
        }
        guard let rot = phi else { return .unaligned(progress: 0) }
        let d = a - aRef
        let c = cos(rot), s = sin(rot)
        let p = Point2(pRef.x + d.x * c - d.y * s, pRef.y + d.x * s + d.y * c)
        let delta = lastMap.map { p - $0 } ?? .zero
        lastMap = p
        return .aligned(position: p, delta: delta)
    }

    /// 跟踪变差时记住旋转，恢复后位置没跳就沿用。
    private var rotationBeforeLoss: Double?
}
