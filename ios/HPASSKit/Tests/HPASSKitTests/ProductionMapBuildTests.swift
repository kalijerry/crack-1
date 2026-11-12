import XCTest
@testable import HPASSKit

/// 云端出图流水线（MultiSessionFusion.buildProduction，hpass-build 和评估共用）：
/// 多个会话各带已知的整体磁场偏移，检查偏移解对、和会话顺序无关、和主体连不上的会话不进云端磁场图、
/// 评估默认（不筛、不排除）和 sequential 的行为。
final class ProductionMapBuildTests: XCTestCase {
    /// 四条互相重叠的路线（a 最长，当基准）+ 一条和别的都不重叠的（e，房间左边 x ≤ 110）。
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
    static let all = ["a", "b", "c", "d", "e"]

    var root: URL!
    var map: StoreMap!
    var fusion: MultiSessionFusion!

    override func setUpWithError() throws {
        map = try SyntheticRoom.map()
        fusion = MultiSessionFusion(map: map)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prodmap_\(UUID().uuidString)")
        for r in Self.routes {
            try SyntheticRoom.writeSession(root.appendingPathComponent("off/\(r.name)"), waypoints: r.waypoints, magOffset: (0, 0, r.dz))
            try SyntheticRoom.writeSession(root.appendingPathComponent("zero/\(r.name)"), waypoints: r.waypoints)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func dirs(_ set: String, _ names: [String]) -> [URL] { names.map { root.appendingPathComponent("\(set)/\($0)") } }
    func load(_ set: String, _ names: [String]) throws -> [SurveySession] { try dirs(set, names).map { try SurveySessionLoader.load($0) } }
    func build(_ set: String, _ names: [String] = all,
               _ options: MultiSessionFusion.ProductionOptions = .cloud) throws -> MultiSessionFusion.ProductionBuild {
        let s = try load(set, names)
        // 这里测的是偏移联合求解 / 分量排除，要求精确到 0.05 µT：关掉多遍对齐（它会把轨迹挪几厘米），对齐另有 SessionRegistrationTests
        var opt = options
        if opt.registration == nil { opt.registration = false }
        return try XCTUnwrap(fusion.buildProduction(s, ble: Array(repeating: [], count: s.count), options: opt))
    }
    func offset(_ r: MultiSessionFusion.Result, _ name: String) throws -> MagneticFeature {
        try XCTUnwrap(r.reports.first { $0.name == name }?.offsetUT, name)
    }

    /// 云端：偏移解对（解出的偏移比无偏移时多出的正好是注入的），每格均值和无偏移时一样，孤立会话不进磁场图
    func testCloudRemovesOffsetsAndExcludesIsolatedSession() throws {
        let off = try build("off"), zero = try build("zero")
        XCTAssertTrue(off.quality.allSatisfy(\.kept), "\(off.quality.map { ($0.name, $0.reason ?? "") })")
        XCTAssertEqual(off.components, 2)
        XCTAssertEqual(off.offMain, ["e"])
        XCTAssertEqual(off.magExcluded, ["e"])
        XCTAssertEqual(off.magnetic.reports.map(\.name), ["a", "b", "c", "d"])
        // 只看真有样本的格子（MagneticFieldBuilder.build 会往外补 150 cm）：e 走的 x ≤ 110（第 0～2 列）一个样本都没有
        let snap = off.magnetic.builder.snapshot(), cols = off.magnetic.builder.cols
        for (k, n) in snap.counts.enumerated() where k % cols < 3 { XCTAssertEqual(n, 0, "格 \(k)") }
        // 偏移：基准 a 固定 0；只加了竖直分量，所以和无偏移时比，竖直多 dz，水平不变
        for r in Self.routes where r.name != "e" {
            let o = try offset(off.magnetic, r.name), z = try offset(zero.magnetic, r.name)
            XCTAssertEqual(o.vertical - z.vertical, r.dz, accuracy: 0.05, r.name)
            XCTAssertEqual(o.horizontal - z.horizontal, 0, accuracy: 0.05, r.name)
            XCTAssertGreaterThan(try XCTUnwrap(off.magnetic.reports.first { $0.name == r.name }).samplesUsed, 100, r.name)
        }
        // 每格均值：减掉偏移后和无偏移时一样。总强度 |B| = √(Bh² + Bz²) 加竖直偏移后各处变化不一样
        // （dz·Bz/|B|，这里 Bz/|B| 在 0.76～0.96 之间），只能整体减一个中位数，所以放宽
        let zs = zero.magnetic.builder.snapshot()
        var compared = 0
        for k in snap.counts.indices where snap.counts[k] >= 5 && zs.counts[k] >= 5 {
            compared += 1
            XCTAssertEqual(snap.means[k * 3], zs.means[k * 3], accuracy: 2.0, "格 \(k) |B|")
            XCTAssertEqual(snap.means[k * 3 + 1], zs.means[k * 3 + 1], accuracy: 0.05, "格 \(k) Bz")
            XCTAssertEqual(snap.means[k * 3 + 2], zs.means[k * 3 + 2], accuracy: 0.05, "格 \(k) Bh")
        }
        XCTAssertGreaterThan(compared, 40)
    }

    /// 评估默认：不筛、不排除。主体部分和「不筛 + 只用主体」一样，孤立会话的格子也在图里
    func testEvalFusionKeepsIsolatedComponent() throws {
        let keep = try build("off", Self.all, .init(qualityGate: false, mainComponentOnly: false))
        let main = try build("off", Self.all, .init(qualityGate: false, mainComponentOnly: true))
        XCTAssertTrue(keep.quality.isEmpty)
        XCTAssertEqual(keep.components, 2)
        XCTAssertEqual(keep.offMain, ["e"])
        XCTAssertTrue(keep.magExcluded.isEmpty)
        XCTAssertEqual(keep.magnetic.reports.map(\.name), Self.all)
        XCTAssertNil(try XCTUnwrap(keep.magnetic.reports.last).offsetUT, "单独一个分量，没有偏移可解")
        let ks = keep.magnetic.builder.snapshot(), ms = main.magnetic.builder.snapshot(), cols = keep.magnetic.builder.cols
        var eCells = 0
        for k in ks.counts.indices {
            if k % cols < 3 { if ks.counts[k] >= 5 { eCells += 1 }; continue }
            XCTAssertEqual(ks.counts[k], ms.counts[k], "格 \(k)")
            guard ks.counts[k] > 0 else { continue }
            for c in 0..<3 { XCTAssertEqual(ks.means[k * 3 + c], ms.means[k * 3 + c], accuracy: 1e-6, "格 \(k)") }
        }
        XCTAssertGreaterThan(eCells, 5)
    }

    /// 结果和会话顺序无关（云端和评估默认两种）
    func testOrderIndependent() throws {
        let perm = ["d", "e", "b", "a", "c"]
        for opt in [MultiSessionFusion.ProductionOptions.cloud, .init(qualityGate: false, mainComponentOnly: false)] {
            let x = try build("off", Self.all, opt), y = try build("off", perm, opt)
            XCTAssertEqual(x.offMain, y.offMain)
            XCTAssertEqual(x.magExcluded, y.magExcluded)
            let xs = x.magnetic.builder.snapshot(), ys = y.magnetic.builder.snapshot()
            XCTAssertEqual(xs.counts, ys.counts)
            for k in xs.counts.indices where xs.counts[k] > 0 {
                for c in 0..<3 { XCTAssertEqual(xs.means[k * 3 + c], ys.means[k * 3 + c], accuracy: 1e-6, "格 \(k)") }
            }
            for r in x.magnetic.reports where r.offsetUT != nil {
                let o = try offset(y.magnetic, r.name), p = try XCTUnwrap(r.offsetUT)
                XCTAssertEqual(o.total, p.total, accuracy: 1e-6, r.name)
                XCTAssertEqual(o.vertical, p.vertical, accuracy: 1e-6, r.name)
                XCTAssertEqual(o.horizontal, p.horizontal, accuracy: 1e-6, r.name)
            }
        }
        // 评估接口：报告按输入顺序，磁场图一样
        let a = try SessionEvaluator.buildMaps(sessions: dirs("off", Self.all), map: map)
        let b = try SessionEvaluator.buildMaps(sessions: dirs("off", perm), map: map)
        XCTAssertEqual(b.reports.map(\.name), perm)
        XCTAssertEqual(a.field.coveredCells, b.field.coveredCells)
        for (p, q) in zip(a.field.cells, b.field.cells) {
            XCTAssertEqual(p == nil, q == nil)
            guard let p, let q else { continue }
            XCTAssertEqual(p.vertical, q.vertical, accuracy: 1e-6)
        }
    }

    /// 评估接口：production = 云端；默认 fusion 不排除但报出云端会排除谁
    func testBuildMapsModes() throws {
        let pr = try SessionEvaluator.buildMaps(sessions: dirs("off", Self.all), map: map, mode: .production)
        XCTAssertEqual(pr.components, 2)
        XCTAssertEqual(pr.magExcluded, ["e"])
        XCTAssertEqual(pr.offMain, ["e"])
        XCTAssertTrue(pr.rejected.isEmpty, "\(pr.rejected)")
        XCTAssertEqual(pr.reports.map(\.name), ["a", "b", "c", "d"])
        let cloud = try build("off", Self.all, .init(registration: true))   // 和 buildMaps 一样（这张图没有通道，自动对齐）
        XCTAssertEqual(pr.field.cells, cloud.magnetic.field.cells)
        let fu = try SessionEvaluator.buildMaps(sessions: dirs("off", Self.all), map: map)
        XCTAssertTrue(fu.magExcluded.isEmpty)
        XCTAssertEqual(fu.offMain, ["e"])
        XCTAssertEqual(fu.reports.map(\.name), Self.all)
        XCTAssertGreaterThan(fu.field.coveredCells, pr.field.coveredCells)
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
