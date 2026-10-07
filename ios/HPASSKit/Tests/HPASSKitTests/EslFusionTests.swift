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
}
