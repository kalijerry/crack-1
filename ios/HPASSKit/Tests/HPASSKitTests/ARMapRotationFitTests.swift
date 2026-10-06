import Foundation
import XCTest
@testable import HPASSKit

final class ARMapRotationFitTests: XCTestCase {
    /// 一段 L 形轨迹，ARKit 系比地图系转了 40°：拟合出来的旋转应该就是 40°。
    func testRecoversRotation() {
        let phi = 40 * Double.pi / 180
        let fit = ARMapRotationFit()
        var path: [Point2] = []
        for i in 0...30 { path.append(Point2(Double(i) * 20, 0)) }
        for i in 1...15 { path.append(Point2(600, Double(i) * 20)) }
        for a in path {
            let m = Point2(1000 + a.x * cos(phi) - a.y * sin(phi), 500 + a.x * sin(phi) + a.y * cos(phi))
            fit.add(ar: a, map: m)
        }
        XCTAssertEqual(fit.phi ?? 0, phi, accuracy: 1e-6)
        // 和 MapARTransform 的约定一致
        let t = MapARTransform(pRef: Point2(1000, 500), aRef: .zero, phi: fit.phi!)
        let m = t.toMap(Point2(600, 300))
        XCTAssertEqual(m.x, 1000 + 600 * cos(phi) - 300 * sin(phi), accuracy: 1e-6)
    }

    /// 走得太短不给结果。
    func testNeedsEnoughPath() {
        let fit = ARMapRotationFit()
        for i in 0...10 { fit.add(ar: Point2(Double(i) * 20, 0), map: Point2(Double(i) * 20, 0)) }
        XCTAssertNil(fit.phi)
    }
}
