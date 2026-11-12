import Foundation

/// 「画 8 字」校准：用陀螺仪姿态估手机自身磁场（硬铁偏置）。
///
/// 思路（陀螺仪辅助校准，见 Kok & Schön 2016、Rodríguez-Martínez & Troni 2024 MAGYC）：
/// 手机原地转的几十秒里，地磁场在世界坐标系里是同一个向量 w；手机自带的偏置 b 跟着手机转。
/// 用不含磁力计的姿态 R_k（设备 → 世界）有  R_k (m_k − b) = w，即  w + R_k b = R_k m_k，
/// 对 (w, b) 六个未知数是线性的，最小二乘一次解出。比只用读数的球面拟合要的转动少得多，
/// 也不用事先假设地磁强度；残差顺便告诉我们附近磁场乱不乱（离金属 / 磁铁太近）。
///
/// 姿态矩阵的方向约定（设备 → 世界还是反过来）两种都解，取残差小的，调用方不用操心。
public struct HardIronCalibration {
    public struct Target {
        /// 解出的地磁强度要在这里（µT）。伦敦约 49；室内钢结构会偏几十
        public var fieldUT: ClosedRange<Double> = 25...75
        /// 残差 RMS 上限（µT）：大了说明附近有金属 / 磁铁，或者手机边转边走了
        public var maxRmsUT = 6.0
        /// 每个轴原始读数的跨度至少是地磁强度的这么多倍（转得够不够）
        public var minSpanRatio = 0.8
        public var minSamples = 150
        /// 最近几次解出的偏置相差不超过这个（µT）才算稳定
        public var stableUT = 3.0
        public init() {}
    }

    public struct Result: Equatable {
        public let bias: [Double]
        public let fieldUT: Double
        public let rmsUT: Double
    }

    public enum Issue: Equatable {
        case needMoreRotation
        case noisy(rmsUT: Double)
        case fieldOutOfRange(fieldUT: Double)
    }

    public let target: Target
    public private(set) var result: Result?
    public private(set) var issue: Issue? = .needMoreRotation
    /// 0～1，给界面进度条
    public private(set) var progress: Double = 0
    public private(set) var sampleCount = 0
    /// 最近一次解（还没达标时也有），给界面 / 日志看
    public private(set) var latest: Result?

    private var samples: [(m: [Double], r: [[Double]])] = []
    private var lo = [Double](repeating: .infinity, count: 3)
    private var hi = [Double](repeating: -.infinity, count: 3)
    private var recent: [[Double]] = []

    public init(target: Target = Target()) { self.target = target }

    /// 送一个样本：原始磁力计（µT，设备坐标）和同一时刻的姿态矩阵（3×3，行优先，不含磁力计的参考系）。
    public mutating func add(raw m: (Double, Double, Double), rotation r: [[Double]]) {
        guard result == nil, samples.count < 6000, r.count == 3, r.allSatisfy({ $0.count == 3 }) else { return }
        let v = [m.0, m.1, m.2]
        samples.append((v, r))
        sampleCount = samples.count
        for k in 0..<3 { lo[k] = min(lo[k], v[k]); hi[k] = max(hi[k], v[k]) }
        if samples.count % 25 == 0 { solveAndJudge() }
    }

    public var minSpanUT: Double { (0..<3).map { hi[$0] - lo[$0] }.min() ?? 0 }

    private mutating func solveAndJudge() {
        let a = Self.solve(samples, transpose: false)
        let b = Self.solve(samples, transpose: true)
        let best: Result? = [a, b].compactMap { $0 }.min { $0.rmsUT < $1.rmsUT }
        latest = best
        let field = best?.fieldUT ?? 49
        let spanNeed = target.minSpanRatio * max(field, target.fieldUT.lowerBound)
        let spanProg = min(1, minSpanUT / spanNeed)
        let countProg = min(1, Double(samples.count) / Double(target.minSamples))
        progress = 0.8 * spanProg + 0.2 * countProg
        guard let r = best else { issue = .needMoreRotation; return }
        recent.append(r.bias)
        if recent.count > 3 { recent.removeFirst() }
        if spanProg < 1 || countProg < 1 { issue = .needMoreRotation; return }
        if r.rmsUT > target.maxRmsUT { issue = .noisy(rmsUT: r.rmsUT); progress = min(progress, 0.9); return }
        if !target.fieldUT.contains(r.fieldUT) { issue = .fieldOutOfRange(fieldUT: r.fieldUT); progress = min(progress, 0.9); return }
        var stable = recent.count >= 3
        for p in recent where Self.distance(p, r.bias) > target.stableUT { stable = false }
        if !stable { issue = .needMoreRotation; progress = min(progress, 0.95); return }
        issue = nil
        progress = 1
        result = r
    }

