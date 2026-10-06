import XCTest
@testable import HPASSKit

/// 一个缩小版的「大卖场」：7 条平行纵向长通道（长度相同、间距 3.6 m），上下各一条横向通道。
/// 重点测：冷启动能不能找对通道、能不能一直跟住、通道约束有没有帮上忙。
final class GraphLocalizationTests: XCTestCase {

    private let width = 3000.0, height = 3300.0
    private let aisleXs: [Double] = (0..<7).map { 400 + Double($0) * 360 }
    private let topY = 250.0, bottomY = 3050.0

    private lazy var crosses: [CrossSegment] = {
        var c: [CrossSegment] = aisleXs.enumerated().map { i, x in
            CrossSegment(code: "V\(i)", a: Point2(x, topY), b: Point2(x, bottomY), lineWidth: 140)
        }
        c.append(CrossSegment(code: "Ht", a: Point2(300, topY), b: Point2(aisleXs.last! + 100, topY), lineWidth: 140))
        c.append(CrossSegment(code: "Hb", a: Point2(300, bottomY), b: Point2(aisleXs.last! + 100, bottomY), lineWidth: 140))
        return c
    }()

    /// 世界磁场：不同位置有不同结构，沿通道方向的变化尺度约 3～6 m。
    private func field(_ p: Point2) -> MagneticFeature {
        let x = p.x / 100, y = p.y / 100
        let bz = -43 + 6 * sin(1.3 * x + 0.5 * y + 0.3) + 5 * sin(0.4 * x - 1.1 * y + 1.2) + 3 * sin(2.1 * x + 1.7 * y)
        let bh = 25 + 7 * sin(0.9 * x - 0.8 * y + 2.0) + 4 * sin(1.7 * x + 0.6 * y) + 3 * sin(0.3 * x + 1.9 * y + 0.7)
        return MagneticFeature(total: (bz * bz + bh * bh).squareRoot(), vertical: bz, horizontal: bh)
    }

    private func surveyMap(noise: Double, seed: UInt64) -> MagneticFieldMap {
        var rng = MagRNG(seed: seed)
        let b = MagneticFieldBuilder(widthCm: width, heightCm: height)
        // 每条通道的中心线 ± 40 cm，双向各走一遍：直接在这些位置采样
        for x in aisleXs {
            for dx in [-40.0, 0, 40.0] {
                for pass in 0..<2 {
                    var y = topY
                    while y <= bottomY {
                        let p = Point2(x + dx, y)
                        let f = field(p)
                        b.add(position: p, feature: MagneticFeature(total: f.total + noise * rng.normal(),
                                                                    vertical: f.vertical + noise * rng.normal(),
                                                                    horizontal: f.horizontal + noise * rng.normal()))
                        y += 10 + Double(pass) * 3
                    }
                }
            }
        }
        for y in [topY, bottomY] {
            for dy in [-40.0, 0, 40.0] {
                var x = 300.0
                while x <= aisleXs.last! + 100 {
                    let p = Point2(x, y + dy)
                    let f = field(p)
                    b.add(position: p, feature: MagneticFeature(total: f.total + noise * rng.normal(),
                                                                vertical: f.vertical + noise * rng.normal(),
                                                                horizontal: f.horizontal + noise * rng.normal()))
                    x += 10
                }
            }
        }
        return b.build(minSamples: 3)
    }

    /// 走的路线：从上方横向通道进入第 2 条通道往下走，到底部横向通道，换到第 4 条通道往上走，再换到第 6 条往下。
    private var route: [Point2] {
        [Point2(aisleXs[1], topY), Point2(aisleXs[1], bottomY), Point2(aisleXs[3], bottomY),
         Point2(aisleXs[3], topY), Point2(aisleXs[5], topY), Point2(aisleXs[5], bottomY)]
    }

    private struct Result { var errors: [Double]; var wrongAisle: Int; var total: Int; var convergedAt: Double? }

