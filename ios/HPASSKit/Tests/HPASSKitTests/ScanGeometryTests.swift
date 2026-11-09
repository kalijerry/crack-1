import Foundation
import XCTest
@testable import HPASSKit

/// 刚体变换代数、特征地图旁注的 frameId 规则、map.json 几何读写层、RoomMapBuilder 的段级参数。
final class MapTransformAlgebraTests: XCTestCase {
    func rnd(_ g: inout SplitMix) -> MapARTransform {
        MapARTransform(pRef: Point2(g.d(-2000, 2000), g.d(-2000, 2000)), aRef: Point2(g.d(-2000, 2000), g.d(-2000, 2000)), phi: g.d(-4, 4))
    }

    struct SplitMix {
        var s: UInt64
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func d(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53) }
    }

    func testComposeInverseIdentityAndChain() {
        var g = SplitMix(s: 7)
        for _ in 0..<50 {
            let a = rnd(&g), b = rnd(&g)
            let id = a.compose(a.inverse)
            for p in [Point2(0, 0), Point2(1234, -567), Point2(-3000, 42)] {
                XCTAssertEqual(id.toMap(p).distance(to: p), 0, accuracy: 1e-9)
                XCTAssertEqual(a.inverse.toMap(p).distance(to: a.toAR(p)), 0, accuracy: 1e-9)
                XCTAssertEqual(a.compose(b).toMap(p).distance(to: b.toMap(a.toMap(p))), 0, accuracy: 1e-9)
            }
            let s = Point2(50, -100)
            let p = Point2(g.d(-500, 500), g.d(-500, 500))
            XCTAssertEqual(a.translated(by: s).toMap(p).distance(to: a.toMap(p) + s), 0, accuracy: 1e-9)
            XCTAssertTrue(a.isClose(to: a.compose(.identity), tolCm: 1e-6))
        }
        XCTAssertEqual(MapARTransform(pRef: .zero, aRef: .zero, phi: 3 * Double.pi / 2).angleDeg, -90, accuracy: 1e-9)
        XCTAssertEqual(MapARTransform.wrapDeg(540), 180, accuracy: 1e-9)
        XCTAssertEqual(MapARTransform.wrapDeg(-180), 180, accuracy: 1e-9)
    }

    func testSegmentToMapInBaseFrame() {
        // 段坐标 → AR → 地图：和直接两步变换一致
        let seg = MapARTransform(pRef: Point2(300, 200), aRef: Point2(10, 20), phi: 0.4)
        let frame = MapARTransform(pRef: Point2(150, 120), aRef: .zero, phi: -1.1)
        let t = ScanRegistry.ScanRecord.toMapInBaseFrame(scanAlign: seg, frameAlign: frame)
        let q = Point2(420, 310)
        XCTAssertEqual(t.toMap(q).distance(to: frame.toMap(seg.toAR(q))), 0, accuracy: 1e-9)
    }
}

final class WorldMapFrameIdTests: XCTestCase {
    let align = MapARTransform(pRef: Point2(120, 80), aRef: .zero, phi: -0.6)

    func testFrameIdRule() throws {
        let s = WorldMapSidecar(createdMs: 1, source: "scan-append", mapId: "m", arAlign: align, frameId: "F")
        let far = align.translated(by: Point2(300, 0))
        XCTAssertTrue(s.isCompatible(with: far, frameId: "F"), "同一个 frameId：arAlign 差 3 m 也兼容（原点平移过）")
        XCTAssertFalse(s.isCompatible(with: align, frameId: "G"), "frameId 不同：arAlign 一样也不兼容")
        XCTAssertTrue(s.isCompatible(with: align, frameId: nil), "地图没有 frameId：退回 arAlign 规则")
        XCTAssertFalse(s.isCompatible(with: far, frameId: nil))
        var old = s; old.frameId = nil
        XCTAssertTrue(old.isCompatible(with: align, frameId: "F"))
        XCTAssertFalse(old.isCompatible(with: far, frameId: "F"))
        let back = try XCTUnwrap(WorldMapSidecar.decode(try s.encoded()))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.version, 1)
        // 老旁注（没有 frameId 键）照样能读
        let legacy = Data(#"{"version":1,"createdMs":5,"source":"scan","arAlign":{"phi":0,"pRefX":1,"pRefY":2,"aRefX":0,"aRefY":0}}"#.utf8)
        XCTAssertNil(try XCTUnwrap(WorldMapSidecar.decode(legacy)).frameId)
    }

