import XCTest
@testable import HPASSKit

// MARK: - 合成数据工具

/// 50 Hz 合成 IMU 数据发生器。全部确定性（固定种子 LCG），不依赖真实采集。
private struct FusionSynth {
    static let g = 9.80665
    static let dtMs: Int64 = 20          // 50 Hz
    static let t0: Int64 = 1_700_000_000_000

    var tMs: Int64 = FusionSynth.t0
    private var seed: UInt64 = 0x2545F4914F6CDD1D

    /// 均匀分布噪声，范围 ±amp。
    private mutating func noise(_ amp: Double) -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let bits = (seed >> 11) & 0x000F_FFFF_FFFF_FFFF      // 52 bit
        let u = Double(bits) / Double(1 << 52)               // [0, 1)
        return (u - 0.5) * 2.0 * amp
    }

    /// 手机屏幕朝上平放、机体 +y 轴指向罗盘方位 psiDeg 时的机体系磁场（µT）。
    /// 水平分量指向磁北，竖直分量向下（北半球倾角约 60°，|m| = 40 µT 在 25–70 的可信区间内）。
    static func magFlat(psiDeg: Double, horizUT: Double = 20.0, downUT: Double = 34.64) -> FusionVec3 {
        let psi = psiDeg * Double.pi / 180.0
        // 机体水平面内的磁北方向 = 把 +y 绕竖直轴逆时针转 psi
        return FusionVec3(-horizUT * sin(psi), horizUT * cos(psi), -downUT)
    }

    mutating func sample(ax: Double, ay: Double, az: Double,
                         gx: Double = 0, gy: Double = 0, gz: Double = 0,
                         mag: FusionVec3,
                         accNoise: Double = 0.02) -> IMUSample {
        let s = IMUSample(tMs: tMs,
                          ax: ax + noise(accNoise),
                          ay: ay + noise(accNoise),
                          az: az + noise(accNoise),
                          gx: gx, gy: gy, gz: gz,
                          mx: mag.x, my: mag.y, mz: mag.z)
        tMs += FusionSynth.dtMs
        return s
    }

    /// 平放静止样本。
    mutating func still(mag: FusionVec3) -> IMUSample {
        sample(ax: 0, ay: 0, az: FusionSynth.g, mag: mag)
    }

    /// 角度差（度），结果在 (−180, 180]。
    static func angleDiffDeg(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360.0)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}

// MARK: - 测试

final class FusionTests: XCTestCase {

    // (a) 静止：航向从合成磁场 + 磁偏角初始化，零步数，位置不动
    func testStationaryInitializesHeadingAndDoesNotMove() {
        var cfg = FusionConfig()
        cfg.magneticDeclinationDeg = 30.0          // 地图 +y 指向磁北偏东 30°
        let engine = FusionEngine(corridors: [], config: cfg)
        let start = Point2(1000, 1000)
        engine.setInitialPosition(start, headingRad: nil)

        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)   // 机体 +y 指向磁北
        var last: FusionOutput?
        for _ in 0..<150 {                          // 3 s
            if let o = engine.process(synth.still(mag: mag)) { last = o }
        }

