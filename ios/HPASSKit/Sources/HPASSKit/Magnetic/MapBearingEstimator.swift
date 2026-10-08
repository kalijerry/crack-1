import Foundation

/// 地图朝向（地图「上方」对应的罗盘方位）：从建图会话自动估。
///
/// 采集时手机朝前拿着走，手机罗盘方向 ≈ 行进方向；对齐好的轨迹给出同一时刻在地图上的行进方向。
/// 两者之差就是地图上方的方位。逐会话取圆周中位，再在会话之间取中位（轨迹偏航的会话会差很多，自然被排除）。
/// 实测 1266 店：三个正常会话 313° / 319° / 323°，偏航的那个 26°。
public enum MapBearingEstimator {
    /// heading.csv：t_ms,magnetic_deg,true_deg,…（用 true_deg）
    public static func loadHeadings(_ dir: URL) -> [(tMs: Int64, deg: Double)] {
        guard let t = try? String(contentsOf: dir.appendingPathComponent("heading.csv"), encoding: .utf8) else { return [] }
        return t.split(whereSeparator: \.isNewline).dropFirst().compactMap { l in
            let c = l.split(separator: ",")
            guard c.count >= 3, let t = Int64(c[0]), let d = Double(c[2]) else { return nil }
            return (t, d)
        }
    }

    /// 一个会话：返回（方位，中位偏差，段数）；有效段太少返回 nil
    public static func estimate(track: [(tMs: Int64, p: Point2)], headings: [(tMs: Int64, deg: Double)]) -> (deg: Double, devDeg: Double, n: Int)? {
        guard track.count > 20, !headings.isEmpty else { return nil }
        let hs = headings.sorted { $0.tMs < $1.tMs }
        var vals: [Double] = []
        var j = 0
        for k in stride(from: 10, to: track.count, by: 5) {
            let d = track[k].p - track[k - 10].p
            guard d.length > 80 else { continue }
            let t = track[k].tMs
            while j + 1 < hs.count && hs[j + 1].tMs <= t { j += 1 }
            let h = (j + 1 < hs.count && abs(hs[j + 1].tMs - t) < abs(hs[j].tMs - t)) ? hs[j + 1] : hs[j]
            guard abs(h.tMs - t) < 500 else { continue }
            let alpha = atan2(d.x, -d.y) * 180 / .pi
            vals.append(norm(h.deg - alpha))
        }
        guard vals.count >= 30 else { return nil }
        let m = circularMean(vals)
        let dev = vals.map { angDiff($0, m) }.sorted()
        return (m, dev[dev.count / 2], vals.count)
    }

    /// 多个会话：中位偏差 ≤ maxDevDeg 的会话里，取和其余会话最一致的那一组的圆周均值
    public static func combine(_ xs: [(deg: Double, devDeg: Double, n: Int)], maxDevDeg: Double = 12, agreeDeg: Double = 20) -> Double? {
        let good = xs.filter { $0.devDeg <= maxDevDeg }
        guard !good.isEmpty else { return nil }
        // 找支持者最多的一个，再对它的支持者求均值
        let best = good.max { a, b in
            good.filter { angDiff($0.deg, a.deg) <= agreeDeg }.reduce(0) { $0 + $1.n } < good.filter { angDiff($0.deg, b.deg) <= agreeDeg }.reduce(0) { $0 + $1.n }
        }!
        let sup = good.filter { angDiff($0.deg, best.deg) <= agreeDeg }
        var sx = 0.0, cx = 0.0
        for s in sup { sx += Double(s.n) * sin(s.deg * .pi / 180); cx += Double(s.n) * cos(s.deg * .pi / 180) }
        return norm(atan2(sx, cx) * 180 / .pi)
    }

    static func norm(_ d: Double) -> Double { let r = d.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r }
    static func angDiff(_ a: Double, _ b: Double) -> Double { abs(norm(a - b + 180) - 180) }
    static func circularMean(_ v: [Double]) -> Double {
        norm(atan2(v.reduce(0) { $0 + sin($1 * .pi / 180) }, v.reduce(0) { $0 + cos($1 * .pi / 180) }) * 180 / .pi)
    }
}
