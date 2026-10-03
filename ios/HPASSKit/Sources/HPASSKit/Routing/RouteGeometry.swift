import Foundation

// MARK: - 坐标约定（全局，务必遵守）
//
// 门店地图使用 **屏幕坐标系**：+x 向右，+y **向下**，单位厘米（cm）。
// 在该约定下，二维叉积 v1 × v2 = v1.x*v2.y - v1.y*v2.x 的符号含义为：
//   叉积 > 0  →  从 v1 转向 v2 是 **右转**（正角度 = 右转）
//   叉积 < 0  →  左转
// 推导：朝向 d 的“右手侧”为 d 旋转 +90°，即 (x, y) → (-y, x)；
//       例如朝向 (1,0)（屏幕上向右）其右侧为 (0,1)（屏幕上向下），与直觉一致。
// 角度一律用 atan2(cross, dot) 得到 (-180°, 180°] 的带符号转角。
//
// 货架 ShelfRect：先取以 (x,y) 为中心、width×height 的轴对齐矩形，再绕中心旋转
// rotation 度。局部轴：u = (cos r, sin r) 对应 width 方向，v = (-sin r, cos r)
// 对应 height 方向（标准二维旋转矩阵的两列）。

/// 纯几何工具（命名空间，无模块级自由函数）。
enum RouteGeometry {

    static let eps = 1e-9

    // MARK: 点 / 线段

    /// 点到线段的垂足投影（参数 t 已截断到 [0,1]）。退化线段返回端点本身。
    static func project(_ p: Point2, onto a: Point2, _ b: Point2) -> (point: Point2, t: Double, distance: Double) {
        let ab = b - a
        let len2 = ab.dot(ab)
        if len2 <= eps {
            return (a, 0.0, p.distance(to: a))
        }
        var t = (p - a).dot(ab) / len2
        if t < 0.0 { t = 0.0 } else if t > 1.0 { t = 1.0 }
        let q = a + ab * t
        return (q, t, p.distance(to: q))
    }

    /// 点到线段距离。
    static func distance(_ p: Point2, toSegment a: Point2, _ b: Point2) -> Double {
        project(p, onto: a, b).distance
    }

    /// 入向 v1 → 出向 v2 的带符号转角（度）。屏幕坐标下正值 = 右转。
    static func signedTurnDeg(_ v1: Point2, _ v2: Point2) -> Double {
        if v1.length <= eps || v2.length <= eps { return 0.0 }
        return atan2(v1.cross(v2), v1.dot(v2)) * 180.0 / Double.pi
    }

    // MARK: 线段求交（精确解析法 + 容差）

    /// 求两条通道中心线之间需要“打断”的连接点。
    ///
    /// 做法（标准线段求交）：
    /// - **非平行**：解 a1 + t·r = b1 + u·s，把 t、u 截断到 [0,1] 后比较两点距离；
    ///   距离 ≤ tolerance 即视为相交（含 T 形接触、端点接触），返回中点作为代表点。
    /// - **平行且共线**：按 a 的参数轴求重叠区间，返回区间两端点（重叠的共线通道会连通）。
    /// - **仅平行不共线**：返回空集合 —— 绝不产生虚假连接。
    ///
    /// 不对坐标做取整，容差只用于判定，不用于量化。
    static func junctions(_ a1: Point2, _ a2: Point2,
                          _ b1: Point2, _ b2: Point2,
                          tolerance tol: Double) -> [Point2] {
        let r = a2 - a1
        let s = b2 - b1
        let rLen2 = r.dot(r)
        let sLen2 = s.dot(s)
        if rLen2 <= eps || sLen2 <= eps { return [] }

        let denom = r.cross(s)
        let scale = (rLen2 * sLen2).squareRoot()
        if abs(denom) > 1e-12 * max(scale, 1.0) {
            // 非平行
            let qp = b1 - a1
            var t = qp.cross(s) / denom
            var u = qp.cross(r) / denom
            t = min(max(t, 0.0), 1.0)
            u = min(max(u, 0.0), 1.0)
            let pa = a1 + r * t
            let pb = b1 + s * u
            if pa.distance(to: pb) <= tol {
                return [(pa + pb) * 0.5]
            }
            return []
        }

        // 平行：先判断是否共线（点到**直线**的距离）
        let nLen = rLen2.squareRoot()
        let d1 = abs((b1 - a1).cross(r)) / nLen
        let d2 = abs((b2 - a1).cross(r)) / nLen
        if d1 > tol || d2 > tol { return [] }

        // 共线：在 a 的参数轴上求重叠区间
        let tb1 = (b1 - a1).dot(r) / rLen2
        let tb2 = (b2 - a1).dot(r) / rLen2
        let lo = max(0.0, min(tb1, tb2))
        let hi = min(1.0, max(tb1, tb2))
        let tolT = tol / nLen
        if lo > hi + tolT { return [] }     // 共线但不重叠
        let c = min(lo, hi)
        let d = max(lo, hi)
        var out: [Point2] = [a1 + r * c]
        if abs(d - c) * nLen > tol { out.append(a1 + r * d) }
        return out
    }

