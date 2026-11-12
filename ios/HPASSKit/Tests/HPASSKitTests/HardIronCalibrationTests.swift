import XCTest
@testable import HPASSKit

final class HardIronCalibrationTests: XCTestCase {
    private let bias = [-3.0, -98.0, -637.0]
    private let world = [18.0, 0.0, -46.0]

    /// 绕 x、y、z 依次转的矩阵（设备 → 世界）
    private func rot(_ a: Double, _ b: Double, _ c: Double) -> [[Double]] {
        let rx: [[Double]] = [[1, 0, 0], [0, cos(a), -sin(a)], [0, sin(a), cos(a)]]
        let ry: [[Double]] = [[cos(b), 0, sin(b)], [0, 1, 0], [-sin(b), 0, cos(b)]]
        let rz: [[Double]] = [[cos(c), -sin(c), 0], [sin(c), cos(c), 0], [0, 0, 1]]
        return mul(rz, mul(ry, rx))
    }

    private func mul(_ p: [[Double]], _ q: [[Double]]) -> [[Double]] {
        var out = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += p[i][k] * q[k][j] }
                out[i][j] = s
            }
        }
        return out
    }

    /// 合成「画 8 字」：读数 m = Rᵀ w + b + 噪声
    private func feed(_ cal: inout HardIronCalibration, amp: Double, seconds: Double = 30, noise: Double = 1,
                      transpose: Bool = false, extraField: Double = 0) {
        var g = SystemRandomNumberGenerator()
        let n = Int(seconds * 25)
        for k in 0..<n {
            let t = Double(k) / 25
            let r = rot(amp * sin(0.5 * t), 0.8 * amp * sin(1.0 * t), 0.6 * amp * sin(0.7 * t + 1))
            var m = [0.0, 0.0, 0.0]
            for j in 0..<3 {
                var v = bias[j]
                for i in 0..<3 { v += r[i][j] * world[i] }
                let jitter = Double.random(in: -noise...noise, using: &g) * 1.7
                m[j] = v + jitter + extraField * sin(3.1 * t)
            }
            var given = r
            if transpose {
                for i in 0..<3 { for j in 0..<3 { given[i][j] = r[j][i] } }
            }
            cal.add(raw: (m[0], m[1], m[2]), rotation: given)
            if cal.result != nil { return }
        }
    }

    func testFigureEightRecoversBias() throws {
        var cal = HardIronCalibration()
        feed(&cal, amp: 1.2)
        let r = try XCTUnwrap(cal.result)
        for k in 0..<3 { XCTAssertEqual(r.bias[k], bias[k], accuracy: 2) }
        XCTAssertEqual(r.fieldUT, 49.4, accuracy: 2)
        XCTAssertEqual(cal.progress, 1)
    }

    func testEitherRotationConventionWorks() throws {
        var cal = HardIronCalibration()
        feed(&cal, amp: 1.2, transpose: true)
        let r = try XCTUnwrap(cal.result)
        for k in 0..<3 { XCTAssertEqual(r.bias[k], bias[k], accuracy: 2) }
    }

    func testTooLittleRotationNeverFinishes() {
        var cal = HardIronCalibration()
        feed(&cal, amp: 0.15)
        XCTAssertNil(cal.result)
        XCTAssertEqual(cal.issue, .needMoreRotation)
        XCTAssertLessThan(cal.progress, 0.9)
    }

    func testDisturbedFieldIsFlaggedNoisy() {
        var cal = HardIronCalibration()
        feed(&cal, amp: 1.2, extraField: 25)
        XCTAssertNil(cal.result)
        if case .noisy = cal.issue {} else { XCTFail("应提示附近磁场乱：\(String(describing: cal.issue))") }
    }

    func testQuickCheckSpotsShiftedBias() {
        let stored = [31.0, 100.0, -636.0]          // 11/9 的偏置
        let now = [(Double, Double, Double)](repeating: (17.0, -93.0, -682.0), count: 60)   // 今天的读数
        XCTAssertEqual(HardIronCheck.shifted(raw: now, bias: stored), true)
        XCTAssertEqual(HardIronCheck.shifted(raw: now, bias: bias), false)
        XCTAssertNil(HardIronCheck.shifted(raw: Array(now.prefix(5)), bias: bias))
    }
}
