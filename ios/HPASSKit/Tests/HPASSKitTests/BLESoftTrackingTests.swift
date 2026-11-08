import XCTest
@testable import HPASSKit

/// 本场地学到的标签范围（BLEFingerprintMap.learnedRanges）和跟踪时蓝牙只做软约束（MagneticConfig.bleSoftTracking）。
final class BLESoftTrackingTests: XCTestCase {

    /// 60 m × 4 m 的走廊，磁场沿 x 平滑变化
    private func field() -> MagneticFieldMap {
        let w = 6000.0, h = 400.0, cell = 50.0
        let cols = Int(w / cell), rows = Int(h / cell)
        var cells = [MagneticFeature?](), sig = [MagneticFeature?]()
        for _ in 0..<rows {
            for i in 0..<cols {
                let x = (Double(i) + 0.5) * cell / 100
                let bz = -42 + 6 * sin(0.9 * x) + 4 * sin(0.37 * x + 1)
                let bh = 24 + 5 * sin(0.6 * x + 2)
                cells.append(MagneticFeature(total: (bz * bz + bh * bh).squareRoot(), vertical: bz, horizontal: bh))
                sig.append(MagneticFeature(total: 0.5, vertical: 0.5, horizontal: 0.5))
            }
        }
        return MagneticFieldMap(widthCm: w, heightCm: h, cellCm: cell, cells: cells, sigmas: sig)
    }

    /// 走廊里每 5 m 一片标签（x = 250, 750, …），没有学到的范围
    private func bleMap(learned: [BLEFingerprintMap.RangeBin]? = nil) -> BLEFingerprintMap {
        var tags: [String: BLEFingerprintMap.Tag] = [:]
        for k in 0..<12 { tags["T\(k)"] = .init(x: 250 + Double(k) * 500, y: 200, maxRssi: -60, samples: 50) }
        var m = BLEFingerprintMap(cellCm: 200, cells: [], tags: tags)
        m.learnedRanges = learned
        return m
    }

    func testLearnRangesBinsQuantileAndMonotone() {
        var obs: [(distanceCm: Double, rssi: Double, n: Int)] = []
        // −62 dBm：距离 0…9 m 各 50 条 → P90 = 8 m
        for d in 0..<10 { obs.append((Double(d) * 100, -62, 50)) }
        // −72 dBm：只有 20 条（不够一档）→ 并进 −75 那档
        obs.append((3000, -72, 20))
        // −77 dBm：全在 4 m（比强信号的 8 m 还近）→ 不能比上一档小
        obs.append((400, -77, 300))
        let r = BLEFingerprintMap.learnRanges(obs)!
        XCTAssertEqual(r.map(\.minRssi), [-65, -80])
        XCTAssertEqual(r[0].rangeCm, 800)
        XCTAssertEqual(r[0].samples, 500)
        XCTAssertEqual(r[1].samples, 320)
        XCTAssertGreaterThanOrEqual(r[1].rangeCm, r[0].rangeCm)
        // 太少就不学
        XCTAssertNil(BLEFingerprintMap.learnRanges([(100, -70, 10)]))
    }

