import XCTest
@testable import HPASSKit

/// 实时定位的参考系不含磁力计、还没有本机硬铁偏置时，App 在 live imu.csv 写 mx..mz = 0,0,0（mag_acc = -1）。
/// 地图自愈（cloud_build --live → LiveRunLoader → SurveyMapBuilder）按「原始 − 校准」的中位数估偏置，
/// 这些行不能参与，否则估出来的是设备系平均磁场（评审）。
final class ZeroMagRowsTests: XCTestCase {
    private let bias = (12.0, -30.0, 45.0)

    /// 一半行有校准值（原始 − 偏置），一半行是 0,0,0
    private func session() -> SurveySession {
        var imu: [IMUSample] = []
        var raw: [(tMs: Int64, v: (Double, Double, Double))] = []
        for k in 0..<400 {
            let t = Int64(k * 20)
            let ang = Double(k) * 0.03
            let cal = (25 * cos(ang), 25 * sin(ang), -40.0)
            let r = (cal.0 + bias.0, cal.1 + bias.1, cal.2 + bias.2)
            raw.append((t, r))
            let m = k % 2 == 0 ? cal : (0.0, 0.0, 0.0)
            imu.append(IMUSample(tMs: t, ax: 0, ay: 0, az: 9.81, gx: 0, gy: 0, gz: 0, mx: m.0, my: m.1, mz: m.2))
        }
        return SurveySession(name: "live", imu: imu, raw: raw, poses: [], anchors: [])
    }

    func testCalibratedFieldValid() {
        XCTAssertFalse(IMUSample.calibratedFieldValid((0, 0, 0)))
        XCTAssertTrue(IMUSample.calibratedFieldValid((20, -5, -40)))
    }

    func testSurveyMapBuilderBiasIgnoresZeroRows() {
        let b = SurveyMapBuilder(widthCm: 1000, heightCm: 1000, crosses: [])
        var rep = SurveySessionReport(name: "live")
        _ = b.features(session(), &rep)
        let est = try? XCTUnwrap(rep.bias)
        XCTAssertEqual(est?.0 ?? .nan, bias.0, accuracy: 0.5)
        XCTAssertEqual(est?.1 ?? .nan, bias.1, accuracy: 0.5)
        XCTAssertEqual(est?.2 ?? .nan, bias.2, accuracy: 0.5)
    }

    func testRawBiasTrackerIgnoresZeroRows() {
        let tr = RawBiasTracker()
        let s = session()
        for (x, r) in zip(s.imu, s.raw) { tr.add(tMs: x.tMs, raw: r.v, calibrated: (x.mx, x.my, x.mz)) }
        if let b = tr.bias {
            XCTAssertEqual(b.0, bias.0, accuracy: 0.5)
            XCTAssertEqual(b.2, bias.2, accuracy: 0.5)
        }
        // 全是 0 行：一个偏置都不该估出来
        let z = RawBiasTracker()
        for (x, r) in zip(s.imu, s.raw) where x.mx == 0 { z.add(tMs: x.tMs, raw: r.v, calibrated: (0, 0, 0)) }
        XCTAssertNil(z.bias)
    }
}