    static func transposed(_ m: [[Double]]) -> [[Double]] {
        var t = m
        for i in 0..<3 { for j in 0..<3 { t[i][j] = m[j][i] } }
        return t
    }

    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for k in 0..<min(a.count, b.count) {
            let d = a[k] - b[k]
            s += d * d
        }
        return s.squareRoot()
    }

    /// 最小二乘解 (w, b)：每个样本三行  [I | R] (w; b) = R m。返回偏置、|w|、残差 RMS。
    static func solve(_ s: [(m: [Double], r: [[Double]])], transpose: Bool) -> Result? {
        guard s.count >= 30 else { return nil }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        var atb = [Double](repeating: 0, count: 6)
        for (m, r0) in s {
            let r = transpose ? transposed(r0) : r0
            for i in 0..<3 {
                var row = [Double](repeating: 0, count: 6)
                row[i] = 1
                for j in 0..<3 { row[3 + j] = r[i][j] }
                let y = r[i][0] * m[0] + r[i][1] * m[1] + r[i][2] * m[2]
                for p in 0..<6 {
                    atb[p] += row[p] * y
                    for q in 0..<6 { ata[p][q] += row[p] * row[q] }
                }
            }
        }
        guard let x = solveLinear(ata, atb) else { return nil }
        let w = Array(x[0..<3]), b = Array(x[3..<6])
        var se = 0.0
        for (m, r0) in s {
            let r = transpose ? transposed(r0) : r0
            let d = [m[0] - b[0], m[1] - b[1], m[2] - b[2]]
            for i in 0..<3 {
                let e = r[i][0] * d[0] + r[i][1] * d[1] + r[i][2] * d[2] - w[i]
                se += e * e
            }
        }
        let field = (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).squareRoot()
        return Result(bias: b, fieldUT: field, rmsUT: (se / Double(s.count)).squareRoot())
    }

    /// n×n 线性方程组（高斯消元，部分主元）。奇异 / 病态（转得太少）时返回 nil。
    static func solveLinear(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        let n = b.count
        let scale = max(1, a.flatMap { $0 }.map { abs($0) }.max() ?? 0)
        for col in 0..<n {
            var piv = col
            for r in col..<n where abs(a[r][col]) > abs(a[piv][col]) { piv = r }
            guard abs(a[piv][col]) > 1e-6 * scale else { return nil }
            if piv != col { a.swapAt(piv, col); b.swapAt(piv, col) }
            for r in 0..<n where r != col {
                let f = a[r][col] / a[col][col]
                if f == 0 { continue }
                for c in col..<n { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        return (0..<n).map { b[$0] / a[$0][$0] }
    }
}

/// 打开 App 时的快速检查：用存下的偏置扣原始读数，|B| 的中位数应该像地磁（室内 15～90 µT）。
/// 偏置变了（加了磁吸配件、手机被磁化）一般会差上百 µT，一眼就能看出来。
public enum HardIronCheck {
    public static let plausibleUT: ClosedRange<Double> = 15...90
    public static let minSamples = 30

    /// nil = 样本不够；否则返回 |原始 − 偏置| 的中位数
    public static func medianField(raw: [(Double, Double, Double)], bias: [Double]) -> Double? {
        guard raw.count >= minSamples, bias.count == 3 else { return nil }
        let t = raw.map { v -> Double in
            let d = (v.0 - bias[0], v.1 - bias[1], v.2 - bias[2])
            return (d.0 * d.0 + d.1 * d.1 + d.2 * d.2).squareRoot()
        }.sorted()
        return t[t.count / 2]
    }

    /// true = 偏置大概率变了，该重新校准
    public static func shifted(raw: [(Double, Double, Double)], bias: [Double]) -> Bool? {
        medianField(raw: raw, bias: bias).map { !plausibleUT.contains($0) }
    }
}
