import Foundation
import XCTest
@testable import HPASSKit

final class RoomMapBuilderTests: XCTestCase {
    /// 4 m × 3 m 的房间，整体转了 10°（扫描开始时手机朝向随意），一张 1.6 × 2.0 m 的床。
    private func room() -> RoomMapBuilder.Input {
        let a = 10 * Double.pi / 180
        func R(_ p: Point2) -> Point2 { Point2(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a)) }
        var inp = RoomMapBuilder.Input()
        inp.walls = [
            .init(category: "wall", center: R(Point2(2, 0)), width: 4, depth: 0, height: 2.6, yaw: a),
            .init(category: "wall", center: R(Point2(2, 3)), width: 4, depth: 0, height: 2.6, yaw: a + .pi),
            .init(category: "wall", center: R(Point2(0, 1.5)), width: 3, depth: 0, height: 2.6, yaw: a + .pi / 2),
            .init(category: "wall", center: R(Point2(4, 1.5)), width: 3, depth: 0, height: 2.6, yaw: a - .pi / 2),
        ]
        inp.doors = [.init(category: "door", center: R(Point2(0, 2.5)), width: 0.9, depth: 0, height: 2.1, yaw: a + .pi / 2)]
        inp.objects = [.init(category: "bed", center: R(Point2(1.2, 1.5)), width: 1.6, depth: 2.0, height: 0.5, yaw: a)]
        return inp
    }

    func testBuildsAxisAlignedRoomWithFurnitureAndFloor() throws {
        let (json, map) = try RoomMapBuilder.build(room(), name: "测试房间")
        XCTAssertFalse(json.isEmpty)
        // 转正之后：4 m × 3 m + 墙厚（按 10 cm 画，各边 5 cm）+ 两边各 1 m 留白
        XCTAssertEqual(map.width, 610, accuracy: 2)
        XCTAssertEqual(map.height, 510, accuracy: 2)
        XCTAssertEqual(map.crosses.count, 0)
        XCTAssertEqual(map.others.filter { $0.shapeType == "MapWall" }.count, 4)
        for w in map.others where w.shapeType == "MapWall" {
            let r = abs(w.rotation).truncatingRemainder(dividingBy: 90)
            XCTAssertTrue(r < 0.5 || r > 89.5, "墙应该横平竖直：\(w.rotation)")
        }
        // 家具：实物，中心在 (105 + 120, 105 + 150)，带高度
        XCTAssertEqual(map.physicalShelves.count, 1)
        let bed = map.physicalShelves[0]
        XCTAssertEqual(bed.code, "Room-bed-1")
        XCTAssertEqual(bed.x, 225, accuracy: 2)
        XCTAssertEqual(bed.y, 255, accuracy: 2)
        XCTAssertEqual(bed.heightCm ?? 0, 50, accuracy: 1)
        // 地面：墙端点凸包；可走 = 地面 − 床（放宽 15 cm）
        XCTAssertEqual(map.floor.count, 1)
        let w = WalkableMap(floor: map.floor, obstacles: map.physicalShelves, widthCm: map.width, heightCm: map.height)
        XCTAssertTrue(w.isWalkable(Point2(400, 250)))
        XCTAssertFalse(w.isWalkable(Point2(225, 255)))        // 床上
        XCTAssertFalse(w.isWalkable(Point2(50, 50)))          // 墙外
        XCTAssertEqual(w.walkableAreaM2, 12 - 1.9 * 2.3, accuracy: 0.8)
        // 涂色可以用房间的可走区域
        let paint = CoveragePaint(walkable: w)
        paint.paint(at: Point2(400, 250))
        XCTAssertGreaterThan(paint.paintedCells, 0)
    }
}
