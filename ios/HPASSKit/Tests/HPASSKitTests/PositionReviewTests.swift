import XCTest
@testable import HPASSKit

final class PositionReviewTests: XCTestCase {

    func testErrorsAndShares() {
        var s = PositionReviewStats()
        let truth = Point2(0, 0)
        // 误差 50、150、250、350 cm，最后一个没估计
        for (i, e) in [50.0, 150, 250, 350].enumerated() {
            let err = s.add(tMs: Int64(i) * 200, truth: truth, estimate: Point2(e, 0), converged: i < 2)
            XCTAssertEqual(err ?? -1, e, accuracy: 1e-9)
        }
        XCTAssertNil(s.add(tMs: 800, truth: truth, estimate: nil, converged: false))
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.truthSamples, 5)
        XCTAssertEqual(s.medianCm ?? 0, 200, accuracy: 1e-9)          // 插值：(150 + 250) / 2
        XCTAssertEqual(s.p90Cm ?? 0, 320, accuracy: 1e-9)             // 250 + 0.7 × 100
        XCTAssertEqual(s.convergedMedianCm ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(s.withinShare(100) ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(s.withinShare(200) ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.estimateShare ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertNil(s.lastErrorCm)
        let sum = s.summary()
        XCTAssertEqual(sum["err_median_m"] as? Double, 2.0)
        XCTAssertEqual(sum["within_2m"] as? Double, 0.5)
        XCTAssertNil(sum["settle_s"])
    }

    /// 误差连续 3 秒在 2 m 内才算稳定；中间跳出去要重新计时
    func testSettleNeedsThreeSecondsWithinTwoMeters() {
        var s = PositionReviewStats()
        var t: Int64 = 10_000
        func feed(_ err: Double, seconds: Double) {
            for _ in 0..<Int(seconds * 5) {
                s.add(tMs: t, truth: .zero, estimate: Point2(err, 0), converged: true)
                t += 200
            }
        }
        feed(500, seconds: 4)           // 0–4 s 偏 5 m
        feed(100, seconds: 2)           // 4–6 s 进 2 m，但不够 3 秒
        feed(300, seconds: 1)           // 跳出去
        XCTAssertNil(s.secondsToSettle)
        feed(80, seconds: 4)            // 7 s 起稳定
        XCTAssertEqual(s.secondsToSettle ?? -1, 7, accuracy: 1e-9)
    }
}
