import Foundation
import XCTest
@testable import HPASSKit

/// 扫描段注册表、原点平移、几何对齐、会话读取的原点偏移换算。
final class ScanRegistryTests: XCTestCase {
    typealias O = SyntheticOffice

    func testRoundTripAndOperations() throws {
        let leftJ = try O.build(O.left, O.frameA, frameId: "F1")
        var r = try ScanRegistry.newMap(mapId: "m", frameId: "F1", scanId: "s1", scanJSON: leftJ, createdMs: 1000, name: "办公室")
        XCTAssertEqual(r.scans.count, 1)
        XCTAssertEqual(r.scans[0].alignment, .base)
        XCTAssertTrue(r.scans[0].transform.isClose(to: .identity, tolCm: 1e-9))
        XCTAssertNotNil(r.frameAlign)
        XCTAssertNotNil(r.canvasCm)
        r = r.adding(.init(id: "s2", createdMs: 2000, inBaseFrame: true, toMap: .identity, alignment: .worldmap,
                           quality: .init(overlapCm: 620, residualCm: 4.1)), nowMs: 2000)
        XCTAssertEqual(r.geometryVersion, 2000)
        let v = r.geometryVersion
        r = r.settingEnabled("s2", false, nowMs: 10)          // 时钟回拨也要单调
        XCTAssertEqual(r.geometryVersion, v + 1)
        XCTAssertEqual(r.summary.count, 2)
        XCTAssertEqual(r.summary[1]["enabled"] as? Bool, false)
        r = r.relabel(unit: "office", category: "room", name: " 会议室 A ", nowMs: 3000)
        XCTAssertEqual(r.unitLabels["office"], .init(category: "room", name: "会议室 A"))
        let back = try XCTUnwrap(ScanRegistry.decode(try r.encoded()))
        XCTAssertEqual(back, r)
        r = r.removing("s2", nowMs: 4000)
        XCTAssertEqual(r.scans.map(\.id), ["s1"])
        XCTAssertEqual(r.removing("nope", nowMs: 5000), r)
    }

    func testNextUnitId() {
        XCTAssertEqual(ScanRegistry.nextUnitId(used: []), "R1")
        XCTAssertEqual(ScanRegistry.nextUnitId(used: ["R1", "R7", "office", "Rx"]), "R8")
    }

    func testLegacyMigration() throws {
        let old = try RoomMapBuilder.build(VenueAuthoringTests.input(VenueAuthoringTests.frame0, ordinal: 0, names: [:]), name: "1F").json
        let r = try ScanRegistry.legacy(mapId: "room_1", mapJSON: old, sidecar: nil, newFrameId: "NEW", nowMs: 99)
        XCTAssertEqual(r.frameId, "NEW")
        XCTAssertEqual(r.scans.count, 1)
        XCTAssertEqual(r.scans[0].alignment, .base)
        XCTAssertTrue(r.scans[0].transform.isClose(to: .identity, tolCm: 1e-9))
        XCTAssertEqual(r.scans[0].unitIds["office"], "office")
        XCTAssertEqual(r.frameAlign?.transform, try O.align(old))
        XCTAssertEqual(r.geometryVersion, 99)
        // 旁注有 frameId 就沿用
        let side = WorldMapSidecar(createdMs: 1, source: "scan", mapId: "room_1", arAlign: try O.align(old), frameId: "SIDE")
        XCTAssertEqual(try ScanRegistry.legacy(mapId: "room_1", mapJSON: old, sidecar: side, newFrameId: "NEW", nowMs: 1).frameId, "SIDE")
    }
}

final class MapFrameShiftTests: XCTestCase {
    typealias O = SyntheticOffice

    func mapWithGeo() throws -> Data {
        try RoomMapBuilder.build(VenueAuthoringTests.input(VenueAuthoringTests.frame0, ordinal: 0, names: ["office": "会议室 A", "lift": "1 号电梯"]), name: "1F").json
    }

