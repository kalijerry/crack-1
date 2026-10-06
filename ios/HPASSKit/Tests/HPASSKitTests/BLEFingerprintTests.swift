import Foundation
import XCTest
@testable import HPASSKit

final class BLEFingerprintTests: XCTestCase {
    /// 沿一条 30 m 的直线走，两边每 2 m 一个价签，信号随距离衰减：
    /// 学出来的价签位置在路线附近，用某处听到的信号估位置误差在几米内。
    func testTagPositionsAndEstimate() {
        var tags: [(String, Point2)] = []
        for k in 0..<15 { tags.append(("T\(k)", Point2(100 + Double(k) * 200, 400 + (k % 2 == 0 ? 150 : -150)))) }
        func rssi(_ p: Point2, _ t: Point2) -> Double { -55 - 20 * log10(max(p.distance(to: t), 50) / 100) }
        var track: [(tMs: Int64, p: Point2)] = []
        var samples: [BLESample] = []
        for i in 0...300 {
            let t = Int64(i * 100)
            let p = Point2(100 + Double(i) * 10, 400)
            track.append((t, p))
            for (id, tp) in tags where rssi(p, tp) > -90 && i % 3 == 0 { samples.append(BLESample(tMs: t, id: id, rssi: rssi(p, tp))) }
        }
        let b = BLEFingerprintBuilder(widthCm: 3500, heightCm: 1000)
        b.maxSpreadCm = .infinity    // 这里的衰减模型很平缓（30 m 外还很响），不测「移动设备」过滤（见 Phase2Tests）
        XCTAssertGreaterThan(b.add(samples: samples, track: track), 100)
        let m = b.build()
        XCTAssertEqual(m.tags.count, 15)
        // 价签位置被拉到走过的路线上（y = 400），x 大致对
        XCTAssertEqual(m.tags["T7"]!.x, 1500, accuracy: 150)
        let here = Point2(1600, 400)
        var obs: [String: Double] = [:]
        for (id, tp) in tags { let r = rssi(here, tp); if r > -90 { obs[id] = r } }
        let e = m.estimateByTags(obs)!
        XCTAssertLessThan(e.position.distance(to: here), 300)
    }

    func testPositionPriorPullsColdStartParticles() {
        let cross = CrossSegment(code: "C", a: Point2(100, 500), b: Point2(5900, 500), lineWidth: 200)
        var cells = [MagneticFeature?](), sig = [MagneticFeature?]()
        for _ in 0..<(120 * 20) { cells.append(MagneticFeature(total: 50, vertical: 40, horizontal: 30)); sig.append(MagneticFeature(total: 1, vertical: 1, horizontal: 1)) }
        let f = MagneticFieldMap(widthCm: 6000, heightCm: 1000, cellCm: 50, cells: cells, sigmas: sig)
        let loc = MagneticLocalizer(field: f, walkable: WalkableMap(crosses: [cross], widthCm: 6000, heightCm: 1000))
        loc.reset(start: nil, headingUnknown: true)
        loc.applyPositionPrior(Point2(4000, 500), sigmaCm: 300, weight: 1, injectFraction: 0.2)
        let e = loc.step(delta: .zero, feature: MagneticFeature(total: 50, vertical: 40, horizontal: 30))
        XCTAssertLessThan(e.position.distance(to: Point2(4000, 500)), 800)
    }
}
