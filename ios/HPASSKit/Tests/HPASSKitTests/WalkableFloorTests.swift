import XCTest
@testable import HPASSKit

/// 地面多边形的可走区域（每个多边形只在自己的外包框里栅格化）和跟踪时的贴墙滑。全部是合成数据（cm）。
final class WalkableFloorTests: XCTestCase {

    /// 按外包框栅格化的结果和逐格测全部多边形 / 家具完全一致（多个多边形、斜放的家具、超出地图的多边形）。
    func testFloorRasterisationMatchesPerCellTest() {
        let w = 2000.0, h = 1200.0, cell = 25.0
        var floor: [[Point2]] = []
        for k in 0..<30 {
            let x = Double(k % 6) * 330 + 10, y = Double(k / 6) * 230 + 5
            floor.append([Point2(x, y), Point2(x + 300, y), Point2(x + 300, y + 210), Point2(x, y + 210)])
        }
        floor.append([Point2(100, 100), Point2(1500, 300), Point2(900, 1100)])           // 斜的三角形
        floor.append([Point2(1800, 900), Point2(2600, 900), Point2(2600, 1500), Point2(1800, 1500)])  // 伸出地图
        let obstacles = [ShelfRect(code: "a", x: 500, y: 400, width: 300, height: 80, rotation: 30),
                         ShelfRect(code: "b", x: 1990, y: 1190, width: 100, height: 100, rotation: 0),
                         ShelfRect(code: "c", x: 1200, y: 600, width: 50, height: 400, rotation: -75)]
        let m = WalkableMap(floor: floor, obstacles: obstacles, widthCm: w, heightCm: h, cellCm: cell, marginCm: 15)
        var n = 0
        for j in 0..<m.rows {
            for i in 0..<m.cols {
                let p = Point2((Double(i) + 0.5) * cell, (Double(j) + 0.5) * cell)
                let expect = floor.contains { pointInPolygon(p, $0) }
                    && !obstacles.contains { pointInRotatedRect(p, center: Point2($0.x, $0.y), width: $0.width, height: $0.height,
                                                                rotationDeg: $0.rotation, margin: 15) }
                XCTAssertEqual(m.isWalkable(index: j * m.cols + i), expect, "格 (\(i), \(j))")
                if expect { n += 1 }
            }
        }
        XCTAssertEqual(m.walkableCellCount, n)
        XCTAssertGreaterThan(n, 1000)
    }

    /// 2 m 宽的直走廊，推算方向偏了 12°（一直往墙上顶）：
    /// 不贴墙滑时粒子顶到墙就原地不动，估计卡在走廊前段；贴墙滑时沿墙继续往前走。
    func testWallSlideKeepsMovingAlongWall() {
        let w = 4000.0, h = 400.0
        let floor = [[Point2(0, 100), Point2(w, 100), Point2(w, 300), Point2(0, 300)]]
        let walk = WalkableMap(floor: floor, obstacles: [], widthCm: w, heightCm: h)
        let field = MagneticFieldMap(widthCm: w, heightCm: h, cellCm: 50,
                                     cells: [MagneticFeature?](repeating: nil, count: 80 * 8),
                                     sigmas: [MagneticFeature?](repeating: nil, count: 80 * 8))
        func run(slide: Bool) -> Point2 {
            var c = MagneticConfig()
            c.initialHeadingBiasSigmaDeg = 0
            c.headingBiasWalkDegPerM = 0
            c.initialScaleSigma = 0
            c.scaleWalkPerM = 0
            c.wallSlide = slide
            let loc = MagneticLocalizer(field: field, walkable: walk, config: c, seed: 5)
            loc.reset(start: Point2(200, 200), spreadCm: 20)
            let a = 12 * Double.pi / 180
            var est = loc.estimate()
            for _ in 0..<150 { est = loc.step(delta: Point2(20 * cos(a), 20 * sin(a)), feature: nil) }   // 30 m
            return est.position
        }
        XCTAssertFalse(MagneticConfig().wallSlide)                 // 默认是原有行为
        XCTAssertFalse(MagneticConfig.tracking(odometry: .pdr).wallSlide)      // 产品跟踪档也不打开（只评估时 --wall-slide）
        let stuck = run(slide: false), slid = run(slide: true)
        XCTAssertLessThan(stuck.x, slid.x - 600, "不滑 \(stuck.x)，滑 \(slid.x)")
        XCTAssertGreaterThan(slid.x, 2600)                          // 30 m × cos 12° ≈ 29 m 的 x 分量，起点 2 m
        XCTAssertTrue(walk.isWalkable(slid))
    }
}
