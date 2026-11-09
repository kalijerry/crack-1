import Foundation
import XCTest
@testable import HPASSKit

/// 合成办公楼（米，+x 东、+y 南，原点西北角），分几段扫描用：
///
///     办公区 office (0,0)-(8,4)   卫生间 wc (8,0)-(12,4)   会议室 meeting (12,0)-(20,4)   走廊 hall (0,4)-(20,7)
///
/// 墙：北 (0,0)-(20,0)、南 (0,7)-(20,7)、西、东、走廊北墙 (0,4)-(20,4)、隔墙 x=8 与 x=12（0..4）→ 一次扫完 7 面墙；
/// 门：办公区 x 3..4、卫生间 x 9.5..10.5、会议室 x 15.5..16.5（都在 y = 4）；桌子：办公区 (3,1.5)、会议室 (16,2)。
///
/// 左段 = 办公区 + 卫生间 + 走廊 0..12；右段 = 会议室 + 走廊 8..20（和左段在走廊 8..12 重叠，含卫生间门和隔墙 x=12）。
enum SyntheticOffice {
    typealias Frame = VenueAuthoringTests.ARFrame

    struct Spec {
        var walls: [(Point2, Point2)] = []
        var doors: [(Point2, Point2)] = []
        var tables: [(Point2, Double, Double)] = []
        var rooms: [(id: String, cat: String, rect: (Double, Double, Double, Double))] = []
    }

    static func P(_ x: Double, _ y: Double) -> Point2 { Point2(x, y) }

    static let full = Spec(
        walls: [(P(0, 0), P(20, 0)), (P(0, 7), P(20, 7)), (P(0, 0), P(0, 7)), (P(20, 0), P(20, 7)),
                (P(0, 4), P(20, 4)), (P(8, 0), P(8, 4)), (P(12, 0), P(12, 4))],
        doors: [(P(3, 4), P(4, 4)), (P(9.5, 4), P(10.5, 4)), (P(15.5, 4), P(16.5, 4))],
        tables: [(P(3, 1.5), 2, 1), (P(16, 2), 2, 1)],
        rooms: [("office", "room", (0, 0, 8, 4)), ("wc", "restroom", (8, 0, 12, 4)),
                ("meeting", "room", (12, 0, 20, 4)), ("hall", "walkway", (0, 4, 20, 7))])

    static let left = Spec(
        walls: [(P(0, 0), P(12, 0)), (P(0, 7), P(12, 7)), (P(0, 0), P(0, 7)), (P(0, 4), P(12, 4)),
                (P(8, 0), P(8, 4)), (P(12, 0), P(12, 4))],
        doors: [(P(3, 4), P(4, 4)), (P(9.5, 4), P(10.5, 4))],
        tables: [(P(3, 1.5), 2, 1)],
        rooms: [("office", "room", (0, 0, 8, 4)), ("wc", "restroom", (8, 0, 12, 4)), ("hallL", "walkway", (0, 4, 12, 7))])

    static let right = Spec(
        walls: [(P(12, 0), P(20, 0)), (P(8, 7), P(20, 7)), (P(20, 0), P(20, 7)), (P(8, 4), P(20, 4)), (P(12, 0), P(12, 4))],
        doors: [(P(9.5, 4), P(10.5, 4)), (P(15.5, 4), P(16.5, 4))],
        tables: [(P(16, 2), 2, 1)],
        rooms: [("meeting", "room", (12, 0, 20, 4)), ("hallR", "walkway", (8, 4, 20, 7))])

    /// 重扫办公区（墙都偏 8 cm，模拟两次扫描的差）
    static let officeRescan = Spec(
        walls: [(P(0, 0), P(8, 0)), (P(0, 0), P(0, 4)), (P(0, 4), P(8, 4)), (P(8, 0), P(8, 4))],
        doors: [(P(3, 4), P(4, 4))],
        tables: [(P(3, 1.5), 2, 1)],
        rooms: [("R1", "room", (0, 0, 8, 4))])

    static let frameA = Frame(beta: 70, origin: P(5, 5))
    static let frameB = Frame(beta: -130, origin: P(12, 2))
    static let frameC = Frame(beta: 15, origin: P(2, 2))

    static func input(_ s: Spec, _ f: Frame, offset: Point2 = .zero) -> RoomMapBuilder.Input {
        var inp = RoomMapBuilder.Input()
        func item(_ cat: String, _ a: Point2, _ b: Point2, _ h: Double) -> RoomMapBuilder.Item {
            let a = a + offset, b = b + offset
            return .init(category: cat, center: f.ar((a + b) * 0.5), width: a.distance(to: b), depth: 0, height: h, yaw: f.yaw(b - a))
        }
        inp.walls = s.walls.map { item("wall", $0.0, $0.1, 2.8) }
        inp.doors = s.doors.map { item("door", $0.0, $0.1, 2.1) }
        inp.objects = s.tables.map { .init(category: "table", center: f.ar($0.0 + offset), width: $0.1, depth: $0.2, height: 0.75, yaw: f.yaw(P(1, 0))) }
        inp.rooms = s.rooms.map { r in
            let (x0, y0, x1, y1) = r.rect
            return RoomMapBuilder.Room(id: r.id, floor: [P(x0, y0), P(x1, y0), P(x1, y1), P(x0, y1)].map { f.ar($0 + offset) }, category: r.cat)
        }
        return inp
    }

    static func build(_ s: Spec, _ f: Frame, offset: Point2 = .zero, frameId: String? = nil) throws -> Data {
        try RoomMapBuilder.build(input(s, f, offset: offset), name: "办公室", frameId: frameId).json
    }

    static func align(_ json: Data) throws -> MapARTransform {
        try XCTUnwrap(MapGeometry.arAlign(try MapGeometry.root(json)))
    }

    /// 楼里的点 → 某一段的地图坐标
    static func scanPoint(_ json: Data, _ f: Frame, _ w: Point2) throws -> Point2 {
        try align(json).toMap(f.ar(w) * 100)
    }

    /// 真值：段 (json, f) 坐标 → 段 (toJSON, toF) 坐标
    static func truth(from json: Data, _ f: Frame, to toJSON: Data, _ toF: Frame) throws -> MapARTransform {
        let a = P(0, 0), b = P(20, 7)
        return try XCTUnwrap(RigidAlign2D.twoPoints(targetA: try scanPoint(toJSON, toF, a), targetB: try scanPoint(toJSON, toF, b),
                                                    sourceA: try scanPoint(json, f, a), sourceB: try scanPoint(json, f, b))).transform
    }

    static func root(_ d: Data) throws -> [String: Any] { try MapGeometry.root(d) }

    static func count(_ root: [String: Any], _ type: String) -> Int {
        (root["mapElementList"] as? [[String: Any]] ?? []).filter { ($0["shapeType"] as? String) == type }.count
    }
}
