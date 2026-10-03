import XCTest
import Foundation
@testable import HPASSKit

// MARK: - 可复现的伪随机数

/// 线性同余 + Box-Muller。测试必须可复现，不能用 systemRandom。
struct FPLCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6364136223846793005 &+ 1442695040888963407
    }

    mutating func next01() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }

    mutating func gauss() -> Double {
        let u1 = Swift.max(next01(), 1e-12)
        let u2 = next01()
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2)
    }
}

// MARK: - 合成门店

/// 一条走廊 + 10 个货架。货架布置故意不对称（左端有一个很近的端架 C1_1），
/// 这样「全局 RSSI 偏移」无法被任何位置模仿，offset 失配一定会把估计拉偏。
struct FPTestStore {

    static let spacing: Double = 150
    static let pointCount: Int = 10

    static let shelves: [(code: String, pos: Point2)] = [
        ("A1_1", Point2(0, -200)),
        ("A2_1", Point2(300, -200)),
        ("A3_1", Point2(600, -200)),
        ("A4_1", Point2(900, -200)),
        ("A5_1", Point2(1200, -200)),
        ("B1_1", Point2(0, 200)),
        ("B2_1", Point2(450, 200)),
        ("B3_1", Point2(900, 200)),
        ("B4_1", Point2(1350, 200)),
        ("C1_1", Point2(75, -80)),
    ]

    // 对数距离路径损耗模型：RSSI(d) = RSSI0 - 10*n*log10(d/d0)
    static let d0: Double = 30
    static let rssi0: Double = -45
    static let pathLossN: Double = 2.2

    static func expectedRSSI(shelf: Point2, at p: Point2) -> Double {
        let d = Swift.max(p.distance(to: shelf), d0)
        return rssi0 - 10.0 * pathLossN * log10(d / d0)
    }

    static func pointId(_ i: Int) -> String { "p\(i)" }
    static func pointPosition(_ i: Int) -> Point2 { Point2(Double(i) * spacing, 0) }

    /// 每个货架 2 个价签，用来验证「同货架多价签」的聚合
    static let eslToShelf: [String: String] = {
        var m: [String: String] = [:]
        for s in FPTestStore.shelves {
            m["\(s.code)-T0"] = s.code
            m["\(s.code)-T1"] = s.code
        }
        return m
    }()

    /// 指纹库：区间 = 期望值 ± halfWidth（=> sigma = halfWidth/2，被 sigmaFloor 3 dB 兜住）
    static func fingerprints(halfWidth: Double = 5.0, visibleFloor: Double = -88.0) -> [FingerprintPoint] {
        var out: [FingerprintPoint] = []
        for i in 0..<pointCount {
            let pos = pointPosition(i)
            var ranges: [ShelfRange] = []
            for s in shelves {
                let e = expectedRSSI(shelf: s.pos, at: pos)
                if e < visibleFloor { continue }
                ranges.append(ShelfRange(shelfCode: s.code,
                                         minRSSI: Int((e - halfWidth).rounded()),
                                         maxRSSI: Int((e + halfWidth).rounded()),
                                         type: 1))
            }
            var nb: [String] = []
            if i > 0 { nb.append(pointId(i - 1)) }
            if i < pointCount - 1 { nb.append(pointId(i + 1)) }
            out.append(FingerprintPoint(id: pointId(i), x: pos.x, y: pos.y, ranges: ranges, neighbours: nb))
        }
        return out
    }

    /// 给定真实位置生成一帧读数。
    static func readings(at p: Point2, tMs: Int64, rng: inout FPLCG,
                         noise: Double = 3.0, repeats: Int = 3,
                         bias: Double = 0.0, visibleFloor: Double = -90.0) -> [BLEReading] {
        var out: [BLEReading] = []
        var k: Int64 = 0
        for s in shelves {
            let e = expectedRSSI(shelf: s.pos, at: p)
            if e < visibleFloor { continue }
            for tag in 0..<2 {
                for _ in 0..<repeats {
                    let v = e + bias + rng.gauss() * noise
                    let clamped = Swift.max(Swift.min(v, -20.0), -120.0)
                    out.append(BLEReading(tagId: "\(s.code)-T\(tag)", rssi: Int(clamped.rounded()),
                                          type: 1, tMs: tMs + k))
                    k += 1
                }
            }
        }
        return out
    }
}

// MARK: - 测试

final class PositioningTests: XCTestCase {

