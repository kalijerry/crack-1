import XCTest
@testable import HPASSKit

/// 路径规划 / 导航的单元测试。全部使用合成门店数据。
///
/// 合成门店（屏幕坐标系，+x 右、+y 下，单位 cm）：
///   横向通道 H0/H1/H2：y = 100 / 500 / 900，x 从 100 到 900
///   纵向通道 V0/V1/V2：x = 100 / 500 / 900，y 从 100 到 900
///   → 3×3 网格，9 个交点，12 条无向边，格距 400
///   货架（均为 360×100，长边朝向相邻通道）：
///     S0   中心 (300, 260) rotation 0    → 朝向 ±y（上下）
///     S90  中心 (260, 700) rotation 90   → 朝向 ±x（左右）
///     S270 中心 (740, 300) rotation 270  → 朝向 ±x（左右）
final class RoutingTests: XCTestCase {

    // MARK: - 合成数据

    private func gridCrosses() -> [CrossSegment] {
        var cs: [CrossSegment] = []
        let ys: [Double] = [100, 500, 900]
        for (i, y) in ys.enumerated() {
            cs.append(CrossSegment(code: "H\(i)", a: Point2(100, y), b: Point2(900, y), lineWidth: 200))
        }
        let xs: [Double] = [100, 500, 900]
        for (i, x) in xs.enumerated() {
            cs.append(CrossSegment(code: "V\(i)", a: Point2(x, 100), b: Point2(x, 900), lineWidth: 200))
        }
        return cs
    }

    private func gridShelves() -> [ShelfRect] {
        [ShelfRect(code: "S0", x: 300, y: 260, width: 360, height: 100, rotation: 0),
         ShelfRect(code: "S90", x: 260, y: 700, width: 360, height: 100, rotation: 90),
         ShelfRect(code: "S270", x: 740, y: 300, width: 360, height: 100, rotation: 270)]
    }

    private func gridPlanner(_ config: RoutePlannerConfig = .init()) -> RoutePlanner {
        RoutePlanner(shelves: gridShelves(), crosses: gridCrosses(), config: config)
    }

    // MARK: - 断言工具

