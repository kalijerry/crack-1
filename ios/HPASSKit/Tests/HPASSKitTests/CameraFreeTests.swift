import XCTest
@testable import HPASSKit

/// 终端用户「不用摄像头」相关的小策略：视觉观测门控、硬铁偏置球面拟合。
final class CameraFreeTests: XCTestCase {

    // MARK: VisualFixPolicy

    func testVisualFixOffByDefaultSetting() {
        for p in [HoldPosture.upright, .reading, .flat, .swinging, .other, .unknown] {
            XCTAssertFalse(VisualFixPolicy.acceptsFix(enhancementEnabled: false, posture: p, arTrackingNormal: true),
                           "视觉增强关着时任何姿态都不接受视觉观测（\(p)）")
            XCTAssertFalse(VisualFixPolicy.wantsARSession(enhancementEnabled: false, posture: p))
        }
    }

    func testVisualFixOnlyUprightAndTrackingNormal() {
        XCTAssertTrue(VisualFixPolicy.acceptsFix(enhancementEnabled: true, posture: .upright, arTrackingNormal: true))
        XCTAssertTrue(VisualFixPolicy.acceptsFix(enhancementEnabled: true, posture: .reading, arTrackingNormal: true))
        XCTAssertFalse(VisualFixPolicy.acceptsFix(enhancementEnabled: true, posture: .upright, arTrackingNormal: false),
                       "ARKit 跟踪不正常时不接受")
        for p in [HoldPosture.flat, .swinging, .other, .unknown] {
            XCTAssertFalse(VisualFixPolicy.acceptsFix(enhancementEnabled: true, posture: p, arTrackingNormal: true),
                           "口袋 / 摆臂 / 平放等姿态不接受（\(p)）")
            XCTAssertFalse(VisualFixPolicy.wantsARSession(enhancementEnabled: true, posture: p),
                           "这些姿态下摄像头应关掉（\(p)）")
        }
        XCTAssertEqual(VisualFixPolicy.sigmaCm, 50, accuracy: 1e-9)
    }

    // MARK: HardIronFit

    /// 均匀分布在球面上的点（加噪声）应拟合回球心和半径
    func testSphereFitRecoversBias() throws {
        let c = (12.0, -30.0, 45.0), r = 48.0
        var pts: [(Double, Double, Double)] = []
        for _ in 0..<400 {
            let z = Double.random(in: -1...1)
            let a = Double.random(in: 0..<(2 * Double.pi))
            let s = (1 - z * z).squareRoot()
            pts.append((c.0 + r * s * cos(a) + Double.random(in: -1...1),
                        c.1 + r * s * sin(a) + Double.random(in: -1...1),
                        c.2 + r * z + Double.random(in: -1...1)))
        }
        let f = try XCTUnwrap(HardIronFit.sphere(pts))
        XCTAssertEqual(f.center.0, c.0, accuracy: 1)
        XCTAssertEqual(f.center.1, c.1, accuracy: 1)
        XCTAssertEqual(f.center.2, c.2, accuracy: 1)
        XCTAssertEqual(f.radius, r, accuracy: 1)
        XCTAssertLessThan(f.rms, 1.5)
    }

    func testSphereFitRejectsDegenerate() {
        // 全部同一个点：方程奇异
        let pts = [(Double, Double, Double)](repeating: (10, 20, 30), count: 50)
        XCTAssertNil(HardIronFit.sphere(pts))
        XCTAssertNil(HardIronFit.sphere([(1, 2, 3)]))
    }

    func testSolve4() throws {
        let a: [[Double]] = [[4, 1, 0, 0], [1, 3, 1, 0], [0, 1, 2, 1], [0, 0, 1, 5]]
        let x = [1.0, -2.0, 3.0, 0.5]
        let b = a.map { row in zip(row, x).map { $0 * $1 }.reduce(0, +) }
        let s = try XCTUnwrap(HardIronFit.solve4(a, b))
        for i in 0..<4 { XCTAssertEqual(s[i], x[i], accuracy: 1e-9) }
    }
}
