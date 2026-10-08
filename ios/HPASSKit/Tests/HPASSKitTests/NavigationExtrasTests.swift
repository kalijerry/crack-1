import XCTest
@testable import HPASSKit

/// 栅格兜底、连续脱线确认、中文播报、货架朝通道站位点。全部使用合成数据（单位 cm，+x 右、+y 下）。
final class NavigationExtrasTests: XCTestCase {

    private func hCross(_ code: String, _ x0: Double, _ x1: Double, y: Double) -> CrossSegment {
        CrossSegment(code: code, a: Point2(x0, y), b: Point2(x1, y), lineWidth: 200)
    }

    // MARK: - 栅格兜底

    /// 没有通道（房间）：只有可走栅格，也能直接规划。
    func testGridFallbackWithoutCorridors() {
        let walk = WalkableMap(crosses: [hCross("a", 100, 900, y: 100)], widthCm: 1000, heightCm: 400)
        let p = RoutePlanner(shelves: [], crosses: [], walkable: walk)
        guard let r = p.plan(from: Point2(100, 100), targets: [Point2(900, 100)]) else {
            return XCTFail("应该走栅格兜底")
        }
        XCTAssertEqual(r.length, 800, accuracy: 60)
        XCTAssertEqual(r.targetPoints.count, 1)
        for n in r.nodes { XCTAssertTrue(walk.isWalkable(n.point)) }
    }

    /// 通道图不连通（中间缺一段），可走栅格是连通的：改走栅格。
    func testGridFallbackWhenGraphDisconnected() {
        let a = hCross("a", 100, 400, y: 100), b = hCross("b", 700, 900, y: 100), c = hCross("c", 400, 700, y: 100)
        let walk = WalkableMap(crosses: [a, b, c], widthCm: 1000, heightCm: 400)
        let p = RoutePlanner(shelves: [], crosses: [a, b], walkable: walk)
        guard let r = p.plan(from: Point2(100, 100), targets: [Point2(900, 100)]) else {
            return XCTFail("应该走栅格兜底")
        }
        XCTAssertEqual(r.targetPoints.count, 1)
        XCTAssertEqual(r.length, 800, accuracy: 60)
        // 没有栅格时仍然是不可达
        let q = RoutePlanner(shelves: [], crosses: [a, b])
        XCTAssertTrue(q.plan(from: Point2(100, 100), targets: [Point2(900, 100)])?.targetPoints.isEmpty ?? true)
    }

    func testGridRouterUnreachable() {
        let a = hCross("a", 100, 300, y: 100), b = hCross("b", 700, 900, y: 100)
        let walk = WalkableMap(crosses: [a, b], widthCm: 1000, heightCm: 400)
        XCTAssertNil(GridRouter(walkable: walk).path(from: Point2(100, 100), to: Point2(900, 100)))
    }

    // MARK: - 连续脱线确认

    private func gridPlanner(confirm: Int) -> RoutePlanner {
        var cfg = RoutePlannerConfig()
        cfg.offRouteDistanceCm = 300
        cfg.offRouteConfirmUpdates = confirm
        let ys: [Double] = [100, 500]
        var cs: [CrossSegment] = ys.enumerated().map { hCross("H\($0.offset)", 100, 900, y: $0.element) }
        cs.append(CrossSegment(code: "V", a: Point2(500, 100), b: Point2(500, 500), lineWidth: 200))
        return RoutePlanner(shelves: [], crosses: cs, config: cfg)
    }

    func testOffRouteNeedsConsecutiveUpdates() {
        let s = NavigationSession(planner: gridPlanner(confirm: 3))
        _ = s.start(targets: [Point2(900, 100)], from: Point2(100, 100))
        // 偏到下面那条通道上（离路线 400 cm > 300）
        let off = Point2(500, 500)
        let h1 = s.onLocation(off)
        XCTAssertEqual(h1?.isOffRoute, true)
        XCTAssertEqual(s.offRouteCount, 1)
        XCTAssertEqual(s.route?.nodes.first?.point.y ?? -1, 100, accuracy: 1e-6)   // 还是旧路线
        _ = s.onLocation(off)
        XCTAssertEqual(s.route?.nodes.first?.point.y ?? -1, 100, accuracy: 1e-6)
        // 中间回到路线上：计数清零
        _ = s.onLocation(Point2(300, 100))
        XCTAssertEqual(s.offRouteCount, 0)
        _ = s.onLocation(off)
        _ = s.onLocation(off)
        let h = s.onLocation(off)   // 第 3 次连续脱线 → 重新规划
        XCTAssertEqual(s.offRouteCount, 0)
        XCTAssertEqual(s.route?.nodes.first?.point.y ?? -1, 500, accuracy: 1e-6)
        XCTAssertEqual(h?.isOffRoute, false)
        XCTAssertEqual(s.route?.length ?? -1, 800, accuracy: 1e-6)
    }