    /// 射线 o + t·dir（t ≥ 0）与线段 [a, b] 的交点参数 t；不相交返回 nil。
    static func rayHit(_ o: Point2, _ dir: Point2, _ a: Point2, _ b: Point2) -> Double? {
        let s = b - a
        let dLen = dir.length
        let sLen = s.length
        if dLen <= eps || sLen <= eps { return nil }
        let denom = dir.cross(s)
        if abs(denom) <= 1e-12 * max(dLen * sLen, 1.0) { return nil }   // 平行
        let qp = a - o
        let t = qp.cross(s) / denom
        let u = qp.cross(dir) / denom
        guard t >= -1e-9, u >= -1e-9, u <= 1.0 + 1e-9 else { return nil }
        return max(t, 0.0)
    }

    // MARK: 旋转矩形（货架）

    /// 货架局部轴：u 对应 width 方向，v 对应 height 方向。均为单位向量。
    static func rectAxes(rotationDeg: Double) -> (u: Point2, v: Point2) {
        let r = rotationDeg * Double.pi / 180.0
        let c = cos(r)
        let s = sin(r)
        return (Point2(c, s), Point2(-s, c))
    }

    /// 四角，多边形顺序（局部 --、+-、++、-+）。
    static func rectCorners(center: Point2, width: Double, height: Double, rotationDeg: Double) -> [Point2] {
        let axes = rectAxes(rotationDeg: rotationDeg)
        let hw = width * 0.5
        let hh = height * 0.5
        return [center + axes.u * (-hw) + axes.v * (-hh),
                center + axes.u * hw + axes.v * (-hh),
                center + axes.u * hw + axes.v * hh,
                center + axes.u * (-hw) + axes.v * hh]
    }

    /// 旋转矩形包含判定：把点变换到局部坐标后比较半边长（margin 为外扩量 cm）。
    static func rectContains(_ p: Point2, center: Point2, width: Double, height: Double,
                             rotationDeg: Double, margin: Double) -> Bool {
        let axes = rectAxes(rotationDeg: rotationDeg)
        let d = p - center
        return abs(d.dot(axes.u)) <= width * 0.5 + margin
            && abs(d.dot(axes.v)) <= height * 0.5 + margin
    }

    // MARK: 投影到路线折线

    /// 把位置投影到路线折线上：取最近线段，距离并列时取**下标更小**的线段（保证确定性）。
    static func project(_ p: Point2, onRoute route: Route) -> RouteProjection {
        guard let first = route.nodes.first else {
            return RouteProjection(point: p, segmentIndex: 0, chainage: 0.0, distance: 0.0)
        }
        if route.nodes.count == 1 {
            return RouteProjection(point: first.point, segmentIndex: 0,
                                   chainage: 0.0, distance: p.distance(to: first.point))
        }
        var bestD = Double.greatestFiniteMagnitude
        var bestIdx = 0
        var bestPoint = first.point
        var bestChainage = 0.0
        for i in 0..<(route.nodes.count - 1) {
            let a = route.nodes[i].point
            let b = route.nodes[i + 1].point
            let pr = project(p, onto: a, b)
            if pr.distance < bestD - 1e-9 {
                bestD = pr.distance
                bestIdx = i
                bestPoint = pr.point
                bestChainage = route.nodes[i].distanceFromStart + a.distance(to: pr.point)
            }
        }
        return RouteProjection(point: bestPoint,
                               segmentIndex: bestIdx,
                               chainage: min(max(bestChainage, 0.0), route.length),
                               distance: bestD)
    }
}

/// 位置在路线折线上的投影结果。
struct RouteProjection {
    /// 垂足点
    var point: Point2
    /// 所在线段下标（nodes[i] → nodes[i+1]）
    var segmentIndex: Int
    /// 沿路线里程（cm）
    var chainage: Double
    /// 横向偏离（cm）
    var distance: Double
}