    private func makePositioner(_ mutate: (inout PositioningConfig) -> Void = { _ in }) -> FingerprintPositioner {
        var cfg = PositioningConfig()
        mutate(&cfg)
        return FingerprintPositioner(points: FPTestStore.fingerprints(),
                                     eslToShelf: FPTestStore.eslToShelf,
                                     config: cfg)
    }

    // MARK: 1. 静止精度

    func testStaticAccuracyWithinOnePointSpacing() {
        var rng = FPLCG(seed: 20240501)
        let tol = 1.5 * FPTestStore.spacing   // 1.5 个采集点间距
        for i in 1..<(FPTestStore.pointCount - 1) {
            let truth = FPTestStore.pointPosition(i)
            let pos = makePositioner { $0.useGraphSmoothing = false }
            pos.add(FPTestStore.readings(at: truth, tMs: 1000, rng: &rng))
            guard let est = pos.estimate(nowMs: 2000) else {
                return XCTFail("点 \(i) 没有得到估计")
            }
            XCTAssertEqual(est.position.x, truth.x, accuracy: tol, "点 \(i) x 误差过大")
            XCTAssertEqual(est.position.y, truth.y, accuracy: tol, "点 \(i) y 误差过大")
            let acceptable = [FPTestStore.pointId(i - 1), FPTestStore.pointId(i), FPTestStore.pointId(i + 1)]
            XCTAssertTrue(acceptable.contains(est.pointId ?? ""), "点 \(i) 最优点跑到了 \(est.pointId ?? "nil")")
            XCTAssertGreaterThan(est.readingsUsed, 0)
            XCTAssertFalse(est.candidates.isEmpty)
        }
    }

    // MARK: 2. 行走轨迹

    func testWalkIsTrackedMonotonically() {
        var rng = FPLCG(seed: 777)
        let pos = makePositioner()
        var xs: [Double] = []
        for f in 0..<14 {
            let truth = Point2(Double(f) * 100.0, 0)
            let t = Int64(f + 1) * 1000
            pos.add(FPTestStore.readings(at: truth, tMs: t - 400, rng: &rng))
            guard let est = pos.estimate(nowMs: t) else {
                return XCTFail("第 \(f) 帧没有估计")
            }
            xs.append(est.position.x)
            XCTAssertEqual(est.position.x, truth.x, accuracy: 300.0, "第 \(f) 帧偏差过大")
        }
        XCTAssertLessThan(xs[0], 300.0)
        XCTAssertGreaterThan(xs[xs.count - 1], 1050.0)
        for i in 1..<xs.count {
            XCTAssertGreaterThan(xs[i], xs[i - 1] - 150.0, "第 \(i) 帧出现明显倒退")
        }
    }

    // MARK: 3. 单帧远端爆发不应瞬移

    func testSingleFarBurstDoesNotTeleportWithSmoothing() {
        let truth = FPTestStore.pointPosition(1)
        let far = FPTestStore.pointPosition(8)

        // 窗口收紧到和帧间隔一致，保证"爆发帧"的窗口里只有远端读数。
        // 用默认的 1500 ms 窗口时，窗口会同时含有上一帧的真实读数，
        // WKNN 质心落在两者中间，对照组就测不出"完全瞬移"。
        func run(smoothing: Bool) -> [Double] {
            var rng = FPLCG(seed: 4242)
            let pos = makePositioner {
                $0.useGraphSmoothing = smoothing
                $0.windowMs = 1000
                $0.maxWindowMs = 1000
            }
            var xs: [Double] = []
            for f in 0..<8 {
                let t = Int64(f + 1) * 1000
                let src = (f == 4) ? far : truth
                pos.add(FPTestStore.readings(at: src, tMs: t - 400, rng: &rng))
                if let e = pos.estimate(nowMs: t) { xs.append(e.position.x) }
            }
            return xs
        }

        let smoothed = run(smoothing: true)
        XCTAssertEqual(smoothed.count, 8)
        for (i, x) in smoothed.enumerated() {
            XCTAssertLessThan(x, 500.0, "开图平滑后第 \(i) 帧被远端爆发带走了")
        }
        // 爆发后立刻回到真实点附近
        XCTAssertEqual(smoothed[7], truth.x, accuracy: 200.0)

        let raw = run(smoothing: false)
        XCTAssertEqual(raw.count, 8)
        XCTAssertGreaterThan(raw[4], 900.0, "关掉图平滑时，远端爆发本应直接瞬移")
        XCTAssertLessThan(raw[3], 500.0)
    }