    private func assertPoint(_ a: Point2, _ b: Point2, _ tol: Double = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: tol, "x 不符: \(a) vs \(b)", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: tol, "y 不符: \(a) vs \(b)", file: file, line: line)
    }

    // MARK: - 1. 建图

    func testGridIntersectionsBecomeNodes() {
        let g = RouteGraph.build(crosses: gridCrosses(), tolerance: 1.0)
        // 9 个交点全部成为节点；每条通道被切成 2 段 → 6 条通道 × 2 = 12 条无向边
        XCTAssertEqual(g.nodes.count, 9)
        XCTAssertEqual(g.edgeCount, 12)
        for x in [100.0, 500.0, 900.0] {
            for y in [100.0, 500.0, 900.0] {
                XCTAssertNotNil(g.findNode(Point2(x, y)), "交点 (\(x),\(y)) 应该是节点")
            }
        }
    }

    func testParallelNonCollinearAislesHaveNoEdge() {
        let crosses = [CrossSegment(code: "a", a: Point2(0, 0), b: Point2(100, 0), lineWidth: 100),
                       CrossSegment(code: "b", a: Point2(0, 50), b: Point2(100, 50), lineWidth: 100)]
        let g = RouteGraph.build(crosses: crosses, tolerance: 1.0)
        XCTAssertEqual(g.nodes.count, 4)
        XCTAssertEqual(g.edgeCount, 2)          // 只有各自那一条，没有虚假连接
        guard let n0 = g.findNode(Point2(0, 0)), let n2 = g.findNode(Point2(0, 50)) else {
            return XCTFail("节点缺失")
        }
        XCTAssertEqual(g.dijkstra(from: n0)[n2], Double.infinity)   // 两条平行通道不连通
    }

    func testCollinearOverlappingAislesConnect() {
        let crosses = [CrossSegment(code: "a", a: Point2(0, 0), b: Point2(100, 0), lineWidth: 100),
                       CrossSegment(code: "b", a: Point2(50, 0), b: Point2(200, 0), lineWidth: 100)]
        let g = RouteGraph.build(crosses: crosses, tolerance: 1.0)
        // 节点：0 / 50 / 100 / 200；边：0-50、50-100、100-200（重复边已去重）
        XCTAssertEqual(g.nodes.count, 4)
        XCTAssertEqual(g.edgeCount, 3)
        guard let n0 = g.findNode(Point2(0, 0)), let nEnd = g.findNode(Point2(200, 0)) else {
            return XCTFail("节点缺失")
        }
        XCTAssertEqual(g.dijkstra(from: n0)[nEnd], 200, accuracy: 1e-6)
    }

    func testCollinearDisjointAislesDoNotConnect() {
        let crosses = [CrossSegment(code: "a", a: Point2(0, 0), b: Point2(100, 0), lineWidth: 100),
                       CrossSegment(code: "b", a: Point2(150, 0), b: Point2(250, 0), lineWidth: 100)]
        let g = RouteGraph.build(crosses: crosses, tolerance: 1.0)
        XCTAssertEqual(g.nodes.count, 4)
        XCTAssertEqual(g.edgeCount, 2)
        guard let n0 = g.findNode(Point2(0, 0)), let n2 = g.findNode(Point2(150, 0)) else {
            return XCTFail("节点缺失")
        }
        XCTAssertEqual(g.dijkstra(from: n0)[n2], Double.infinity)
    }

    // MARK: - 2. 货架几何与目标吸附

    func testShelfVerticesRotation0() {
        let p = gridPlanner()
        let v = p.shelfVertices(ShelfRect(code: "t", x: 100, y: 100, width: 200, height: 100, rotation: 0))
        XCTAssertEqual(v.count, 4)
        assertPoint(v[0], Point2(0, 50))
        assertPoint(v[1], Point2(200, 50))
        assertPoint(v[2], Point2(200, 150))
        assertPoint(v[3], Point2(0, 150))
    }

    func testShelfVerticesRotation90() {
        let p = gridPlanner()
        let v = p.shelfVertices(ShelfRect(code: "t", x: 100, y: 100, width: 200, height: 100, rotation: 90))
        XCTAssertEqual(v.count, 4)
        // 旋转 90° 后 width 沿 +y，height 沿 -x
        assertPoint(v[0], Point2(150, 0))
        assertPoint(v[1], Point2(150, 200))
        assertPoint(v[2], Point2(50, 200))
        assertPoint(v[3], Point2(50, 0))
    }

    /// rotation 0：最近的通道是左侧纵向通道（距离 40），但货架长边朝上下，
    /// 正确答案在上方横向通道 y=100。
    func testSnapToAisleRotation0PicksFacingSideNotNearest() {
        let p = gridPlanner()
        let product = Point2(140, 260)          // 位于 S0 内（x 120..480，y 210..310）
        let snapped = p.snapToAisle(product)
        assertPoint(snapped, Point2(140, 100))
        XCTAssertGreaterThan(snapped.distance(to: Point2(100, 260)), 1.0, "不能吸附到最近但朝向错误的通道")
    }

    /// rotation 90：最近的通道是上方横向通道 y=500（距离 40），
    /// 但货架长边朝左右，正确答案在左侧纵向通道 x=100。
    func testSnapToAisleRotation90PicksFacingSideNotNearest() {
        let p = gridPlanner()
        let product = Point2(260, 540)          // 位于 S90 内（x 210..310，y 520..880）
        let snapped = p.snapToAisle(product)
        assertPoint(snapped, Point2(100, 540))
        XCTAssertGreaterThan(snapped.distance(to: Point2(260, 500)), 1.0)
    }

    /// rotation 270：最近的通道是上方横向通道 y=100（距离 40），
    /// 但货架长边朝左右，正确答案在右侧纵向通道 x=900。
    func testSnapToAisleRotation270PicksFacingSideNotNearest() {
        let p = gridPlanner()
        let product = Point2(740, 140)          // 位于 S270 内（x 690..790，y 120..480）
        let snapped = p.snapToAisle(product)
        assertPoint(snapped, Point2(900, 140))
        XCTAssertGreaterThan(snapped.distance(to: Point2(740, 100)), 1.0)
    }

    func testSnapToAisleFallsBackToNearestWhenNotOnShelf() {
        let p = gridPlanner()
        assertPoint(p.snapToAisle(Point2(300, 30)), Point2(300, 100))
    }

    func testSnapOnShelfIsUsedByPlan() {
        let p = gridPlanner()
        guard let r = p.plan(from: Point2(100, 100), targets: [Point2(140, 260)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(r.length, 40, accuracy: 1e-6)
        XCTAssertEqual(r.targetPoints.count, 1)
        assertPoint(r.targetPoints[0], Point2(140, 100))
    }

    // MARK: - 3. A* 搜索

    func testShortestPathExactLength() {
        let p = gridPlanner()
        guard let r = p.plan(from: Point2(100, 500), targets: [Point2(900, 500)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(r.length, 800, accuracy: 1e-6)   // 沿 H1 直走 800 cm
        XCTAssertEqual(r.points.count, 2)               // 中间的 (500,500) 共线被化简掉
        XCTAssertTrue(r.turns.isEmpty)
        XCTAssertEqual(r.unreachableTargets.count, 0)
    }

    /// 等长的两种走法（L 形 1 个转弯 vs 阶梯 2 个转弯）中，转弯惩罚选转弯少的。
    func testEqualLengthRoutesPreferFewerTurns() {
        let p = gridPlanner()
        guard let r = p.plan(from: Point2(100, 100), targets: [Point2(900, 900)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(r.length, 1600, accuracy: 1e-6)  // 800 + 800，网格下任何单调路径都是 1600
        XCTAssertEqual(r.turns.count, 1)                // L 形，只拐一次
        XCTAssertEqual(r.points.count, 3)
    }

    func testDeterministicOutputForEqualCostRoutes() {
        let p = gridPlanner()
        let a = p.plan(from: Point2(100, 100), targets: [Point2(900, 900)])
        let b = p.plan(from: Point2(100, 100), targets: [Point2(900, 900)])
        XCTAssertEqual(a?.points, b?.points)
    }

    /// 转弯惩罚确实会改变选择：
    /// 路线 A（1 个 62° 转弯）长 2·√(500²+300²) = 1166.19 cm
    /// 路线 Z（3 个 60° 转弯）长 4·(250/cos30°) = 1154.70 cm
    /// 惩罚 200 cm/次 → A 代价 1366.19 < Z 代价 1754.70，选 A；惩罚 0 → 选更短的 Z。
    func testTurnPenaltyChangesChosenRoute() {
        let h = 250.0 / 3.0.squareRoot()                // 144.33756729740646
        let crosses = [
            CrossSegment(code: "A1", a: Point2(0, 0), b: Point2(500, -300), lineWidth: 100),
            CrossSegment(code: "A2", a: Point2(500, -300), b: Point2(1000, 0), lineWidth: 100),
            CrossSegment(code: "Z1", a: Point2(0, 0), b: Point2(250, h), lineWidth: 100),
            CrossSegment(code: "Z2", a: Point2(250, h), b: Point2(500, 0), lineWidth: 100),
            CrossSegment(code: "Z3", a: Point2(500, 0), b: Point2(750, h), lineWidth: 100),
            CrossSegment(code: "Z4", a: Point2(750, h), b: Point2(1000, 0), lineWidth: 100)
        ]
        let lenA = 2.0 * (500.0 * 500.0 + 300.0 * 300.0).squareRoot()   // 1166.1903789690602
        let lenZ = 4.0 * (250.0 * 250.0 + h * h).squareRoot()           // 1154.7005383792515

        let g = RouteGraph.build(crosses: crosses, tolerance: 1.0)
        XCTAssertEqual(g.nodes.count, 6)
        XCTAssertEqual(g.edgeCount, 6)

        var withPenalty = RoutePlannerConfig()
        withPenalty.turnPenaltyCm = 200
        guard let rA = RoutePlanner(shelves: [], crosses: crosses, config: withPenalty)
                .plan(from: Point2(0, 0), targets: [Point2(1000, 0)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(rA.length, lenA, accuracy: 1e-6)
        XCTAssertEqual(rA.turns.count, 1)
        XCTAssertEqual(rA.points.count, 3)

        var noPenalty = RoutePlannerConfig()
        noPenalty.turnPenaltyCm = 0
        guard let rZ = RoutePlanner(shelves: [], crosses: crosses, config: noPenalty)
                .plan(from: Point2(0, 0), targets: [Point2(1000, 0)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(rZ.length, lenZ, accuracy: 1e-6)
        XCTAssertEqual(rZ.turns.count, 3)
        XCTAssertEqual(rZ.points.count, 5)
    }

    // MARK: - 4. 多目标

    func testNearestNeighbourOrdering() {
        let p = gridPlanner()
        // 输入顺序刻意打乱：(900,100) 最远，(500,100) 最近
        guard let r = p.plan(from: Point2(100, 100),
                             targets: [Point2(900, 100), Point2(500, 100), Point2(100, 900)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(r.targetPoints.count, 3)
        assertPoint(r.targetPoints[0], Point2(500, 100))
        assertPoint(r.targetPoints[1], Point2(900, 100))
        assertPoint(r.targetPoints[2], Point2(100, 900))
        // 400 + 400 + 1600
        XCTAssertEqual(r.length, 2400, accuracy: 1e-6)
        XCTAssertTrue(r.unreachableTargets.isEmpty)
    }

    func testUnreachableTargetReportedAndOthersRouted() {
        var crosses = gridCrosses()
        crosses.append(CrossSegment(code: "ISO", a: Point2(2000, 2000), b: Point2(2000, 2400), lineWidth: 200))
        let p = RoutePlanner(shelves: gridShelves(), crosses: crosses)
        guard let r = p.plan(from: Point2(100, 100),
                             targets: [Point2(900, 100), Point2(2000, 2200)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(r.unreachableTargets.count, 1)
        assertPoint(r.unreachableTargets[0], Point2(2000, 2200))
        XCTAssertEqual(r.targetPoints.count, 1)
        assertPoint(r.targetPoints[0], Point2(900, 100))
        XCTAssertEqual(r.length, 800, accuracy: 1e-6)
    }

    func testMaxTargetsCap() {
        var config = RoutePlannerConfig()
        config.maxTargets = 2
        let p = gridPlanner(config)
        guard let r = p.plan(from: Point2(100, 100),
                             targets: [Point2(500, 100), Point2(900, 100), Point2(100, 900)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(r.targetPoints.count, 2)
        XCTAssertEqual(r.length, 800, accuracy: 1e-6)
    }

    func testDuplicatedTargetsCollapse() {
        let p = gridPlanner()
        guard let r = p.plan(from: Point2(100, 100),
                             targets: [Point2(500, 100), Point2(500, 100)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(r.targetPoints.count, 1)
        XCTAssertEqual(r.length, 400, accuracy: 1e-6)
    }

    // MARK: - 5. 化简

    func testCollinearSimplificationKeepsTargets() {
        let p = gridPlanner()
        guard let r = p.plan(from: Point2(100, 100),
                             targets: [Point2(500, 100), Point2(900, 100)]) else {
            return XCTFail("应该能规划")
        }
        // (500,100) 与前后共线，但它是目标 → 必须保留
        XCTAssertEqual(r.points.count, 3)
        assertPoint(r.points[1], Point2(500, 100))
        XCTAssertTrue(r.turns.isEmpty)
        XCTAssertEqual(r.length, 800, accuracy: 1e-6)
    }

    // MARK: - 6. 稳定性（迟滞）

    func testUpdateSmallDeviationTrimsAndKeepsRoute() {
        let p = gridPlanner()
        guard let first = p.plan(from: Point2(100, 100), targets: [Point2(900, 100)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(first.length, 800, accuracy: 1e-6)

        guard let next = p.update(location: Point2(300, 30),
                                  targets: [Point2(900, 100)],
                                  lastRoute: first) else {
            return XCTFail("应该返回路线")
        }
        // 偏离 70 cm < 500 cm：裁掉已走的 200 cm，保持同一条折线
        XCTAssertEqual(next.points.count, 2)
        assertPoint(next.points[0], Point2(300, 100))
        assertPoint(next.points[1], Point2(900, 100))
        XCTAssertEqual(next.length, 600, accuracy: 1e-6)
    }

    func testUpdateOffRouteReplans() {
        let p = gridPlanner()
        guard let first = p.plan(from: Point2(100, 100), targets: [Point2(900, 100)]) else {
            return XCTFail("应该能规划")
        }
        // 横向偏离 1900 cm > 500 cm → 重规划，起点吸附到 (100,900)
        guard let next = p.update(location: Point2(100, 2000),
                                  targets: [Point2(900, 100)],
                                  lastRoute: first) else {
            return XCTFail("应该返回路线")
        }
        assertPoint(next.points[0], Point2(100, 900))
        assertPoint(next.points[next.points.count - 1], Point2(900, 100))
        XCTAssertEqual(next.length, 1600, accuracy: 1e-6)
        XCTAssertEqual(next.turns.count, 1)
    }

    func testUpdateTargetsChangedReplans() {
        let p = gridPlanner()
        guard let first = p.plan(from: Point2(100, 100), targets: [Point2(900, 100)]) else {
            return XCTFail("应该能规划")
        }
        guard let next = p.update(location: Point2(300, 100),
                                  targets: [Point2(100, 900)],
                                  lastRoute: first) else {
            return XCTFail("应该返回路线")
        }
        XCTAssertEqual(next.targetPoints.count, 1)
        assertPoint(next.targetPoints[0], Point2(100, 900))
        XCTAssertEqual(next.length, 1000, accuracy: 1e-6)   // 200 + 800
    }

    func testUpdateBackwardMoveSmallKeepsBigReplans() {
        let p = gridPlanner()
        guard let first = p.plan(from: Point2(100, 100), targets: [Point2(900, 100)]),
              let walked = p.update(location: Point2(700, 100),
                                    targets: [Point2(900, 100)],
                                    lastRoute: first) else {
            return XCTFail("应该返回路线")
        }
        XCTAssertEqual(walked.length, 200, accuracy: 1e-6)
        assertPoint(walked.points[0], Point2(700, 100))

        // 小幅后退 100 cm（< 500 cm）：沿用旧路线，不重算
        guard let small = p.update(location: Point2(600, 100),
                                  targets: [Point2(900, 100)],
                                  lastRoute: walked) else {
            return XCTFail("应该返回路线")
        }
        XCTAssertEqual(small.length, 200, accuracy: 1e-6)
        assertPoint(small.points[0], Point2(700, 100))

        // 大幅后退 600 cm（> offRouteDistanceCm = 500）：当作脱线，重新规划
        guard let big = p.update(location: Point2(100, 100),
                                 targets: [Point2(900, 100)],
                                 lastRoute: walked) else {
            return XCTFail("应该返回路线")
        }
        XCTAssertEqual(big.length, 800, accuracy: 1e-6)
        assertPoint(big.points[0], Point2(100, 100))
    }

    // MARK: - 7. 转向分类与播报

    /// 向右（屏幕上 +x）走后转向下（+y）= 右转，带符号转角为 +90°。
    func testTurnClassificationRight() {
        let crosses = [CrossSegment(code: "a", a: Point2(0, 0), b: Point2(400, 0), lineWidth: 100),
                       CrossSegment(code: "b", a: Point2(400, 0), b: Point2(400, 400), lineWidth: 100)]
        let p = RoutePlanner(shelves: [], crosses: crosses)
        guard let r = p.plan(from: Point2(0, 0), targets: [Point2(400, 400)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(r.turns.count, 1)
        XCTAssertEqual(r.turns[0].direction, .right)
        XCTAssertEqual(r.turns[0].angleDeg, 90, accuracy: 1e-6)
        XCTAssertEqual(r.turns[0].nodeIndex, 1)
        XCTAssertEqual(r.turns[0].chainage, 400, accuracy: 1e-6)
    }

    /// 向右走后转向上（-y）= 左转，带符号转角为 -90°。
    func testTurnClassificationLeft() {
        let crosses = [CrossSegment(code: "a", a: Point2(0, 0), b: Point2(400, 0), lineWidth: 100),
                       CrossSegment(code: "b", a: Point2(400, 0), b: Point2(400, -400), lineWidth: 100)]
        let p = RoutePlanner(shelves: [], crosses: crosses)
        guard let r = p.plan(from: Point2(0, 0), targets: [Point2(400, -400)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(r.turns.count, 1)
        XCTAssertEqual(r.turns[0].direction, .left)
        XCTAssertEqual(r.turns[0].angleDeg, -90, accuracy: 1e-6)
    }

    /// 同一条通道上先去 (500,0) 再回头去 (100,0)：在 (500,0) 掉头。
    func testTurnClassificationUturn() {
        let crosses = [CrossSegment(code: "a", a: Point2(0, 0), b: Point2(900, 0), lineWidth: 100)]
        let p = RoutePlanner(shelves: [], crosses: crosses)
        guard let r = p.plan(from: Point2(300, 0), targets: [Point2(500, 0), Point2(100, 0)]) else {
            return XCTFail("应该能规划")
        }
        XCTAssertEqual(r.points.count, 3)
        XCTAssertEqual(r.length, 600, accuracy: 1e-6)   // 200 + 400
        XCTAssertEqual(r.turns.count, 1)
        XCTAssertEqual(r.turns[0].direction, .uturn)
        XCTAssertEqual(abs(r.turns[0].angleDeg), 180, accuracy: 1e-6)
    }

    private func lShapedPlannerAndRoute() -> (RoutePlanner, Route)? {
        let crosses = [CrossSegment(code: "a", a: Point2(0, 0), b: Point2(400, 0), lineWidth: 100),
                       CrossSegment(code: "b", a: Point2(400, 0), b: Point2(400, 400), lineWidth: 100)]
        let p = RoutePlanner(shelves: [], crosses: crosses)
        guard let r = p.plan(from: Point2(0, 0), targets: [Point2(400, 400)]) else { return nil }
        return (p, r)
    }

    func testHintOutsideWindowIsStraight() {
        guard let (p, r) = lShapedPlannerAndRoute() else { return XCTFail("应该能规划") }
        let h = p.hint(for: Point2(100, 0), on: r)
        XCTAssertEqual(h.alongDistance, 100, accuracy: 1e-6)
        XCTAssertEqual(h.distanceToRoute, 0, accuracy: 1e-6)
        XCTAssertEqual(h.remainingDistance, 700, accuracy: 1e-6)
        XCTAssertEqual(h.distanceToNextTurn ?? -1, 300, accuracy: 1e-6)   // 300 > 200 的播报窗口
        XCTAssertEqual(h.direction, .straight)
        XCTAssertEqual(h.distanceToNextTarget ?? -1, 700, accuracy: 1e-6)
        XCTAssertFalse(h.isOffRoute)
    }

    func testHintInsideWindowAnnouncesTurn() {
        guard let (p, r) = lShapedPlannerAndRoute() else { return XCTFail("应该能规划") }
        let h = p.hint(for: Point2(250, 30), on: r)
        XCTAssertEqual(h.alongDistance, 250, accuracy: 1e-6)
        XCTAssertEqual(h.distanceToRoute, 30, accuracy: 1e-6)
        XCTAssertEqual(h.distanceToNextTurn ?? -1, 150, accuracy: 1e-6)   // 150 ≤ 200
        XCTAssertEqual(h.direction, .right)
        XCTAssertFalse(h.isOffRoute)
    }

    func testHintTieBreaksToLowerSegmentIndex() {
        guard let (p, r) = lShapedPlannerAndRoute() else { return XCTFail("应该能规划") }
        // (450,-50) 到两段的距离完全相同（都落在拐点上）→ 取下标更小的那段
        let h = p.hint(for: Point2(450, -50), on: r)
        XCTAssertEqual(h.alongDistance, 400, accuracy: 1e-6)
        XCTAssertNil(h.distanceToNextTurn)        // 拐点已经在身后
        XCTAssertEqual(h.direction, .straight)
    }

    func testHintOffRoute() {
        guard let (p, r) = lShapedPlannerAndRoute() else { return XCTFail("应该能规划") }
        let h = p.hint(for: Point2(-1000, 0), on: r)
        XCTAssertEqual(h.distanceToRoute, 1000, accuracy: 1e-6)
        XCTAssertTrue(h.isOffRoute)
        XCTAssertEqual(h.alongDistance, 0, accuracy: 1e-6)
        XCTAssertEqual(h.remainingDistance, 800, accuracy: 1e-6)
    }

    func testRouteSnapper() {
        guard let (_, r) = lShapedPlannerAndRoute() else { return XCTFail("应该能规划") }
        guard let snapped = RouteSnapper.snap(Point2(250, 30), to: r) else {
            return XCTFail("应该能吸附")
        }
        assertPoint(snapped, Point2(250, 0))
        XCTAssertNil(RouteSnapper.snap(Point2(-1000, 0), to: r, maxDistance: 500))
        XCTAssertNil(RouteSnapper.snap(Point2(0, 0), to: Route()))
    }

    // MARK: - 8. 会话

    func testNavigationSessionFlow() {
        let session = NavigationSession(planner: gridPlanner())
        XCTAssertFalse(session.isActive)

        guard let h0 = session.start(targets: [Point2(900, 100)], from: Point2(100, 100)) else {
            return XCTFail("应该能开始导航")
        }
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(h0.remainingDistance, 800, accuracy: 1e-6)
        XCTAssertEqual(h0.direction, .straight)
        XCTAssertEqual(session.route?.length ?? -1, 800, accuracy: 1e-6)

        guard let h1 = session.onLocation(Point2(300, 100)) else { return XCTFail("应该有播报") }
        XCTAssertEqual(h1.remainingDistance, 600, accuracy: 1e-6)
        XCTAssertEqual(session.route?.length ?? -1, 600, accuracy: 1e-6)

        guard let h2 = session.onLocation(Point2(500, 100)) else { return XCTFail("应该有播报") }
        XCTAssertEqual(h2.remainingDistance, 400, accuracy: 1e-6)

        guard let h3 = session.onLocation(Point2(900, 100)) else { return XCTFail("应该有播报") }
        XCTAssertEqual(h3.remainingDistance, 0, accuracy: 1e-6)
        XCTAssertEqual(session.route?.nodes.count ?? -1, 1)

        session.stop()
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.route)
        XCTAssertNil(session.lastLocation)
        XCTAssertNil(session.onLocation(Point2(500, 100)))
    }

    func testNavigationSessionStartWithoutLocation() {
        let session = NavigationSession(planner: gridPlanner())
        XCTAssertNil(session.start(targets: [Point2(900, 100)], from: nil))
        XCTAssertTrue(session.isActive)          // 目标已记下，等第一个定位
        XCTAssertNil(session.route)
        XCTAssertNotNil(session.onLocation(Point2(100, 100)))
        XCTAssertEqual(session.route?.length ?? -1, 800, accuracy: 1e-6)
    }

    func testPreviewDoesNotMutateSession() {
        let session = NavigationSession(planner: gridPlanner())
        let r = session.preview(targets: [Point2(900, 100)], from: Point2(100, 100))
        XCTAssertEqual(r?.length ?? -1, 800, accuracy: 1e-6)
        XCTAssertNil(session.route)
        XCTAssertFalse(session.isActive)
    }

    // MARK: - 9. 健壮性

    func testEmptyMap() {
        let p = RoutePlanner(shelves: [], crosses: [])
        XCTAssertNil(p.plan(from: Point2(0, 0), targets: [Point2(100, 100)]))
        assertPoint(p.snapToAisle(Point2(5, 5)), Point2(5, 5))
        XCTAssertNil(p.update(location: Point2(0, 0), targets: [], lastRoute: nil))
        let h = p.hint(for: Point2(0, 0), on: Route())
        XCTAssertEqual(h.direction, .straight)
        XCTAssertEqual(h.distanceToRoute, 0, accuracy: 1e-6)
        XCTAssertFalse(h.isOffRoute)
    }

    func testDegenerateSinglePointAisle() {
        let p = RoutePlanner(shelves: [],
                             crosses: [CrossSegment(code: "d", a: Point2(0, 0), b: Point2(0, 0), lineWidth: 100)])
        guard let r = p.plan(from: Point2(0, 0), targets: [Point2(100, 100)]) else {
            return XCTFail("不应返回 nil")
        }
        XCTAssertEqual(r.nodes.count, 1)
        XCTAssertEqual(r.length, 0, accuracy: 1e-6)
        XCTAssertTrue(r.turns.isEmpty)
    }

    func testStartEqualsTarget() {
        let p = gridPlanner()
        guard let r = p.plan(from: Point2(100, 100), targets: [Point2(100, 100)]) else {
            return XCTFail("不应返回 nil")
        }
        XCTAssertEqual(r.nodes.count, 1)
        XCTAssertEqual(r.length, 0, accuracy: 1e-6)
        XCTAssertEqual(r.targetPoints.count, 1)
        let h = p.hint(for: Point2(100, 100), on: r)
        XCTAssertEqual(h.remainingDistance, 0, accuracy: 1e-6)
        XCTAssertEqual(h.direction, .straight)
    }

    func testNoTargetsGivesSingleNodeRoute() {
        let p = gridPlanner()
        guard let r = p.plan(from: Point2(300, 100), targets: []) else {
            return XCTFail("不应返回 nil")
        }
        XCTAssertEqual(r.nodes.count, 1)
        assertPoint(r.points[0], Point2(300, 100))
        XCTAssertEqual(r.length, 0, accuracy: 1e-6)
    }

    func testNonFiniteInputsDoNotCrash() {
        let p = gridPlanner()
        XCTAssertNil(p.plan(from: Point2(Double.nan, 0), targets: [Point2(900, 100)]))
        guard let r = p.plan(from: Point2(100, 100),
                             targets: [Point2(Double.infinity, 0), Point2(900, 100)]) else {
            return XCTFail("应该忽略非法目标后继续")
        }
        XCTAssertEqual(r.targetPoints.count, 1)
        XCTAssertEqual(r.length, 800, accuracy: 1e-6)
    }

    func testStoreMapInitializer() {
        let map = StoreMap(width: 1000, height: 1000, shelves: gridShelves(), crosses: gridCrosses())
        let p = RoutePlanner(map: map)
        XCTAssertEqual(p.graphNodeCount, 9)
        XCTAssertEqual(p.graphEdgeCount, 12)
        XCTAssertEqual(p.plan(from: Point2(100, 500), targets: [Point2(900, 500)])?.length ?? -1,
                       800, accuracy: 1e-6)
    }
}
