import XCTest
@testable import HPASSKit

final class SoftwareLayerTests: XCTestCase {

    // MARK: 磁场可信度

    /// 校准后磁场在走路时带抖动，原始磁力计 = 校准磁场 + 硬磁偏置；偏置突然变了，就是重新校准。
    func testTrustDropsAfterRecalibrationJumpAndRecovers() {
        let mon = MagneticTrustMonitor()
        var rng = MagRNG(seed: 5)
        var t: Int64 = 0
        var bias = (5.0, -3.0, 2.0)
        var minAfterJump = 1.0, trustAtEnd = 0.0, trustBefore = 0.0
        for i in 0..<600 {                          // 12 s，50 Hz
            t += 20
            let cal = (20 + 3 * rng.normal(), 5 + 3 * rng.normal(), -43 + 3 * rng.normal())   // 快速转身带来的抖动
            if i == 300 { bias = (11, -3, 2) }      // 6 s 时偏置突变 6 µT
            let raw = (cal.0 + bias.0 + 0.8 * rng.normal(), cal.1 + bias.1 + 0.8 * rng.normal(), cal.2 + bias.2 + 0.8 * rng.normal())
            let tr = mon.update(tMs: t, calibrated: cal, raw: raw, accuracy: 2)
            if i == 290 { trustBefore = tr }
            if i > 300 && i < 450 { minAfterJump = min(minAfterJump, tr) }
            trustAtEnd = tr
        }
        XCTAssertEqual(trustBefore, 1, accuracy: 1e-9)
        XCTAssertEqual(minAfterJump, 0, accuracy: 1e-9)
        XCTAssertEqual(mon.jumpCount, 1)
        XCTAssertEqual(trustAtEnd, 1, accuracy: 1e-9)
    }

    func testTrustFollowsAccuracyAndRejectsInsaneField() {
        let mon = MagneticTrustMonitor()
        let ok = (20.0, 5.0, -43.0)
        XCTAssertEqual(mon.update(tMs: 0, calibrated: ok, raw: nil, accuracy: 2), 1, accuracy: 1e-9)
        XCTAssertEqual(mon.update(tMs: 20, calibrated: ok, raw: nil, accuracy: 1), 0.6, accuracy: 1e-9)
        XCTAssertEqual(mon.update(tMs: 40, calibrated: ok, raw: nil, accuracy: 0), 0.25, accuracy: 1e-9)
        XCTAssertEqual(mon.update(tMs: 60, calibrated: ok, raw: nil, accuracy: -1), 0, accuracy: 1e-9)
        XCTAssertEqual(mon.update(tMs: 80, calibrated: (1, 1, 1), raw: nil, accuracy: 2), 0, accuracy: 1e-9)
    }

    /// 可信度为 0 的读数不应该影响滤波；可信度满的读数应该。
    func testLocalizerIgnoresUntrustedFeature() {
        let b = MagneticFieldBuilder(widthCm: 1000, heightCm: 1000)
        for x in stride(from: 50.0, to: 950, by: 10) {
            for y in [100.0, 300, 500] {
                let f = MagneticFeature(total: 50 + 0.02 * x, vertical: -43 + 0.01 * x, horizontal: 25 + 0.015 * x)
                for _ in 0..<6 { b.add(position: Point2(x, y), feature: f) }
            }
        }
        let map = b.build()
        func runWith(trust: Double) -> Double {
            let loc = MagneticLocalizer(field: map, seed: 3)
            loc.reset(start: Point2(100, 100), spreadCm: 30)
            var est = loc.estimate()
            for _ in 0..<12 {
                // 读数对应 x = 700，与已知起点附近矛盾
                est = loc.step(delta: Point2(40, 0), feature: MagneticFeature(total: 50 + 0.02 * 700, vertical: -43 + 0.01 * 700, horizontal: 25 + 0.015 * 700), trust: trust)
            }
            return est.position.x
        }
        XCTAssertLessThan(runWith(trust: 0), 700)                  // 不参与：位置只靠推算，在 580 左右
        XCTAssertEqual(runWith(trust: 0), 100 + 12 * 40, accuracy: 120)
        XCTAssertGreaterThan(runWith(trust: 1), runWith(trust: 0) + 20)   // 参与：被拉向 700
    }

