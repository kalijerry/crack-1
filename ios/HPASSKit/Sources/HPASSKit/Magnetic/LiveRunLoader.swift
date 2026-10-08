import Foundation

/// 地图自愈：把一次实时定位的记录变成「可信的磁场样本」，云端融合时低权重并入磁场图。
///
/// 实时定位的位置是定位算法自己估的，有对有错；直接拿来建图会把错位置的磁场写进地图（越用越糟）。
/// 所以只留**有独立证据撑腰**的路段：
///
/// 1. 定位自己有把握：置信度 ≥ minConfidence、不确定度 ≤ maxUncertaintyCm（一段里 ≥ minRowShare 的行都满足）；
/// 2. 位置没有突然跳（相邻行跳 > jumpCm 说明中途重定位过，前面那段位置也不可信，连同前后各一段丢掉）；
/// 3. 和价签位置表一致：每 3 秒一片，最强几片价签的范围圆（TagRangeFix.agreement）要罩住轨迹位置；
///    和货架标签（摄像头读到的）一致：读到标签时人离那段货架前不超过 signMaxCm；
/// 4. 只有「有把握」没有价签 / 标签佐证的段，只在紧挨着已被佐证的好段时（bridgeWindows 段内）才用；
/// 5. 磁力计样本的位置用可信的定位点插值；两点间隔大的地方用 ARKit 的相对位移（路程占比）插值，不用直线匀速。
///
/// 不合格的段连同前后各一段丢掉；能判断的段里坏的太多，整个记录不用。
public struct LiveTrustConfig {
    public var minConfidence = 0.7
    public var maxUncertaintyCm = 200.0
    /// 一段里满足上面两条的行至少占多少
    public var minRowShare = 0.8
    public var windowMs: Int64 = 10_000
    public var jumpCm = 400.0
    public var jumpMaxDtMs: Int64 = 1500
    /// 价签：分片长度、最少几片价签才算一次判断、范围圆罩住的比例下限
    public var tagSliceMs: Int64 = 3000
    public var tagMinTags = 3
    public var tagMinRssi = -85.0
    public var tagMinAgreement = 0.5
    public var signMaxCm = 300.0
    /// 没有佐证的段挨着好段多少段内算可信
    public var bridgeWindows = 2
    /// 能判断的段里坏的比例超过这个，整个记录不用
    public var maxBadFraction = 0.4
    /// 至少这么多可信的段（每段 10 秒）和路程
    public var minTrustedWindows = 4
    public var minTrustedPathCm = 1500.0
    /// 定位点间隔多大还能直线插值 / 用 ARKit 位移插值（毫秒）
    public var linearGapMs: Int64 = 1500
    public var arGapMs: Int64 = 4000
    public var minSpeedCmS = 30.0
    public init() {}
}

/// 定位轨迹的一行（track.csv：t_ms,x_cm,y_cm,unc_cm,conf,…）
public struct LiveTrackRow {
    public var tMs: Int64
    public var p: Point2
    public var uncCm: Double
    public var conf: Double
    public init(tMs: Int64, p: Point2, uncCm: Double, conf: Double) { self.tMs = tMs; self.p = p; self.uncCm = uncCm; self.conf = conf }
}

public struct LiveTrustReport: Codable {
    public var name: String
    public var used: Bool
    public var reason: String?
    public var windows: Int
    public var trustedWindows: Int
    /// 各原因丢了多少段
    public var rejectedWindows: [String: Int]
    /// 被价签 / 标签佐证的段数
    public var verifiedWindows: Int
    public var pathM: Double
    public var trustedPathM: Double
    public var samples: Int
    /// 丢掉的段，相对记录开始的秒数
    public var droppedSpans: [[Int]]
}

public struct LiveRunSamples {
    public var name: String
    public var samples: [(tMs: Int64, p: Point2, f: MagneticFeature)]
    /// 可信的定位轨迹（质量筛选用）
    public var track: [(tMs: Int64, p: Point2)]
    public var ble: [BLESample]
    public var signs: [(tMs: Int64, distanceTo: (Point2) -> Double)]
    public var report: LiveTrustReport
}

public enum LiveRunLoader {
    public enum Verdict: Equatable { case bad(String), good, unknown }

    /// 是不是实时定位记录（meta.live = true 且不是建图会话）
    public static func isLive(_ dir: URL) -> Bool {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (m["live"] as? Bool) == true && (m["survey"] as? Bool) != true
    }