    // MARK: - 中文播报

    /// L 形路线：向右走 400 再向下走 400（右转）。
    private func lRoute() -> (RoutePlanner, Route) {
        let cs = [CrossSegment(code: "a", a: Point2(0, 0), b: Point2(400, 0), lineWidth: 100),
                  CrossSegment(code: "b", a: Point2(400, 0), b: Point2(400, 400), lineWidth: 100)]
        let p = RoutePlanner(shelves: [], crosses: cs)
        return (p, p.plan(from: Point2(0, 0), targets: [Point2(400, 400)])!)
    }

    func testInstructionTurnAndArrival() {
        let (p, r) = lRoute()
        let far = p.hint(for: Point2(0, 0), on: r)
        XCTAssertEqual(NavInstruction.text(far), "前方 4 m 右转进入通道，还有 8 m")
        let near = p.hint(for: Point2(300, 0), on: r)
        XCTAssertEqual(NavInstruction.text(near), "前方 1 m 右转，还有 5 m")
        let shelf = NavInstruction.Shelf(name: "082-20", center: Point2(330, 400))
        let end = p.hint(for: Point2(400, 380), on: r)
        XCTAssertEqual(NavInstruction.text(end, shelf: shelf), "到了，货架 082-20在右手边")
        let left = NavInstruction.Shelf(name: "082-20", center: Point2(470, 400))
        XCTAssertEqual(NavInstruction.text(end, shelf: left), "到了，货架 082-20在左手边")
        let leg2 = p.hint(for: Point2(400, 100), on: r)
        XCTAssertEqual(NavInstruction.text(leg2, shelf: shelf), "目标在右手边货架 082-20，还有 3 m")
    }

    func testShelfSideStraightAhead() {
        let (_, r) = lRoute()
        XCTAssertNil(NavInstruction.shelfSide(route: r, shelfCenter: Point2(400, 500)))
        XCTAssertEqual(NavInstruction.shelfSide(route: r, shelfCenter: Point2(300, 400)), .right)
        XCTAssertEqual(NavInstruction.shelfSide(route: r, shelfCenter: Point2(500, 400)), .left)
    }

    func testOffRouteInstruction() {
        let (p, r) = lRoute()
        var h = p.hint(for: Point2(0, 0), on: r)
        h.isOffRoute = true
        XCTAssertEqual(NavInstruction.text(h), "偏离了路线，正在重新规划")
    }

    // MARK: - 货架朝通道的站位点

    func testStandPointByShelfCode() {
        let shelf = ShelfRect(code: "Shelf-001-01", x: 300, y: 260, width: 360, height: 100, rotation: 0)
        let map = StoreMap(width: 1000, height: 1000, shelves: [shelf], crosses: [])
        // 只有上面（y = 100）那条通道可走 → 朝向 -y
        let walk = WalkableMap(crosses: [hCross("h", 100, 900, y: 100)], widthCm: 1000, heightCm: 1000)
        let signs = ShelfSigns(map: map, walkable: walk)
        guard let sg = signs.sign(forShelfCode: "Shelf-001-01") else { return XCTFail("应该找到货架") }
        XCTAssertEqual(sg.text, "001-01")
        let sp = signs.standPoint(sg)
        XCTAssertEqual(sp.x, 300, accuracy: 1e-6)
        XCTAssertEqual(sp.y, 120, accuracy: 1e-6)
        XCTAssertNil(signs.sign(forShelfCode: "Shelf-009-09"))
    }
}