    func testShiftAndBack() throws {
        let j = try mapWithGeo()
        let s = Point2(50, 100)
        let shifted = try MapFrameShift.apply(mapJSON: j, shift: s)
        let back = try MapFrameShift.apply(mapJSON: shifted, shift: Point2(-50, -100))
        let a = try O.root(j), b = try O.root(back), m = try O.root(shifted)
        XCTAssertEqual(a["mapElementList"] as? NSArray, b["mapElementList"] as? NSArray)
        XCTAssertEqual(a["units"] as? NSArray, b["units"] as? NSArray)
        XCTAssertEqual(a["floorPolygons"] as? NSArray, b["floorPolygons"] as? NSArray)
        XCTAssertEqual(a["connectors"] as? NSArray, b["connectors"] as? NSArray)
        XCTAssertEqual(b["originOffsetCm"] as? [Double], [0, 0])
        XCTAssertEqual(m["originOffsetCm"] as? [Double], [50, 100])
        XCTAssertEqual(MapGeometry.num(m["width"])!, MapGeometry.num(a["width"])! + 50, accuracy: 0.01)
        // arAlign：同一个 AR 点恰好挪了 (50, 100)
        let t0 = try XCTUnwrap(MapGeometry.arAlign(a)), t1 = try XCTUnwrap(MapGeometry.arAlign(m))
        let p = Point2(321, -77)
        XCTAssertEqual(t1.toMap(p).distance(to: t0.toMap(p) + s), 0, accuracy: 1e-9)
        XCTAssertTrue(try XCTUnwrap(MapGeometry.arAlign(b)).isClose(to: t0, tolCm: 1e-6))
        // geoRef：同一个物理点经纬度不变
        let g0 = try XCTUnwrap(GeoRef(dict: a["geoRef"] as? [String: Any])), g1 = try XCTUnwrap(GeoRef(dict: m["geoRef"] as? [String: Any]))
        for q in [Point2(100, 100), Point2(1500, 600)] {
            XCTAssertEqual((g0.toLonLat(q).lon - g1.toLonLat(q + s).lon) * g0.mPerDegLon * 100, 0, accuracy: 1)
            XCTAssertEqual((g0.toLonLat(q).lat - g1.toLonLat(q + s).lat) * g0.mPerDegLat * 100, 0, accuracy: 1)
        }
        let ga = try XCTUnwrap(m["geoAnchor"] as? [String: Any]), gb = try XCTUnwrap(a["geoAnchor"] as? [String: Any])
        XCTAssertEqual(MapGeometry.num(ga["x"])!, MapGeometry.num(gb["x"])! + 50, accuracy: 0.01)
        // 平移后的地图能正常读，可走面积不变
        let w0 = SessionEvaluator.walkable(try StoreDataLoader.loadMap(j))!.walkableAreaM2
        let w1 = SessionEvaluator.walkable(try StoreDataLoader.loadMap(shifted))!.walkableAreaM2
        XCTAssertEqual(w0, w1, accuracy: 0.5)
        XCTAssertEqual(try StoreDataLoader.loadMap(shifted).originOffsetCm, s)
        XCTAssertThrowsError(try MapFrameShift.apply(mapJSON: j, shift: Point2(25, 0)))
    }

    func testRequiredShift() {
        XCTAssertEqual(MapFrameShift.requiredShift(minX: 105, minY: 100), .zero)
        XCTAssertEqual(MapFrameShift.requiredShift(minX: -20, minY: 60), Point2(150, 50))
    }
}

final class RigidAlign2DTests: XCTestCase {
    typealias O = SyntheticOffice

    func assertClose(_ a: MapARTransform, _ b: MapARTransform, tolCm: Double, degTol: Double, file: StaticString = #filePath, line: UInt = #line) {
        for p in [Point2(0, 0), Point2(800, 0), Point2(0, 800), Point2(1500, 900)] {
            XCTAssertLessThanOrEqual(a.toMap(p).distance(to: b.toMap(p)), tolCm, file: file, line: line)
        }
        XCTAssertLessThanOrEqual(abs(MapARTransform.wrapDeg(a.angleDeg - b.angleDeg)), degTol, file: file, line: line)
    }

