import Foundation
import XCTest
@testable import HPASSKit

/// 地图自愈：实时定位记录的可信度筛选、磁力计样本定位、低权重并入磁场图（合成数据）
final class LiveRunTests: XCTestCase {
    // 一条沿 y = 2000 往 +x 走的轨迹，1 m/s、10 Hz，价签每 3 m 一片（在 y = 2200）
    private let tags: [String: Point2] = Dictionary(uniqueKeysWithValues: (0..<60).map { ("t\($0)", Point2(Double($0) * 300, 2200)) })

    private func truth(_ sec: Double) -> Point2 { Point2(sec * 100, 2000) }

    private func track(seconds: Int, conf: Double = 0.9, shift: (from: Double, to: Double, cm: Double)? = nil) -> [LiveTrackRow] {
        (0...(seconds * 10)).map { i in
            let sec = Double(i) / 10
            var p = truth(sec)
            if let s = shift, sec >= s.from, sec < s.to { p = Point2(p.x + s.cm, p.y) }
            return LiveTrackRow(tMs: 1_000_000 + Int64(i * 100), p: p, uncCm: 100, conf: conf)
        }
    }

    /// 人真实走到的位置附近的价签（距离 ≤ 6 m）按距离给信号
    private func ble(seconds: Int) -> [BLESample] {
        var out: [BLESample] = []
        for i in 0..<(seconds * 2) {
            let sec = Double(i) / 2
            let p = truth(sec)
            for (id, tp) in tags where p.distance(to: tp) <= 600 {
                out.append(BLESample(tMs: 1_000_000 + Int64(i * 500), id: id, rssi: -60 - p.distance(to: tp) / 100 * 4))
            }
        }
        return out
    }

    func testGoodRunIsTrusted() throws {
        let t = try XCTUnwrap(LiveRunLoader.trust(track: track(seconds: 120), ble: ble(seconds: 120), tagPositions: tags))
        XCTAssertEqual(t.badCount, 0)
        XCTAssertTrue(t.trusted.prefix(11).allSatisfy { $0 })
        XCTAssertTrue(t.verified.prefix(11).allSatisfy { $0 })
    }

    func testShiftedStretchIsDroppedWithNeighbours() throws {
        // 40–60 秒整体平移 10 m：价签对不上 + 两头位置跳变
        let t = try XCTUnwrap(LiveRunLoader.trust(track: track(seconds: 120, shift: (40, 60, 1000)), ble: ble(seconds: 120), tagPositions: tags))
        XCTAssertGreaterThan(t.badCount, 0)
        for w in 3...7 { XCTAssertFalse(t.trusted[w], "窗 \(w) 应该被丢") }       // 40–60 秒（含两头的跳变）及前后各一段
        XCTAssertTrue(t.trusted[0] && t.trusted[1] && t.trusted[9] && t.trusted[10])
        XCTAssertTrue(t.droppedSpans.contains([30, 80]))
    }

    func testSmoothShiftCaughtByTags() throws {
        // 没有跳变（慢慢漂走），只有价签能发现：整段平移 12 m 但从头到尾一致
        let t = try XCTUnwrap(LiveRunLoader.trust(track: track(seconds: 60, shift: (0, 60, 1200)), ble: ble(seconds: 60), tagPositions: tags))
        XCTAssertEqual(t.trusted.filter { $0 }.count, 0)
    }

    func testLowConfidenceRejected() throws {
        let t = try XCTUnwrap(LiveRunLoader.trust(track: track(seconds: 60, conf: 0.4), ble: ble(seconds: 60), tagPositions: tags))
        XCTAssertEqual(t.trusted.filter { $0 }.count, 0)
        XCTAssertEqual(t.rejected["定位没把握"], t.verdicts.count)
    }

    func testNoEvidenceNotTrusted() throws {
        // 定位自己有把握，但没有价签 / 标签可以佐证：不用
        let t = try XCTUnwrap(LiveRunLoader.trust(track: track(seconds: 60), ble: [], tagPositions: tags))
        XCTAssertEqual(t.trusted.filter { $0 }.count, 0)
    }

    func testUnverifiedStretchBridgedOnlyNextToGood() throws {
        // 前 40 秒有价签，后 40 秒没有：紧挨着的 2 段（20 秒）算可信，更远的不算
        let b = ble(seconds: 80).filter { $0.tMs < 1_040_000 }
        let t = try XCTUnwrap(LiveRunLoader.trust(track: track(seconds: 80), ble: b, tagPositions: tags))
        XCTAssertTrue(t.trusted[3])
        XCTAssertTrue(t.trusted[5])          // 紧挨着好段
        XCTAssertFalse(t.trusted[7])         // 离好段太远
    }

    func testSignDisagreementDropsWindow() throws {
        // 货架标签说人应该离这里很远
        let signs: [(tMs: Int64, distanceTo: (Point2) -> Double)] = [(1_025_000, { _ in 900 })]
        let t = try XCTUnwrap(LiveRunLoader.trust(track: track(seconds: 60), ble: ble(seconds: 60), tagPositions: tags, signs: signs))
        XCTAssertFalse(t.trusted[2])
        XCTAssertFalse(t.trusted[1])
        XCTAssertTrue(t.trusted[5])
    }