    private func run(cold: Bool, useWalkable: Bool, seed: UInt64) -> Result {
        let map = surveyMap(noise: 0.4, seed: seed)
        let walk = useWalkable ? WalkableMap(crosses: crosses, widthCm: width, heightCm: height) : nil
        let loc = MagneticLocalizer(field: map, walkable: walk, seed: seed)
        loc.reset(start: cold ? nil : route[0], spreadCm: 80)
        var rng = MagRNG(seed: seed &+ 99)
        var errors: [Double] = [], wrong = 0, total = 0, walked = 0.0
        var convergedAt: Double?
        for k in 0..<(route.count - 1) {
            let a = route[k], b = route[k + 1]
            let n = Int(a.distance(to: b) / 70)
            for s in 1...n {
                let d = Point2((b.x - a.x) / Double(n), (b.y - a.y) / Double(n))
                let truth = Point2(a.x + d.x * Double(s), a.y + d.y * Double(s))
                let ang = (5.0 + 0.5 * rng.normal()) * Double.pi / 180
                let sc = 1.04 + 0.02 * rng.normal()
                let delta = Point2((d.x * cos(ang) - d.y * sin(ang)) * sc, (d.x * sin(ang) + d.y * cos(ang)) * sc)
                let f = field(truth)
                let obs = MagneticFeature(total: f.total + 0.5 * rng.normal(), vertical: f.vertical + 0.5 * rng.normal(),
                                          horizontal: f.horizontal + 0.5 * rng.normal())
                let est = loc.step(delta: delta, feature: obs)
                walked += 0.7
                if est.converged && convergedAt == nil { convergedAt = walked }
                if cold && convergedAt == nil { continue }          // 冷启动阶段不计入误差
                errors.append(est.position.distance(to: truth))
                total += 1
                // 通道判对：x 落在真实通道的 ±1.8 m 内（通道间距 3.6 m）
                if abs(est.position.x - truth.x) > 180 && abs(truth.y - topY) > 150 && abs(truth.y - bottomY) > 150 { wrong += 1 }
            }
        }
        errors.sort()
        return Result(errors: errors, wrongAisle: wrong, total: total, convergedAt: convergedAt)
    }

    func testWalkableMapCoversAislesAndBlocksShelves() {
        let w = WalkableMap(crosses: crosses, widthCm: width, heightCm: height)
        XCTAssertTrue(w.isWalkable(Point2(aisleXs[2], 1500)))
        XCTAssertFalse(w.isWalkable(Point2(aisleXs[2] + 180, 1500)))        // 两条通道之间是货架
        XCTAssertFalse(w.isSegmentClear(from: Point2(aisleXs[2], 1500), to: Point2(aisleXs[3], 1500)))
        XCTAssertTrue(w.isSegmentClear(from: Point2(aisleXs[2], 1500), to: Point2(aisleXs[2], 2500)))
        // 纵向通道的轴线方向是 90°（π/2）
        XCTAssertEqual(w.axisAngle(at: Point2(aisleXs[2], 1500)) ?? 0, Double.pi / 2, accuracy: 0.01)
        XCTAssertNil(w.axisAngle(at: Point2(aisleXs[2], topY)))             // 路口没有单一走向
        XCTAssertGreaterThan(w.walkableAreaM2, 100)
    }

    func testKnownStartTracksAcrossAisles() {
        let r = run(cold: false, useWalkable: true, seed: 11)
        XCTAssertGreaterThan(r.total, 100)
        XCTAssertLessThan(r.errors[r.errors.count / 2], 120)
        XCTAssertLessThan(r.errors[Int(Double(r.errors.count) * 0.9)], 250)
        XCTAssertEqual(r.wrongAisle, 0)
    }

    func testColdStartFindsRightAisleAndConverges() {
        let r = run(cold: true, useWalkable: true, seed: 21)
        XCTAssertNotNil(r.convergedAt)
        XCTAssertLessThan(r.convergedAt ?? 999, 60)                         // 60 m 内收敛
        XCTAssertGreaterThan(r.total, 40)
        XCTAssertLessThan(r.errors[r.errors.count / 2], 200)
        XCTAssertLessThanOrEqual(Double(r.wrongAisle) / Double(max(r.total, 1)), 0.1)
    }
}
