import Foundation
import XCTest
@testable import HPASSKit

final class Phase2Tests: XCTestCase {
    private let crosses = [CrossSegment(code: "W", a: Point2(100, 500), b: Point2(2100, 500), lineWidth: 200),
                           CrossSegment(code: "N", a: Point2(100, 900), b: Point2(2100, 900), lineWidth: 80)]

    /// 2 m 宽的通道三条走线（两边 + 中间，宽于 4 个圆圈半径），0.8 m 的一条；涂完一条之后下一段换别的
    func testPlannerLanesAndNext() {
        let p = CoveragePaint(crosses: crosses, widthCm: 2300, heightCm: 1200)
        let plan = SurveyPlanner(crosses: crosses, radiusCm: p.radiusCm)
        XCTAssertEqual(plan.lanes.filter { $0.corridor == "W" }.count, 3)
        XCTAssertEqual(plan.lanes.filter { $0.corridor == "N" }.count, 1)
        let n1 = plan.next(from: Point2(100, 440), paint: p)!
        XCTAssertEqual(n1.lane.corridor, "W")
        XCTAssertEqual(n1.from.distance(to: Point2(100, 440)), 0, accuracy: 60)
        let before = plan.remainingCm(p)
        for x in stride(from: 100.0, through: 2100, by: 15) { p.paint(at: Point2(x, n1.from.y)) }
        XCTAssertLessThan(plan.remainingCm(p), before - 1500)
        let n2 = plan.next(from: Point2(2100, n1.from.y), paint: p)!
        XCTAssertNotEqual(n2.from.y, n1.from.y, accuracy: 10)      // 换到另一侧或另一条通道
    }

    /// 增量建图：累积状态存盘再读回，蓝牙价签一个不少；名单过滤生效
    func testBLEStateRoundTripAndWhitelist() throws {
        let b = BLEFingerprintBuilder(widthCm: 2300, heightCm: 1200)
        b.whitelist = ["AA-AA-AA-AA", "BB-BB-BB-BB"]
        for i in 0..<20 {
            let p = Point2(100 + Double(i) * 50, 500)
            b.add(position: p, id: "AA-AA-AA-AA", rssi: -60)
            b.add(position: p, id: "BB-BB-BB-BB", rssi: -70)
            b.add(position: p, id: "CC-CC-CC-CC", rssi: -65)       // 不在名单
        }
        let data = try JSONEncoder().encode(b.state())
        let b2 = BLEFingerprintBuilder(state: try JSONDecoder().decode(BLEFingerprintBuilder.State.self, from: data))
        let m = b2.build()
        XCTAssertEqual(Set(m.tags.keys), ["AA-AA-AA-AA", "BB-BB-BB-BB"])
        XCTAssertEqual(BLEFingerprintBuilder.parseIdList("id\n88-a7-20-91, x\nFE-D7-85-92").count, 2)
    }

    /// 到处都听得到的「价签」（跟着人走的设备）不进指纹
    func testMovingDeviceRejected() {
        let b = BLEFingerprintBuilder(widthCm: 10000, heightCm: 1200)
        for i in 0..<100 {
            let p = Point2(100 + Double(i) * 90, 500)
            b.add(position: p, id: "PHONE", rssi: -50)                // 走了 90 m 一直很响
            if i < 10 { b.add(position: p, id: "TAG", rssi: -60) }    // 只在开头 9 m 听得到
        }
        let m = b.build()
        XCTAssertNil(m.tags["PHONE"])
        XCTAssertNotNil(m.tags["TAG"])
    }
}
