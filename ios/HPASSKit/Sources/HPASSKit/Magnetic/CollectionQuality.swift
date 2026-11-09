import Foundation

/// 采集时的质量打分：边采边判断，差的段直接剔除，太差就停。
///
/// 和云端的 SessionQualityGate 用同一套标准（同一个 10 秒一段、同样的阈值，直接从 gate 读）：
/// - **轨迹对不对**：强信号标签离轨迹的距离中位 > bleMaxMedianCm、读到的货架标签离轨迹 > signMaxCm、
///   磁场和已有磁场图（减掉整体偏移后）的残差中位 > magMaxResidualUT，任何一条成立这段就不合格；
///   另外长按 / 蓝牙 / 标签修正一次跳了 > jumpCm，说明修正前那段轨迹已经偏了，也不合格。
/// - **数据本身好不好**（手机上才看得到，云端只能事后猜）：ARKit 跟踪受限、走太快、IMU 采样率低、
///   磁场强度不正常（附近有磁铁、磁吸壳，或者传感器饱和）。按占这段时间的比例扣分。
///
/// 每段 0～100 分，< badScore 算差段。处理和云端一样：差段连同前后各一段丢掉；
/// 整个会话：走得太短、差段比例 > maxBadFraction、或者平均分 < rejectScore，整个不用（不上传、不进磁场图）。
/// 采集中最近连续 stopStreak 段都差、或者最近 liveWindows 段平均 < stopScore，就该自动停止。
///
/// 结果写在会话目录的 quality.json（`Summary`），读会话时 `SurveySessionLoader` 按它丢段 / 跳过整个会话。
public final class CollectionQualityMonitor {

    public enum Issue: String, Codable, CaseIterable {
        case tracking, tooFast, lowRate, magAnomaly, tagMismatch, signMismatch, magMismatch, jump

        /// 给采集的人看的提示
        public var hint: String {
            switch self {
            case .tracking: return "相机跟丢了：摄像头朝前，别挡住"
            case .tooFast: return "走太快了，放慢一点"
            case .lowRate: return "传感器采样率低：保持 App 在前台"
            case .magAnomaly: return "磁场异常：拿掉磁吸壳 / 支架，离开磁铁"
            case .tagMismatch: return "轨迹和蓝牙标签对不上：长按地图修正位置"
            case .signMismatch: return "轨迹和货架标签对不上：长按地图修正位置"
            case .magMismatch: return "磁场和已有地图对不上：长按地图修正位置"
            case .jump: return "轨迹漂了（修正跳得很远）：多修正几次"
            }
        }
    }

    /// 一段（windowMs）的结果
    public struct Window: Codable, Equatable {
        public var index: Int
        public var startMs: Int64
        public var score: Int
        public var bad: Bool
        /// 这段算不算分（走动了，或者本身就差）。站着不动的好段不算，免得把平均分拉高
        public var counted: Bool
        public var issues: [Issue]
        public var pathM: Double
        public var bleMedianM: Double?
        public var magResidualUT: Double?
    }

    public enum Level: String, Codable { case good, fair, poor }

    /// 采集中的实时状态
    public struct Live: Equatable {
        /// 最近几段的平均分（还没有算分的段时为 nil）
        public var score: Int?
        public var level: Level
        /// 正在采的这一段的问题（数据还太少时用上一段的）
        public var issues: [Issue]
        /// 最近连续差段数
        public var badStreak: Int
        /// 该自动停止的原因（nil = 不用停）
        public var stopReason: String?
    }

    /// 整个会话的结果（写进 quality.json）
    public struct Summary: Codable {
        public var version = 1
        public var score: Int
        /// 好 / 一般 / 差
        public var grade: String
        public var kept: Bool
        /// 整个不用的原因
        public var reason: String?
        public var windows: Int
        public var counted: Int
        public var bad: Int
        /// 丢掉的段（含前后扩展），相对会话开始的秒数
        public var droppedSpans: [[Int]]
        /// 同上，绝对时间（毫秒，和 imu.csv 的 t_ms 同一个时钟）
        public var droppedSpansMs: [[Int64]]
        public var pathM: Double
        public var autoStopped: Bool
        public var stopReason: String?
        /// 各种问题出现在几段里
        public var issueCounts: [String: Int]
        public var windowList: [Window]
    }

