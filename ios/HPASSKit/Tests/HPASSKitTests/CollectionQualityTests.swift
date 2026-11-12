import XCTest
@testable import HPASSKit

/// 采集时质量打分：合成 10 Hz 的位姿 + 磁场，沿 x 以 1 m/s 走
final class CollectionQualityTests: XCTestCase {
    private let T0: Int64 = 1_700_000_000_000

    /// 走 seconds 秒。tracking / magShape：第 k 个样本（0.1 秒一个）跟踪是否正常、磁场额外的形状差（µT）
    @discardableResult
    private func walk(_ m: CollectionQualityMonitor, seconds: Int, speedMS: Double = 1.0,
                      tracking: (Int) -> Bool = { _ in true }, magShape: (Int) -> Double = { _ in 0 },
                      each: ((Int, Int64) -> Void)? = nil) -> Int64 {
        var t = T0
        for k in 0..<(seconds * 10) {
            t = T0 + Int64(k * 100)
            let x = Double(k) * speedMS * 10
            let ok = tracking(k)
            m.pose(tMs: t, position: ok ? Point2(x, 0) : nil, trackingOK: ok, speedMS: speedMS, imuHz: 100)
            let f = 45 + 5 * sin(x / 200)
            m.mag(tMs: t, totalUT: f + 12 + magShape(k), expectedUT: f)   // 整体偏 12 µT（不算问题）
            each?(k, t)
        }
        return t
    }

    func testGoodWalkKeepsEverything() {
        let m = CollectionQualityMonitor()
        let t = walk(m, seconds: 120)
        XCTAssertNil(m.live.stopReason)
        XCTAssertEqual(m.live.level, .good)
        let q = m.finish(tMs: t)
        XCTAssertTrue(q.kept, q.reason ?? "")
        XCTAssertEqual(q.score, 100)
        XCTAssertEqual(q.grade, "好")
        XCTAssertEqual(q.counted, 12)
        XCTAssertEqual(q.bad, 0)
        XCTAssertTrue(q.droppedSpansMs.isEmpty)
    }

    func testTrackingLostAutoStopsAndRejects() {
        let m = CollectionQualityMonitor()
        var stoppedAt: Int?
        // 前 60 秒正常，后 40 秒 ARKit 跟丢
        let t = walk(m, seconds: 100, tracking: { $0 < 600 }, each: { k, _ in
            if stoppedAt == nil, m.live.stopReason != nil { stoppedAt = k }
        })
        XCTAssertNotNil(m.live.stopReason)
        // 连续 3 段（30 秒）差才停：第 6、7、8 段差，第 8 段结束（90 秒）时停
        XCTAssertEqual(stoppedAt, 900)
        XCTAssertTrue(m.live.stopReason?.contains("相机跟丢了") ?? false, m.live.stopReason ?? "")
        let q = m.finish(tMs: t, autoStopped: true)
        XCTAssertTrue(q.autoStopped)
        XCTAssertEqual(q.bad, 4)
        XCTAssertFalse(q.kept)                                  // 10 段里 4 段差 > 30%
        XCTAssertEqual(q.issueCounts["tracking"], 4)
        // 差段连同前一段（第 5 段）一起丢
        XCTAssertEqual(q.droppedSpansMs, [[T0 + 50_000, T0 + 100_000]])
    }

    func testShortSessionRejected() {
        let m = CollectionQualityMonitor()
        let q = m.finish(tMs: walk(m, seconds: 10))
        XCTAssertFalse(q.kept)
        XCTAssertTrue(q.reason?.hasPrefix("太短") ?? false, q.reason ?? "")
    }

    func testMagMismatchDropsOneWindowWithNeighbours() {
        let m = CollectionQualityMonitor()
        // 第 5 段（50～60 秒）磁场形状和已有地图对不上
        let t = walk(m, seconds: 120, magShape: { k in (500..<600).contains(k) ? 15 * sin(Double(k)) : 0 })
        XCTAssertNil(m.live.stopReason)
        let q = m.finish(tMs: t)
        let w5 = q.windowList[5]
        XCTAssertTrue(w5.bad)
        XCTAssertTrue(w5.issues.contains(.magMismatch))
        XCTAssertEqual(q.bad, 1)
        XCTAssertTrue(q.kept, q.reason ?? "")                   // 1/12 段差，整体照用
        XCTAssertNil(q.mapStale)
        XCTAssertEqual(q.droppedSpansMs, [[T0 + 40_000, T0 + 70_000]])
        XCTAssertEqual(q.droppedSpans, [[40, 70]])
    }

    /// 整段都和已有地图对不上（地图过期 / 当初带磁吸配件采的）：不自动停、不剔除，标 mapStale，好让云端用它重建
    func testWholeSessionMapMismatchMeansStaleMap() {
        let m = CollectionQualityMonitor()
        let t = walk(m, seconds: 120, magShape: { k in 15 * sin(Double(k)) })
        XCTAssertNil(m.live.stopReason)
        let q = m.finish(tMs: t)
        XCTAssertEqual(q.mapStale, true)
        XCTAssertTrue(q.kept, q.reason ?? "")
        XCTAssertEqual(q.bad, 0)
        XCTAssertTrue(q.droppedSpansMs.isEmpty)
        XCTAssertGreaterThan(q.issueCounts["magMismatch"] ?? 0, 6)      // 问题照样记下来
    }

    /// 地图过期也不放过别的问题：跟丢照样停
    func testStaleMapStillStopsOnTrackingLoss() {
        let m = CollectionQualityMonitor()
        walk(m, seconds: 100, tracking: { $0 < 600 }, magShape: { k in 15 * sin(Double(k)) })
        XCTAssertTrue(m.live.stopReason?.contains("相机跟丢了") ?? false, m.live.stopReason ?? "")
    }

    func testBigCorrectionMarksDrift() {
        let m = CollectionQualityMonitor()
        let t = walk(m, seconds: 60, each: { k, t in if k == 350 { m.correction(tMs: t, jumpCm: 800) } })
        let q = m.finish(tMs: t)
        XCTAssertTrue(q.windowList[3].issues.contains(.jump))
        XCTAssertEqual(q.bad, 1)
    }

    func testLiveHintWhileWalkingTooFast() {
        let m = CollectionQualityMonitor()
        walk(m, seconds: 3, speedMS: 2.0)
        XCTAssertTrue(m.live.issues.contains(.tooFast))
        XCTAssertNil(m.live.score)                              // 还没有完整的一段
    }

    func testQualityJSONReadBackByLoader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(SurveySessionLoader.qualityDrops(dir).isEmpty)       // 旧会话：没打分，不丢
        XCTAssertNil(SurveySessionLoader.qualityRejected(dir))

        let m = CollectionQualityMonitor()
        let q = m.finish(tMs: walk(m, seconds: 100, tracking: { $0 < 600 }))
        try q.write(to: dir)
        XCTAssertEqual(SurveySessionLoader.qualityDrops(dir), [(T0 + 50_000)...(T0 + 100_000)])
        XCTAssertNotNil(SurveySessionLoader.qualityRejected(dir))

        let ok = CollectionQualityMonitor()
        try ok.finish(tMs: walk(ok, seconds: 60)).write(to: dir)
        XCTAssertNil(SurveySessionLoader.qualityRejected(dir))
    }
}
