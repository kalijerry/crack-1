import Foundation

/// 把任意位置吸附到一条已有路线上（给地图上的小人用）。
public enum RouteSnapper {
    /// 返回位置在路线折线上的垂足；横向偏离超过 maxDistance 时返回 nil。
    public static func snap(_ p: Point2, to route: Route, maxDistance: Double = 500) -> Point2? {
        guard !route.nodes.isEmpty else { return nil }
        guard p.x.isFinite, p.y.isFinite else { return nil }
        let pr = RouteGeometry.project(p, onRoute: route)
        return pr.distance <= maxDistance ? pr.point : nil
    }
}

/// 一次导航会话：持有目标列表与当前路线，位置每次更新时产出播报信息。
///
/// 目标列表只能通过 start 设置；此时强制全新规划（update 的 lastRoute 传 nil）。
/// 之后每次 onLocation 都走迟滞逻辑（见 RoutePlanner.update 的说明），
/// 正常前进时只会裁剪同一条折线，不会每秒换一条路。
public final class NavigationSession {

    private let planner: RoutePlanner

    public private(set) var targets: [Point2] = []
    public private(set) var route: Route? = nil
    /// 最近一次收到的位置
    public private(set) var lastLocation: Point2? = nil
    /// 连续脱线的定位更新次数
    public private(set) var offRouteCount = 0

    public init(planner: RoutePlanner) {
        self.planner = planner
    }

    /// 是否处于导航中（还有目标）。
    public var isActive: Bool { !targets.isEmpty }

    /// 开始导航。location 为 nil 时只记下目标，等第一个定位结果再规划。
    @discardableResult
    public func start(targets: [Point2], from location: Point2?) -> NavHint? {
        self.targets = targets
        self.route = nil
        self.lastLocation = location
        guard !targets.isEmpty, let loc = location else { return nil }
        guard let r = planner.update(location: loc, targets: targets, lastRoute: nil) else { return nil }
        self.route = r
        return planner.hint(for: loc, on: r)
    }

    /// 试算一条路线但不改变会话状态（用于“预览”）。
    public func preview(targets: [Point2], from location: Point2) -> Route? {
        planner.plan(from: location, targets: targets)
    }

    /// 收到新定位。返回最新播报；未在导航中返回 nil。
    @discardableResult
    public func onLocation(_ p: Point2) -> NavHint? {
        guard isActive else { return nil }
        guard p.x.isFinite, p.y.isFinite else { return nil }
        lastLocation = p
        if let cur = route, cur.nodes.count >= 2 {
            if RouteGeometry.project(p, onRoute: cur).distance > planner.config.offRouteDistanceCm {
                offRouteCount += 1
                // 还没连续脱线够次数：先沿用旧路线（hint 里 isOffRoute 已置位）
                if offRouteCount < planner.config.offRouteConfirmUpdates { return planner.hint(for: p, on: cur) }
            } else {
                offRouteCount = 0
            }
        }
        offRouteCount = 0
        guard let r = planner.update(location: p, targets: targets, lastRoute: route) else { return nil }
        route = r
        return planner.hint(for: p, on: r)
    }

    /// 结束导航并清空状态。
    public func stop() {
        targets = []
        route = nil
        lastLocation = nil
        offRouteCount = 0
    }
}