    func testShiftedSidecar() {
        let s = WorldMapSidecar(createdMs: 1, source: "scan", mapId: "m", arAlign: align, frameId: "F")
        let sh = s.shifted(by: Point2(50, 100))
        let mapAlign = align.translated(by: Point2(50, 100))
        XCTAssertTrue(sh.isCompatible(with: mapAlign))
        XCTAssertEqual(sh.frameId, "F")
        // 原来的旁注：有 frameId 时仍兼容平移后的地图；没有 frameId 时不兼容（所以需要 frameId）
        XCTAssertTrue(s.isCompatible(with: mapAlign, frameId: "F"))
        var noId = s; noId.frameId = nil
        XCTAssertFalse(noId.isCompatible(with: mapAlign, frameId: "F"))
    }
}

final class MapGeometryTests: XCTestCase {
    func testWallRoundTrip() throws {
        let e: [String: Any] = ["shapeType": "MapWall", "x": 412.3, "y": 255.0, "width": 380.0, "height": 10, "rotation": 33.4, "heightCm": 280.0, "extra": "keep"]
        let s = try XCTUnwrap(MapGeometry.segment(e))
        let back = MapGeometry.element(MapGeometry.Segment(type: s.type, a: s.a, b: s.b, thickness: s.thickness, heightCm: s.heightCm), template: e)
        XCTAssertEqual(MapGeometry.num(back["x"])!, 412.3, accuracy: 0.05)
        XCTAssertEqual(MapGeometry.num(back["y"])!, 255.0, accuracy: 0.05)
        XCTAssertEqual(MapGeometry.num(back["width"])!, 380, accuracy: 0.05)
        XCTAssertEqual(MapGeometry.num(back["rotation"])!, 33.4, accuracy: 0.05)
        XCTAssertEqual(back["extra"] as? String, "keep")
    }

    func testFurnitureTopLeftCenterRoundTrip() {
        for rot in [0.0, 30, -75, 180] {
            let tl = Point2(100, 200)
            let c = MapGeometry.rectCenter(topLeft: tl, width: 160, height: 90, rotationDeg: rot)
            XCTAssertEqual(MapGeometry.rectTopLeft(center: c, width: 160, height: 90, rotationDeg: rot).distance(to: tl), 0, accuracy: 1e-9)
        }
        // 刚体变换：中心跟着走，左上角换回来
        let e: [String: Any] = ["shapeType": "MapShelf", "code": "Room-table-1", "x": 100.0, "y": 200.0, "width": 160.0, "height": 90.0, "rotation": 0.0]
        let t = MapARTransform(pRef: Point2(500, 500), aRef: Point2(0, 0), phi: Double.pi / 2)
        let r0 = MapGeometry.rect(e)!, r1 = MapGeometry.rect(MapGeometry.transform(element: e, by: t))!
        XCTAssertEqual(r1.center.distance(to: t.toMap(r0.center)), 0, accuracy: 0.1)
        XCTAssertEqual(r1.rotationDeg, 90, accuracy: 0.05)
        XCTAssertEqual(r0.category, "table")
    }

    func testIntervalUnionAndAngles() throws {
        let a = MapGeometry.Segment(type: "MapWall", a: Point2(0, 0), b: Point2(500, 0), thickness: 10, heightCm: 250)
        let b = MapGeometry.Segment(type: "MapWall", a: Point2(400, 8), b: Point2(900, 8), thickness: 10, heightCm: 280)
        let u = try XCTUnwrap(MapGeometry.unionOnLine(a, b, maxGapCm: 20))
        XCTAssertEqual(u.length, 900, accuracy: 0.5)
        XCTAssertEqual(u.heightCm, 280)
        XCTAssertEqual(u.a.y, 0, accuracy: 1e-9)
        let far = MapGeometry.Segment(type: "MapWall", a: Point2(530, 0), b: Point2(700, 0), thickness: 10)
        XCTAssertNil(MapGeometry.unionOnLine(a, far, maxGapCm: 20))
        XCTAssertNotNil(MapGeometry.unionOnLine(a, far, maxGapCm: 40))
        XCTAssertEqual(MapGeometry.lineAngleDiffDeg(179, -1), 0, accuracy: 1e-9)
        XCTAssertEqual(MapGeometry.lineAngleDiffDeg(10, 100), 90, accuracy: 1e-9)
        XCTAssertEqual(abs(a.offset(of: Point2(250, 30))), 30, accuracy: 1e-9)
    }

    func testPolygonHelpers() {
        let sq = [Point2(0, 0), Point2(400, 0), Point2(400, 400), Point2(0, 400)]
        let moved = sq.map { $0 + Point2(10, 0) }
        XCTAssertTrue(MapGeometry.sameRoom(sq, moved))
        XCTAssertFalse(MapGeometry.sameRoom(sq, sq.map { $0 * 0.5 }), "面积比 4：不是同一个房间")
        XCTAssertEqual(MapGeometry.shareInside(moved, [sq]), 390.0 / 400, accuracy: 0.03)
        XCTAssertTrue(MapGeometry.isWithin(sq, Point2(420, 200), marginCm: 30))
        XCTAssertFalse(MapGeometry.isWithin(sq, Point2(440, 200), marginCm: 30))
        XCTAssertEqual(MapGeometry.area(sq), 160_000, accuracy: 1e-6)
    }

