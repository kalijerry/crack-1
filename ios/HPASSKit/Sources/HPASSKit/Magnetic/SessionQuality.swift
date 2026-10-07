import Foundation

/// 云端融合的质量筛选：融合不是把会话简单拼起来，而是只留可信的数据。
///
/// 每个建图会话按时间切成 10 秒一段，每段用两种独立的证据检查「轨迹位置对不对」：
///
/// 1. **价签**：强信号（≥ −78 dBm）的价签基本就在人旁边。把这段里所有强读数对应的价签位置（价签位置表里的货架）
///    和当时轨迹上的人位置比，距离中位数 > bleMaxMedianCm 说明轨迹偏了（实测偏航的一段：12～18 m；正常：约 2 m）。
///    价签表个别不准不影响（取中位）。
/// 2. **磁场**：和别的会话（已减掉各自整体偏移）在同一格的磁场比，这段的中位残差 > magMaxResidualUT 说明
///    位置对不上或者这段磁场有问题。没有重叠的段不判断。
///
/// 处理：
/// - 不合格的段连同前后各一段（漂移在被看出来之前就开始了）丢掉，磁场和蓝牙都不用；
/// - 能判断的段里不合格的超过 maxBadFraction，整个会话不用（轨迹整体不可信）；
/// - 太短的会话（路程 < minPathCm 或合格样本 < minGoodSamples）不用。
public final class SessionQualityGate {
    public struct Report: Codable {
        public var name: String
        public var kept: Bool
        /// 不用的原因（整个会话不用时）
        public var reason: String?
        public var windows: Int
        /// 能判断的段（有足够强读数或磁场重叠）
        public var judged: Int
        public var bad: Int
        /// 丢掉的段（含前后扩展），相对会话开始的秒数
        public var droppedSpans: [[Int]]
        /// 各段价签距离中位数的中位（m）、最差一段（m）
        public var bleMedianM: Double?
        public var bleWorstM: Double?
        /// 磁场残差：各段中位的中位（µT）、最差一段
        public var magResidualUT: Double?
        public var magWorstUT: Double?
        public var pathM: Double
    }

    public var windowMs: Int64 = 10_000
    public var bleMinRssi = -78.0
    public var bleMinReadings = 3
    public var bleMaxMedianCm = 700.0
    public var magMinSamples = 30
    public var magMaxResidualUT = 5.0
    public var maxBadFraction = 0.3
    public var minPathCm = 2000.0
    public var minGoodSamples = 300

    /// 价签 → 位置（价签位置表对上的货架中心）
    public let tagPositions: [String: Point2]

    public init(tagPositions: [String: Point2]) { self.tagPositions = tagPositions }

    /// 一个会话的结果：报告 + 保留哪些时刻（nil = 整个不用）
    public struct Verdict {
        public var report: Report
        public var keep: ((Int64) -> Bool)?
    }