    // MARK: 4. 真跳转后要能恢复

    func testRecoversAfterGenuineJump() {
        var rng = FPLCG(seed: 90210)
        let a = FPTestStore.pointPosition(1)
        let b = FPTestStore.pointPosition(8)
        let pos = makePositioner()
        for f in 0..<5 {
            let t = Int64(f + 1) * 1000
            pos.add(FPTestStore.readings(at: a, tMs: t - 400, rng: &rng))
            _ = pos.estimate(nowMs: t)
        }
        var last: Double = 0
        for f in 5..<12 {
            let t = Int64(f + 1) * 1000
            pos.add(FPTestStore.readings(at: b, tMs: t - 400, rng: &rng))
            if let e = pos.estimate(nowMs: t) { last = e.position.x }
        }
        XCTAssertEqual(last, b.x, accuracy: 350.0, "真实跳转后没有恢复")
    }

    // MARK: 5. 读数稀疏时自动放宽窗口

    func testWindowExtensionWhenReadingsAreSparse() {
        let tags = FPTestStore.shelves.map { "\($0.code)-T0" }
        // 6 条读数，每 500 ms 一条，1500 ms 窗口里只有 3 条
        func feed(_ p: FingerprintPositioner) {
            for (i, tag) in tags.prefix(6).enumerated() {
                p.add([BLEReading(tagId: tag, rssi: -60, type: 1, tMs: Int64(200 + i * 500))])
            }
        }

        let narrow = makePositioner {
            $0.minReadings = 1
            $0.useGraphSmoothing = false
        }
        feed(narrow)
        guard let e1 = narrow.estimate(nowMs: 3000) else { return XCTFail("窄窗口没有估计") }
        XCTAssertEqual(e1.readingsUsed, 3, "1500 ms 窗口内应该只有 3 条读数")

        let wide = makePositioner {
            $0.minReadings = 5
            $0.maxWindowMs = 3000
            $0.useGraphSmoothing = false
        }
        feed(wide)
        guard let e2 = wide.estimate(nowMs: 3000) else { return XCTFail("放宽窗口后没有估计") }
        XCTAssertEqual(e2.readingsUsed, 6, "读数不足时应放宽到 maxWindowMs")
    }

    // MARK: 6. 鲁棒性

    func testReturnsNilWithoutUsableReadings() {
        let pos = makePositioner()
        XCTAssertNil(pos.estimate(nowMs: 1000), "没有读数时必须返回 nil")
        XCTAssertTrue(pos.scores(nowMs: 1000).isEmpty)

        // 全是未知价签
        pos.add([BLEReading(tagId: "UNKNOWN-1", rssi: -50, type: 1, tMs: 900),
                 BLEReading(tagId: "UNKNOWN-2", rssi: -55, type: 1, tMs: 950)])
        XCTAssertNil(pos.estimate(nowMs: 1000), "未知价签应被忽略")

        // 读数太弱
        pos.reset()
        pos.add([BLEReading(tagId: "A1_1-T0", rssi: -120, type: 1, tMs: 900)])
        XCTAssertNil(pos.estimate(nowMs: 1000), "低于 minRSSI 的读数应被丢弃")

        // 空指纹库
        let empty = FingerprintPositioner(points: [], eslToShelf: FPTestStore.eslToShelf)
        empty.add([BLEReading(tagId: "A1_1-T0", rssi: -50, type: 1, tMs: 900)])
        XCTAssertNil(empty.estimate(nowMs: 1000))
        XCTAssertFalse(empty.validate().isEmpty)
    }

    func testScoresFormDistributionAndSeedWorks() {
        var rng = FPLCG(seed: 31337)
        let pos = makePositioner()
        pos.seed(position: FPTestStore.pointPosition(3))
        pos.add(FPTestStore.readings(at: FPTestStore.pointPosition(3), tMs: 600, rng: &rng))
        let s = pos.scores(nowMs: 1000)
        XCTAssertEqual(s.count, FPTestStore.pointCount)
        let total = s.values.reduce(0, +)
        XCTAssertEqual(total, 1.0, accuracy: 1e-6)
        let best = s.max { $0.value < $1.value }
        XCTAssertEqual(best?.key, "p3")
        XCTAssertNotNil(pos.estimate(nowMs: 1000))
        pos.reset()
        XCTAssertNil(pos.estimate(nowMs: 1000))
    }

    // MARK: 7. 置信度

