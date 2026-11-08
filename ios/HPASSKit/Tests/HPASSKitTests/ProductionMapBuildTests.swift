import XCTest
@testable import HPASSKit

/// 评估建图（SessionEvaluator.buildMaps .fusion）= 云端出图流水线（MultiSessionFusion.buildProduction）：
/// 多个会话各带已知的整体磁场偏移，检查偏移被解掉、和会话顺序无关、和主体连不上的会话不进磁场图、sequential 还是老办法。
final class ProductionMapBuildTests: XCTestCase {
    /// 四条互相重叠的路线（a 最长，当基准）+ 一条和别的都不重叠的（e，房间左边）。
    /// 每条第一段都沿 +y 直走 ≥ 2 m（建图靠这段定 ARKit → 地图的旋转）
    static let routes: [(name: String, waypoints: [Point2], dz: Double)] = [
        ("a", SyntheticRoom.buildRoute, 0),
        ("b", [Point2(250, 150), Point2(250, 400), Point2(600, 400), Point2(600, 300), Point2(250, 300), Point2(250, 200),
               Point2(600, 200)], 8),
        ("c", [Point2(250, 150), Point2(250, 400), Point2(350, 400), Point2(350, 150), Point2(450, 150), Point2(450, 400),
               Point2(550, 400), Point2(550, 150)], -6),
        ("d", [Point2(300, 150), Point2(300, 400), Point2(550, 400), Point2(550, 250), Point2(350, 250)], 12),
        ("e", [Point2(60, 100), Point2(60, 450), Point2(110, 450), Point2(110, 100)], 4),
    ]

    var root: URL!
    var map: StoreMap!