    // MARK: 持握姿态

    private func sample(tiltDeg: Double, gyro: Double = 0, t: Int64) -> IMUSample {
        let r = tiltDeg * Double.pi / 180
        return IMUSample(tMs: t, ax: 0, ay: 9.81 * sin(r), az: 9.81 * cos(r), gx: gyro, gy: 0, gz: 0, mx: 20, my: 0, mz: -40)
    }

    func testHoldClassifier() {
        func classify(_ tilt: Double, gyro: Double = 0) -> HoldPosture {
            let c = HoldClassifier()
            var out = HoldPosture.unknown
            for i in 0..<200 { out = c.process(sample(tiltDeg: tilt, gyro: gyro, t: Int64(i * 20))) }
            return out
        }
        XCTAssertEqual(classify(5), .flat)
        XCTAssertEqual(classify(45), .reading)
        XCTAssertEqual(classify(90), .upright)
        XCTAssertEqual(classify(160), .other)
        XCTAssertEqual(classify(45, gyro: 3.5), .swinging)
        XCTAssertTrue(HoldPosture.upright.suitsCamera)
        XCTAssertFalse(HoldPosture.flat.suitsCamera)
    }

    // MARK: 步长缩放

    func testFusionStepLengthScaleDefaultsToOne() {
        XCTAssertEqual(FusionConfig().stepLengthScale, 1.0, accuracy: 1e-12)
    }
}

final class VisualOdometryAlignerTests: XCTestCase {
    private let phi = 0.9                       // 真实旋转：ARKit → 地图

    /// 地图上的真实轨迹 → ARKit 坐标（逆旋转 + 平移）。
    private func ar(_ p: Point2, from p0: Point2, a0: Point2) -> Point2 {
        let d = p - p0
        let c = cos(-phi), s = sin(-phi)
        return Point2(a0.x + d.x * c - d.y * s, a0.y + d.x * s + d.y * c)
    }

    func testAlignsAfterWalkingAndReproducesMapPositions() {
        let al = VisualOdometryAligner()
        let p0 = Point2(2000, 1000), a0 = Point2(123, -456)
        // 沿地图 +x 方向走（朝向 θ = 90°：dx = sinθ）
        al.anchor(map: p0, ar: a0, headingRad: Double.pi / 2)
        var last: VisualOdometryAligner.Output?
        var early = 0
        for k in 1...40 {
            let truth = Point2(p0.x + Double(k) * 10, p0.y)
            last = al.process(ar: ar(truth, from: p0, a0: a0), trackingNormal: true)
            if case .unaligned = last! { early += 1 }
        }
        XCTAssertGreaterThan(early, 10)                         // 没走够 1.5 m 之前不输出
        guard case .aligned(let pos, _) = last! else { return XCTFail("应该已经对齐") }
        XCTAssertEqual(pos.x, 2400, accuracy: 0.5)
        XCTAssertEqual(pos.y, 1000, accuracy: 0.5)
        XCTAssertEqual(al.rotationRad ?? 0, phi, accuracy: 1e-6)
    }

    func testBriefTrackingLossKeepsRotationButResetDoesNot() {
        let al = VisualOdometryAligner()
        let p0 = Point2(2000, 1000), a0 = Point2(0, 0)
        al.anchor(map: p0, ar: a0, headingRad: Double.pi / 2)
        for k in 1...30 { _ = al.process(ar: ar(Point2(p0.x + Double(k) * 10, p0.y), from: p0, a0: a0), trackingNormal: true) }
        XCTAssertTrue(al.isAligned)
        _ = al.process(ar: ar(Point2(2310, 1000), from: p0, a0: a0), trackingNormal: false)
        // 短暂受限后位置连续：沿用旋转，立刻有输出
        let out = al.process(ar: ar(Point2(2320, 1000), from: p0, a0: a0), trackingNormal: true)
        guard case .aligned(let pos, _) = out else { return XCTFail("位置连续时应沿用旋转") }
        XCTAssertEqual(pos.x, 2320, accuracy: 3)
        // ARKit 重置：位置跳到很远，旋转不能再用
        _ = al.process(ar: Point2(5000, 5000), trackingNormal: false)
        let reset = al.process(ar: Point2(9000, 9000), trackingNormal: true, headingHint: 0, currentMap: Point2(2400, 1000))
        if case .aligned = reset { XCTFail("重置后必须重新对齐") }
        XCTAssertFalse(al.isAligned)
    }
}

