import XCTest
@testable import HPASSKit

/// 合成一次「只有起点 + 朝向、途中不修正」的建图采集：用户设的朝向偏了 3°，ARKit 还有 0.5% 的尺度误差。
/// 不贴通道时轨迹越走越偏；自动贴通道后应该回到通道上，建出的磁场也更接近真值。
final class SurveyMapBuilderTests: XCTestCase {
    private let aisleX = 500.0
    private let crosses = [CrossSegment(code: "V", a: Point2(500, 100), b: Point2(500, 4100), lineWidth: 140),
                           CrossSegment(code: "H", a: Point2(100, 4100), b: Point2(900, 4100), lineWidth: 140)]

    private func field(_ p: Point2) -> (Double, Double, Double) {
        // 世界系磁场（设备平放、不转，设备坐标 = 世界坐标）
        let y = p.y / 100, x = p.x / 100
        return (20 + 6 * sin(0.8 * y) + 2 * x, 5 + 4 * sin(1.3 * y + 1), -43 + 5 * sin(0.5 * y + 2))
    }

    private func session() -> SurveySession {
        let phi = 0.6                                       // ARKit → 地图 的真实旋转
        let a0 = Point2(37, -12), p0 = Point2(aisleX, 300)
        func ar(_ p: Point2) -> Point2 {
            let d = (p - p0) * 1.005                        // ARKit 尺度误差 0.5%
            let c = cos(-phi), s = sin(-phi)
            return Point2(a0.x + d.x * c - d.y * s, a0.y + d.x * s + d.y * c)
        }
        var imu: [IMUSample] = [], raw: [(tMs: Int64, v: (Double, Double, Double))] = [], poses: [SurveySession.Pose] = []
        let bias = (80.0, -110.0, -650.0)
        let T0: Int64 = 1_700_000_000_000
        let speed = 120.0, len = 3600.0
        let n = Int(len / speed * 100)                       // 100 Hz
        for i in 0...n {
            let t = T0 + Int64(i * 10)
            let p = Point2(aisleX, 300 + len * Double(i) / Double(n))
            let f = field(p)
            if i % 2 == 0 {
                // 校准磁场带着 iOS 漂移
                let drift = i > n / 2 ? 3.0 : 0.0
                imu.append(IMUSample(tMs: t, ax: 0, ay: 0, az: 9.81, gx: 0, gy: 0, gz: 0, mx: f.0 + drift, my: f.1, mz: f.2))
            }
            raw.append((t, (f.0 + bias.0, f.1 + bias.1, f.2 + bias.2)))
            if i % 3 == 0 { poses.append(.init(tMs: t, a: ar(p), normal: true)) }
        }
        // 用户设的朝向：沿 +y 走，θ = 0；但手偏了 3°
        let hd = 3 * Double.pi / 180
        let anchors = [SurveySession.Anchor(tMs: T0, kind: "start", map: p0, ar: ar(p0), heading: nil),
                       SurveySession.Anchor(tMs: T0 + 5, kind: "heading", map: p0, ar: ar(p0), heading: hd)]
        return SurveySession(name: "syn", imu: imu, raw: raw, poses: poses, anchors: anchors)
    }

    private func fieldError(_ m: MagneticFieldMap) -> Double {
        var errs: [Double] = []
        for y in stride(from: 500.0, through: 3700, by: 100) {
            let p = Point2(aisleX, y)
            guard let s = m.sample(at: p) else { continue }
            let f = field(p)
            let truthBz = f.2                               // 平放：Bz 就是 z 分量
            errs.append(abs(s.mean.vertical - truthBz))
        }
        return errs.sorted()[errs.count / 2]
    }

    func testSnapPullsTrackBackOntoCorridorAndImprovesField() {
        let s = session()
        let a = SurveyMapBuilder(widthCm: 1000, heightCm: 4400, crosses: crosses)
        a.snapEnabled = false
        let ra = a.add(s)
        let b = SurveyMapBuilder(widthCm: 1000, heightCm: 4400, crosses: crosses)
        let rb = b.add(s)
        XCTAssertEqual(rb.magSource, "raw")
        XCTAssertEqual(rb.bias?.2 ?? 0, -650, accuracy: 0.5)
        XCTAssertGreaterThan(rb.corridorResidualBefore ?? 0, 50)          // 3° 偏差走 36 m，横向偏出 1 m 多
        // 只把出界的拉回通道（140 cm 宽：离中心线 70 − 30 = 40 cm 以内不拉），不强拉到正中
        XCTAssertLessThan(rb.corridorResidualAfter ?? 999, 45)
        // 对齐后的轨迹离真实路线（x = 500）多远：不贴通道越走越偏，贴了之后基本在线上
        func lateral(_ r: SurveySessionReport) -> Double {
            let d = r.track.map { abs($0.p.x - aisleX) }.sorted()
            return d[d.count / 2]
        }
        XCTAssertGreaterThan(lateral(ra), 50)
        XCTAssertLessThan(lateral(rb), 45)
        XCTAssertLessThan(fieldError(b.build()), 1.0)
        XCTAssertGreaterThan(rb.samplesUsed, 1000)
    }

    func testMissingHeadingWarns() {
        var s = session()
        s.anchors.removeAll { $0.kind == "heading" }
        let b = SurveyMapBuilder(widthCm: 1000, heightCm: 4400, crosses: crosses)
        let r = b.add(s)
        XCTAssertFalse(r.warnings.isEmpty)
        XCTAssertEqual(r.samplesUsed, 0)
    }
}
