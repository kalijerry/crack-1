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
