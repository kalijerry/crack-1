import Foundation
import XCTest
@testable import HPASSKit

/// 多段扫描合成：接着扫（追加）、重扫（替换）、关掉一段、去重、单元编号与名字继承、原点平移、确定性。
final class MapComposerTests: XCTestCase {
    typealias O = SyntheticOffice

    struct Fixture {
        var leftJ: Data
        var rightJ: Data
        var reg: ScanRegistry
        var scans: [String: Data]
    }

    func twoScans() throws -> Fixture {
        let leftJ = try O.build(O.left, O.frameA, frameId: "F1")
        let rightJ = try O.build(O.right, O.frameB)
        var reg = try ScanRegistry.newMap(mapId: "office", frameId: "F1", scanId: "s1", scanJSON: leftJ, createdMs: 1000, name: "办公室")
        let t = try O.truth(from: rightJ, O.frameB, to: leftJ, O.frameA)
        reg = reg.adding(.init(id: "s2", createdMs: 2000, inBaseFrame: false, toMap: t, alignment: .geometry), nowMs: 2000)
        return Fixture(leftJ: leftJ, rightJ: rightJ, reg: reg, scans: ["s1": leftJ, "s2": rightJ])
    }

    func walkableArea(_ json: Data) throws -> Double {
        let m = try StoreDataLoader.loadMap(json)
        return try XCTUnwrap(SessionEvaluator.walkable(m)).walkableAreaM2
    }

    /// 合成地图里楼的某个点：左段坐标 + 原点平移
    func at(_ f: Fixture, _ w: Point2, shift: Point2 = .zero) throws -> Point2 {
        try O.scanPoint(f.leftJ, O.frameA, w) + shift
    }

    func testAppendTwoHalvesMatchesSingleBuild() throws {
        let f = try twoScans()
        let res = try MapComposer.compose(registry: f.reg, scans: f.scans)
        let root = try O.root(res.json)
        let whole = try O.root(try O.build(O.full, O.frameA))
        // 共墙去重：两段拼起来和整栋一次扫完的墙数一样
        XCTAssertEqual(O.count(root, "MapWall"), O.count(whole, "MapWall"))
        XCTAssertEqual(O.count(root, "MapWall"), 7)
        XCTAssertEqual(O.count(root, "MapDoor"), 3)           // 卫生间门两段都扫到，只留一扇
        XCTAssertEqual(O.count(root, "MapShelf"), 2)
        // 单元：左 3 个 + 右 2 个（右边的走廊和左边的只重叠 1/3，不是同一个房间）
        let units = MapGeometry.units(root)
        XCTAssertEqual(units.count, 5)
        XCTAssertEqual(Set(units.map(\.id)), ["office", "wc", "hallL", "R1", "R2"])
        // 可走面积 = 整栋（走廊重叠部分不重复算）
        XCTAssertEqual(try walkableArea(res.json), try walkableArea(try O.build(O.full, O.frameA)), accuracy: 1.0)
        // 坐标系：arAlign 是左段（基准）的（有平移时一起平移）
        let shift = res.originShift ?? .zero
        let a = try O.align(f.leftJ).translated(by: shift), b = try XCTUnwrap(MapGeometry.arAlign(root))
        XCTAssertEqual(a.phi, b.phi, accuracy: 1e-12)
        XCTAssertEqual(a.pRef.x, b.pRef.x, accuracy: 1e-9); XCTAssertEqual(a.pRef.y, b.pRef.y, accuracy: 1e-9)
        XCTAssertEqual(a.aRef, b.aRef)
        XCTAssertEqual(root["frameId"] as? String, "F1")
        // 右段的会议室桌子落在楼里正确的位置
        let table = try XCTUnwrap(StoreDataLoader.loadMap(res.json).physicalShelves.min {
            Point2($0.x, $0.y).distance(to: try! at(f, O.P(16, 2), shift: shift)) < Point2($1.x, $1.y).distance(to: try! at(f, O.P(16, 2), shift: shift))
        })
        XCTAssertLessThan(Point2(table.x, table.y).distance(to: try at(f, O.P(16, 2), shift: shift)), 2)
        // 注册表记下了单元编号
        XCTAssertEqual(res.registry.scans.first { $0.id == "s2" }?.unitIds, ["meeting": "R1", "hallR": "R2"])
        // 合成地图能直接被读成地图、根字段齐全
        XCTAssertEqual(root["floorName"] as? String, "办公室")
        XCTAssertEqual(root["source"] as? String, "roomplan")
        XCTAssertEqual((root["scans"] as? [Any])?.count, 2)
        XCTAssertNotNil(root["floorPolygons"])
    }

