import Foundation

/// 建图采集时在线「贴通道」：沿通道直走的时候，用通道方向和中心线把 ARKit 轨迹的朝向和横向偏差慢慢拉回来。
///
/// 离线建图（SurveyMapBuilder）也会贴通道，但那是走完才做。在线做的好处：
/// - 采集进度标在对的通道上，不会因为 ARKit 朝向漂了几度就标到隔壁；
/// - 不用每 30 m 长按修正一次，只需要起点和朝向；
/// - AR 叠加、3D 里看到的位置一直贴着通道。
///
/// 只在「最近几米明显是直线、方向和附近某条通道差不多」时才修正，路口拐弯、横穿时不动。
/// 修正量按增益打折，一次只改一点，不会跳。沿通道方向的误差看不出来，不修。
public final class CorridorLock {
    public struct Correction {
        /// 绕当前位置旋转的角度（弧度，和 atan2(y, x) 同一个方向）
        public var dPhi: Double
        /// 旋转之后再平移（cm，地图坐标）
        public var shift: Point2
        public var corridor: String
    }

    public let crosses: [CrossSegment]
    /// 用最近多少路程（cm）的轨迹估方向
    public var windowCm = 600.0
    /// 至少走了这么远才开始估
    public var minWindowCm = 400.0
    /// 两次修正之间至少走多远（cm）
    public var everyCm = 100.0
    /// 轨迹方向和通道方向最多差多少才认为在沿这条通道走（弧度，约 12°）
    public var maxAngle = 0.21
    /// 直线度：点到拟合直线的均方根超过这个（cm）就不算直走
    public var maxStraightRmsCm = 30.0
    /// 窗口中心离通道中心线超过 半宽 + 这个（cm）就不认这条通道
    public var maxOutsideCm = 80.0
    /// 横向：人不一定走正中，所以只在轨迹跑出通道（离中心线超过 半宽 − 这个，cm）时才往回拉。
    /// 拉中心线会带来偏差（回放实测：拉中心线中位误差 29 cm，只拉出界的 23 cm）
    public var lateralMarginCm = 30.0
    public var angleGain = 0.5
    public var lateralGain = 0.3

    private var pts: [(p: Point2, s: Double)] = []
    private var path = 0.0
    private var lastFixPath = -Double.infinity

    public private(set) var corrections = 0
    public private(set) var totalAbsAngle = 0.0

    public init(crosses: [CrossSegment]) {
        self.crosses = crosses.filter { $0.a.distance(to: $0.b) > 100 }
    }

    /// 修正（长按）之后、跟踪丢了之后调用：旧轨迹不再可信。
    public func reset() {
        pts.removeAll()
        lastFixPath = -Double.infinity
    }

    /// 喂当前位置（已经包含之前的修正）。需要修正时返回修正量，调用方把它应用到对齐参数上。
    public func update(_ p: Point2) -> Correction? {
        if let last = pts.last {
            let d = p.distance(to: last.p)
            guard d >= 10 else { return nil }
            path += d
        }
        pts.append((p, path))
        while let f = pts.first, path - f.s > windowCm { pts.removeFirst() }
        guard let first = pts.first, path - first.s >= minWindowCm, path - lastFixPath >= everyCm,
              pts.count >= 8 else { return nil }

        // 主方向（PCA）和直线度
        let n = Double(pts.count)
        let c = pts.reduce(Point2.zero) { $0 + $1.p } * (1 / n)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for q in pts { let d = q.p - c; sxx += d.x * d.x; syy += d.y * d.y; sxy += d.x * d.y }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let u = Point2(cos(theta), sin(theta))
        let rms = (pts.reduce(0.0) { let d = $1.p - c; let e = d.x * u.y - d.y * u.x; return $0 + e * e } / n).squareRoot()
        guard rms <= maxStraightRmsCm else { return nil }

        // 找方向接近、离得够近的通道
        var best: (cross: CrossSegment, dA: Double, dist: Double)?
        for x in crosses {
            let d = x.b - x.a
            let l2 = d.dot(d)
            let t = (c - x.a).dot(d) / l2
            guard t > -0.05, t < 1.05 else { continue }
            let foot = Point2(x.a.x + d.x * t, x.a.y + d.y * t)
            let dist = c.distance(to: foot)
            guard dist <= max(x.lineWidth, 0) / 2 + maxOutsideCm else { continue }
            var dA = atan2(d.y, d.x) - theta                 // 把轨迹方向转到通道方向
            while dA > Double.pi / 2 { dA -= Double.pi }      // 方向不分正反
            while dA < -Double.pi / 2 { dA += Double.pi }
            guard abs(dA) <= maxAngle else { continue }
            if best == nil || dist < best!.dist { best = (x, dA, dist) }
        }
        guard let b = best else { return nil }

        // 先绕当前位置转，再看窗口中心离中心线多远
        let rot = angleGain * b.dA
        let co = cos(rot), si = sin(rot)
        func turn(_ q: Point2) -> Point2 { let r = q - p; return Point2(p.x + r.x * co - r.y * si, p.y + r.x * si + r.y * co) }
        let c2 = turn(c)
        let d = b.cross.b - b.cross.a
        let len = d.length
        let nrm = Point2(-d.y / len, d.x / len)
        let off = nrm.dot(c2 - b.cross.a)
        var shift = Point2.zero
        let band = max(b.cross.lineWidth / 2 - lateralMarginCm, 20)
        if abs(off) > band {
            let excess = off - (off > 0 ? band : -band)
            shift = nrm * (-lateralGain * excess)
        }
        for i in pts.indices { pts[i].p = turn(pts[i].p) + shift }
        lastFixPath = path
        corrections += 1
        totalAbsAngle += abs(rot)
        return Correction(dPhi: rot, shift: shift, corridor: b.cross.code)
    }
}
