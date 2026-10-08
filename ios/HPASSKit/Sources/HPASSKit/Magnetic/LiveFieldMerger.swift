import Foundation

/// 地图自愈：把实时定位记录里可信的磁场样本低权重并进建图得到的磁场图。
///
/// - 每个记录先和建图数据对齐整体偏移（共同格子 ≥ minCommonCells，没有重叠就不用；对齐后残差还大也不用），
///   再过一遍和建图会话同一套质量筛选（SessionQualityGate：价签 / 货架标签 / 磁场残差，坏段连同前后丢掉）；
/// - 建图数据没覆盖的格子（< 5 个样本）：实时数据够多（≥ fillMinSamples 个）才补，方差放大 liveSigmaInflate 倍；
/// - 建图数据已覆盖的格子：实时样本每个只算 weight（默认 0.3）个样本，且总权重不超过建图样本数的一半，
///   所以建图数据始终是主体、实时数据只是缓慢地修正；和建图均值差太多（> maxCellShiftUT）的格子不动，记为冲突。
public final class LiveFieldMerger {
    public struct RunInfo: Codable {
        public var name: String
        public var used: Bool
        public var reason: String?
        public var trust: LiveTrustReport
        /// 对齐时减掉的偏移（µT）：|B|、Bz、Bh
        public var offset: [Double]?
        public var commonCells: Int
        public var samplesUsed: Int
    }

    public struct Report: Codable {
        public var runsGiven: Int
        public var runsUsed: Int
        public var samplesUsed: Int
        public var cellsAdded: Int
        public var cellsUpdated: Int
        public var cellsConflict: Int
        /// 更新的格子里均值挪动的中位 / 最大（µT，|B|）
        public var medianShiftUT: Double?
        public var maxShiftUT: Double?
        public var runs: [RunInfo]
    }

    public var weight = 0.3
    public var maxLiveShare = 0.5
    public var fillMinSamples = 8
    public var liveSigmaInflate = 1.5
    public var minCommonCells = 20
    public var alignMinSurveyCount = 5
    public var alignMinLiveCount = 3
    public var maxAlignMadUT = 4.0
    public var maxCellShiftUT = 8.0

    public init() {}

    public func merge(survey: MagneticFieldBuilder, runs: [LiveRunSamples], gate: SessionQualityGate) -> (builder: MagneticFieldBuilder, report: Report) {
        let base = survey.snapshot()
        let acc = MagneticFieldBuilder(widthCm: base.widthCm, heightCm: base.heightCm, cellCm: base.cellCm)
        var infos: [RunInfo] = []
        func med(_ a: [Double]) -> Double { let s = a.sorted(); return s[s.count / 2] }
        for r in runs {
            var info = RunInfo(name: r.name, used: false, reason: r.report.reason, trust: r.report, offset: nil, commonCells: 0, samplesUsed: 0)
            defer { infos.append(info) }
            guard r.report.used, !r.samples.isEmpty else { continue }
            // 1. 对齐整体偏移
            let own = MagneticFieldBuilder(widthCm: base.widthCm, heightCm: base.heightCm, cellCm: base.cellCm)
            for x in r.samples { _ = own.add(position: x.p, feature: x.f) }
            let s = own.snapshot()
            var d: [[Double]] = [[], [], []]
            for k in s.counts.indices where s.counts[k] >= alignMinLiveCount && base.counts[k] >= alignMinSurveyCount {
                for c in 0..<3 { d[c].append(s.means[k * 3 + c] - base.means[k * 3 + c]) }
            }
            info.commonCells = d[0].count
            guard d[0].count >= minCommonCells else {
                info.reason = "和建图数据重叠不够（\(d[0].count) < \(minCommonCells) 个共同格子），整体偏移对不齐"
                continue
            }
            let off = d.map(med)
            info.offset = off.map { ($0 * 100).rounded() / 100 }
            let mad = med(d[0].map { abs($0 - off[0]) })
            guard mad <= maxAlignMadUT else {
                info.reason = String(format: "磁场对不上（对齐后各格残差中位 %.1f µT > %.1f）", mad, maxAlignMadUT)
                continue
            }
            let o = MagneticFeature(total: off[0], vertical: off[1], horizontal: off[2])
            let mag = r.samples.map { (tMs: $0.tMs, p: $0.p, f: $0.f - o) }
            // 2. 和建图会话同一套质量筛选
            let v = gate.evaluate(name: r.name, track: r.track, ble: r.ble, mag: mag, others: base, othersBuilder: survey, signs: r.signs)
            guard let keep = v.keep else {
                info.reason = "质量筛选不过：" + (v.report.reason ?? "")
                continue
            }
            var n = 0
            for x in mag where keep(x.tMs) { if acc.add(position: x.p, feature: x.f) { n += 1 } }
            info.samplesUsed = n
            info.used = n > 0
            if n == 0 { info.reason = "质量筛选后没有样本" }
        }
        // 3. 并进建图数据
        var out = base
        let live = acc.snapshot()
        var added = 0, updated = 0, conflict = 0
        var shifts: [Double] = []
        for k in live.counts.indices where live.counts[k] > 0 {
            let nl = live.counts[k], c0 = base.counts[k]
            if c0 >= alignMinSurveyCount {
                // 已覆盖：低权重、慢更新
                let nbEff = min(weight * Double(nl), maxLiveShare * Double(c0))
                guard nbEff >= 0.5 else { continue }
                var ok = true
                for c in 0..<3 where abs(live.means[k * 3 + c] - base.means[k * 3 + c]) > maxCellShiftUT { ok = false }
                guard ok else { conflict += 1; continue }
                let na = Double(c0), tot = na + nbEff
                for c in 0..<3 {
                    let i = k * 3 + c
                    let delta = live.means[i] - base.means[i]
                    out.means[i] = base.means[i] + delta * nbEff / tot
                    out.m2s[i] = base.m2s[i] + live.m2s[i] * (nbEff / Double(nl)) + delta * delta * na * nbEff / tot
                }
                out.counts[k] = c0 + Int(nbEff.rounded())
                shifts.append(abs(out.means[k * 3] - base.means[k * 3]))
                updated += 1
            } else if nl >= fillMinSamples {
                // 没覆盖：补上。计数设成 5（刚够出格子），方差按实时样本的离散程度放大
                let cnt = max(alignMinSurveyCount, Int((weight * Double(nl)).rounded()))
                for c in 0..<3 {
                    let i = k * 3 + c
                    let var1 = live.m2s[i] / Double(max(nl - 1, 1))
                    out.means[i] = live.means[i]
                    out.m2s[i] = var1 * liveSigmaInflate * liveSigmaInflate * Double(cnt - 1)
                }
                out.counts[k] = cnt
                added += 1
            }
        }
        let builder = MagneticFieldBuilder(snapshot: out) ?? survey
        let sorted = shifts.sorted()
        let rep = Report(runsGiven: runs.count, runsUsed: infos.filter(\.used).count, samplesUsed: infos.reduce(0) { $0 + $1.samplesUsed },
                         cellsAdded: added, cellsUpdated: updated, cellsConflict: conflict,
                         medianShiftUT: sorted.isEmpty ? nil : sorted[sorted.count / 2], maxShiftUT: sorted.last, runs: infos)
        return (builder, rep)
    }
}
