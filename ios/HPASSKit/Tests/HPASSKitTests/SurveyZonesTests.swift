import XCTest
@testable import HPASSKit

final class SurveyZonesTests: XCTestCase {
    /// 20 条 40 m 长、2 m 宽的平行通道（每条三条走线 = 120 m），总 2.4 km，按 400 m 一块分
    func makeZones() -> (SurveyZones, CoveragePaint, [CrossSegment]) {
        let crosses = (0..<20).map { i in
            CrossSegment(code: "C\(i)", a: Point2(Double(i) * 500 + 300, 200), b: Point2(Double(i) * 500 + 300, 4200), lineWidth: 200)
        }
        let zs = SurveyZones(crosses: crosses, targetLaneCm: 40_000)
        let p = CoveragePaint(crosses: crosses, widthCm: 10_500, heightCm: 4_500)
        return (zs, p, crosses)
    }

    func testPartitionIsCompactAndCoversEverything() {
        let (zs, _, _) = makeZones()
        XCTAssertGreaterThanOrEqual(zs.zones.count, 4)
        XCTAssertEqual(zs.zones.reduce(0) { $0 + $1.laneCm }, zs.planner.lanes.reduce(0) { $0 + $1.length }, accuracy: 1)
        for z in zs.zones { XCTAssertLessThanOrEqual(z.laneCm, 40_000 * 1.3) }
        XCTAssertEqual(zs.zones.map(\.id), Array(1...zs.zones.count))
    }

    func testNextZoneFinishesStartedThenNeighbour() {
        let (zs, p, _) = makeZones()
        // 什么都没采：离我最近的
        let near = zs.next(p, from: Point2(300, 200))
        XCTAssertEqual(zs.zone(near)?.corridors.contains("C0"), true)
        // 把这块采一半：继续它
        guard let z = zs.zone(near) else { return XCTFail() }
        let lanes = zs.lanes(z)
        for l in lanes.prefix(lanes.count / 2) {
            p.breakStroke()
            for k in 0...40 { p.paint(at: l.a + (l.b - l.a) * (Double(k) / 40)) }
        }
        XCTAssertEqual(zs.next(p), z.id)
        // 采完：下一块要挨着已采部分，并给出入口
        for l in lanes { p.breakStroke(); for k in 0...40 { p.paint(at: l.a + (l.b - l.a) * (Double(k) / 40)) } }
        XCTAssertTrue(zs.status(p).first { $0.id == z.id }!.done)
        guard let n = zs.next(p), let nz = zs.zone(n) else { return XCTFail() }
        XCTAssertNotEqual(n, z.id)
        let e = zs.entry(nz, paint: p)
        XCTAssertNotNil(e)
        let gap = nz.pieces.map { SurveyZones.segDist(e!, $0.a, $0.b) }.min()!
        XCTAssertLessThan(gap, 800)      // 相邻：入口离新区域 < 8 m
    }
}
