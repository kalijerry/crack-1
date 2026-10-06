import Foundation

/// 现场校准：把「走过已知位置时测到的磁场」累积成网格地图。
///
/// 位置来自操作者在已知点位上点「到达 / 离开」记下的时间：点位之间按匀速直线插值，
/// 在点位上停留的时间用该点位置。多次校准可以反复 `addTrack`，每格用 Welford 在线算法累积。
/// 非线程安全。
public final class MagneticFieldBuilder {
    public let widthCm: Double
    public let heightCm: Double
    public let cellCm: Double
    public let cols: Int
    public let rows: Int
    public private(set) var sampleCount = 0

    private var counts: [Int]
    private var means: [Double]   // 每格 3 个：|B|, Bz, Bh
    private var m2s: [Double]

    /// 时间轴上的一个已知位置。
    public struct Waypoint {
        public var tMs: Int64
        public var position: Point2
        public init(tMs: Int64, position: Point2) {
            self.tMs = tMs
            self.position = position
        }
    }

    public struct TimedFeature {
        public var tMs: Int64
        public var feature: MagneticFeature
        public init(tMs: Int64, feature: MagneticFeature) {
            self.tMs = tMs
            self.feature = feature
        }
    }

    /// 可序列化的累积状态，用来存盘 / 恢复。
    public struct Snapshot: Codable {
        public var widthCm: Double
        public var heightCm: Double
        public var cellCm: Double
        public var counts: [Int]
        public var means: [Double]
        public var m2s: [Double]
    }

    public init(widthCm: Double, heightCm: Double, cellCm: Double = 50) {
        precondition(widthCm > 0 && heightCm > 0 && cellCm > 0)
        self.widthCm = widthCm
        self.heightCm = heightCm
        self.cellCm = cellCm
        cols = Int((widthCm / cellCm).rounded(.up))
        rows = Int((heightCm / cellCm).rounded(.up))
        counts = [Int](repeating: 0, count: cols * rows)
        means = [Double](repeating: 0, count: cols * rows * 3)
        m2s = means
    }

    /// 从存盘状态恢复。尺寸或数组长度对不上时返回 nil。
    public convenience init?(snapshot s: Snapshot) {
        guard s.widthCm > 0, s.heightCm > 0, s.cellCm > 0 else { return nil }
        self.init(widthCm: s.widthCm, heightCm: s.heightCm, cellCm: s.cellCm)
        guard s.counts.count == cols * rows, s.means.count == cols * rows * 3, s.m2s.count == s.means.count else { return nil }
        counts = s.counts
        means = s.means
        m2s = s.m2s
        sampleCount = s.counts.reduce(0, +)
    }

    public func snapshot() -> Snapshot {
        Snapshot(widthCm: widthCm, heightCm: heightCm, cellCm: cellCm, counts: counts, means: means, m2s: m2s)
    }

    public func reset() {
        counts = [Int](repeating: 0, count: cols * rows)
        means = [Double](repeating: 0, count: cols * rows * 3)
        m2s = means
        sampleCount = 0
    }

    /// 累积一个已知位置的特征。位置在地图外返回 false。
    @discardableResult
    public func add(position p: Point2, feature f: MagneticFeature) -> Bool {
        guard p.x >= 0, p.x <= widthCm, p.y >= 0, p.y <= heightCm,
              f.total.isFinite, f.vertical.isFinite, f.horizontal.isFinite else { return false }
        let i = min(Int(p.x / cellCm), cols - 1), j = min(Int(p.y / cellCm), rows - 1)
        let k = j * cols + i
        counts[k] += 1
        let n = Double(counts[k])
        let v = [f.total, f.vertical, f.horizontal]
        for c in 0..<3 {
            let d = v[c] - means[k * 3 + c]
            means[k * 3 + c] += d / n
            m2s[k * 3 + c] += d * (v[c] - means[k * 3 + c])
        }
        sampleCount += 1
        return true
    }

