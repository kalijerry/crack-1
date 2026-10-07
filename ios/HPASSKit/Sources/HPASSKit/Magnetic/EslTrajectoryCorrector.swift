import Foundation

/// 价签锚定的轨迹修正（我们自己的融合算法核心）：全店 2 万片价签，位置都在价签位置表里，相当于 2 万个免费的
/// 绝对位置锚点。别家（Oriient 等）只能靠磁场回环和众包轨迹互相对齐，我们每走几步就能听到几十个已知位置的价签。
///
/// 做法（因子图 / 平滑器，按坐标轴分开解）：
/// - 未知量：每 knotMs 一个结点的平移修正 Dₖ = (dx, dy)，结点之间线性插值，修正后位置 = 轨迹位置 + D(t)；
/// - 价签因子：每条强读数（≥ minRssi）要求「修正后的人位置 ≈ 价签所在货架」，σ 随信号变弱变大
///   （−60 dBm 约 1.5 m，−85 dBm 约 5 m）；货架中心和人站的位置差 1～2 m，两边货架的读数会互相抵消；
/// - 平滑因子：相邻结点差 σ = smoothCm（ARKit 漂移是慢的；贴错通道这种跳变也能一段段拉回来）；
/// - 先验：D ≈ 0，σ = priorCm（很弱，只防没读数的地方乱跑）；
/// - Cauchy 鲁棒权重迭代重加权（IRLS）：表里位置不对的价签、反射读数自动降权。
/// 每个坐标轴是三对角线性方程，几千个结点也是毫秒级。修正完再贴一次通道（SurveyMapBuilder 里做）。
public final class EslTrajectoryCorrector {
    public struct Stats: Codable {
        public var readings: Int
        public var knots: Int
        /// 修正前 / 后：强读数「人 − 价签」距离中位数（m）
        public var beforeMedianM: Double
        public var afterMedianM: Double
        /// 最大修正量（m）
        public var maxShiftM: Double
    }

    public var knotMs: Int64 = 5000
    public var minRssi = -85.0
    public var smoothCm = 150.0
    public var priorCm = 2000.0
    public var cauchyCm = 300.0
    public var iterations = 10
    public var minReadings = 20

    public let tagPositions: [String: Point2]
    public init(tagPositions: [String: Point2]) { self.tagPositions = tagPositions }

    func sigma(_ rssi: Double) -> Double { min(max(150 + (-60 - rssi) * 14, 150), 500) }