    func testDeterministic() throws {
        let f = try twoScans()
        let a = try MapComposer.compose(registry: f.reg, scans: f.scans)
        let b = try MapComposer.compose(registry: f.reg, scans: f.scans)
        XCTAssertEqual(a.json, b.json)
        // 用合成后的注册表再合成一次，结果的元素和单元不变（编号稳定）
        let c = try MapComposer.compose(registry: a.registry, scans: f.scans)
        let ra = try O.root(a.json), rc = try O.root(c.json)
        XCTAssertEqual(ra["units"] as? NSArray, rc["units"] as? NSArray)
        XCTAssertEqual(ra["mapElementList"] as? NSArray, rc["mapElementList"] as? NSArray)
    }

    func testDisableScanRestoresBase() throws {
        let f = try twoScans()
        let onlyLeft = ScanRegistry(mapId: "office", frameId: "F1", frameAlign: try O.align(f.leftJ), geometryVersion: 1,
                                    scans: [f.reg.scans[0]], name: "办公室")
        var ol = onlyLeft
        ol.canvasCm = f.reg.canvasCm
        let a = try MapComposer.compose(registry: ol, scans: ["s1": f.leftJ])
        let b = try MapComposer.compose(registry: f.reg.settingEnabled("s2", false, nowMs: 3000), scans: f.scans)
        let ra = try O.root(a.json), rb = try O.root(b.json)
        XCTAssertEqual(ra["units"] as? NSArray, rb["units"] as? NSArray)
        XCTAssertEqual(ra["mapElementList"] as? NSArray, rb["mapElementList"] as? NSArray)
        XCTAssertEqual(O.count(rb, "MapWall"), 6)
    }

    func testReplaceRescanKeepsIdsAndLabels() throws {
        var f = try twoScans()
        f.reg = f.reg.relabel(unit: "office", name: "办公区", nowMs: 2500)
        let first = try MapComposer.compose(registry: f.reg, scans: f.scans)
        let shift0 = first.originShift ?? .zero
        // 重扫办公区：另一个坐标系，墙整体偏了 8 cm；toMap 用真值（不含偏差）
        let off = O.P(0.08, 0)
        let rescan = try O.build(O.officeRescan, O.frameC, offset: off)
        let t = try O.truth(from: rescan, O.frameC, to: f.leftJ, O.frameA)     // 真值按楼里的位置算，偏差留在几何里
        var reg = first.registry
        reg = reg.adding(.init(id: "s3", createdMs: 3000, inBaseFrame: false, toMap: t.translated(by: shift0), alignment: .manual, mode: .replace), nowMs: 3000)
        var scans = f.scans
        scans["s3"] = rescan
        let res = try MapComposer.compose(registry: reg, scans: scans)
        let shift = shift0 + (res.originShift ?? .zero)
        let root = try O.root(res.json)
        XCTAssertEqual(O.count(root, "MapWall"), 7, "旧墙被裁掉的部分由新墙补上，共线的接起来")
        XCTAssertEqual(O.count(root, "MapDoor"), 3)
        XCTAssertEqual(O.count(root, "MapShelf"), 2)
        let units = MapGeometry.units(root)
        XCTAssertEqual(units.count, 5)
        let office = try XCTUnwrap(units.first { $0.id == "office" })
        XCTAssertEqual(office.name, "办公区")
        XCTAssertEqual(office.category, "room")
        XCTAssertEqual(res.registry.scans.first { $0.id == "s3" }?.unitIds["R1"], "office")
        XCTAssertEqual(res.registry.scans.first { $0.id == "s3" }?.replaces, ["office"])
        // 隔墙 x = 8 换成了新扫的（x = 8.08）
        let walls = MapGeometry.segments(root, types: ["MapWall"])
        let newV1 = try at(f, O.P(8.08, 2), shift: shift), oldV1 = try at(f, O.P(8, 2), shift: shift)
        XCTAssertTrue(walls.contains { $0.center.distance(to: newV1) < 3 })
        XCTAssertFalse(walls.contains { $0.center.distance(to: oldV1) < 3 })
        // 关掉重扫段：旧的回来
        let back = try MapComposer.compose(registry: res.registry.settingEnabled("s3", false, nowMs: 4000), scans: scans)
        let wb = MapGeometry.segments(try O.root(back.json), types: ["MapWall"])
        XCTAssertTrue(wb.contains { $0.center.distance(to: oldV1) < 3 })
    }