    func testGeoRefTransformKeepsLonLat() {
        let g = GeoRef(lon0: 121.47, lat0: 31.23, marginCm: 100, rotationDeg: 17)
        let t = MapARTransform(pRef: Point2(800, -300), aRef: Point2(20, 40), phi: 1.2)
        let g2 = g.transformed(by: t)
        for p in [Point2(0, 0), Point2(1500, 700), Point2(-300, 2000)] {
            let a = g.toLonLat(p), b = g2.toLonLat(t.toMap(p))
            XCTAssertEqual((a.lon - b.lon) * g.mPerDegLon * 100, 0, accuracy: 0.5)
            XCTAssertEqual((a.lat - b.lat) * g.mPerDegLat * 100, 0, accuracy: 0.5)
        }
    }
}

final class RoomMapBuilderScanTests: XCTestCase {
    func testPrefixAndFrameId() throws {
        let inp = VenueAuthoringTests.input(VenueAuthoringTests.frame0, ordinal: 0, names: [:])
        let plain = try MapGeometry.root(try RoomMapBuilder.build(inp, name: "1F").json)
        XCTAssertNil(plain["frameId"]); XCTAssertNil(plain["geometryVersion"]); XCTAssertNil(plain["originOffsetCm"])
        let r = try MapGeometry.root(try RoomMapBuilder.build(inp, name: "1F", unitIdPrefix: "s2-", frameId: "F9", geometryVersion: 77).json)
        XCTAssertEqual(r["frameId"] as? String, "F9")
        XCTAssertEqual(MapGeometry.num(r["geometryVersion"]), 77)
        XCTAssertEqual(r["originOffsetCm"] as? [Double], [0, 0])
        XCTAssertEqual(Set(MapGeometry.units(r).map(\.id)), ["s2-office", "s2-wc", "s2-lift", "s2-store", "s2-hall"])
        // 新键之外和老输出一样
        var stripped = r
        for k in ["frameId", "geometryVersion", "originOffsetCm"] { stripped.removeValue(forKey: k) }
        XCTAssertEqual(MapGeometry.units(plain).count, MapGeometry.units(stripped).count)
        // 标签 / 连接体的编号跟着单元编号变，其余元素一样
        func core(_ r: [String: Any]) -> NSArray? {
            (r["mapElementList"] as? [[String: Any]])?.filter { !MapGeometry.derivedTypes.contains($0["shapeType"] as? String ?? "") } as NSArray?
        }
        XCTAssertEqual(core(plain), core(stripped))
        XCTAssertEqual(try StoreDataLoader.loadMap(try MapGeometry.data(r)).frameId, "F9")
        // 单房间：默认编号 R1，带前缀 s3-R1
        var one = RoomMapBuilder.Input()
        one.walls = inp.walls
        let u = MapGeometry.units(try MapGeometry.root(try RoomMapBuilder.build(one, name: "x", unitIdPrefix: "s3-").json))
        XCTAssertEqual(u.map(\.id), ["s3-R1"])
    }

    func testRoomUnit() throws {
        let small = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)]
        let big = [Point2(0, 0), Point2(5, 0), Point2(5, 4), Point2(0, 4)]
        let u = try XCTUnwrap(RoomMapBuilder.roomUnit(floors: [small, big], walls: [], sectionLabel: "bathroom", hasStairs: false, index: 1, prefix: "s2-"))
        XCTAssertEqual(u.id, "s2-R2")
        XCTAssertEqual(u.floor, big)
        XCTAssertEqual(u.category, IMDFUnitCategory.suggest(roomPlanSection: "bathroom") ?? "room")
        // 没有地面：墙端点凸包；有楼梯 → stairs
        let walls = [RoomMapBuilder.Item(category: "wall", center: Point2(2, 0), width: 4, depth: 0, height: 2.5, yaw: 0),
                     RoomMapBuilder.Item(category: "wall", center: Point2(2, 3), width: 4, depth: 0, height: 2.5, yaw: 0)]
        let v = try XCTUnwrap(RoomMapBuilder.roomUnit(floors: [], walls: walls, sectionLabel: nil, hasStairs: true, index: 0))
        XCTAssertEqual(v.id, "R1"); XCTAssertEqual(v.category, "stairs")
        XCTAssertEqual(MapGeometry.area(v.floor), 12, accuracy: 1e-9)
        XCTAssertNil(RoomMapBuilder.roomUnit(floors: [], walls: [], sectionLabel: nil, hasStairs: false, index: 0))
    }
}