    // MARK: 参数

    /// 云端同一套阈值（段长、标签 / 磁场 / 货架标签、差段比例、最短路程）
    public let gate: SessionQualityGate
    public var maxSpeedMS = 1.6
    public var minImuHz = 50
    /// 磁场强度正常范围（µT）：地磁 25～65，室内钢货架附近会偏，超出这个范围基本是磁铁或传感器饱和
    public var magRangeUT: ClosedRange<Double> = 10...120
    /// 一次修正跳这么远（cm）说明之前那段轨迹偏了
    public var jumpCm = 500.0
    public var badScore = 50
    public var rejectScore = 50
    public var stopScore = 35
    public var stopStreak = 3
    public var liveWindows = 6
    /// 一段里走了这么远（cm）才算「走动了」
    public var movingCm = 100.0

    /// 标签 → 位置（标签位置表）
    public let tagPositions: [String: Point2]

    public init(gate: SessionQualityGate = SessionQualityGate(tagPositions: [:]), tagPositions: [String: Point2]? = nil) {
        self.gate = gate
        self.tagPositions = tagPositions ?? gate.tagPositions
    }

    // MARK: 状态

    private struct Acc {
        var poses = 0, limited = 0, fast = 0, rateN = 0, rateLow = 0, magN = 0, magAnom = 0
        var bleD: [Double] = [], signD: [Double] = [], magDiffs: [Double] = []
        var maxJump = 0.0
        var path = 0.0
    }

    private var t0: Int64?
    private var cur = Acc()
    private var curIndex = 0
    private var lastP: Point2?
    private var lastMagMs: Int64?
    private var allMagDiffs: [Double] = []
    private var totalPath = 0.0
    public private(set) var windows: [Window] = []
    public private(set) var live = Live(score: nil, level: .good, issues: [], badStreak: 0, stopReason: nil)
    private var stopReason: String?

    private var wms: Int64 { gate.windowMs }

    // MARK: 输入

    /// ARKit 位姿（采集对齐之后每帧一次）。position：地图坐标（跟踪受限时 nil）
    public func pose(tMs: Int64, position: Point2?, trackingOK: Bool, speedMS: Double, imuHz: Int) {
        advance(tMs)
        cur.poses += 1
        if !trackingOK || position == nil { cur.limited += 1 }
        if speedMS > maxSpeedMS { cur.fast += 1 }
        if imuHz > 0 { cur.rateN += 1; if imuHz < minImuHz { cur.rateLow += 1 } }
        if let p = position, trackingOK {
            if let q = lastP {
                let d = p.distance(to: q)
                if d < 300 { cur.path += d; totalPath += d }
            }
            lastP = p
        }
        refreshLive(tMs: tMs)
    }

    /// 磁场强度（µT，校准后的模长）。expected：已有磁场图在当前位置的强度（没有图 / 图外为 nil）。
    /// 内部按 10 Hz 抽样。
    public func mag(tMs: Int64, totalUT: Double, expectedUT: Double?) {
        if let l = lastMagMs, tMs - l < 100 { return }
        lastMagMs = tMs
        advance(tMs)
        cur.magN += 1
        if !magRangeUT.contains(totalUT) { cur.magAnom += 1; return }
        if let e = expectedUT {
            let d = totalUT - e
            cur.magDiffs.append(d)
            allMagDiffs.append(d)
        }
    }

    /// 一条蓝牙读数（用当前位置比）
    public func ble(tMs: Int64, id: String, rssi: Double) {
        guard rssi >= gate.bleMinRssi, let tp = tagPositions[id], let p = lastP else { return }
        advance(tMs)
        cur.bleD.append(p.distance(to: tp))
    }

    /// 读到货架标签：当前位置离那段货架前的区域多远（cm）
    public func sign(tMs: Int64, distanceCm: Double) {
        advance(tMs)
        cur.signD.append(distanceCm)
    }

    /// 位置被修正（长按 / 蓝牙 / 货架标签 / 视觉重定位）：跳了多远（cm）
    public func correction(tMs: Int64, jumpCm d: Double) {
        advance(tMs)
        cur.maxJump = max(cur.maxJump, d)
        lastP = nil          // 修正后的位置不连到修正前，免得把跳变算成路程
    }