    func testAutoFindsTruth() throws {
        let leftJ = try O.build(O.left, O.frameA), rightJ = try O.build(O.right, O.frameB)
        let truth = try O.truth(from: rightJ, O.frameB, to: leftJ, O.frameA)
        let r = try XCTUnwrap(RigidAlign2D.auto(target: try .init(mapJSON: leftJ), source: try .init(mapJSON: rightJ)))
        assertClose(r.transform, truth, tolCm: 5, degTol: 0.5)
        XCTAssertFalse(r.ambiguous)
        XCTAssertGreaterThanOrEqual(r.overlapCm, 300)
        XCTAssertLessThan(r.residualCm, 3)
        XCTAssertGreaterThanOrEqual(r.doorsMatched, 1)
        // 反过来也行
        let r2 = try XCTUnwrap(RigidAlign2D.auto(target: try .init(mapJSON: rightJ), source: try .init(mapJSON: leftJ)))
        assertClose(r2.transform, truth.inverse, tolCm: 5, degTol: 0.5)
    }

    func testNoOverlapReturnsNil() throws {
        let leftJ = try O.build(O.left, O.frameA)
        var store = O.Spec()
        // 5 × 2.5 m 的库房：放进走廊（3 m 深）或办公区（4 m 深）都会有墙落在房间中间
        store.walls = [(O.P(30, 0), O.P(35, 0)), (O.P(35, 0), O.P(35, 2.5)), (O.P(35, 2.5), O.P(30, 2.5)), (O.P(30, 2.5), O.P(30, 0))]
        store.doors = [(O.P(32, 2.5), O.P(33, 2.5))]
        store.rooms = [("R1", "room", (30, 0, 35, 2.5))]
        let sJ = try O.build(store, O.frameB)
        XCTAssertNil(RigidAlign2D.auto(target: try .init(mapJSON: leftJ), source: try .init(mapJSON: sJ)))
    }

    func testSymmetricCorridorIsAmbiguous() throws {
        var c = O.Spec()
        c.walls = [(O.P(0, 0), O.P(10, 0)), (O.P(10, 0), O.P(10, 2)), (O.P(10, 2), O.P(0, 2)), (O.P(0, 2), O.P(0, 0))]
        c.doors = [(O.P(0, 0.5), O.P(0, 1.5)), (O.P(10, 0.5), O.P(10, 1.5))]
        c.rooms = [("R1", "walkway", (0, 0, 10, 2))]
        let a = try O.build(c, O.frameA), b = try O.build(c, O.frameB)
        let r = try XCTUnwrap(RigidAlign2D.auto(target: try .init(mapJSON: a), source: try .init(mapJSON: b)))
        XCTAssertTrue(r.ambiguous)
    }

    func testTwoPointsAndSnap() throws {
        let truth = MapARTransform(pRef: Point2(500, 300), aRef: Point2(100, 100), phi: 0.7)
        let sa = Point2(100, 100), sb = Point2(900, 400)
        let noise = [Point2(7, -6), Point2(-8, 5)]
        let (t, scale) = try XCTUnwrap(RigidAlign2D.twoPoints(targetA: truth.toMap(sa) + noise[0], targetB: truth.toMap(sb) + noise[1],
                                                              sourceA: sa, sourceB: sb))
        for p in [sa, sb, Point2(500, 250)] { XCTAssertLessThanOrEqual(t.toMap(p).distance(to: truth.toMap(p)), 15) }
        XCTAssertTrue((0.97...1.03).contains(scale))
        XCTAssertNil(RigidAlign2D.twoPoints(targetA: .zero, targetB: Point2(100, 0), sourceA: .zero, sourceB: Point2(1, 0)))
        // 吸附：差 2° → 0°；88.5° → 90°；10° 不动
        let p = Point2(300, 200)
        let s0 = RigidAlign2D.snapToAxes(MapARTransform(pRef: .zero, aRef: .zero, phi: 2 * Double.pi / 180), pivot: p)
        XCTAssertEqual(s0.phi, 0, accuracy: 1e-12)
        XCTAssertEqual(s0.toMap(p).distance(to: MapARTransform(pRef: .zero, aRef: .zero, phi: 2 * Double.pi / 180).toMap(p)), 0, accuracy: 1e-9)
        XCTAssertEqual(RigidAlign2D.snapToAxes(MapARTransform(pRef: .zero, aRef: .zero, phi: 88.5 * Double.pi / 180)).angleDeg, 90, accuracy: 1e-9)
        XCTAssertEqual(RigidAlign2D.snapToAxes(MapARTransform(pRef: .zero, aRef: .zero, phi: 10 * Double.pi / 180)).angleDeg, 10, accuracy: 1e-9)
    }