    func testGhostCopyOfOldRoomIsDropped() throws {
        let leftJ = try O.build(O.left, O.frameA, frameId: "F1")
        var reg = try ScanRegistry.newMap(mapId: "m", frameId: "F1", scanId: "s1", scanJSON: leftJ, createdMs: 1)
        // 站在办公区里又扫出半个办公区（墙抖动 8 cm）
        var ghost = O.Spec()
        ghost.walls = [(O.P(0, 0), O.P(3, 0)), (O.P(0, 0), O.P(0, 4)), (O.P(0, 4), O.P(3, 4))]
        ghost.rooms = [("R1", "room", (0, 0, 3, 4))]
        let gJ = try O.build(ghost, O.frameC, offset: O.P(0.05, -0.08))
        let t = try O.truth(from: gJ, O.frameC, to: leftJ, O.frameA)
        reg = reg.adding(.init(id: "s2", createdMs: 2, inBaseFrame: false, toMap: t, alignment: .geometry), nowMs: 2)
        let res = try MapComposer.compose(registry: reg, scans: ["s1": leftJ, "s2": gJ])
        let root = try O.root(res.json)
        XCTAssertEqual(MapGeometry.units(root).count, 3, "残缺的旧房间副本不能变成新单元")
        XCTAssertEqual(O.count(root, "MapWall"), 6, "抖动的墙和旧墙合并")
    }

    func testOriginShiftWhenGrowingTowardsNegative() throws {
        let leftJ = try O.build(O.left, O.frameA, frameId: "F1")
        let a = try O.align(leftJ)
        // 找楼里哪个方向在左段地图上是 −x，就往那边加一间
        let m0 = a.toMap(O.frameA.ar(O.P(0, 0)) * 100)
        func dirX(_ d: Point2) -> Double { a.toMap(O.frameA.ar(d) * 100).x - m0.x }
        let rect: (Double, Double, Double, Double)
        if dirX(O.P(1, 0)) < -50 { rect = (12, 0, 16, 4) } else if dirX(O.P(-1, 0)) < -50 { rect = (-4, 0, 0, 4) }
        else if dirX(O.P(0, 1)) < -50 { rect = (0, 7, 4, 11) } else { rect = (0, -4, 4, 0) }
        let (x0, y0, x1, y1) = rect
        var annex = O.Spec()
        annex.walls = [(O.P(x0, y0), O.P(x1, y0)), (O.P(x1, y0), O.P(x1, y1)), (O.P(x1, y1), O.P(x0, y1)), (O.P(x0, y1), O.P(x0, y0))]
        annex.rooms = [("R1", "room", rect)]
        let anJ = try O.build(annex, O.frameB)
        var reg = try ScanRegistry.newMap(mapId: "m", frameId: "F1", scanId: "s1", scanJSON: leftJ, createdMs: 1)
        let t = try O.truth(from: anJ, O.frameB, to: leftJ, O.frameA)
        reg = reg.adding(.init(id: "s2", createdMs: 2, inBaseFrame: false, toMap: t, alignment: .geometry), nowMs: 2)
        let res = try MapComposer.compose(registry: reg, scans: ["s1": leftJ, "s2": anJ])
        let s = try XCTUnwrap(res.originShift)
        XCTAssertGreaterThan(s.x, 0)
        XCTAssertEqual(s.x.truncatingRemainder(dividingBy: 50), 0)
        XCTAssertEqual(s.y.truncatingRemainder(dividingBy: 50), 0)
        XCTAssertEqual(res.registry.originOffsetCm, [s.x, s.y])
        let root = try O.root(res.json)
        let pts = (root["mapElementList"] as? [[String: Any]] ?? []).flatMap(MapGeometry.extentPoints)
        XCTAssertGreaterThanOrEqual(pts.map(\.x).min()!, 99)
        XCTAssertGreaterThanOrEqual(pts.map(\.y).min()!, 99)
        XCTAssertEqual(root["originOffsetCm"] as? [Double], [s.x, s.y])
        // arAlign 跟着平移：同一个 AR 点在地图上恰好挪了 s
        let b = try XCTUnwrap(MapGeometry.arAlign(root))
        let p = Point2(123, -456)
        XCTAssertEqual(b.toMap(p).distance(to: a.toMap(p) + s), 0, accuracy: 1e-6)
        // 画布变大（只增不减）
        XCTAssertGreaterThan(MapGeometry.num(root["width"])!, MapGeometry.num(try O.root(leftJ)["width"])!)
    }