    /// 采集被打断（重新定起点）：位置不连上
    public func breakTrack() { lastP = nil }

    // MARK: 结果

    /// 结束：把最后一段也算进去，出整个会话的结果
    public func finish(tMs: Int64, autoStopped: Bool = false) -> Summary {
        advance(tMs)
        if t0 != nil, cur.poses > 0 { close() }
        let counted = windows.filter(\.counted)
        let bad = counted.filter(\.bad).count
        let score = counted.isEmpty ? 0 : Int((Double(counted.map(\.score).reduce(0, +)) / Double(counted.count)).rounded())
        // 差段连同前后各一段丢掉（和云端一样：漂移在被看出来之前就开始了）
        var drop = windows.map(\.bad)
        for (i, w) in windows.enumerated() where w.bad {
            if i > 0 { drop[i - 1] = true }
            if i + 1 < drop.count { drop[i + 1] = true }
        }
        var spans: [[Int]] = [], spansMs: [[Int64]] = []
        var i = 0
        while i < drop.count {
            guard drop[i] else { i += 1; continue }
            var e = i
            while e + 1 < drop.count && drop[e + 1] { e += 1 }
            spansMs.append([windows[i].startMs, windows[e].startMs + wms])
            if let s = t0 { spans.append([Int((windows[i].startMs - s) / 1000), Int((windows[e].startMs + wms - s) / 1000)]) }
            i = e + 1
        }
        var reason: String?
        if counted.isEmpty {
            reason = "没有有效数据（没对齐地图就结束了，或者一直没走动）"
        } else if totalPath < gate.minPathCm {
            reason = String(format: "太短（路程 %.0f m）", totalPath / 100)
        } else if Double(bad) / Double(counted.count) > gate.maxBadFraction {
            reason = "质量差的段太多：\(counted.count) 段里 \(bad) 段不合格（\(Self.topIssues(counted.filter(\.bad)))）"
        } else if score < rejectScore {
            reason = "质量分太低（\(score) 分）"
        }
        var counts: [String: Int] = [:]
        for w in windows { for x in w.issues { counts[x.rawValue, default: 0] += 1 } }
        return Summary(score: score, grade: Self.grade(score), kept: reason == nil, reason: reason,
                       windows: windows.count, counted: counted.count, bad: bad,
                       droppedSpans: spans, droppedSpansMs: spansMs, pathM: (totalPath / 100).rounded(),
                       autoStopped: autoStopped, stopReason: stopReason, issueCounts: counts, windowList: windows)
    }

    public static func grade(_ score: Int) -> String { score >= 80 ? "好" : score >= 60 ? "一般" : "差" }
    public static func level(_ score: Int) -> Level { score >= 80 ? .good : score >= 60 ? .fair : .poor }

