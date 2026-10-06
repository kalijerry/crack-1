import Foundation
import XCTest
@testable import HPASSKit

final class CorridorLockTests: XCTestCase {
    /// 沿竖直通道走，轨迹朝向偏 6°、横向偏 150 cm（跑出了通道）：自动贴通道之后应该回到中心线附近。
    func testPullsTiltedWalkBackOntoCorridor() {
        let cross = CrossSegment(code: "C", a: Point2(1000, 0), b: Point2(1000, 4000), lineWidth: 200)
        let lock = CorridorLock(crosses: [cross])
        let err = 6.0 * Double.pi / 180
        var pRef = Point2(1150, 100), aRef = Point2.zero, phi = err
        var last = Point2.zero
        for i in 0...300 {
            let a = Point2(0, Double(i) * 10)         // ARKit 里笔直走 30 m
            let d = a - aRef
            var p = Point2(pRef.x + d.x * cos(phi) - d.y * sin(phi), pRef.y + d.x * sin(phi) + d.y * cos(phi))
            if let fix = lock.update(p) { phi += fix.dPhi; p = p + fix.shift; pRef = p; aRef = a }
            last = p
        }
        XCTAssertLessThan(abs(phi), 1 * Double.pi / 180)
        XCTAssertLessThan(abs(last.x - 1000), 75)   // 拉回通道内（半宽 100 − 30），不强拉到正中
        XCTAssertGreaterThan(lock.corrections, 5)
    }

    /// 横穿（方向和通道差很多）不修正。
    func testIgnoresCrossingWalk() {
        let cross = CrossSegment(code: "C", a: Point2(1000, 0), b: Point2(1000, 4000), lineWidth: 200)
        let lock = CorridorLock(crosses: [cross])
        var n = 0
        for i in 0...100 { if lock.update(Point2(500 + Double(i) * 10, 2000)) != nil { n += 1 } }
        XCTAssertEqual(n, 0)
    }
}