    /// 返回修正函数（时间 → 平移量）和统计；强读数太少返回 nil（不修正）。
    public func solve(track: [(tMs: Int64, p: Point2)], ble: [BLESample]) -> (correction: (Int64) -> Point2, stats: Stats)? {
        guard track.count >= 2, let t0 = track.first?.tMs, let t1 = track.last?.tMs, t1 > t0 else { return nil }
        let times = track.map(\.tMs)
        func posAt(_ t: Int64) -> Point2? {
            var lo = 0, hi = times.count - 1
            guard t >= times[lo], t <= times[hi] else { return nil }
            while hi - lo > 1 { let m = (lo + hi) / 2; if times[m] <= t { lo = m } else { hi = m } }
            guard times[hi] - times[lo] <= 1000 else { return nil }
            let f = times[hi] > times[lo] ? Double(t - times[lo]) / Double(times[hi] - times[lo]) : 0
            let a = track[lo].p, b = track[hi].p
            return Point2(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
        }
        let K = Int((t1 - t0) / knotMs) + 2
        // 观测：结点下标 k、插值权重 w（属于 k 的部分）、轨迹位置、价签位置、σ
        var obs: [(k: Int, w: Double, p: Point2, g: Point2, s: Double)] = []
        for b in ble where b.rssi >= minRssi {
            guard let g = tagPositions[b.id], let p = posAt(b.tMs) else { continue }
            let u = Double(b.tMs - t0) / Double(knotMs)
            let k = min(Int(u), K - 2)
            obs.append((k, 1 - (u - Double(k)), p, g, sigma(b.rssi)))
        }
        guard obs.count >= minReadings else { return nil }

        var D = [[Double]](repeating: [Double](repeating: 0, count: K), count: 2)
        var rw = [Double](repeating: 1, count: obs.count)
        for _ in 0..<iterations {
            for axis in 0..<2 {
                // 三对角：a 下、b 主、c 上
                var a = [Double](repeating: 0, count: K), bdiag = a, c = a, r = a
                for k in 0..<K { bdiag[k] += 1 / (priorCm * priorCm) }
                let ws = 1 / (smoothCm * smoothCm)
                for k in 1..<K { bdiag[k] += ws; bdiag[k - 1] += ws; a[k] -= ws; c[k - 1] -= ws }
                for (i, o) in obs.enumerated() {
                    let wt = rw[i] / (o.s * o.s)
                    let y = axis == 0 ? o.g.x - o.p.x : o.g.y - o.p.y
                    let w0 = o.w, w1 = 1 - o.w
                    bdiag[o.k] += wt * w0 * w0; bdiag[o.k + 1] += wt * w1 * w1
                    c[o.k] += wt * w0 * w1; a[o.k + 1] += wt * w0 * w1
                    r[o.k] += wt * w0 * y; r[o.k + 1] += wt * w1 * y
                }
                D[axis] = Self.thomas(a, bdiag, c, r)
            }
            // 鲁棒权重（Cauchy，按 2D 距离）
            for (i, o) in obs.enumerated() {
                let dx = o.p.x + o.w * D[0][o.k] + (1 - o.w) * D[0][o.k + 1] - o.g.x
                let dy = o.p.y + o.w * D[1][o.k] + (1 - o.w) * D[1][o.k + 1] - o.g.y
                let e = (dx * dx + dy * dy).squareRoot()
                rw[i] = 1 / (1 + (e / cauchyCm) * (e / cauchyCm))
            }
        }
        func med(_ x: [Double]) -> Double { let s = x.sorted(); return s[s.count / 2] }
        let before = med(obs.map { $0.p.distance(to: $0.g) })
        let after = med(obs.map { o in
            Point2(o.p.x + o.w * D[0][o.k] + (1 - o.w) * D[0][o.k + 1], o.p.y + o.w * D[1][o.k] + (1 - o.w) * D[1][o.k + 1]).distance(to: o.g)
        })
        let maxShift = (0..<K).map { (D[0][$0] * D[0][$0] + D[1][$0] * D[1][$0]).squareRoot() }.max() ?? 0
        let knotMs = knotMs
        let dx = D[0], dy = D[1]
        let fn: (Int64) -> Point2 = { t in
            let u = min(max(Double(t - t0) / Double(knotMs), 0), Double(K - 1))
            let k = min(Int(u), K - 2), f = u - Double(k)
            return Point2(dx[k] * (1 - f) + dx[k + 1] * f, dy[k] * (1 - f) + dy[k + 1] * f)
        }
        return (fn, Stats(readings: obs.count, knots: K, beforeMedianM: (before / 10).rounded() / 10,
                          afterMedianM: (after / 10).rounded() / 10, maxShiftM: (maxShift / 10).rounded() / 10))
    }

    /// 三对角方程（Thomas 算法）：a 下对角（a[0] 不用）、b 主对角、c 上对角（c[n-1] 不用）
    static func thomas(_ a: [Double], _ b: [Double], _ c: [Double], _ d: [Double]) -> [Double] {
        let n = b.count
        var cp = [Double](repeating: 0, count: n), dp = cp
        cp[0] = c[0] / b[0]; dp[0] = d[0] / b[0]
        for i in 1..<n {
            let m = b[i] - a[i] * cp[i - 1]
            cp[i] = i < n - 1 ? c[i] / m : 0
            dp[i] = (d[i] - a[i] * dp[i - 1]) / m
        }
        var x = dp
        for i in stride(from: n - 2, through: 0, by: -1) { x[i] = dp[i] - cp[i] * x[i + 1] }
        return x
    }
}
