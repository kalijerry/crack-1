import Foundation
import XCTest
@testable import HPASSKit

final class CoveragePaintTests: XCTestCase {
    /// 一条 2 m 宽、20 m 长的横通道
    private let crosses = [CrossSegment(code: "C", a: Point2(100, 500), b: Point2(2100, 500), lineWidth: 200)]

    func testCenterPassPaintsOnlyPartOfWidthEdgesFillIt() {
        let p = CoveragePaint(crosses: crosses, widthCm: 2300, heightCm: 1000)
        for x in stride(from: 100.0, through: 2100, by: 15) { p.paint(at: Point2(x, 500)) }
        let center = p.fraction(corridor: 0)
        XCTAssertGreaterThan(center, 0.3)
        XCTAssertLessThan(center, 0.5)                  // 圆圈 40 cm：只涂到 2 m 宽里的约 80 cm
        p.breakStroke()
        for x in stride(from: 2100.0, through: 100, by: -15) { p.paint(at: Point2(x, 440)) }
        p.breakStroke()
        for x in stride(from: 100.0, through: 2100, by: 15) { p.paint(at: Point2(x, 560)) }
        XCTAssertGreaterThan(p.fraction(corridor: 0), 0.8)
        XCTAssertEqual(p.corridorIndex(at: Point2(800, 520)), 0)
        XCTAssertNil(p.corridorIndex(at: Point2(800, 800)))
    }

    /// 同一趟里反复涂同一格只算一次；走开再回来算第二趟
    func testPassCounting() {
        let p = CoveragePaint(crosses: crosses, widthCm: 2300, heightCm: 1000)
        for _ in 0..<20 { p.paint(at: Point2(1000, 500)) }
        let k = (500 / 25) * p.cols + 1000 / 25
        XCTAssertEqual(p.counts[k], 1)
        for x in stride(from: 1000.0, through: 1500, by: 15) { p.paint(at: Point2(x, 500)) }
        for x in stride(from: 1500.0, through: 1000, by: -15) { p.paint(at: Point2(x, 500)) }
        XCTAssertEqual(p.counts[k], 2)
    }

    func testSerializeRoundTrip() {
        let p = CoveragePaint(crosses: crosses, widthCm: 2300, heightCm: 1000)
        for x in stride(from: 100.0, through: 900, by: 15) { p.paint(at: Point2(x, 500)) }
        let q = CoveragePaint(crosses: crosses, widthCm: 2300, heightCm: 1000)
        XCTAssertTrue(q.load(p.serialized()))
        XCTAssertEqual(q.paintedCells, p.paintedCells)
        let other = CoveragePaint(crosses: crosses + crosses, widthCm: 2300, heightCm: 1000)
        XCTAssertFalse(other.load(p.serialized()))      // 换了地图不读
    }
}