    /// 按时间插值出每个样本的位置并累积。返回实际用到的样本数。
    /// `waypoints` 必须按时间升序；第一个之前、最后一个之后的样本丢弃。
    @discardableResult
    public func addTrack(waypoints: [Waypoint], samples: [TimedFeature]) -> Int {
        guard waypoints.count >= 2 else { return 0 }
        var used = 0
        var seg = 0
        for s in samples.sorted(by: { $0.tMs < $1.tMs }) {
            if s.tMs < waypoints[0].tMs || s.tMs > waypoints[waypoints.count - 1].tMs { continue }
            while seg < waypoints.count - 2 && s.tMs > waypoints[seg + 1].tMs { seg += 1 }
            let a = waypoints[seg], b = waypoints[seg + 1]
            let span = Double(b.tMs - a.tMs)
            let t = span > 0 ? Double(s.tMs - a.tMs) / span : 0
            let p = Point2(a.position.x + (b.position.x - a.position.x) * t,
                           a.position.y + (b.position.y - a.position.y) * t)
            if add(position: p, feature: s.feature) { used += 1 }
        }
        return used
    }

    /// 有足够样本的格子数。
    public func validCells(minSamples: Int = 5) -> Int { counts.reduce(0) { $0 + ($1 >= minSamples ? 1 : 0) } }
    public var totalCells: Int { cols * rows }

    /// 生成地图。样本不足的格子用周围有效格子反距离加权补齐（半径内），补出来的格子标准差放大。
    public func build(minSamples: Int = 5, fillRadiusCm: Double = 150, sigmaFloorUT: Double = 0.5) -> MagneticFieldMap {
        var cells = [MagneticFeature?](repeating: nil, count: cols * rows)
        var sigmas = [MagneticFeature?](repeating: nil, count: cols * rows)
        func sigma(_ k: Int, _ c: Int) -> Double {
            let n = counts[k]
            return max(n > 1 ? (m2s[k * 3 + c] / Double(n - 1)).squareRoot() : 0, sigmaFloorUT)
        }
        for k in 0..<counts.count where counts[k] >= minSamples {
            cells[k] = MagneticFeature(total: means[k * 3], vertical: means[k * 3 + 1], horizontal: means[k * 3 + 2])
            sigmas[k] = MagneticFeature(total: sigma(k, 0), vertical: sigma(k, 1), horizontal: sigma(k, 2))
        }
        let reach = Int((fillRadiusCm / cellCm).rounded(.up))
        let original = cells
        let originalSig = sigmas
        for j in 0..<rows {
            for i in 0..<cols where original[j * cols + i] == nil {
                var wsum = 0.0
                var dmin = Double.infinity
                var m = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
                var s = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
                for dj in -reach...reach {
                    for di in -reach...reach {
                        let ii = i + di, jj = j + dj
                        guard ii >= 0, ii < cols, jj >= 0, jj < rows, let nm = original[jj * cols + ii] else { continue }
                        let d = Double(di * di + dj * dj).squareRoot() * cellCm
                        guard d > 0, d <= fillRadiusCm else { continue }
                        let w = 1 / (d * d)
                        dmin = min(dmin, d)
                        m = m + nm * w
                        s = s + originalSig[jj * cols + ii]! * w
                        wsum += w
                    }
                }
                if wsum > 0 {
                    cells[j * cols + i] = m * (1 / wsum)
                    // 补出来的格子不太可信，离真实数据越远越不可信：50 cm 处放大 1.5 倍，150 cm 处 2.5 倍
                    sigmas[j * cols + i] = s * ((1 + dmin / 100) / wsum)
                }
            }
        }
        return MagneticFieldMap(widthCm: widthCm, heightCm: heightCm, cellCm: cellCm, cells: cells, sigmas: sigmas)
    }
}

extension MagneticFieldMap {
    /// 写回地图 JSON 的 `magField` 节点（与 `StoreDataLoader.loadMagneticField` 对应）。
    public func jsonObject() -> [String: Any] {
        func enc(_ a: [MagneticFeature?]) -> [Any] {
            a.map { f in
                guard let f else { return NSNull() as Any }
                return [round3(f.total), round3(f.vertical), round3(f.horizontal)] as [Double]
            }
        }
        return ["cellCm": cellCm, "cols": cols, "rows": rows, "cells": enc(cells), "sigma": enc(sigmas)]
    }

    private func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

/// 一张地图的建图累积状态：磁场每格统计 + 蓝牙指纹累积 + 已经加进去的会话。
/// 增量建图时存盘，新会话只往上追加；旧会话删掉也不影响地图。
public struct MapBuildState: Codable {
    public var field: MagneticFieldBuilder.Snapshot
    public var ble: BLEFingerprintBuilder.State
    public var sessions: [String]

    public init(field: MagneticFieldBuilder.Snapshot, ble: BLEFingerprintBuilder.State, sessions: [String]) {
        self.field = field; self.ble = ble; self.sessions = sessions
    }
}