final class LateralRangeTests: XCTestCase {
    /// 竖直通道：左右各一排货架，通道净宽 160 cm（x 从 420 到 580）。
    private let shelves = [
        ShelfRect(code: "L", x: 260, y: 1000, width: 320, height: 2000, rotation: 0),   // x ∈ [100, 420]
        ShelfRect(code: "R", x: 740, y: 1000, width: 320, height: 2000, rotation: 0),   // x ∈ [580, 900]
    ]

    func testRayDistancesAndSides() {
        let rc = ShelfRaycaster(shelves: shelves, widthCm: 1000, heightCm: 2000)
        // 站在 x = 480，朝 +y（θ = 0）走：左手边是 +x（580，距 100），右手边是 −x（420，距 60）
        let (l, r) = rc.lateral(from: Point2(480, 800), headingRad: 0)
        XCTAssertEqual(l ?? -1, 100, accuracy: 0.01)
        XCTAssertEqual(r ?? -1, 60, accuracy: 0.01)
        // 掉头朝 −y（θ = π）：左右互换
        let (l2, r2) = rc.lateral(from: Point2(480, 800), headingRad: Double.pi)
        XCTAssertEqual(l2 ?? -1, 60, accuracy: 0.01)
        XCTAssertEqual(r2 ?? -1, 100, accuracy: 0.01)
        // 顺着通道往前看，500 cm 内没有货架挡着
        XCTAssertNil(rc.distance(from: Point2(480, 800), angleRad: 0, maxCm: 500))
        // 旋转的货架：同一块货架旋转 90° 再放到对应位置，射线距离不变
        let rotated = [ShelfRect(code: "T", x: 480, y: 900, width: 2000, height: 100, rotation: 90)]   // 竖条：x ∈ [430, 530]... 不挡，改成挡在前面
        let rc2 = ShelfRaycaster(shelves: [ShelfRect(code: "T", x: 480, y: 1000, width: 100, height: 400, rotation: 90)],
                                 widthCm: 1000, heightCm: 2000)
        _ = rotated
        // 宽 100、高 400，旋转 90°：实际占 x ∈ [280, 680]，y ∈ [950, 1050]；从 (480, 800) 朝 +y 打到 y = 950，距 150
        XCTAssertEqual(rc2.distance(from: Point2(480, 800), angleRad: 0, maxCm: 500) ?? -1, 150, accuracy: 0.01)
    }

    /// 磁场一点信息都没有（均匀），只靠左右货架距离，粒子应该收敛到通道里的正确横向位置。
    func testLateralObservationPinsAcrossAisleOffset() {
        let b = MagneticFieldBuilder(widthCm: 1000, heightCm: 2000)
        for x in stride(from: 25.0, to: 1000, by: 50) { for y in stride(from: 25.0, to: 2000, by: 50) {
            for _ in 0..<6 { b.add(position: Point2(x, y), feature: MagneticFeature(total: 50, vertical: -43, horizontal: 25)) }
        } }
        let map = b.build()
        func run(weight: Double) -> Double {
            var cfg = MagneticConfig()
            cfg.lateralWeight = weight
            cfg.initialHeadingBiasSigmaDeg = 1
            let loc = MagneticLocalizer(field: map, config: cfg, seed: 9)
            loc.raycaster = ShelfRaycaster(shelves: shelves, widthCm: 1000, heightCm: 2000)
            loc.reset(start: Point2(500, 300), spreadCm: 60)           // 起点横向有 60 cm 的不确定
            var est = loc.estimate()
            var truthX = 480.0
            for k in 0..<25 {
                let y = 300.0 + Double(k) * 40
                est = loc.step(delta: Point2(0, 40), feature: MagneticFeature(total: 50, vertical: -43, horizontal: 25),
                               lateral: LateralObservation(leftCm: 100, rightCm: 60, headingRad: 0))
                _ = y
            }
            truthX = 480
            return abs(est.position.x - truthX)
        }
        XCTAssertLessThan(run(weight: 1), 25)
        XCTAssertGreaterThan(run(weight: 1) + 1, 0)
        XCTAssertLessThan(run(weight: 1), run(weight: 0) + 1)
    }
}