    func testConsistencyReportsOffset() throws {
        let f = try twoScans()
        let t = f.reg.scans[1].transform
        let good = try MapComposer.consistency(new: f.rightJ, toMap: t, existing: f.leftJ)
        XCTAssertGreaterThan(good.overlapCm, 800)
        XCTAssertLessThan(good.residualCm, 0.5)
        // 整体偏 5 cm（左段地图是横平竖直的，所以每面墙的垂直偏差都是 5 cm）
        let bad = try MapComposer.consistency(new: f.rightJ, toMap: t.translated(by: Point2(5, 5)), existing: f.leftJ)
        XCTAssertEqual(bad.residualCm, 5, accuracy: 0.6)
        // 右段大部分不在左段里 → 建议追加；重扫办公区 → 建议替换
        XCTAssertEqual(try MapComposer.suggestedMode(new: f.rightJ, toMap: t, existing: f.leftJ), .append)
        let rescan = try O.build(O.officeRescan, O.frameC)
        let t3 = try O.truth(from: rescan, O.frameC, to: f.leftJ, O.frameA)
        XCTAssertEqual(try MapComposer.suggestedMode(new: rescan, toMap: t3, existing: f.leftJ), .replace)
    }

    func testLegacyMapComposesToItself() throws {
        // 老地图（没有注册表）：当前 map.json 当基准段，合成结果的元素、单元和原来一样
        let old = try RoomMapBuilder.build(VenueAuthoringTests.input(VenueAuthoringTests.frame0, ordinal: 0, names: ["office": "会议室 A"]), name: "1F").json
        let reg = try ScanRegistry.legacy(mapId: "room_1", mapJSON: old, sidecar: nil, newFrameId: "NEW", nowMs: 5)
        let res = try MapComposer.compose(registry: reg, scans: ["base": old])
        let a = try O.root(old), b = try O.root(res.json)
        XCTAssertEqual(MapGeometry.units(a), MapGeometry.units(b))
        XCTAssertEqual(O.count(a, "MapWall"), O.count(b, "MapWall"))
        XCTAssertEqual(O.count(a, "MapLabel"), O.count(b, "MapLabel"))
        XCTAssertEqual((a["connectors"] as? [Any])?.count, (b["connectors"] as? [Any])?.count)
        XCTAssertNil(res.originShift)
        XCTAssertEqual(a["width"] as? Double, b["width"] as? Double)
        XCTAssertEqual(a["ordinal"] as? Int, b["ordinal"] as? Int)
        XCTAssertEqual(a["venueId"] as? String, b["venueId"] as? String)
        let ga = try XCTUnwrap(GeoRef(dict: a["geoRef"] as? [String: Any])), gb = try XCTUnwrap(GeoRef(dict: b["geoRef"] as? [String: Any]))
        let p = Point2(500, 300)
        XCTAssertEqual(ga.toLonLat(p).lon, gb.toLonLat(p).lon, accuracy: 1e-9)
        XCTAssertEqual(b["frameId"] as? String, "NEW")
        XCTAssertEqual(try walkableArea(old), try walkableArea(res.json), accuracy: 0.01)
    }
}