    func testConfidenceIsLowerInAmbiguousSpots() {
        var rng = FPLCG(seed: 5150)
        // 清晰：正好站在采集点上，噪声 1 dB，读数多
        let clear = makePositioner { $0.useGraphSmoothing = false }
        clear.add(FPTestStore.readings(at: FPTestStore.pointPosition(4), tMs: 600,
                                       rng: &rng, noise: 1.0, repeats: 5))
        guard let a = clear.estimate(nowMs: 1000) else { return XCTFail("清晰点没有估计") }

        // 模糊：站在两个采集点中间，噪声 10 dB，读数少
        let fuzzy = makePositioner { $0.useGraphSmoothing = false }
        fuzzy.add(FPTestStore.readings(at: Point2(525, 0), tMs: 600,
                                       rng: &rng, noise: 10.0, repeats: 1))
        guard let b = fuzzy.estimate(nowMs: 1000) else { return XCTFail("模糊点没有估计") }

        XCTAssertGreaterThan(a.confidence, 0.35, "清晰点置信度过低")
        XCTAssertLessThan(b.confidence, a.confidence - 0.08, "模糊点的置信度应明显更低")
        XCTAssertGreaterThan(b.uncertaintyCm, a.uncertaintyCm, "模糊点的不确定半径应更大")
        XCTAssertTrue(a.confidence >= 0 && a.confidence <= 1)
        XCTAssertTrue(b.confidence >= 0 && b.confidence <= 1)
    }

    // MARK: 8. offset 失配 & 标定

    func testWrongOffsetDegradesAccuracy() {
        let truths = [0, 1, 8, 9].map { FPTestStore.pointPosition($0) }

        func meanError(offset: Double) -> Double {
            var rng = FPLCG(seed: 8888)
            var sum = 0.0
            var n = 0
            for truth in truths {
                for f in 0..<3 {
                    let pos = makePositioner {
                        $0.useGraphSmoothing = false
                        $0.rssiOffset = offset
                    }
                    let t = Int64(f + 1) * 1000
                    // 新机型比指纹库系统性高 8 dB
                    pos.add(FPTestStore.readings(at: truth, tMs: t - 400, rng: &rng, bias: 8.0))
                    if let e = pos.estimate(nowMs: t) {
                        sum += e.position.distance(to: truth)
                        n += 1
                    }
                }
            }
            return n > 0 ? sum / Double(n) : .infinity
        }

        let good = meanError(offset: -8.0)
        let bad = meanError(offset: 0.0)
        XCTAssertLessThan(good, 200.0, "校正正确时误差应该不大，实际 \(good)")
        XCTAssertGreaterThan(bad, good + 100.0, "offset 失配 8 dB 应该显著变差：\(bad) vs \(good)")
    }

    func testCalibratorFitRecoversOffset() {
        var rng = FPLCG(seed: 112233)
        var byPoint: [String: [BLEReading]] = [:]
        for i in 0..<FPTestStore.pointCount {
            var rs: [BLEReading] = []
            for w in 0..<4 {
                rs += FPTestStore.readings(at: FPTestStore.pointPosition(i),
                                           tMs: Int64(w) * 1500 + 100, rng: &rng,
                                           noise: 2.0, repeats: 5, bias: 8.0)
            }
            byPoint[FPTestStore.pointId(i)] = rs
        }
        let cal = RSSICalibrator.fit(readingsByPoint: byPoint,
                                    points: FPTestStore.fingerprints(),
                                    eslToShelf: FPTestStore.eslToShelf)
        XCTAssertGreaterThan(cal.samples, 10)
        XCTAssertEqual(cal.scale, 1.0, accuracy: 1e-9, "fitScale=false 时 scale 必须保持 1")
        XCTAssertEqual(cal.offset, -8.0, accuracy: 2.0, "没能恢复注入的 8 dB 偏移：\(cal.offset)")
        XCTAssertGreaterThan(cal.score, cal.scoreBefore)
        XCTAssertFalse(cal.curve.isEmpty)
    }