    func testRefineRecoversSmallError() throws {
        // 手动两点点歪了一点（1.5°、20 cm）→ 吸附 + ICP 回到真值
        let leftJ = try O.build(O.left, O.frameA), rightJ = try O.build(O.right, O.frameB)
        let truth = try O.truth(from: rightJ, O.frameB, to: leftJ, O.frameA)
        let rough = MapARTransform(pRef: truth.pRef + Point2(14, -14), aRef: truth.aRef, phi: truth.phi + 1.5 * Double.pi / 180)
        let snapped = RigidAlign2D.snapToAxes(rough)
        let fine = RigidAlign2D.refine(snapped, target: try .init(mapJSON: leftJ), source: try .init(mapJSON: rightJ))
        assertClose(fine, truth, tolCm: 5, degTol: 0.5)
    }
}

final class SessionOffsetTests: XCTestCase {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("hp-offset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testAnchorsAndTrackFollowMapOrigin() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SyntheticRoom.writeSession(dir, waypoints: [Point2(200, 200), Point2(600, 200)])
        let base = try SurveySessionLoader.load(dir)
        // 没有 meta：会话偏移当 [0, 0]
        let moved = try SurveySessionLoader.load(dir, mapOriginOffsetCm: Point2(50, 100))
        XCTAssertEqual(moved.anchors.count, base.anchors.count)
        for (a, b) in zip(base.anchors, moved.anchors) {
            XCTAssertEqual(b.map, a.map + Point2(50, 100))
            XCTAssertEqual(b.ar, a.ar)
        }
        // 会话录制时地图已经是 [50, 100]：和地图一样，不动
        try Data(#"{"survey":true,"map_origin_offset_cm":[50,100]}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        XCTAssertEqual(SurveySessionLoader.originOffset(dir), Point2(50, 100))
        let same = try SurveySessionLoader.load(dir, mapOriginOffsetCm: Point2(50, 100))
        XCTAssertEqual(same.anchors.map(\.map), base.anchors.map(\.map))
        // 地图后来又平移到 [100, 100]
        let later = try SurveySessionLoader.load(dir, mapOriginOffsetCm: Point2(100, 100))
        XCTAssertEqual(later.anchors.map(\.map), base.anchors.map { $0.map + Point2(50, 0) })
        // 实时记录的轨迹
        try "t_ms,x_cm,y_cm,unc_cm,conf\n1,10,20,50,0.9\n2,11,21,50,0.9\n".write(to: dir.appendingPathComponent("track.csv"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LiveRunLoader.loadTrack(dir, mapOriginOffsetCm: Point2(50, 100)).map(\.p), [Point2(10, 20), Point2(11, 21)])
        XCTAssertEqual(LiveRunLoader.loadTrack(dir, mapOriginOffsetCm: Point2(100, 150)).map(\.p), [Point2(60, 70), Point2(61, 71)])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("meta.json"))
        XCTAssertEqual(LiveRunLoader.loadTrack(dir).map(\.p), [Point2(10, 20), Point2(11, 21)])
    }
}
