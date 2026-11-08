import Foundation
import HPASSKit
import SwiftUI

/// App 里唯一的一份定位引擎 / 采集引擎。导航、建图、高级控制台共用，避免两个页面同时开传感器。
///
/// 只负责「持有」和「换地图时的通用刷新」，引擎本身的行为不变。
@MainActor
final class AppEngines: ObservableObject {
    static let shared = AppEngines()

    let magnetic = MagneticEngine()
    let survey = SurveyEngine()
    let mapService = SurveyMapService()

    private var prepared = false
    /// 正在走精度测试（结束后把测试会话开关还原）
    var accuracyTestRunning = false

    /// 第一次显示地图相关页面时调用：补上通道、建覆盖网格、读会话列表和地图监测。
    func prepareIfNeeded() {
        guard !prepared else { return }
        prepared = true
        refreshForMap()
    }

    /// 换地图（或地图内容更新）后刷新。
    func refreshForMap() {
        let store = MagMapStore.shared
        store.adopt(map: StoreDataStore.shared.map)
        configureCoverage()
        mapService.refresh()
        magnetic.loadMonitor()
    }

    /// 和高级控制台里的同名逻辑一致：先补上通道，再建覆盖网格。
    func configureCoverage() {
        let store = MagMapStore.shared
        if let m = StoreDataStore.shared.map, !m.crosses.isEmpty, store.crosses.isEmpty { return }
        survey.coverage.configure(crosses: store.crosses)
        survey.coverage.configurePaint(crosses: store.crosses, widthCm: store.widthCm, heightCm: store.heightCm,
                                       walkable: store.walkableMap())
    }

    /// 画布用的地图：有场地地图就用它，没有就是一块空白测试区。
    var canvasMap: StoreMap? {
        if let m = StoreDataStore.shared.map, m.width > 0 { return m }
        let s = MagMapStore.shared
        return StoreMap(width: s.widthCm, height: s.heightCm, shelves: [], crosses: [])
    }

    /// 有可用的场地地图（不是空白测试区）
    var hasVenueMap: Bool { StoreDataStore.shared.map != nil && MagMapStore.shared.usesStoreMap }
}

// MARK: - 演示模式（CI 截图用）

/// 启动参数 `-uiDemo` 打开：不读传感器，用一张合成的示例地图和固定的位置 / 路线画界面，方便在模拟器里截图评审。
/// `-uiTab <navigate|mapping|library|settings>` 指定启动后显示哪个 Tab。
enum DemoMode {
    static let isOn: Bool = ProcessInfo.processInfo.arguments.contains("-uiDemo")

    static var initialTab: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiTab"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// 演示状态：`-uiDemoState <idle|searching|tracking|navigating>`
    static var state: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiDemoState"), args.indices.contains(i + 1) else { return "navigating" }
        return args[i + 1]
    }

    /// 合成的示例场地：40 × 24 m，四排障碍物，两横三纵的走廊。
    static let map: StoreMap = {
        var shelves: [ShelfRect] = []
        let rows: [Double] = [500, 1000, 1500]
        var n = 0
        for (ri, y) in rows.enumerated() {
            for x in stride(from: 600.0, through: 3400, by: 400) where !(x == 2200 && ri == 1) {
                n += 1
                shelves.append(ShelfRect(code: String(format: "A-%02d", n), x: x, y: y + 150, width: 300, height: 120, rotation: 0))
            }
        }
        let crosses: [CrossSegment] = [
            CrossSegment(code: "C1", a: Point2(200, 400), b: Point2(3800, 400), lineWidth: 160),
            CrossSegment(code: "C2", a: Point2(200, 900), b: Point2(3800, 900), lineWidth: 160),
            CrossSegment(code: "C3", a: Point2(200, 1400), b: Point2(3800, 1400), lineWidth: 160),
            CrossSegment(code: "C4", a: Point2(200, 2000), b: Point2(3800, 2000), lineWidth: 220),
            CrossSegment(code: "V1", a: Point2(300, 300), b: Point2(300, 2100), lineWidth: 200),
            CrossSegment(code: "V2", a: Point2(2200, 300), b: Point2(2200, 2100), lineWidth: 200),
            CrossSegment(code: "V3", a: Point2(3700, 300), b: Point2(3700, 2100), lineWidth: 200),
        ]
        let walls: [(shapeType: String, x: Double, y: Double, width: Double, height: Double, rotation: Double)] = [
            ("MapWall", 2000, 50, 4000, 20, 0),
            ("MapWall", 2000, 2350, 4000, 20, 0),
            ("MapWall", 50, 1200, 20, 2400, 0),
            ("MapWall", 3950, 1200, 20, 2400, 0),
            ("MapDoor", 1200, 2350, 200, 24, 0),
        ]
        return StoreMap(floorName: "1F", width: 4000, height: 2400, shelves: shelves, crosses: crosses, others: walls)
    }()

    static let position = Point2(1350, 2000)
    static let headingRad = Double.pi / 2           // 朝 +x（向右）
    static let trail: [Point2] = (0..<30).map { Point2(500 + Double($0) * 29, 2000 + sin(Double($0) / 3) * 6) }

    static let route: Route = {
        let pts = [Point2(1350, 2000), Point2(2200, 2000), Point2(2200, 900), Point2(3000, 900)]
        var acc = 0.0
        var nodes: [RouteNode] = []
        for (i, p) in pts.enumerated() {
            if i > 0 { acc += p.distance(to: pts[i - 1]) }
            nodes.append(RouteNode(point: p, isTarget: i == pts.count - 1, distanceFromStart: acc))
        }
        let turns = [RouteTurn(nodeIndex: 1, chainage: 850, angleDeg: -90, direction: .left),
                     RouteTurn(nodeIndex: 2, chainage: 1950, angleDeg: 90, direction: .right)]
        return Route(nodes: nodes, length: acc, turns: turns)
    }()
}