    func testCalibratorFitScaleStaysNearUnity() {
        var rng = FPLCG(seed: 445566)
        var byPoint: [String: [BLEReading]] = [:]
        for i in 0..<FPTestStore.pointCount {
            var rs: [BLEReading] = []
            for w in 0..<3 {
                rs += FPTestStore.readings(at: FPTestStore.pointPosition(i),
                                           tMs: Int64(w) * 1500 + 100, rng: &rng,
                                           noise: 2.0, repeats: 5, bias: 8.0)
            }
            byPoint[FPTestStore.pointId(i)] = rs
        }
        let cal = RSSICalibrator.fit(readingsByPoint: byPoint,
                                     points: FPTestStore.fingerprints(),
                                     eslToShelf: FPTestStore.eslToShelf,
                                     fitScale: true)
        // 注入的是纯平移，斜率应该接近 1
        XCTAssertEqual(cal.scale, 1.0, accuracy: 0.08, "纯平移却拟合出明显斜率：\(cal.scale)")
        XCTAssertEqual(cal.scale * (-70.0) + cal.offset, -78.0, accuracy: 3.0,
                       "在典型 RSSI 处的校正量应接近 -8 dB")
    }

    func testCalibratorFitBlindRecoversOffset() {
        var rng = FPLCG(seed: 998877)
        var all: [BLEReading] = []
        for f in 0..<20 {
            let truth = Point2(Double(f) * 70.0, 0)
            all += FPTestStore.readings(at: truth, tMs: Int64(f) * 1500 + 100, rng: &rng,
                                        noise: 2.0, repeats: 4, bias: 8.0)
        }
        let cal = RSSICalibrator.fitBlind(readings: all,
                                         points: FPTestStore.fingerprints(),
                                         eslToShelf: FPTestStore.eslToShelf)
        XCTAssertGreaterThan(cal.samples, 5)
        XCTAssertEqual(cal.offset, -8.0, accuracy: 3.0, "盲标定没能恢复偏移：\(cal.offset)")
        XCTAssertGreaterThan(cal.score, cal.scoreBefore)
    }

    func testCalibratorHandlesEmptyInput() {
        let cal = RSSICalibrator.fit(readingsByPoint: [:], points: FPTestStore.fingerprints(),
                                     eslToShelf: FPTestStore.eslToShelf)
        XCTAssertEqual(cal.samples, 0)
        XCTAssertEqual(cal.offset, 0.0, accuracy: 1e-9)
        XCTAssertTrue(cal.curve.isEmpty)

        let blind = RSSICalibrator.fitBlind(readings: [], points: FPTestStore.fingerprints(),
                                            eslToShelf: FPTestStore.eslToShelf)
        XCTAssertEqual(blind.samples, 0)
    }

    // MARK: 9. validate()

    func testValidateIsCleanOnGoodData() {
        let pos = makePositioner()
        XCTAssertTrue(pos.validate().isEmpty, "干净数据上 validate() 应为空：\(pos.validate())")
    }

    func testValidateCatchesSeededProblems() {
        var pts = FPTestStore.fingerprints()
        // a) 重复 id
        pts.append(FingerprintPoint(id: "p0", x: 0, y: 0, ranges: pts[0].ranges, neighbours: ["p1"]))
        // b) 空区间 + 悬空邻居 + 孤立点
        pts.append(FingerprintPoint(id: "bad_empty", x: 5000, y: 5000, ranges: [], neighbours: ["nope"]))
        pts.append(FingerprintPoint(id: "bad_lonely", x: 6000, y: 6000,
                                    ranges: [ShelfRange(shelfCode: "A1_1", minRSSI: -70, maxRSSI: -60, type: 1)],
                                    neighbours: []))
        // c) min > max / RSSI 越界 / 区间过宽 / 未知货架
        pts.append(FingerprintPoint(id: "bad_ranges", x: 7000, y: 7000, ranges: [
            ShelfRange(shelfCode: "A1_1", minRSSI: -40, maxRSSI: -70, type: 1),
            ShelfRange(shelfCode: "A2_1", minRSSI: -200, maxRSSI: 50, type: 1),
            ShelfRange(shelfCode: "A3_1", minRSSI: -95, maxRSSI: -40, type: 1),
            ShelfRange(shelfCode: "GHOST_1", minRSSI: -70, maxRSSI: -60, type: 1),
            ShelfRange(shelfCode: "", minRSSI: -70, maxRSSI: -60, type: 1),
        ], neighbours: ["bad_lonely"]))
        // d) 坐标重合
        pts.append(FingerprintPoint(id: "bad_dup_xy", x: FPTestStore.pointPosition(2).x, y: 0,
                                    ranges: pts[2].ranges, neighbours: ["p2"]))

        var esl = FPTestStore.eslToShelf
        esl["ORPHAN-TAG"] = "UNUSED_SHELF_1"     // e) 映射里有、指纹库里没有的货架

        let pos = FingerprintPositioner(points: pts, eslToShelf: esl)
        let msgs = pos.validate()

        func has(_ needle: String) -> Bool { msgs.contains { $0.contains(needle) } }

        XCTAssertTrue(has("重复的指纹点 id：p0"), "没报出重复 id：\(msgs)")
        XCTAssertTrue(has("bad_empty") && has("没有任何 RSSI 区间"), "没报出空区间：\(msgs)")
        XCTAssertTrue(has("邻居 nope 不存在"), "没报出悬空邻居：\(msgs)")
        XCTAssertTrue(has("bad_lonely") && has("没有邻居"), "没报出孤立点：\(msgs)")
        XCTAssertTrue(has("minRSSI(-40) > maxRSSI(-70)"), "没报出 min>max：\(msgs)")
        XCTAssertTrue(has("RSSI 越界"), "没报出 RSSI 越界：\(msgs)")
        XCTAssertTrue(has("区间过宽"), "没报出过宽区间：\(msgs)")
        XCTAssertTrue(has("shelfCode 为空"), "没报出空货架编码：\(msgs)")
        XCTAssertTrue(has("坐标重合"), "没报出坐标重合：\(msgs)")
        XCTAssertTrue(has("在价签映射中不存在"), "没报出 GHOST_1 覆盖问题：\(msgs)")
        XCTAssertTrue(has("在指纹库里没有区间"), "没报出 UNUSED_SHELF_1：\(msgs)")
        XCTAssertTrue(has("不对称"), "没报出不对称邻居：\(msgs)")

        // validate() 是只读的，重复调用结果一致
        XCTAssertEqual(pos.validate().count, msgs.count)
    }

