import Foundation

/// 二维点。地图 / 指纹 / 导航相关一律用厘米（门店地图坐标，y 轴向下）；融合引擎内部用米。
public struct Point2: Hashable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2(0, 0)

    public static func + (a: Point2, b: Point2) -> Point2 { Point2(a.x + b.x, a.y + b.y) }
    public static func - (a: Point2, b: Point2) -> Point2 { Point2(a.x - b.x, a.y - b.y) }
    public static func * (a: Point2, k: Double) -> Point2 { Point2(a.x * k, a.y * k) }

    public func distance(to p: Point2) -> Double { hypot(x - p.x, y - p.y) }
    public var length: Double { hypot(x, y) }
    public func dot(_ p: Point2) -> Double { x * p.x + y * p.y }
    public func cross(_ p: Point2) -> Double { x * p.y - y * p.x }

    public var description: String { String(format: "(%.1f, %.1f)", x, y) }
}

/// 点是否在多边形内（射线法）。
public func pointInPolygon(_ p: Point2, _ poly: [Point2]) -> Bool {
    guard poly.count >= 3 else { return false }
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let a = poly[i], b = poly[j]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        j = i
    }
    return inside
}

/// 点是否在「中心 + 尺寸 + 旋转（度，y 向下顺时针）」的矩形里，四周再放宽 margin。
public func pointInRotatedRect(_ p: Point2, center c: Point2, width w: Double, height h: Double,
                               rotationDeg: Double, margin: Double = 0) -> Bool {
    let r = rotationDeg * Double.pi / 180
    let d = p - c
    let u = d.x * cos(r) + d.y * sin(r)
    let v = -d.x * sin(r) + d.y * cos(r)
    return abs(u) <= w / 2 + margin && abs(v) <= h / 2 + margin
}