final class MapARTransformTests: XCTestCase {
    func testRoundTripAndAlignerAgreement() {
        let al = VisualOdometryAligner()
        let p0 = Point2(2000, 1000), a0 = Point2(123, -456), phi = 0.9
        func ar(_ p: Point2) -> Point2 {                 // 与对齐器测试里同一种构造
            let d = p - p0, c = cos(-phi), s = sin(-phi)
            return Point2(a0.x + d.x * c - d.y * s, a0.y + d.x * s + d.y * c)
        }
        al.anchor(map: p0, ar: a0, headingRad: Double.pi / 2)
        for k in 1...30 { _ = al.process(ar: ar(Point2(p0.x + Double(k) * 10, p0.y)), trackingNormal: true) }
        let t = try! XCTUnwrap(al.transform)
        let m = Point2(2500, 1400)
        XCTAssertEqual(t.toAR(m).x, ar(m).x, accuracy: 1e-6)
        XCTAssertEqual(t.toAR(m).y, ar(m).y, accuracy: 1e-6)
        XCTAssertEqual(t.toMap(t.toAR(m)).x, m.x, accuracy: 1e-6)
        XCTAssertEqual(t.toMap(t.toAR(m)).y, m.y, accuracy: 1e-6)
    }

    /// SceneKit 根节点的「绕 y 旋转 + 平移」与 toAR 一致：场景坐标 c = 地图 cm / 100。
    func testSceneRootMatchesToAR() {
        let t = MapARTransform(pRef: Point2(3000, 800), aRef: Point2(-50, 700), phi: -1.2)
        for m in [Point2(0, 0), Point2(3000, 800), Point2(4200, 2500), Point2(100, 9000)] {
            let a = t.sceneRotationY
            let cx = m.x / 100, cz = m.y / 100
            let rx = cx * cos(a) + cz * sin(a), rz = -cx * sin(a) + cz * cos(a)   // SceneKit 绕 +y 转 α
            let tr = t.sceneTranslationM
            XCTAssertEqual((rx + tr.x) * 100, t.toAR(m).x, accuracy: 1e-6)
            XCTAssertEqual((rz + tr.z) * 100, t.toAR(m).y, accuracy: 1e-6)
        }
    }
}

final class RawBiasTrackerTests: XCTestCase {
    /// iOS 的偏置估计在漂（±3 µT），原始读数 = 真实磁场 + 固定偏置；中位数应该接近固定偏置，校正后读数不漂。
    func testMedianBiasIgnoresIOSDrift() {
        let tr = RawBiasTracker()
        let trueBias = (80.0, -112.0, -649.0)
        var rng = MagRNG(seed: 9)
        for i in 0..<(60 * 50) {
            let t = Int64(i * 20)
            let field = (20 + 5 * sin(Double(i) / 200), 5.0, -43.0)
            let drift = i > 1100 && i < 1500 ? 3.5 : 0.4 * rng.normal()      // 中间有一段 iOS 估计偏了 3.5 µT
            let raw = (field.0 + trueBias.0, field.1 + trueBias.1, field.2 + trueBias.2)
            let cal = (field.0 - drift, field.1, field.2)
            tr.add(tMs: t, raw: raw, calibrated: cal)
        }
        XCTAssertTrue(tr.isReady)
        let b = tr.bias!
        XCTAssertEqual(b.0, trueBias.0, accuracy: 0.3)
        XCTAssertEqual(b.2, trueBias.2, accuracy: 0.3)
        let c = tr.corrected((100, -107, -692))!
        XCTAssertEqual(c.0, 20, accuracy: 0.3)
    }

    func testNotReadyBeforeMinSeconds() {
        let tr = RawBiasTracker()
        for i in 0..<100 { tr.add(tMs: Int64(i * 20), raw: (1, 1, 1), calibrated: (0, 0, 0)) }   // 2 秒
        XCTAssertFalse(tr.isReady)
        XCTAssertNil(tr.corrected((1, 1, 1)))
    }
}
