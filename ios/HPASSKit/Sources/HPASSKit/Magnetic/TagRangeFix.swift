import Foundation

/// 只用价签（全店价签位置表，不用采集）定位：每片听到的价签给一个「人在它多少米以内」的圆（BLEAssist.rangeCm），
/// 找同时落在最多圆里的地方。采集时当「底」：自动定起点、发现轨迹走偏（地磁 / ARKit 做高精度，价签做低精度兜底）。
public enum TagRangeFix {
    public typealias Tag = (position: Point2, rangeCm: Double)

    /// 最近几秒每片价签的平均信号 → 最强的 k 片（表里有位置的）
    public static func tags(_ obs: [String: Double], map: BLEFingerprintMap, k: Int = 6, minRssi: Double = -88) -> [Tag] {
        BLEFingerprintMap.strongest(obs, k: k, minRssi: minRssi).compactMap { o in
            map.tags[o.0].map { (Point2($0.x, $0.y), BLEAssist.rangeCm(o.1)) }
        }
    }

    /// p 落在几成圆里
    public static func agreement(_ tags: [Tag], at p: Point2) -> Double {
        tags.isEmpty ? 0 : Double(tags.filter { p.distance(to: $0.position) <= $0.rangeCm }.count) / Double(tags.count)
    }

    static func penalty(_ tags: [Tag], _ p: Point2) -> Double {
        tags.reduce(0) { acc, t in
            let e = p.distance(to: t.position) - t.rangeCm
            return acc + (e > 0 ? min(e * e / (150 * 150), 4) : 0)
        }
    }

    /// 位置估计：在最强（范围最小）那片价签的圆里按 50 cm 网格找罚分最小的点，取最优附近一圈点的中心；
    /// spread = 这些点离中心的均方根（cm）。可走区域给了就只在能走的地方找。
    public static func fix(_ tags: [Tag], walkable: WalkableMap? = nil) -> (position: Point2, spreadCm: Double)? {
        guard tags.count >= 3, let s = tags.min(by: { $0.rangeCm < $1.rangeCm }) else { return nil }
        var pts: [(Point2, Double)] = []
        let r = s.rangeCm
        for gx in stride(from: -r, through: r, by: 50) {
            for gy in stride(from: -r, through: r, by: 50) where gx * gx + gy * gy <= r * r {
                let p = Point2(s.position.x + gx, s.position.y + gy)
                if let w = walkable, !w.isWalkable(p) { continue }
                pts.append((p, penalty(tags, p)))
            }
        }
        guard let best = pts.map(\.1).min() else { return nil }
        let near = pts.filter { $0.1 <= best + 0.5 }.map(\.0)
        let c = Point2(near.reduce(0) { $0 + $1.x } / Double(near.count), near.reduce(0) { $0 + $1.y } / Double(near.count))
        let rms = (near.reduce(0) { $0 + $1.distance(to: c) * $1.distance(to: c) } / Double(near.count)).squareRoot()
        return (c, max(rms, 100))
    }

    /// 离 p 最近、落在至少 frac 成圆里的点（找不到返回 nil）
    public static func nearestConsistent(_ tags: [Tag], to p: Point2, frac: Double = 0.6, searchCm: Double = 2500,
                                         walkable: WalkableMap? = nil) -> Point2? {
        guard !tags.isEmpty else { return nil }
        var best: (Point2, Double)?
        for gx in stride(from: -searchCm, through: searchCm, by: 50) {
            for gy in stride(from: -searchCm, through: searchCm, by: 50) {
                let d = (gx * gx + gy * gy).squareRoot()
                guard d <= searchCm, best == nil || d < best!.1 else { continue }
                let q = Point2(p.x + gx, p.y + gy)
                if let w = walkable, !w.isWalkable(q) { continue }
                if agreement(tags, at: q) >= frac { best = (q, d) }
            }
        }
        return best?.0
    }

    /// 罗盘真北方位 + 地图朝向（地图上方的方位）→ 地图上的朝向（弧度，0 = 地图 +y 向下，和 atan2(dx, dy) 一致）
    public static func mapHeading(compassDeg: Double, mapUpBearingDeg: Double) -> Double {
        let a = (compassDeg - mapUpBearingDeg) * .pi / 180     // 从地图上方顺时针
        var h = Double.pi - a
        while h > .pi { h -= 2 * .pi }
        while h < -.pi { h += 2 * .pi }
        return h
    }
}
