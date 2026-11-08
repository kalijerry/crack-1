import XCTest
@testable import HPASSKit

/// 跟踪配置档（MagneticConfig.tracking）：已知起点时不远跳、丢了只在附近找回。
final class TrackingProfileTests: XCTestCase {

    /// 沿 x 变化的磁场（m 为单位），30 m 内不重复。
    private func g(_ xCm: Double) -> MagneticFeature {
        let x = xCm / 100
        let bz = -42 + 6 * sin(0.9 * x) + 4 * sin(0.37 * x + 1) + 2 * sin(1.7 * x + 0.5)
        let bh = 24 + 5 * sin(0.6 * x + 2) + 3 * sin(1.3 * x)
        return MagneticFeature(total: (bz * bz + bh * bh).squareRoot(), vertical: bz, horizontal: bh)
    }

    /// 60 m × 4 m 的走廊，磁场每 30 m 重复一次：x 和 x + 30 m 完全一样（远处的「长得像」）。
    /// hole：第一段里这一段 x 范围没有磁场数据（没采过）。
    private func world(hole: ClosedRange<Double>? = nil) -> MagneticFieldMap {
        let w = 6000.0, h = 400.0, cell = 50.0
        let cols = Int(w / cell), rows = Int(h / cell)
        var cells = [MagneticFeature?](), sig = [MagneticFeature?]()
        for _ in 0..<rows {
            for i in 0..<cols {
                let x = (Double(i) + 0.5) * cell
                if let hl = hole, hl.contains(x) { cells.append(nil); sig.append(nil); continue }
                cells.append(g(x.truncatingRemainder(dividingBy: 3000)))
                sig.append(MagneticFeature(total: 0.5, vertical: 0.5, horizontal: 0.5))
            }
        }
        return MagneticFieldMap(widthCm: w, heightCm: h, cellCm: cell, cells: cells, sigmas: sig)
    }

    /// 计步：步长多 2%，航向偏 2°
    private func pdr(_ d: Point2) -> Point2 {
        let a = 2.0 * Double.pi / 180
        return Point2((d.x * cos(a) - d.y * sin(a)) * 1.02, (d.x * sin(a) + d.y * cos(a)) * 1.02)
    }

    func testDefaultsKeepOldBehaviour() {
        let c = MagneticConfig()
        XCTAssertEqual(c.convergedMagWeight, 1)
        XCTAssertFalse(c.coverageGatedMagWeight)
        XCTAssertTrue(c.zeroConfidenceOffMap)
        XCTAssertFalse(c.keepClusterRequiresNear)
        XCTAssertFalse(c.localRecovery)
        XCTAssertEqual(c.randomInjectionConverged, 0.003)
    }

    /// 视觉里程计跟踪档和实时定位页原来的写法数值一致
    func testVIOProfileMatchesAppValues() {
        let c = MagneticConfig.tracking(odometry: .vio)
        XCTAssertEqual(c.initialHeadingBiasSigmaDeg, 5)
        XCTAssertEqual(c.headingBiasWalkDegPerM, 1)
        XCTAssertEqual(c.positionNoiseFraction, 0.04)
        XCTAssertEqual(c.initialScaleSigma, 0.03)
        XCTAssertEqual(c.scaleWalkPerM, 0.003)
        XCTAssertEqual(c.featureWeights.0, 0.5); XCTAssertEqual(c.featureWeights.1, 1.0); XCTAssertEqual(c.featureWeights.2, 0.25)
        XCTAssertEqual(c.jumpConfirmUpdates, 15)
        XCTAssertEqual(c.convergedPositionNoiseFraction, 0.03)
        XCTAssertTrue(c.hybridOffset)
        XCTAssertEqual(TrackingProfile.startSpreadCm, 50)
        let p = MagneticConfig.tracking(odometry: .pdr)
        XCTAssertEqual(p.initialHeadingBiasSigmaDeg, 10)
        XCTAssertEqual(MagneticConfig.tracking(odometry: .pdr, headingKnown: false).initialHeadingBiasSigmaDeg, 30)
        for x in [c, p] {
            XCTAssertEqual(x.randomInjectionConverged, 0)
            XCTAssertTrue(x.keepClusterRequiresNear)
            XCTAssertFalse(x.zeroConfidenceOffMap)
            XCTAssertTrue(x.localRecovery)
            XCTAssertTrue(x.coverageGatedMagWeight)
            XCTAssertLessThan(x.convergedMagWeight, 1)
        }
    }

    /// 已知起点，路上有一段 15 m 没采过磁场；30 m 外有一模一样、而且有数据的地方。
    /// 跟踪档：那一段靠推算走过去，估计不会跳到远处长得像的地方。
    func testNoFarJumpWhenFarLookAlikeExists() {
        let map = world(hole: 1000...2500)
        for odo in OdometrySource.allCases {
            let loc = MagneticLocalizer(field: map, config: .tracking(odometry: odo), seed: 11)
            var truth = Point2(300, 200)
            loc.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
            var maxErr = 0.0
            let step = Point2(25, 0)
            while truth.x < 2800 {
                truth = truth + step
                let e = loc.step(delta: pdr(step), feature: g(truth.x))
                if e.converged { maxErr = max(maxErr, e.position.distance(to: truth)) }
                XCTAssertTrue(e.converged, "\(odo) 在 x = \(truth.x) 判丢了")
            }
            XCTAssertLessThan(maxErr, 300, "\(odo)：最大误差 \(Int(maxErr)) cm")
            XCTAssertEqual(loc.lostCount, 0)
        }
    }

    /// 已知起点，中途外部判定定错（declareLost）：只在最后一次可靠位置附近找回，不跳到 30 m 外长得像的地方；
    /// 走一段之后重新有把握，位置仍然对。
    func testLocalRecoveryStaysLocal() {
        let map = world()
        let loc = MagneticLocalizer(field: map, config: .tracking(odometry: .pdr), seed: 5)
        var truth = Point2(300, 200)
        loc.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
        let step = Point2(25, 0)
        for _ in 0..<12 { truth = truth + step; loc.step(delta: pdr(step), feature: g(truth.x)) }
        loc.declareLost()
        var recovered = false
        var maxErr = 0.0
        while truth.x < 2200 {
            truth = truth + step
            let e = loc.step(delta: pdr(step), feature: g(truth.x))
            maxErr = max(maxErr, e.position.distance(to: truth))
            if let c = loc.localRecoveryCenter, let r = loc.localRecoveryRadiusCm {
                XCTAssertLessThan(c.distance(to: truth), 300, "找回中心离真值太远")
                XCTAssertLessThanOrEqual(r, MagneticConfig.tracking(odometry: .pdr).localRecoveryMaxCm)
                XCTAssertLessThan(e.position.distance(to: c), r + 300, "估计跑出了找回范围")
            }
            if e.converged { recovered = true }
        }
        XCTAssertTrue(recovered, "走了 18 m 还没重新有把握")
        XCTAssertLessThan(maxErr, 1000, "找回期间跳到了别处：最大误差 \(Int(maxErr)) cm")
        let e = loc.estimate()
        XCTAssertTrue(e.converged)
        XCTAssertLessThan(e.position.distance(to: truth), 300)
    }
}