    func testBuilderLearnsRangesAndTagTableDoesNot() {
        let b = BLEFingerprintBuilder(widthCm: 6000, heightCm: 400)
        // 一片标签在 x = 1000：离得越远越弱
        for k in 0..<3000 {
            let x = Double(k % 300) * 10 + 500       // 5…35 m
            let d = abs(x - 1000)
            b.add(position: Point2(x, 200), id: "A", rssi: max(-60 - d / 50, -99))
        }
        let m = b.build()
        let r = try! XCTUnwrap(m.learnedRanges)
        XCTAssertFalse(r.isEmpty)
        for (a, c) in zip(r, r.dropFirst()) { XCTAssertLessThanOrEqual(a.rangeCm, c.rangeCm) }
        // 人工打点的标签位置表合成的底图：不带学到的范围（照旧用固定表）
        let seeded = TagLocations.seededBLEMap([], learned: m)
        XCTAssertNil(seeded.learnedRanges)
        // 旧格式（没有这个字段）照样读得出来
        let old = try! JSONDecoder().decode(BLEFingerprintMap.self, from: Data(#"{"cellCm":200,"cells":[],"tags":{}}"#.utf8))
        XCTAssertNil(old.learnedRanges)
        let rt = try! JSONDecoder().decode(BLEFingerprintMap.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(rt.learnedRanges, m.learnedRanges)
    }

    func testAssistRangeUsesLearnedButNeverTighterThanFixed() {
        let plain = BLEAssist(map: bleMap())
        XCTAssertEqual(plain.rangeCm(-70), BLEAssist.rangeCm(-70))
        let learned = BLEAssist(map: bleMap(learned: [.init(minRssi: -70, rangeCm: 900, samples: 500),
                                                       .init(minRssi: -90, rangeCm: 200, samples: 500)]))
        XCTAssertEqual(learned.rangeCm(-65), 900)
        XCTAssertEqual(learned.rangeCm(-88), BLEAssist.rangeCm(-88))   // 学到的比固定表小：用固定表
        XCTAssertEqual(learned.rangeCm(-95), BLEAssist.rangeCm(-95))   // 比学过的都弱：固定表
        learned.useLearnedRanges = false
        XCTAssertEqual(learned.rangeCm(-65), BLEAssist.rangeCm(-65))
    }

    /// 听到的是 40 m 外的标签（和地磁的位置完全对不上）
    private let farObs: [String: Double] = ["T9": -62, "T10": -64, "T8": -70]

    func testSoftTrackingNeverBlocksAndOnlyRecoversLocally() {
        let f = field()
        var cfg = MagneticConfig.tracking(odometry: .pdr)
        XCTAssertTrue(cfg.bleSoftTracking)
        XCTAssertTrue(MagneticConfig.tracking(odometry: .vio).bleSoftTracking)
        XCTAssertFalse(MagneticConfig().bleSoftTracking)       // 默认（冷启动 / 原有调用）不变
        cfg.particleCount = 400
        let loc = MagneticLocalizer(field: f, config: cfg, seed: 3)
        let start = Point2(500, 200)
        loc.reset(start: start, spreadCm: TrackingProfile.startSpreadCm)
        let assist = BLEAssist(map: bleMap())
        for _ in 0..<12 {
            assist.tick(obs: farObs, localizer: loc, current: loc.isConverged ? start : nil, candidate: start)
            XCTAssertFalse(loc.convergenceBlocked)
            XCTAssertFalse(assist.outsideField)
        }
        // 对不上 → 只触发局部找回：围着最后一次可靠位置找，不全图找
        XCTAssertGreaterThanOrEqual(assist.resets, 1)
        XCTAssertFalse(loc.isConverged)
        let c = try! XCTUnwrap(loc.localRecoveryCenter)
        XCTAssertLessThan(c.distance(to: start), 300)
        // 软先验很宽：粒子平均位置几乎不被 40 m 外的蓝牙拉走
        let e = loc.estimate()
        XCTAssertLessThan(e.position.distance(to: start), 300)
    }

    /// 学过范围：软范围约束把粒子往听到的标签那边拉，但每片有上限——和地磁完全对不上的远处标签不会把估计拽走
    func testSoftTrackingUsesCappedLearnedRanges() {
        let learned: [BLEFingerprintMap.RangeBin] = [.init(minRssi: -70, rangeCm: 700, samples: 500),
                                                     .init(minRssi: -90, rangeCm: 1100, samples: 500)]
        func run(_ obs: [String: Double], rangeWeight: Double, start: Point2, spread: Double) -> Point2 {
            var cfg = MagneticConfig.tracking(odometry: .pdr)
            cfg.particleCount = 600
            cfg.bleSoftRangeWeight = rangeWeight
            cfg.bleSoftLocalRecovery = false
            let loc = MagneticLocalizer(field: field(), config: cfg, seed: 5)
            loc.reset(start: start, spreadCm: spread)
            let assist = BLEAssist(map: bleMap(learned: learned))
            for _ in 0..<5 {
                assist.tick(obs: obs, localizer: loc, current: start, candidate: start)
                XCTAssertFalse(loc.convergenceBlocked)
            }
            return loc.particleMean
        }
        // 起点 x = 25 m、散得很开；听到的是 x = 7.5 m、12.5 m 的标签（学到的范围 7 m）→ 被拉向 x ≈ 10 m
        let near: [String: Double] = ["T1": -62, "T2": -64]
        let start = Point2(2500, 200)
        let pulled = run(near, rangeWeight: 1, start: start, spread: 1200)
        let priorOnly = run(near, rangeWeight: 0, start: start, spread: 1200)
        XCTAssertLessThan(pulled.x, start.x - 300)
        XCTAssertLessThan(pulled.x, priorOnly.x)
        // 起点很准、听到的却是 40 m 外的标签：每片罚有上限、所有粒子一样远 → 估计不动
        let held = run(farObs, rangeWeight: 1, start: Point2(500, 200), spread: 50)
        XCTAssertLessThan(held.distance(to: Point2(500, 200)), 300)
    }

    func testHardBehaviourWhenSoftTrackingOff() {
        let f = field()
        var cfg = MagneticConfig.tracking(odometry: .pdr)
        cfg.bleSoftTracking = false
        cfg.particleCount = 400
        let loc = MagneticLocalizer(field: f, config: cfg, seed: 3)
        let start = Point2(500, 200)
        loc.reset(start: start, spreadCm: TrackingProfile.startSpreadCm)
        let assist = BLEAssist(map: bleMap())
        for _ in 0..<4 { assist.tick(obs: farObs, localizer: loc, current: loc.isConverged ? start : nil, candidate: start) }
        // 原有行为：判丢后全图找（没有局部找回中心）并挡住收敛
        XCTAssertFalse(loc.isConverged)
        XCTAssertNil(loc.localRecoveryCenter)
        XCTAssertTrue(loc.convergenceBlocked)
    }

    func testColdStartUnaffected() {
        var cfg = MagneticConfig.tracking(odometry: .pdr)
        cfg.particleCount = 400
        cfg.coldStartParticleCount = 800
        let loc = MagneticLocalizer(field: field(), config: cfg, seed: 3)
        loc.reset(start: nil)
        XCTAssertFalse(loc.startedFromPrior)
        let assist = BLEAssist(map: bleMap())
        assist.tick(obs: farObs, localizer: loc, current: nil, candidate: Point2(500, 200))
        // 冷启动：候选位置对不上 → 照旧挡住收敛
        XCTAssertTrue(loc.convergenceBlocked)
    }

    func testDeclareLostLocalFallsBackToGlobalOutsideTracking() {
        var cfg = MagneticConfig()
        cfg.particleCount = 200
        let loc = MagneticLocalizer(field: field(), config: cfg, seed: 1)
        loc.reset(start: Point2(500, 200), spreadCm: 50)
        XCTAssertTrue(loc.isConverged)
        loc.declareLost(local: true)       // 没开 localRecovery：和 declareLost() 一样
        XCTAssertFalse(loc.isConverged)
        XCTAssertNil(loc.localRecoveryCenter)
    }
}