        guard let out = last else {
            XCTFail("静止 3 s 应该已经初始化并产生输出")
            return
        }
        // +y 正对磁北（ψ=0），地图航向 θ = declination − ψ = 30°
        XCTAssertEqual(FusionSynth.angleDiffDeg(out.headingDeg, 30.0), 0.0, accuracy: 3.0)
        XCTAssertEqual(out.stepCount, 0)
        XCTAssertFalse(out.stepDetected)
        XCTAssertFalse(out.isMoving)
        XCTAssertLessThan(out.position.distance(to: start), 20.0)   // cm
        XCTAssertTrue(engine.isInitialized)
        XCTAssertNotNil(engine.lastOutput)
    }

    /// 航向约定自检：机体 +y 指向正东（ψ=90°）、磁偏角 0 → 地图航向 = −90° ≡ 270°。
    func testHeadingConventionEastFacing() {
        let engine = FusionEngine(corridors: [])
        engine.setInitialPosition(.zero, headingRad: nil)
        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 90)
        var last: FusionOutput?
        for _ in 0..<120 {
            if let o = engine.process(synth.still(mag: mag)) { last = o }
        }
        guard let out = last else { XCTFail("应有输出"); return }
        XCTAssertEqual(FusionSynth.angleDiffDeg(out.headingDeg, 270.0), 0.0, accuracy: 3.0)
    }

    // (b) 1.8 Hz 直行 20 s：步数 ±10%，步长 0.4–0.9 m，位置沿航向前进
    func testWalkingStraightCountsStepsAndAdvances() {
        var cfg = FusionConfig()
        cfg.magneticDeclinationDeg = 0
        let engine = FusionEngine(corridors: [], config: cfg)
        engine.setInitialPosition(.zero, headingRad: nil)

        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)    // 航向 0 → 朝地图 +y
        let freq = 1.8
        let amp = 2.0
        let n = 1000                                 // 20 s @ 50 Hz
        var last: FusionOutput?
        var sawStep = false
        for i in 0..<n {
            let t = Double(i) * 0.02
            let az = FusionSynth.g + amp * sin(2.0 * Double.pi * freq * t)
            let s = synth.sample(ax: 0, ay: 0, az: az, mag: mag)
            if let o = engine.process(s) {
                last = o
                if o.stepDetected { sawStep = true }
            }
        }

        guard let out = last else { XCTFail("应有输出"); return }
        XCTAssertTrue(sawStep)
        // 真值 1.8 Hz × 20 s = 36 步；首个周期没有前置谷值不计数，所以期望 35 步左右
        XCTAssertGreaterThanOrEqual(out.stepCount, 32)
        XCTAssertLessThanOrEqual(out.stepCount, 40)
        // Weinberg：峰峰值约 3.7 m/s² → 0.45 · 3.7^0.25 ≈ 0.62 m
        XCTAssertGreaterThan(out.stepLengthM, 0.4)
        XCTAssertLessThan(out.stepLengthM, 0.9)
        XCTAssertTrue(out.isMoving)
        // 航向 0 → 位移应该几乎全在 +y 上（约 35 × 0.62 = 21.7 m = 2170 cm）
        XCTAssertGreaterThan(out.position.y, 1500.0)
        XCTAssertLessThan(out.position.y, 2900.0)
        XCTAssertLessThan(abs(out.position.x), 300.0)
        XCTAssertEqual(FusionSynth.angleDiffDeg(out.headingDeg, 0.0), 0.0, accuracy: 15.0)
    }

    // (c) 由陀螺 z 积分出的 90° 转弯
    func testGyroTurnChangesHeadingBy90Degrees() {
        let engine = FusionEngine(corridors: [])
        engine.setInitialPosition(.zero, headingRad: nil)

        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)

        // 先静止 1 s，让航向完成初始化
        var before: FusionOutput?
        for _ in 0..<50 {
            if let o = engine.process(synth.still(mag: mag)) { before = o }
        }
        guard let pre = before else { XCTFail("转弯前应有输出"); return }

        // 3 s 内绕竖直轴转 90°（θ 以逆时针为正，ω_up = +π/6 rad/s）
        let rate = (Double.pi / 2.0) / 3.0
        var after: FusionOutput?
        for _ in 0..<150 {
            let s = synth.sample(ax: 0, ay: 0, az: FusionSynth.g, gz: rate, mag: mag)
            if let o = engine.process(s) { after = o }
        }
        // 再补 0.4 s 静止，确保转完的航向能落到一个输出节拍上
        for _ in 0..<20 {
            if let o = engine.process(synth.still(mag: mag)) { after = o }
        }
        guard let post = after else { XCTFail("转弯后应有输出"); return }

        let delta = FusionSynth.angleDiffDeg(post.headingDeg, pre.headingDeg)
        XCTAssertEqual(delta, 90.0, accuracy: 10.0)
    }

    // (d) 持续偏 2 m 的定位：轨迹几秒内收敛过去
    func testRepeatedFixesPullTrackOver() {
        let engine = FusionEngine(corridors: [])
        engine.setInitialPosition(.zero, headingRad: nil)

        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)
        var last: FusionOutput?
        for i in 0..<500 {                              // 10 s
            let s = synth.still(mag: mag)
            let t = s.tMs
            if let o = engine.process(s) { last = o }
            if i > 0 && i % 50 == 0 {                   // 每 1 s 一次定位
                engine.updateFix(position: Point2(200, 0), confidence: 1.0, tMs: t)
            }
        }
        guard let out = last else { XCTFail("应有输出"); return }
        XCTAssertGreaterThan(out.position.x, 150.0)
        XCTAssertLessThan(out.position.x, 230.0)
        XCTAssertLessThan(abs(out.position.y), 60.0)
    }

    // (e) 单个 30 m 野点：被卡方门限拒掉，轨迹几乎不动
    func testOutlierFixIsRejected() {
        let engine = FusionEngine(corridors: [])
        engine.setInitialPosition(.zero, headingRad: nil)

        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)
        var last: FusionOutput?
        for i in 0..<200 {                               // 4 s
            let s = synth.still(mag: mag)
            let t = s.tMs
            if let o = engine.process(s) { last = o }
            if i == 100 {
                engine.updateFix(position: Point2(3000, 0), confidence: 1.0, tMs: t)
            }
        }
        guard let out = last else { XCTFail("应有输出"); return }
        XCTAssertLessThan(out.position.length, 50.0)     // cm
    }

    /// 连续野点（同一方向持续 6 次）时的兜底：不能永远拒绝，必须最终重置过去。
    func testPersistentDisagreementEventuallyResets() {
        let engine = FusionEngine(corridors: [])
        engine.setInitialPosition(.zero, headingRad: nil)

        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)
        var last: FusionOutput?
        for i in 0..<500 {
            let s = synth.still(mag: mag)
            let t = s.tMs
            if let o = engine.process(s) { last = o }
            if i > 0 && i % 50 == 0 {
                engine.updateFix(position: Point2(3000, 0), confidence: 1.0, tMs: t)
            }
        }
        guard let out = last else { XCTFail("应有输出"); return }
        XCTAssertGreaterThan(out.position.x, 2000.0)
    }

    // (f) 被推到通道外的点会被投影回通道内
    func testCorridorConstraintPullsPointInside() {
        var cfg = FusionConfig()
        cfg.corridorMarginCm = 30
        // 沿 +y 的通道，宽 200 cm → 有效半宽 = 100 − 30 = 70 cm
        let corridor = CrossSegment(code: "C1", a: Point2(0, 0), b: Point2(0, 1000), lineWidth: 200)
        let engine = FusionEngine(corridors: [corridor], config: cfg)
        engine.setInitialPosition(Point2(0, 500), headingRad: nil)

        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)
        var last: FusionOutput?
        var sawConstrained = false
        for i in 0..<600 {                               // 12 s
            let s = synth.still(mag: mag)
            let t = s.tMs
            if let o = engine.process(s) {
                last = o
                if o.wasConstrained { sawConstrained = true }
            }
            if i > 0 && i % 50 == 0 {
                // 定位把点往通道外（x = 300 cm）推
                engine.updateFix(position: Point2(300, 500), confidence: 1.0, tMs: t)
            }
        }
        guard let out = last else { XCTFail("应有输出"); return }
        XCTAssertTrue(sawConstrained, "点被推到通道外时应触发约束")
        XCTAssertLessThanOrEqual(abs(out.position.x), 70.5)   // 半宽 70，投影内缩到 66.5
        XCTAssertGreaterThan(out.position.x, 30.0)            // 确实朝定位方向移动过
        XCTAssertLessThan(abs(out.position.y - 500.0), 80.0)
    }

    // (g) 空通道列表：不崩，wasConstrained 恒为 false
    func testEmptyCorridorListNeverConstrains() {
        let engine = FusionEngine(corridors: [])
        engine.setInitialPosition(Point2(500, 500), headingRad: 0)
        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)
        var count = 0
        for i in 0..<400 {
            let s = synth.still(mag: mag)
            let t = s.tMs
            if let o = engine.process(s) {
                count += 1
                XCTAssertFalse(o.wasConstrained)
            }
            if i == 100 {
                engine.updateFix(position: Point2(9000, -9000), confidence: 0.2, tMs: t)
            }
        }
        XCTAssertGreaterThan(count, 10)

        // StoreMap 版构造器 + 空 crosses 同样不能崩
        let map = StoreMap(width: 5000, height: 5000, shelves: [], crosses: [])
        let engine2 = FusionEngine(map: map)
        engine2.setInitialPosition(Point2(100, 100), headingRad: nil)
        var synth2 = FusionSynth()
        var out2: FusionOutput?
        for _ in 0..<200 {
            if let o = engine2.process(synth2.still(mag: mag)) { out2 = o }
        }
        XCTAssertNotNil(out2)
        XCTAssertFalse(out2?.wasConstrained ?? true)
    }

    // (h) 定位中断：不确定度单调增长
    func testUncertaintyGrowsWhenFixesStop() {
        let engine = FusionEngine(corridors: [])
        engine.setInitialPosition(.zero, headingRad: nil)
        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)
        var us: [Double] = []
        for _ in 0..<400 {                               // 8 s，全程没有定位
            if let o = engine.process(synth.still(mag: mag)) { us.append(o.uncertaintyCm) }
        }
        XCTAssertGreaterThan(us.count, 10)
        for i in 1..<us.count {
            XCTAssertGreaterThanOrEqual(us[i], us[i - 1] - 1e-9, "第 \(i) 帧不确定度下降了")
        }
        guard let first = us.first, let lastU = us.last else { XCTFail("无输出"); return }
        XCTAssertGreaterThan(lastU - first, 1.0)         // 8 s 至少涨 1 cm
    }

    // MARK: - 辅助行为

    /// 输出节拍不超过 outputIntervalMs 一次。
    func testOutputRateIsThrottled() {
        var cfg = FusionConfig()
        cfg.outputIntervalMs = 340
        let engine = FusionEngine(corridors: [], config: cfg)
        engine.setInitialPosition(.zero, headingRad: 0)
        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)
        var ts: [Int64] = []
        for _ in 0..<500 {                               // 10 s
            if let o = engine.process(synth.still(mag: mag)) { ts.append(o.tMs) }
        }
        XCTAssertGreaterThan(ts.count, 20)
        XCTAssertLessThan(ts.count, 40)                  // 10 s / 0.34 s ≈ 29
        for i in 1..<ts.count {
            XCTAssertGreaterThanOrEqual(ts[i] - ts[i - 1], 340)
        }
    }

    /// 未初始化时 process 返回 nil。
    func testNoOutputBeforeInitialization() {
        let engine = FusionEngine(corridors: [])
        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)
        for _ in 0..<100 {
            XCTAssertNil(engine.process(synth.still(mag: mag)))
        }
        XCTAssertFalse(engine.isInitialized)
        XCTAssertNil(engine.lastOutput)
    }

    /// 第一次 updateFix 可以充当初始化。
    func testFirstFixInitializesPosition() {
        let engine = FusionEngine(corridors: [])
        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)
        engine.updateFix(position: Point2(700, 800), confidence: 1.0, tMs: FusionSynth.t0)
        var last: FusionOutput?
        for _ in 0..<150 {
            if let o = engine.process(synth.still(mag: mag)) { last = o }
        }
        guard let out = last else { XCTFail("应有输出"); return }
        XCTAssertLessThan(out.position.distance(to: Point2(700, 800)), 30.0)
    }

    /// reset 之后回到未初始化状态。
    func testResetClearsState() {
        let engine = FusionEngine(corridors: [])
        engine.setInitialPosition(Point2(100, 100), headingRad: 0)
        var synth = FusionSynth()
        let mag = FusionSynth.magFlat(psiDeg: 0)
        for _ in 0..<150 { _ = engine.process(synth.still(mag: mag)) }
        XCTAssertTrue(engine.isInitialized)
        engine.reset()
        XCTAssertFalse(engine.isInitialized)
        XCTAssertNil(engine.lastOutput)
        XCTAssertNil(engine.process(synth.still(mag: mag)))
    }

    /// 磁场模长不可信（硬铁干扰）时不接受磁观测：航向只能靠兜底值初始化。
    func testImplausibleMagnetometerIsRejected() {
        let engine = FusionEngine(corridors: [])
        engine.setInitialPosition(.zero, headingRad: nil)
        var synth = FusionSynth()
        let bad = FusionVec3(300, 300, 300)             // |m| ≈ 520 µT，远超 70
        var last: FusionOutput?
        for _ in 0..<300 {                               // 6 s，超过 3 s 初始化超时
            if let o = engine.process(synth.sample(ax: 0, ay: 0, az: FusionSynth.g, mag: bad)) {
                last = o
            }
        }
        // 超时兜底：headingRad 为 nil 时退化为 0，但引擎必须照常出结果而不是卡死
        guard let out = last else { XCTFail("磁场不可信时也应有输出（兜底航向）"); return }
        XCTAssertEqual(FusionSynth.angleDiffDeg(out.headingDeg, 0.0), 0.0, accuracy: 5.0)
    }

    /// 通道几何：胶囊包含判定 + 矩形角点。
    func testCorridorGeometry() {
        let seg = CrossSegment(code: "C", a: Point2(0, 0), b: Point2(0, 1000), lineWidth: 200)
        let map = FusionCorridorMap([seg])
        XCTAssertEqual(map.halfWidth(seg, marginCm: 30), 70.0, accuracy: 1e-9)
        XCTAssertTrue(map.contains(Point2(50, 500), marginCm: 30))
        XCTAssertFalse(map.contains(Point2(200, 500), marginCm: 30))
        XCTAssertNil(map.project(Point2(50, 500), marginCm: 30))
        guard let proj = map.project(Point2(200, 500), marginCm: 30) else {
            XCTFail("通道外的点应返回投影")
            return
        }
        XCTAssertEqual(proj.point.x, 66.5, accuracy: 1e-6)
        XCTAssertEqual(proj.point.y, 500.0, accuracy: 1e-6)
        XCTAssertEqual(proj.distanceCm, 133.5, accuracy: 1e-6)
        XCTAssertEqual(map.polygon(at: 0, marginCm: 30).count, 4)
        XCTAssertEqual(map.polygon(at: 5, marginCm: 30).count, 0)
        XCTAssertTrue(FusionCorridorMap([]).isEmpty)
        XCTAssertNil(FusionCorridorMap([]).project(Point2(1, 1), marginCm: 30))
    }
}