    public static func loadTrack(_ dir: URL) -> [LiveTrackRow] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("track.csv"), encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let c = line.split(separator: ",", omittingEmptySubsequences: false)
            guard c.count >= 5, let t = Int64(c[0]), let x = Double(c[1]), let y = Double(c[2]),
                  let u = Double(c[3]), let cf = Double(c[4]) else { return nil }
            return LiveTrackRow(tMs: t, p: Point2(x, y), uncCm: u, conf: cf)
        }
    }

    // MARK: 可信度判断（纯函数，测试直接喂数据）

    public struct Trust {
        public var windowStartMs: Int64
        public var verdicts: [Verdict]          // 每段原始判断
        public var trusted: [Bool]              // 最终是否可信
        public var verified: [Bool]
        public var rejected: [String: Int]
        public var droppedSpans: [[Int]]
        public var badCount: Int
        public var judged: Int
    }

    public static func trust(track: [LiveTrackRow], ble: [BLESample], tagPositions: [String: Point2],
                             signs: [(tMs: Int64, distanceTo: (Point2) -> Double)] = [],
                             config c: LiveTrustConfig = LiveTrustConfig()) -> Trust? {
        guard let t0 = track.first?.tMs, let t1 = track.last?.tMs, t1 > t0 else { return nil }
        let nw = Int((t1 - t0) / c.windowMs) + 1
        func win(_ t: Int64) -> Int? { t < t0 || t > t1 ? nil : Int((t - t0) / c.windowMs) }
        func med(_ a: [Double]) -> Double { let s = a.sorted(); return s[s.count / 2] }
        let times = track.map(\.tMs)
        func posAt(_ t: Int64) -> Point2? {
            var lo = 0, hi = times.count - 1
            guard t >= times[lo], t <= times[hi] else { return nil }
            while hi - lo > 1 { let m = (lo + hi) / 2; if times[m] <= t { lo = m } else { hi = m } }
            guard min(t - times[lo], times[hi] - t) <= 1000 else { return nil }
            return track[t - times[lo] <= times[hi] - t ? lo : hi].p
        }
        // 1. 定位自己有把握
        var rows = [Int](repeating: 0, count: nw), good = [Int](repeating: 0, count: nw)
        for r in track {
            guard let w = win(r.tMs) else { continue }
            rows[w] += 1
            if r.conf >= c.minConfidence && r.uncCm <= c.maxUncertaintyCm { good[w] += 1 }
        }
        // 2. 跳变：相邻行跳得远 → 这一段标坏（前后各一段下面一起丢）
        var jump = [Bool](repeating: false, count: nw)
        for i in track.indices.dropFirst() {
            let a = track[i - 1], b = track[i]
            if b.tMs - a.tMs <= c.jumpMaxDtMs, a.p.distance(to: b.p) > c.jumpCm, let w = win(b.tMs) {
                jump[w] = true
            }
        }
        // 3. 价签：每 3 秒一片，最强几片罩住位置的比例
        var slices: [Int: [[String: [Double]]]] = [:]       // 窗 → 各片 → 价签 → 读数
        let per = Int(c.windowMs / c.tagSliceMs) + 1
        for b in ble where b.rssi >= c.tagMinRssi && tagPositions[b.id] != nil {
            guard let w = win(b.tMs) else { continue }
            let s = Int((b.tMs - t0 - Int64(w) * c.windowMs) / c.tagSliceMs)
            var arr = slices[w] ?? [[String: [Double]]](repeating: [:], count: per)
            arr[min(s, per - 1)][b.id, default: []].append(b.rssi)
            slices[w] = arr
        }
        var tagAgree = [[Double]](repeating: [], count: nw)
        for (w, arr) in slices {
            for (s, obs) in arr.enumerated() {
                let avg = obs.mapValues { $0.reduce(0, +) / Double($0.count) }
                let tags = BLEFingerprintMap.strongest(avg, k: 6, minRssi: c.tagMinRssi).compactMap { o in
                    tagPositions[o.0].map { (position: $0, rangeCm: BLEAssist.rangeCm(o.1)) }
                }
                // 一段 10 秒切成 3 秒一片，最后一片只有 1 秒：中心取这片实际覆盖的中间
                let len = min(c.tagSliceMs, c.windowMs - Int64(s) * c.tagSliceMs)
                guard tags.count >= c.tagMinTags, len > 0,
                      let p = posAt(t0 + Int64(w) * c.windowMs + Int64(s) * c.tagSliceMs + len / 2) else { continue }
                tagAgree[w].append(TagRangeFix.agreement(tags, at: p))
            }
        }
        // 4. 货架标签
        var signD = [[Double]](repeating: [], count: nw)
        for sg in signs { if let w = win(sg.tMs), let p = posAt(sg.tMs) { signD[w].append(sg.distanceTo(p)) } }
        // 5. 每段的判断
        var verdicts = [Verdict](repeating: .unknown, count: nw), verified = [Bool](repeating: false, count: nw)
        var judged = 0
        for w in 0..<nw {
            if rows[w] == 0 { verdicts[w] = .bad("没有定位点"); continue }
            if Double(good[w]) < c.minRowShare * Double(rows[w]) { verdicts[w] = .bad("定位没把握"); continue }
            if jump[w] { verdicts[w] = .bad("位置突然跳变"); continue }
            var v: Verdict = .unknown
            if !tagAgree[w].isEmpty {
                verified[w] = true; judged += 1
                if tagAgree[w].reduce(0, +) / Double(tagAgree[w].count) < c.tagMinAgreement { v = .bad("和价签对不上") } else { v = .good }
            }
            if !signD[w].isEmpty {
                if !verified[w] { judged += 1 }
                verified[w] = true
                if med(signD[w]) > c.signMaxCm { v = .bad("和货架标签对不上") } else if v == .unknown { v = .good }
            }
            verdicts[w] = v
        }
        // 6. 汇总：坏段前后各一段也丢；没佐证的段挨着好段才用
        var rejected: [String: Int] = [:]
        var trusted = [Bool](repeating: false, count: nw)
        var drop = [Bool](repeating: false, count: nw)
        var bad = 0
        for w in 0..<nw {
            if case .bad(let why) = verdicts[w] {
                bad += 1; rejected[why, default: 0] += 1
                // 没把握 / 没定位点的段本身就不用；价签 / 跳变 / 标签说明位置错了，前后也可能错
                if why != "定位没把握" && why != "没有定位点" {
                    for k in [w - 1, w + 1] where k >= 0 && k < nw { drop[k] = true }
                }
                drop[w] = true
            }
        }
        for w in 0..<nw where !drop[w] {
            switch verdicts[w] {
            case .good: trusted[w] = true
            case .unknown:
                let near = (max(0, w - c.bridgeWindows)...min(nw - 1, w + c.bridgeWindows))
                if near.contains(where: { verdicts[$0] == .good && !drop[$0] }) && !near.contains(where: { drop[$0] }) {
                    trusted[w] = true
                } else { rejected["没有价签 / 标签佐证", default: 0] += 1 }
            case .bad: break
            }
        }
        for w in 0..<nw where drop[w] && !{ if case .bad = verdicts[w] { return true } else { return false } }() {
            rejected["挨着坏段", default: 0] += 1
        }
        var spans: [[Int]] = []
        var w = 0
        let ws = Int(c.windowMs / 1000)
        while w < nw {
            guard !trusted[w] else { w += 1; continue }
            var e = w
            while e + 1 < nw && !trusted[e + 1] { e += 1 }
            spans.append([w * ws, (e + 1) * ws])
            w = e + 1
        }
        return Trust(windowStartMs: t0, verdicts: verdicts, trusted: trusted, verified: verified, rejected: rejected,
                     droppedSpans: spans, badCount: bad, judged: judged)
    }

    // MARK: 磁力计样本的位置

    /// 磁力计样本的位置：可信的定位点之间插值。间隔小直线插值，间隔大用 ARKit 路程占比插值。
    public static func position(at t: Int64, fixes: [LiveTrackRow], poses: [SurveySession.Pose],
                                config c: LiveTrustConfig = LiveTrustConfig()) -> Point2? {
        guard let f0 = fixes.first, let fl = fixes.last, t >= f0.tMs, t <= fl.tMs else { return nil }
        var lo = 0, hi = fixes.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if fixes[m].tMs <= t { lo = m } else { hi = m } }
        let a = fixes[lo], b = fixes[hi]
        if a.tMs == t { return a.p }
        let gap = b.tMs - a.tMs
        guard gap > 0 else { return a.p }
        let lin = Double(t - a.tMs) / Double(gap)
        func lerp(_ f: Double) -> Point2 { Point2(a.p.x + (b.p.x - a.p.x) * f, a.p.y + (b.p.y - a.p.y) * f) }
        if gap <= c.linearGapMs { return lerp(lin) }
        guard gap <= c.arGapMs else { return nil }
        // ARKit：a→b 之间都是正常跟踪，按 ARKit 走过的路程占比定位置
        var plo = 0, phi = poses.count
        while plo < phi { let m = (plo + phi) / 2; if poses[m].tMs < a.tMs { plo = m + 1 } else { phi = m } }
        var cum = 0.0, upTo = 0.0, total = 0.0
        var prev: SurveySession.Pose?
        var i = plo
        while i < poses.count, poses[i].tMs <= b.tMs {
            let p = poses[i]
            guard p.normal else { return lerp(lin) }
            if let q = prev { cum += p.a.distance(to: q.a) }
            if p.tMs <= t { upTo = cum }
            total = cum
            prev = p; i += 1
        }
        guard prev != nil, total > 1 else { return lerp(lin) }
        return lerp(min(max(upTo / total, 0), 1))
    }

    // MARK: 读一个记录

    public static func load(_ dir: URL, tagPositions: [String: Point2], shelfSigns: ShelfSigns? = nil,
                            config c: LiveTrustConfig = LiveTrustConfig()) -> LiveRunSamples {
        let name = dir.lastPathComponent
        func fail(_ why: String, windows: Int = 0) -> LiveRunSamples {
            LiveRunSamples(name: name, samples: [], track: [], ble: [], signs: [],
                           report: LiveTrustReport(name: name, used: false, reason: why, windows: windows, trustedWindows: 0,
                                                   rejectedWindows: [:], verifiedWindows: 0, pathM: 0, trustedPathM: 0,
                                                   samples: 0, droppedSpans: []))
        }
        let track = loadTrack(dir)
        guard track.count > 20 else { return fail("没有定位轨迹（track.csv）") }
        guard let s = try? SurveySessionLoader.load(dir, requireAnchors: false), s.poses.count > 30, !s.imu.isEmpty else { return fail("缺少惯导 / ARKit 位姿") }
        let ble = SurveySessionLoader.loadBLE(dir)
        var signDist: [(tMs: Int64, distanceTo: (Point2) -> Double)] = []
        if let sh = shelfSigns {
            signDist = SignSample.load(dir).compactMap { x in sh.sign(for: x.text).map { sg in (x.tMs, { sh.distance(sg, from: $0) }) } }
        }
        guard let tr = trust(track: track, ble: ble, tagPositions: tagPositions, signs: signDist, config: c) else { return fail("轨迹太短") }
        var path = 0.0
        for i in track.indices.dropFirst() { let d = track[i].p.distance(to: track[i - 1].p); if d < 300 { path += d } }
        let nw = tr.trusted.count
        func ok(_ t: Int64) -> Bool {
            guard t >= tr.windowStartMs else { return false }
            let w = Int((t - tr.windowStartMs) / c.windowMs)
            return w < nw && tr.trusted[w]
        }
        let fixes = track.filter { ok($0.tMs) && $0.conf >= c.minConfidence && $0.uncCm <= c.maxUncertaintyCm }
        var trustedPath = 0.0
        for i in fixes.indices.dropFirst() where fixes[i].tMs - fixes[i - 1].tMs <= c.linearGapMs {
            let d = fixes[i].p.distance(to: fixes[i - 1].p); if d < 300 { trustedPath += d }
        }
        let nTrusted = tr.trusted.filter { $0 }.count
        var rep = LiveTrustReport(name: name, used: false, reason: nil, windows: nw, trustedWindows: nTrusted,
                                  rejectedWindows: tr.rejected, verifiedWindows: tr.verified.filter { $0 }.count,
                                  pathM: path / 100, trustedPathM: trustedPath / 100, samples: 0, droppedSpans: tr.droppedSpans)
        if tr.judged > 0 && Double(tr.badCount) / Double(tr.judged) > c.maxBadFraction {
            rep.reason = "定位不可信：能判断的 \(tr.judged) 段里 \(tr.badCount) 段位置对不上"
            return LiveRunSamples(name: name, samples: [], track: [], ble: ble, signs: signDist, report: rep)
        }
        if nTrusted < c.minTrustedWindows || trustedPath < c.minTrustedPathCm {
            rep.reason = String(format: "可信的路段太少（%d 段、%.0f m）", nTrusted, trustedPath / 100)
            return LiveRunSamples(name: name, samples: [], track: [], ble: ble, signs: signDist, report: rep)
        }
        // 磁场特征 → 位置
        let b = SurveyMapBuilder(widthCm: 1, heightCm: 1, crosses: [])
        var srep = SurveySessionReport(name: name)
        let feats = b.features(s, &srep)
        let poses = s.poses.sorted { $0.tMs < $1.tMs }
        var out: [(tMs: Int64, p: Point2, f: MagneticFeature)] = []
        for (t, f) in feats where ok(t) {
            guard let p = position(at: t, fixes: fixes, poses: poses, config: c) else { continue }
            guard let q = position(at: t - 500, fixes: fixes, poses: poses, config: c),
                  p.distance(to: q) / 0.5 >= c.minSpeedCmS else { continue }      // 站着不动的不要
            out.append((t, p, f))
        }
        rep.samples = out.count
        rep.used = true
        return LiveRunSamples(name: name, samples: out, track: fixes.map { ($0.tMs, $0.p) }, ble: ble, signs: signDist, report: rep)
    }

}