    func testPositionInterpolatesWithARKitMotion() {
        // 两个可信点相隔 3 秒：前 2 秒站着、后 1 秒走完全程，按 ARKit 路程占比应在 2 秒时还在起点
        let fixes = [LiveTrackRow(tMs: 0, p: Point2(0, 0), uncCm: 50, conf: 1), LiveTrackRow(tMs: 3000, p: Point2(300, 0), uncCm: 50, conf: 1)]
        var poses: [SurveySession.Pose] = []
        for i in 0...100 {
            let t = Int64(i * 30)
            let x = t <= 2000 ? 0.0 : Double(t - 2000) / 1000 * 300
            poses.append(SurveySession.Pose(tMs: t, a: Point2(x, 0), normal: true))
        }
        let c = LiveTrustConfig()
        XCTAssertEqual(LiveRunLoader.position(at: 1500, fixes: fixes, poses: poses, config: c)?.x ?? -1, 0, accuracy: 1)
        XCTAssertEqual(LiveRunLoader.position(at: 2500, fixes: fixes, poses: poses, config: c)?.x ?? -1, 150, accuracy: 15)
        // 间隔太大：不插值
        let far = [fixes[0], LiveTrackRow(tMs: 9000, p: Point2(900, 0), uncCm: 50, conf: 1)]
        XCTAssertNil(LiveRunLoader.position(at: 4000, fixes: far, poses: poses, config: c))
    }

    // MARK: 并入磁场图

    private func f(_ x: Double) -> MagneticFeature { MagneticFeature(total: 50 + 5 * sin(x / 300), vertical: -20 + 3 * cos(x / 250), horizontal: 40 + 2 * sin(x / 400)) }

    private func survey(xMax: Double) -> MagneticFieldBuilder {
        let b = MagneticFieldBuilder(widthCm: 10_000, heightCm: 1000, cellCm: 50)
        var x = 0.0
        while x < xMax { for k in 0..<10 { _ = b.add(position: Point2(x + Double(k) * 4, 500), feature: f(x + Double(k) * 4)) }; x += 50 }
        return b
    }

    private func run(name: String, xMax: Double, offset: Double, usable: Bool = true) -> LiveRunSamples {
        var samples: [(tMs: Int64, p: Point2, f: MagneticFeature)] = []
        var trackPts: [(tMs: Int64, p: Point2)] = []
        var i: Int64 = 0
        var x = 0.0
        while x < xMax {          // 50 Hz 磁力计，1 m/s
            samples.append((i * 20, Point2(x, 500), f(x) + MagneticFeature(total: offset, vertical: offset, horizontal: offset)))
            if i % 5 == 0 { trackPts.append((i * 20, Point2(x, 500))) }
            x += 2; i += 1
        }
        let rep = LiveTrustReport(name: name, used: usable, reason: usable ? nil : "x", windows: 10, trustedWindows: 10, rejectedWindows: [:],
                                  verifiedWindows: 10, pathM: xMax / 100, trustedPathM: xMax / 100, samples: samples.count, droppedSpans: [])
        return LiveRunSamples(name: name, samples: samples, track: trackPts, ble: [], signs: [], report: rep)
    }

    func testMergeAlignsOffsetFillsNewCellsAndKeepsSurveyDominant() throws {
        let s = survey(xMax: 4000)
        let before = s.snapshot()
        let g = SessionQualityGate(tagPositions: [:])
        let (b, rep) = LiveFieldMerger().merge(survey: s, runs: [run(name: "ok", xMax: 6000, offset: 3)], gate: g)
        XCTAssertEqual(rep.runsUsed, 1)
        XCTAssertEqual(rep.runs[0].offset?[0] ?? 0, 3, accuracy: 0.1)
        XCTAssertGreaterThan(rep.cellsAdded, 20)             // 4000–6000 原来没有数据
        let after = b.snapshot()
        // 已覆盖的格子：偏移对齐后均值几乎不动
        let k = try XCTUnwrap(s.cellIndex(Point2(1000, 500)))
        XCTAssertEqual(after.means[k * 3], before.means[k * 3], accuracy: 0.3)
        // 新补的格子有了，值和真值接近
        let kn = try XCTUnwrap(s.cellIndex(Point2(5000, 500)))
        XCTAssertGreaterThanOrEqual(after.counts[kn], 5)
        XCTAssertEqual(after.means[kn * 3], f(5010).total, accuracy: 1.5)
        // 建图数据始终是主体：计数涨幅不超过一半
        XCTAssertLessThanOrEqual(after.counts[k], before.counts[k] + before.counts[k] / 2 + 1)
    }

    func testMergeSkipsRunWithoutOverlapOrUntrusted() {
        let s = survey(xMax: 2000)
        let g = SessionQualityGate(tagPositions: [:])
        var far = run(name: "far", xMax: 3000, offset: 0)
        far.samples = far.samples.map { ($0.tMs, Point2($0.p.x + 5000, $0.p.y), $0.f) }
        far.track = far.track.map { ($0.tMs, Point2($0.p.x + 5000, $0.p.y)) }
        let bad = run(name: "bad", xMax: 3000, offset: 0, usable: false)
        let (_, rep) = LiveFieldMerger().merge(survey: s, runs: [far, bad], gate: g)
        XCTAssertEqual(rep.runsUsed, 0)
        XCTAssertEqual(rep.cellsAdded + rep.cellsUpdated, 0)
        XCTAssertTrue(rep.runs[0].reason?.contains("重叠不够") ?? false)
    }

    func testMergeRejectsRunWhoseFieldDoesNotMatch() {
        // 位置错了：磁场形状和建图数据对不上
        let s = survey(xMax: 4000)
        var wrong = run(name: "wrong", xMax: 4000, offset: 0)
        wrong.samples = wrong.samples.map { ($0.tMs, Point2(4000 - $0.p.x, $0.p.y), $0.f) }
        let (_, rep) = LiveFieldMerger().merge(survey: s, runs: [wrong], gate: SessionQualityGate(tagPositions: [:]))
        XCTAssertEqual(rep.runsUsed, 0)
    }
}