    override func setUpWithError() throws {
        map = try SyntheticRoom.map()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prodmap_\(UUID().uuidString)")
        for r in Self.routes {
            try SyntheticRoom.writeSession(root.appendingPathComponent("off/\(r.name)"), waypoints: r.waypoints, magOffset: (0, 0, r.dz))
            try SyntheticRoom.writeSession(root.appendingPathComponent("zero/\(r.name)"), waypoints: r.waypoints)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func dirs(_ set: String, _ names: [String]) -> [URL] { names.map { root.appendingPathComponent("\(set)/\($0)") } }

    func testProductionRemovesOffsetsAndExcludesIsolatedSession() throws {
        let built = try SessionEvaluator.buildMaps(sessions: dirs("off", ["a", "b", "c", "d", "e"]), map: map, mode: .production)
        // e 和别的会话没有共同格子：单独一个连通分量，磁场图不用（和 hpass-build 一样）
        XCTAssertEqual(built.components, 2)
        XCTAssertEqual(built.magExcluded, ["e"])
        XCTAssertEqual(built.offMain, ["e"])
        XCTAssertTrue(built.rejected.isEmpty, "\(built.rejected)")
        XCTAssertEqual(built.reports.map(\.name), ["a", "b", "c", "d"])
        let f = built.field
        for row in 0..<f.rows { for col in 0..<3 { XCTAssertNil(f.cells[row * f.cols + col], "e 的格子不该进磁场图（\(col), \(row)）") } }
        // 解出的偏移 = 注入的偏移 − 基准（a，0）；只加了竖直分量，水平分量不变
        for r in Self.routes where r.name != "e" {
            let rep = try XCTUnwrap(built.reports.first { $0.name == r.name })
            let o = try XCTUnwrap(rep.offsetUT, r.name)
            XCTAssertEqual(o.vertical, r.dz, accuracy: 0.5, r.name)
            XCTAssertEqual(o.horizontal, 0, accuracy: 0.5, r.name)
            XCTAssertGreaterThan(rep.samplesUsed, 100, r.name)
        }
        // 每格均值 = 没有偏移时（同样路线、偏移都是 0）建出来的图
        let control = try SessionEvaluator.buildMaps(sessions: dirs("zero", ["a", "b", "c", "d", "e"]), map: map, mode: .production).field
        var compared = 0
        for (k, c) in f.cells.enumerated() {
            guard let c, let z = control.cells[k] else { continue }
            compared += 1
            XCTAssertEqual(c.vertical, z.vertical, accuracy: 0.3, "格 \(k)")
            XCTAssertEqual(c.horizontal, z.horizontal, accuracy: 0.3, "格 \(k)")
            XCTAssertEqual(c.total, z.total, accuracy: 0.6, "格 \(k)")
        }
        XCTAssertGreaterThan(compared, 40)
    }

    /// 评估默认（.fusion）：同一条流水线，只是孤立的分量留在图里；主体部分和 .production 一样
    func testFusionKeepsIsolatedComponent() throws {
        let ds = dirs("off", ["a", "b", "c", "d", "e"])
        let fu = try SessionEvaluator.buildMaps(sessions: ds, map: map)
        let pr = try SessionEvaluator.buildMaps(sessions: ds, map: map, mode: .production)
        XCTAssertEqual(fu.components, 2)
        XCTAssertTrue(fu.magExcluded.isEmpty)
        XCTAssertEqual(fu.offMain, ["e"])
        XCTAssertEqual(fu.reports.map(\.name), ["a", "b", "c", "d", "e"])
        XCTAssertNil(try XCTUnwrap(fu.reports.last).offsetUT, "单独一个分量，没有偏移可解")
        let f = fu.field
        var eCells = 0
        for (k, c) in f.cells.enumerated() {
            if k % f.cols < 3 { if c != nil { eCells += 1 }; continue }
            XCTAssertEqual(c == nil, pr.field.cells[k] == nil, "格 \(k)")
            guard let c, let p = pr.field.cells[k] else { continue }
            XCTAssertEqual(c.vertical, p.vertical, accuracy: 1e-6, "格 \(k)")
        }
        XCTAssertGreaterThan(eCells, 5)
    }

    func testFusionIsOrderIndependent() throws {
        let a = try SessionEvaluator.buildMaps(sessions: dirs("off", ["a", "b", "c", "d", "e"]), map: map)
        let b = try SessionEvaluator.buildMaps(sessions: dirs("off", ["d", "e", "b", "a", "c"]), map: map)
        XCTAssertEqual(a.field.coveredCells, b.field.coveredCells)
        for (x, y) in zip(a.field.cells, b.field.cells) {
            XCTAssertEqual(x == nil, y == nil)
            guard let x, let y else { continue }
            XCTAssertEqual(x.total, y.total, accuracy: 1e-6)
            XCTAssertEqual(x.vertical, y.vertical, accuracy: 1e-6)
            XCTAssertEqual(x.horizontal, y.horizontal, accuracy: 1e-6)
        }
        XCTAssertEqual(b.offMain, ["e"])
        // 报告按输入顺序
        XCTAssertEqual(b.reports.map(\.name), ["d", "e", "b", "a", "c"])
        for r in a.reports where r.name != "e" {
            let o = try XCTUnwrap(b.reports.first { $0.name == r.name }?.offsetUT)
            XCTAssertEqual(o.vertical, try XCTUnwrap(r.offsetUT).vertical, accuracy: 1e-6)
        }
    }

    func testSequentialModeIsOldIncrementalBuilder() throws {
        let ds = dirs("off", ["b", "a", "c", "d"])
        let built = try SessionEvaluator.buildMaps(sessions: ds, map: map, mode: .sequential)
        let b = SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses)
        var names: [String] = []
        for d in ds { names.append(b.add(try SurveySessionLoader.load(d)).name) }
        let ref = b.build()
        XCTAssertEqual(built.reports.map(\.name), names)
        XCTAssertEqual(built.components, 1)
        XCTAssertTrue(built.magExcluded.isEmpty)
        XCTAssertEqual(built.field.cells, ref.cells)
    }
}
