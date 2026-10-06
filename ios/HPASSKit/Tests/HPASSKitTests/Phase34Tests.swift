import Foundation
import XCTest
@testable import HPASSKit

final class Phase34Tests: XCTestCase {
    private func field() -> MagneticFieldMap {
        let b = MagneticFieldBuilder(widthCm: 3000, heightCm: 500, cellCm: 50)
        for i in 0..<600 {
            let x = Double(i) * 5
            for _ in 0..<6 {
                b.add(position: Point2(x, 250), feature: MagneticFeature(total: 50 + 3 * sin(x / 150), vertical: 40, horizontal: 25))
            }
        }
        return b.build()
    }

    /// 变化检测：没变时不报；一段磁场整体偏 6 µT，只标出那一段
    func testChangeDetection() {
        let f = field()
        for shift in [0.0, 6.0] {
            let m = LiveFieldMonitor(field: f)
            for _ in 0..<3 {
                for x in stride(from: 0.0, through: 2990, by: 20) {
                    let p = Point2(x, 250), s = f.sample(at: p)!.mean
                    let changed = shift > 0 && x >= 1000 && x < 1500
                    m.add(position: p, feature: MagneticFeature(total: s.total + (changed ? shift : 0), vertical: s.vertical, horizontal: s.horizontal), field: f)
                }
            }
            let ch = m.changed()
            if shift == 0 { XCTAssertTrue(ch.isEmpty) } else {
                XCTAssertFalse(ch.isEmpty)
                XCTAssertTrue(ch.allSatisfy { $0.center.x >= 950 && $0.center.x <= 1550 })
            }
        }
    }

    /// 高斯过程补空格：两段数据中间空出来的地方，值落在两边之间、不确定度比有数据的格子大
    func testGPFill() {
        let b = MagneticFieldBuilder(widthCm: 1000, heightCm: 200, cellCm: 50)
        b.fillMethod = .gp
        for x in stride(from: 0.0, to: 400, by: 10) { for _ in 0..<6 { b.add(position: Point2(x, 100), feature: MagneticFeature(total: 50, vertical: 40, horizontal: 20)) } }
        for x in stride(from: 500.0, to: 1000, by: 10) { for _ in 0..<6 { b.add(position: Point2(x, 100), feature: MagneticFeature(total: 54, vertical: 40, horizontal: 20)) } }
        let f = b.build()
        let gap = f.sample(at: Point2(425, 125))!
        XCTAssertGreaterThan(gap.mean.total, 49.5)
        XCTAssertLessThan(gap.mean.total, 54.5)
        XCTAssertGreaterThan(gap.sigma.total, f.sample(at: Point2(125, 125))!.sigma.total)
    }

    /// 定位器被外部判「不在采集区域」时不收敛
    func testConvergenceBlocked() {
        let f = field()
        let loc = MagneticLocalizer(field: f, walkable: nil)
        loc.reset(start: nil, headingUnknown: true)
        loc.convergenceBlocked = true
        var e: MagneticEstimate?
        for i in 0..<60 {
            let x = Double(i) * 20
            e = loc.step(delta: Point2(20, 0), feature: f.sample(at: Point2(x, 250))!.mean)
        }
        XCTAssertEqual(e?.converged, false)
    }
}