    /// 出现最多的几种问题（给人看）
    static func topIssues(_ ws: [Window]) -> String {
        var c: [Issue: Int] = [:]
        for w in ws { for x in w.issues { c[x, default: 0] += 1 } }
        let top = c.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }.prefix(2)
        return top.isEmpty ? "轨迹不可信" : top.map { $0.key.hint.components(separatedBy: "：").first ?? $0.key.hint }.joined(separator: "、")
    }

    // MARK: 内部

    private func advance(_ t: Int64) {
        guard let s = t0 else { t0 = t; return }
        let idx = Int((t - s) / wms)
        while curIndex < idx {
            close()
        }
    }

    private func close() {
        guard let s = t0 else { return }
        let w = evaluate(cur, index: curIndex, startMs: s + Int64(curIndex) * wms, final: true)
        windows.append(w)
        cur = Acc()
        curIndex += 1
        let counted = windows.filter(\.counted)
        var streak = 0
        for x in counted.reversed() { if x.bad { streak += 1 } else { break } }
        let recent = counted.suffix(liveWindows)
        let avg = recent.isEmpty ? nil : Int((Double(recent.map(\.score).reduce(0, +)) / Double(recent.count)).rounded())
        if stopReason == nil {
            let wsec = Int(wms / 1000)
            if streak >= stopStreak {
                stopReason = "连续 \(streak * wsec) 秒采集质量太差（\(Self.topIssues(Array(counted.suffix(streak))))），已自动停止"
            } else if let a = avg, recent.count >= liveWindows, a < stopScore {
                stopReason = "最近 \(recent.count * wsec) 秒质量分只有 \(a)（\(Self.topIssues(recent.filter(\.bad)))），已自动停止"
            }
        }
        live.score = avg
        live.badStreak = streak
        live.stopReason = stopReason
        refreshLive()
    }

    private var lastLiveMs: Int64 = .min

    private func refreshLive(tMs: Int64? = nil) {
        // 位姿 60 Hz，实时提示每秒最多算一次
        if let t = tMs {
            guard lastLiveMs == .min || t - lastLiveMs >= 1000 else { return }
            lastLiveMs = t
        }
        // 当前这段数据够 2 秒就看它，否则看上一段
        let enough = cur.poses >= 20
        let issues = enough ? evaluate(cur, index: curIndex, startMs: 0, final: false).issues : (windows.last?.issues ?? [])
        live.issues = issues
        if let s = live.score { live.level = Self.level(s) } else { live.level = issues.isEmpty ? .good : .fair }
    }

    private func evaluate(_ a: Acc, index: Int, startMs: Int64, final: Bool) -> Window {
        func med(_ x: [Double]) -> Double { let s = x.sorted(); return s[s.count / 2] }
        var issues: [Issue] = []
        var s = 100.0
        let n = Double(max(a.poses, 1))
        let limF = a.poses == 0 ? 0 : Double(a.limited) / n
        let fastF = Double(a.fast) / n
        let lowF = a.rateN == 0 ? 0 : Double(a.rateLow) / Double(a.rateN)
        let anomF = a.magN == 0 ? 0 : Double(a.magAnom) / Double(a.magN)
        s -= 70 * limF + 50 * fastF + 40 * lowF + 60 * anomF
        if limF > 0.2 { issues.append(.tracking) }
        if fastF > 0.3 { issues.append(.tooFast) }
        if lowF > 0.5 { issues.append(.lowRate) }
        if anomF > 0.2 { issues.append(.magAnomaly) }
        // 轨迹位置对不对（和云端同样的阈值）
        var bleM: Double?, magM: Double?
        if a.bleD.count >= gate.bleMinReadings {
            let m = med(a.bleD); bleM = (m / 10).rounded() / 10
            if m > gate.bleMaxMedianCm { issues.append(.tagMismatch) }
        }
        if !a.signD.isEmpty, med(a.signD) > gate.signMaxCm { issues.append(.signMismatch) }
        // 磁场：整体偏移用到目前为止所有样本的中位差估（和云端一样只看形状），样本够了才判断
        // （实时提示时不算：要把所有样本排一遍；段结束时再判断）
        if final, a.magDiffs.count >= gate.magMinSamples, allMagDiffs.count >= gate.magMinSamples * 3 {
            let off = med(allMagDiffs)
            let m = med(a.magDiffs.map { abs($0 - off) }); magM = (m * 10).rounded() / 10
            if m > gate.magMaxResidualUT { issues.append(.magMismatch) }
        }
        if a.maxJump > jumpCm { issues.append(.jump) }
        if issues.contains(where: { [Issue.tagMismatch, .signMismatch, .magMismatch, .jump].contains($0) }) { s = min(s, 20) }
        let score = Int(max(0, min(100, s)).rounded())
        let bad = a.poses > 0 && score < badScore
        return Window(index: index, startMs: startMs, score: score, bad: bad,
                      counted: bad || a.path >= movingCm, issues: issues,
                      pathM: (a.path / 10).rounded() / 10, bleMedianM: bleM, magResidualUT: magM)
    }
}

extension CollectionQualityMonitor.Summary {
    /// 读会话目录里的 quality.json（没有 = 旧会话或采集时没打分，返回 nil）
    public static func load(_ dir: URL) -> CollectionQualityMonitor.Summary? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("quality.json")) else { return nil }
        return try? JSONDecoder().decode(CollectionQualityMonitor.Summary.self, from: d)
    }

    public func write(to dir: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: dir.appendingPathComponent("quality.json"))
    }
}
