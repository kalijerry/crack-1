import XCTest
@testable import HPASSKit

/// 价签锚定修正 + 质量筛选：合成一条沿 x 走的路，中间一段轨迹被推偏 12 m
final class EslFusionTests: XCTestCase {
    func scenario() -> (track: [(tMs: Int64, p: Point2)], ble: [BLESample], tags: [String: Point2]) {
        var tags: [String: Point2] = [:]
        for i in 0..<120 { tags["T\(i)"] = Point2(Double(i) * 50, i % 2 == 0 ? 150 : -150) }
        var track: [(tMs: Int64, p: Point2)] = [], ble: [BLESample] = []
        for k in 0..<600 {                       // 60 秒，1 m/s
            let t = Int64(k * 100), x = Double(k) * 10
            let drift = (200...400).contains(k) ? 1200.0 : 0   // 20–40 秒偏 12 m
            track.append((t, Point2(x, drift)))
            if k % 2 == 0 {
                let i = min(Int(x / 50), 119)
                ble.append(BLESample(tMs: t, id: "T\(i)", rssi: -66))
            }
        }
        return (track, ble, tags)
    }

    func testCorrectorPullsDriftBack() {
        let s = scenario()
        let c = EslTrajectoryCorrector(tagPositions: s.tags)
        c.smoothCm = 600
        guard let (fn, st) = c.solve(track: s.track, ble: s.ble) else { return XCTFail("没解") }
        XCTAssertGreaterThan(st.maxShiftM, 10)
        XCTAssertLessThan(st.afterMedianM, 2.5)
        XCTAssertLessThan(abs(fn(30_000).y + 1200), 300)   // 偏的那段拉回来
        XCTAssertLessThan(abs(fn(5_000).y), 300)           // 正常的段不乱动
    }

    func testGateRejectsDriftedSession() {
        let s = scenario()
        let g = SessionQualityGate(tagPositions: s.tags)
        g.minGoodSamples = 0
        let v = g.evaluate(name: "x", track: s.track, ble: s.ble, mag: [], others: nil, othersBuilder: nil)
        XCTAssertGreaterThan(v.report.bad, 0)
        XCTAssertFalse(v.report.kept)                       // 能判断的段里 1/3 不合格 > 30%
        let ok = g.evaluate(name: "y", track: s.track.map { ($0.tMs, Point2($0.p.x, 0)) }, ble: s.ble, mag: [], others: nil, othersBuilder: nil)
        XCTAssertTrue(ok.report.kept)
        XCTAssertEqual(ok.report.bad, 0)
    }

    func testShelfSignParse() {
        XCTAssertEqual(ShelfSigns.parse("082-20")?.aisle, 82)
        XCTAssertEqual(ShelfSigns.parse("O82 - 2O")?.bay, 20)
        XCTAssertEqual(ShelfSigns.parse("货位 067-02 ABC")?.aisle, 67)
        XCTAssertNil(ShelfSigns.parse("1082-201"))
        XCTAssertNil(ShelfSigns.parse("IP54"))
    }

    /// 只有货架标签、没有价签：每 10 秒读到一次标签（人在 y≈0 的通道里），中间 20 秒轨迹偏 12 m
    func testSignsAloneCorrectDrift() {
        let s = scenario()
        // 区域：x 在读到时真实位置 ±150、y 在 [-100, 100]
        var signs: [EslTrajectoryCorrector.SignObservation] = []
        for k in stride(from: 0, to: 600, by: 50) {
            let x = Double(k) * 10
            signs.append(.init(tMs: Int64(k * 100), region: { p in Point2(min(max(p.x, x - 150), x + 150), min(max(p.y, -100), 100)) }))
        }
        let c = EslTrajectoryCorrector(tagPositions: [:])
        c.smoothCm = 600
        guard let (fn, st) = c.solve(track: s.track, ble: [], signs: signs) else { return XCTFail("没解") }
        XCTAssertEqual(st.signs, signs.count)
        XCTAssertLessThan(abs(fn(30_000).y + 1200), 300)
        XCTAssertLessThan(abs(fn(5_000).y), 150)
        // 质量检查：偏的那段被标出来
        let g = SessionQualityGate(tagPositions: [:])
        g.minGoodSamples = 0
        let dist: [(tMs: Int64, distanceTo: (Point2) -> Double)] = signs.map { sg in (sg.tMs, { p in p.distance(to: sg.region(p)) }) }
        let v = g.evaluate(name: "x", track: s.track, ble: [], mag: [], others: nil, othersBuilder: nil, signs: dist)
        XCTAssertGreaterThan(v.report.bad, 0)
    }
}


final class TagRangeFixTests: XCTestCase {
    func testFixAndNearestConsistent() {
        // 人在 (1000, 500)；四片价签在周围 1～3 m，信号对应范围 3.5～6 m
        let tags: [TagRangeFix.Tag] = [(Point2(1100, 500), 350), (Point2(900, 600), 420), (Point2(1000, 300), 600), (Point2(1250, 450), 600)]
        let f = TagRangeFix.fix(tags)!
        XCTAssertLessThan(f.position.distance(to: Point2(1000, 500)), 250)
        XCTAssertEqual(TagRangeFix.agreement(tags, at: Point2(1000, 500)), 1)
        // 轨迹偏到 (3000, 500)：最近的一致点回到价签附近
        let q = TagRangeFix.nearestConsistent(tags, to: Point2(3000, 500))!
        XCTAssertLessThan(q.distance(to: Point2(1000, 500)), 700)
    }

    func testMapHeading() {
        // 地图上方 = 318°；罗盘 318° → 朝地图上方（-y）= π；罗盘 48°（上方顺时针 90°）→ 朝 +x = π/2
        XCTAssertEqual(abs(TagRangeFix.mapHeading(compassDeg: 318, mapUpBearingDeg: 318)), Double.pi, accuracy: 1e-9)
        XCTAssertEqual(TagRangeFix.mapHeading(compassDeg: 48, mapUpBearingDeg: 318), Double.pi / 2, accuracy: 1e-9)
    }
}
