import XCTest
@testable import HPASSKit

/// App 0.1.22～0.1.23：手机睡眠后 arkit_pose.csv 的时间比 IMU / 锚点慢几十秒，加载时按锚点对回来
final class PoseClockOffsetTests: XCTestCase {
    /// 走一条 L 形：前 30 秒原地，之后 1 m/s 往 −x 走 20 秒，再往 −y 走 20 秒（30 Hz 位姿）
    private func walk(start: Int64, lagMs: Int64) -> [SurveySession.Pose] {
        (0..<(70 * 30)).map { k -> SurveySession.Pose in
            let s = Double(k) / 30
            let x: Double = s < 30 ? 0 : -min(s - 30, 20) * 100
            let y: Double = s < 50 ? 0 : -(s - 50) * 100
            return SurveySession.Pose(tMs: start + Int64(s * 1000) - lagMs, a: Point2(x, y), normal: true)
        }
    }

    private func anchors(start: Int64) -> [SurveySession.Anchor] {
        [SurveySession.Anchor(tMs: start + 32_000, kind: "start", map: Point2(1339, 121), ar: Point2(-200, 0), heading: nil),
         SurveySession.Anchor(tMs: start + 60_000, kind: "end", map: Point2(1644, 1786), ar: Point2(-2000, -1000), heading: nil)]
    }

    func testLaggedPosesAreDetected() throws {
        let t0: Int64 = 1_794_495_651_883
        let off = try XCTUnwrap(SurveySessionLoader.poseClockOffsetMs(poses: walk(start: t0, lagMs: 48_250), anchors: anchors(start: t0)))
        XCTAssertEqual(Double(off), -48_250, accuracy: 30)
    }

    func testNormalSessionUntouched() {
        let t0: Int64 = 1_794_491_909_862
        XCTAssertNil(SurveySessionLoader.poseClockOffsetMs(poses: walk(start: t0, lagMs: 0), anchors: anchors(start: t0)))
    }
}
