import XCTest
@testable import HPASSKit

/// 气压楼层检测：合成 4 Hz 的相对高度（噪声 σ 0.1 m）和 1.8 Hz 的步，
/// 场景之间只差「垂直速度」和「这段有没有在走路」。Python 镜像实现上每个场景跑过 200 个随机种子，结果都一致。
final class FloorDetectorTests: XCTestCase {

    /// (时长 s, 垂直速度 m/s, 是否在走)
    private typealias Segment = (dur: Double, v: Double, walking: Bool)

    private func run(_ segs: [Segment], seed: UInt64 = 1, noise: Double = 0.1,
                     pressure: Bool = false, driftHPaPerS: Double = 0,
                     floorHeightM: Double = 4.5) -> FloorDetector {
        var cfg = FloorDetector.Config()
        cfg.floorHeightM = floorHeightM
        let fd = FloorDetector(startFloor: 0, config: cfg)
        var rng = MagRNG(seed: seed)
        var t = 0.0, h = 0.0, nextStep = 0.0
        for s in segs {
            let n = Int(s.dur * 4)
            for _ in 0..<n {
                t += 0.25
                h += s.v * 0.25
                if s.walking {
                    if t >= nextStep {
                        fd.addStep(tMs: Int64(t * 1000))
                        nextStep = t + 1 / 1.8
                    }
                } else {
                    nextStep = t
                }
                let hm = h + noise * rng.normal()
                if pressure {
                    let p = 1013.25 * pow(1 - hm / 44330, 5.255) + driftHPaPerS * t
                    fd.addPressure(tMs: Int64(t * 1000), hPa: p)
                } else {
                    fd.addRelativeAltitude(tMs: Int64(t * 1000), meters: hm)
                }
            }
        }
        return fd
    }

    func testElevatorUpTwoFloors() {
        let fd = run([(10, 0, true), (2, 0, false), (6, 1.5, false), (2, 0, false), (15, 0, true)])
        XCTAssertEqual(fd.floor, 2)
        XCTAssertEqual(fd.changes.count, 1)
        XCTAssertEqual(fd.changes.first?.mode, .elevator)
        XCTAssertEqual(fd.changes.first?.deltaMeters ?? 0, 9, accuracy: 0.6)
        XCTAssertFalse(fd.isMovingVertically)
    }

    func testElevatorDownOneFloorWithStepsAround() {
        let fd = run([(10, 0, true), (1, 0, false), (4.5, -1.0, false), (1, 0, false), (15, 0, true)])
        XCTAssertEqual(fd.floor, -1)
        XCTAssertEqual(fd.changes.first?.mode, .elevator)
    }

    func testStairsDown() {
        let fd = run([(10, 0, true), (18, -0.25, true), (15, 0, true)])
        XCTAssertEqual(fd.floor, -1)
        XCTAssertEqual(fd.changes.first?.mode, .stairs)
        XCTAssertGreaterThan(fd.changes.first?.stepRate ?? 0, 1.0)
    }

    func testEscalatorStandingUp() {
        let fd = run([(10, 0, true), (20, 0.25, false), (15, 0, true)])
        XCTAssertEqual(fd.floor, 1)
        XCTAssertEqual(fd.changes.first?.mode, .escalator)
        XCTAssertLessThan(fd.changes.first?.peakSpeed ?? 1, 0.6)
    }

    /// 开门 / 空调造成的气压跳动、1.5 m 的夹层台阶都不算换层。
    func testDoorBlipAndMezzanineIgnored() {
        let blip = run([(10, 0, true), (0.25, 1.6, true), (20, 0, true), (0.25, -1.6, true), (20, 0, true)])
        XCTAssertEqual(blip.floor, 0)
        XCTAssertTrue(blip.changes.isEmpty)
        let mezz = run([(10, 0, true), (6, 0.25, true), (15, 0, true)])
        XCTAssertEqual(mezz.floor, 0)
    }

    /// 天气：一小时气压降 1 hPa（约 8 m 的「假高度」），人一直在同层走动，不应换层。
    func testWeatherDriftDoesNotChangeFloor() {
        let fd = run([(3600, 0, true)], pressure: true, driftHPaPerS: -1.0 / 3600)
        XCTAssertEqual(fd.floor, 0)
        XCTAssertTrue(fd.changes.isEmpty)
    }

    func testPressureInputMatchesAltitudeInput() {
        let fd = run([(10, 0, true), (2, 0, false), (6, 1.5, false), (2, 0, false), (15, 0, true)], pressure: true)
        XCTAssertEqual(fd.floor, 2)
        XCTAssertEqual(fd.changes.first?.mode, .elevator)
    }

    func testSetFloorAndOutOfOrderSamples() {
        let fd = FloorDetector(startFloor: 3)
        XCTAssertNil(fd.addRelativeAltitude(tMs: 1000, meters: 0))
        XCTAssertNil(fd.addRelativeAltitude(tMs: 900, meters: 50))      // 时间倒退，忽略
        XCTAssertEqual(fd.altitudeM, 0, accuracy: 1e-9)
        XCTAssertNil(fd.addPressure(tMs: 2000, hPa: 5))                  // 不合理的气压，忽略
        fd.setFloor(-2)
        XCTAssertEqual(fd.floor, -2)
    }
}
