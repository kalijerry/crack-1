import Foundation

/// 定位时顺便看「地图还准不准」：
///
/// - **变化检测**：每次有把握的定位，把这一刻的磁场读数和地图在这个位置的值比，按地图的标准差标准化（z）。
///   某格攒够读数后 |z| 平均还很大 → 那里的磁场和建图时不一样了（货架挪了、换了陈列），标出来让人补采；
/// - **定位即采集（先只记录）**：同时把这些读数按格累积起来，和采集的磁场图比差多少。差得小、稳定，
///   以后才考虑低权重并进地图；现在只看不并，免得把定错时的读数写进地图。
///
/// 按地图工作区存盘（live-monitor.json）。非线程安全。
public final class LiveFieldMonitor: Codable {
    public struct Acc: Codable {
        public var n = 0
        public var sumAbsZ = 0.0
        public var sum = [0.0, 0.0, 0.0]
        /// 读数 − 地图，带符号累加：真的变了是系统性的偏差，噪声会互相抵消
        public var sumRes = [0.0, 0.0, 0.0]
        /// 地图在这格的标准差（记最后一次）
        public var sigma = [1.0, 1.0, 1.0]
    }

    public let cellCm: Double
    public let cols: Int
    public let rows: Int
    public private(set) var cells: [Int: Acc] = [:]

    /// - Parameter blockCm: 按多大的块统计。定位时大约每走 20 cm 才有一个读数，50 cm 的格子一趟只有两三个，
    ///   所以按 1 m 的块攒，走两三趟就够判断。
    public init(field: MagneticFieldMap, blockCm: Double = 100) {
        cellCm = blockCm
        cols = Int((field.widthCm / blockCm).rounded(.up))
        rows = Int((field.heightCm / blockCm).rounded(.up))
    }

    public func matches(_ f: MagneticFieldMap) -> Bool {
        cols == Int((f.widthCm / cellCm).rounded(.up)) && rows == Int((f.heightCm / cellCm).rounded(.up))
    }

    /// 有把握的定位结果 + 这一刻的磁场特征
    public func add(position p: Point2, feature f: MagneticFeature, field: MagneticFieldMap) {
        guard let m = field.sample(at: p), p.x >= 0, p.y >= 0 else { return }
        let i = Int(p.x / cellCm), j = Int(p.y / cellCm)
        guard i < cols, j < rows else { return }
        let z0: Double = abs(f.total - m.mean.total) / max(m.sigma.total, 0.5)
        let z1: Double = abs(f.vertical - m.mean.vertical) / max(m.sigma.vertical, 0.5)
        let z2: Double = abs(f.horizontal - m.mean.horizontal) / max(m.sigma.horizontal, 0.5)
        let z = (z0 + z1 + z2) / 3
        var a = cells[j * cols + i] ?? Acc()
        a.n += 1
        a.sumAbsZ += min(z, 10)
        a.sum[0] += f.total; a.sum[1] += f.vertical; a.sum[2] += f.horizontal
        a.sumRes[0] += f.total - m.mean.total
        a.sumRes[1] += f.vertical - m.mean.vertical
        a.sumRes[2] += f.horizontal - m.mean.horizontal
        a.sigma = [m.sigma.total, m.sigma.vertical, m.sigma.horizontal]
        cells[j * cols + i] = a
    }

    /// 可能变了的格子：读数够多，且某个特征的平均偏差（带符号，噪声抵消掉）超过 max(minShiftUT, 地图标准差)。
    /// 返回值里的 shiftUT 是三个特征里偏得最多的那个。
    public func changed(minCount: Int = 8, minShiftUT: Double = 2.0) -> [(center: Point2, shiftUT: Double, n: Int)] {
        cells.compactMap { k, a in
            guard a.n >= minCount else { return nil }
            var worst = 0.0
            for c in 0..<3 {
                let bias = abs(a.sumRes[c] / Double(a.n))
                if bias > max(minShiftUT, a.sigma[c]) { worst = max(worst, bias) }
            }
            guard worst > 0 else { return nil }
            return (Point2((Double(k % cols) + 0.5) * cellCm, (Double(k / cols) + 0.5) * cellCm), worst, a.n)
        }.sorted { $0.shiftUT > $1.shiftUT }
    }

    /// 定位攒的磁场和采集的磁场图差多少：有足够读数的格子里 |差| 的中位（µT，三个特征平均）
    public func liveVsMap(_ field: MagneticFieldMap, minCount: Int = 8) -> (medianUT: Double, cells: Int)? {
        var d: [Double] = []
        for (k, a) in cells where a.n >= minCount {
            let p = Point2((Double(k % cols) + 0.5) * cellCm, (Double(k / cols) + 0.5) * cellCm)
            guard let m = field.sample(at: p) else { continue }
            let n = Double(a.n)
            let d0: Double = abs(a.sum[0] / n - m.mean.total)
            let d1: Double = abs(a.sum[1] / n - m.mean.vertical)
            let d2: Double = abs(a.sum[2] / n - m.mean.horizontal)
            d.append((d0 + d1 + d2) / 3)
        }
        guard !d.isEmpty else { return nil }
        d.sort()
        return (d[d.count / 2], d.count)
    }

    public var totalSamples: Int { cells.values.reduce(0) { $0 + $1.n } }
}