    /// - track: 对齐后的轨迹；ble: 这个会话的蓝牙读数
    /// - mag: 这个会话每个样本（时间、位置、减掉整体偏移后的磁场）和「别的会话」的图（没有就 nil）
    public func evaluate(name: String, track: [(tMs: Int64, p: Point2)], ble: [BLESample],
                         mag: [(tMs: Int64, p: Point2, f: MagneticFeature)], others: MagneticFieldBuilder.Snapshot?,
                         othersBuilder: MagneticFieldBuilder?) -> Verdict {
        var path = 0.0
        for i in track.indices.dropFirst() {
            let d = track[i].p.distance(to: track[i - 1].p)
            if d < 300 { path += d }
        }
        guard let t0 = track.first?.tMs, let t1 = track.last?.tMs, t1 > t0 else {
            return Verdict(report: Report(name: name, kept: false, reason: "没有轨迹", windows: 0, judged: 0, bad: 0,
                                          droppedSpans: [], pathM: 0), keep: nil)
        }
        let wms = windowMs
        let nw = Int((t1 - t0) / wms) + 1
        func win(_ t: Int64) -> Int? { t < t0 || t > t1 ? nil : Int((t - t0) / wms) }

        // 1. 价签
        let times = track.map(\.tMs)
        func posAt(_ t: Int64) -> Point2? {
            var lo = 0, hi = times.count - 1
            guard t >= times[lo], t <= times[hi] else { return nil }
            while hi - lo > 1 { let m = (lo + hi) / 2; if times[m] <= t { lo = m } else { hi = m } }
            guard min(t - times[lo], times[hi] - t) <= 500 else { return nil }
            return track[t - times[lo] <= times[hi] - t ? lo : hi].p
        }
        var bleD = [[Double]](repeating: [], count: nw)
        for b in ble where b.rssi >= bleMinRssi {
            guard let tp = tagPositions[b.id], let w = win(b.tMs), let p = posAt(b.tMs) else { continue }
            bleD[w].append(p.distance(to: tp))
        }
        // 2. 磁场
        // 会话之间磁场整体水平差 10～16 µT（没有足够重叠时融合解不出来），所以先用全部重叠样本的中位差
        // 估出这个会话相对别的会话的整体偏移，减掉后再看每段的残差（比的是形状）
        func med(_ a: [Double]) -> Double { let s = a.sorted(); return s[s.count / 2] }
        var magR = [[Double]](repeating: [], count: nw)
        if let o = others, let ob = othersBuilder {
            var diffs: [(w: Int, d: Double)] = []
            for s in mag {
                guard let w = win(s.tMs), let k = ob.cellIndex(s.p), o.counts[k] >= 3 else { continue }
                diffs.append((w, s.f.total - o.means[k * 3]))
            }
            if diffs.count >= magMinSamples * 3 {
                let off = med(diffs.map(\.d))
                for x in diffs { magR[x.w].append(abs(x.d - off)) }
            }
        }
        var bad = [Bool](repeating: false, count: nw), judged = 0
        var bleMeds: [Double] = [], magMeds: [Double] = []
        for w in 0..<nw {
            var j = false
            if bleD[w].count >= bleMinReadings {
                let m = med(bleD[w]); bleMeds.append(m); j = true
                if m > bleMaxMedianCm { bad[w] = true }
            }
            if magR[w].count >= magMinSamples {
                let m = med(magR[w]); magMeds.append(m); j = true
                if m > magMaxResidualUT { bad[w] = true }
            }
            if j { judged += 1 }
        }
        let nBad = bad.filter { $0 }.count
        var drop = bad
        for w in 0..<nw where bad[w] { if w > 0 { drop[w - 1] = true }; if w + 1 < nw { drop[w + 1] = true } }
        var spans: [[Int]] = []
        var w = 0
        while w < nw {
            guard drop[w] else { w += 1; continue }
            var e = w
            while e + 1 < nw && drop[e + 1] { e += 1 }
            spans.append([w * Int(wms / 1000), (e + 1) * Int(wms / 1000)])
            w = e + 1
        }
        let goodSamples = mag.filter { win($0.tMs).map { !drop[$0] } ?? false }.count
        var reason: String?
        if path < minPathCm { reason = String(format: "太短（路程 %.0f m）", path / 100) }
        else if judged > 0 && Double(nBad) / Double(judged) > maxBadFraction {
            reason = "轨迹不可信：能判断的 \(judged) 段里 \(nBad) 段位置对不上（价签 / 磁场）"
        } else if goodSamples < minGoodSamples { reason = "合格样本太少（\(goodSamples) 个）" }
        let rep = Report(name: name, kept: reason == nil, reason: reason, windows: nw, judged: judged, bad: nBad,
                         droppedSpans: spans,
                         bleMedianM: bleMeds.isEmpty ? nil : (med(bleMeds) / 10).rounded() / 10,
                         bleWorstM: bleMeds.max().map { ($0 / 10).rounded() / 10 },
                         magResidualUT: magMeds.isEmpty ? nil : (med(magMeds) * 10).rounded() / 10,
                         magWorstUT: magMeds.max().map { ($0 * 10).rounded() / 10 },
                         pathM: (path / 100).rounded())
        guard reason == nil else { return Verdict(report: rep, keep: nil) }
        let keepFlags = drop.map { !$0 }
        return Verdict(report: rep, keep: { t in
            guard t >= t0, t <= t1 else { return false }
            return keepFlags[Int((t - t0) / wms)]
        })
    }
}