    func testEmptyMappingIsReported() {
        let pos = FingerprintPositioner(points: FPTestStore.fingerprints(), eslToShelf: [:])
        XCTAssertTrue(pos.validate().contains { $0.contains("价签→货架映射为空") })
    }

    // MARK: 10. 数据异常下仍能工作

    func testSurvivesDirtyDatabase() {
        var rng = FPLCG(seed: 24680)
        var pts = FPTestStore.fingerprints()
        pts.append(FingerprintPoint(id: "ghost", x: 9000, y: 9000, ranges: [], neighbours: ["nope"]))
        pts.append(FingerprintPoint(id: "p0", x: 0, y: 0, ranges: [], neighbours: []))   // 重复 id
        let pos = FingerprintPositioner(points: pts, eslToShelf: FPTestStore.eslToShelf)

        for f in 0..<4 {
            let t = Int64(f + 1) * 1000
            pos.add(FPTestStore.readings(at: FPTestStore.pointPosition(5), tMs: t - 400, rng: &rng))
            pos.add([BLEReading(tagId: "NOT-A-TAG", rssi: -50, type: 1, tMs: t - 300)])
        }
        guard let e = pos.estimate(nowMs: 4000) else { return XCTFail("脏数据下没有估计") }
        XCTAssertEqual(e.position.x, FPTestStore.pointPosition(5).x, accuracy: 300.0)
        XCTAssertNotEqual(e.pointId, "ghost", "空区间的点不应该夺冠")
        // p0 的重复条目被丢弃，第一条仍然有区间
        XCTAssertEqual(pos.scores(nowMs: 4000).count, FPTestStore.pointCount + 1)
    }

    func testTypeFallbackWhenDatabaseOnlyHasOtherType() {
        // 库里只有 type=0，手机读数是 type=1 —— 应该回退而不是全部算成「意外货架」
        let base = FPTestStore.fingerprints()
        var pts: [FingerprintPoint] = []
        for p in base {
            let ranges = p.ranges.map {
                ShelfRange(shelfCode: $0.shelfCode, minRSSI: $0.minRSSI, maxRSSI: $0.maxRSSI, type: 0)
            }
            pts.append(FingerprintPoint(id: p.id, x: p.x, y: p.y, ranges: ranges, neighbours: p.neighbours))
        }
        var rng = FPLCG(seed: 13579)
        let pos = FingerprintPositioner(points: pts, eslToShelf: FPTestStore.eslToShelf)
        pos.add(FPTestStore.readings(at: FPTestStore.pointPosition(6), tMs: 600, rng: &rng))
        guard let e = pos.estimate(nowMs: 1000) else { return XCTFail("type 回退失败，没有估计") }
        XCTAssertEqual(e.position.x, FPTestStore.pointPosition(6).x, accuracy: 300.0)
    }
}
