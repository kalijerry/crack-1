import Foundation

/// 一条蓝牙读数（价签广播）：时间、价签编号、信号强度（dBm）。
public struct BLESample {
    public var tMs: Int64
    public var id: String
    public var rssi: Double
    public init(tMs: Int64, id: String, rssi: Double) { self.tMs = tMs; self.id = id; self.rssi = rssi }
}

/// 蓝牙自动指纹：建图采集时位置已知（ARKit + 贴通道），顺便录下周围价签的信号强度，自动生成指纹，不用人工打点。
///
/// 存两样东西：
/// - **格子指纹**：每 2 m 一格，记每个价签在这格里的平均信号强度；
/// - **价签位置**：每个价签按「在哪儿听到它最响」加权估出大致位置。
/// 定位时取最近 3 秒听到的价签，两种方法都能给出位置的似然：格子指纹在采过的地方准，价签位置能外推到旁边没走过的地方。
/// 给地磁粒子滤波当「粗定位」：冷启动几秒内把粒子圈到对的区域，地磁再精修。
public struct BLEFingerprintMap: Codable {
    public struct Cell: Codable {
        public var x: Double
        public var y: Double
        /// 价签 → 平均信号强度
        public var tags: [String: Double]
        public var samples: Int
    }
    public struct Tag: Codable {
        public var x: Double
        public var y: Double
        /// 听到过的最强信号
        public var maxRssi: Double
        public var samples: Int
    }

    public var cellCm: Double
    public var cells: [Cell]
    public var tags: [String: Tag]

    public var isEmpty: Bool { cells.isEmpty }

    /// 用来匹配的观测：只取最强的 K 个、且强于 minRssi 的
    public static func strongest(_ obs: [String: Double], k: Int = 12, minRssi: Double = -95) -> [(String, Double)] {
        Array(obs.filter { $0.value >= minRssi }.sorted { $0.value > $1.value }.prefix(k))
    }

    /// 格子指纹的对数似然（越大越像）。观测到的强价签在这格里没出现过要扣分（越强扣得越多）。
    public func cellLogLikelihood(_ c: Cell, _ obs: [(String, Double)], sigma: Double = 7) -> Double {
        var ll = 0.0
        for (id, r) in obs {
            if let m = c.tags[id] {
                let d = r - m
                ll -= d * d / (2 * sigma * sigma)
            } else {
                let miss = max(0, r + 95)
                ll -= miss * miss / (2 * 10 * 10)
            }
        }
        return ll
    }

    /// 按格子指纹估位置：所有格子按似然做 softmax，取加权平均（只看最好的几格附近）。
    public func estimateByCells(_ obsAll: [String: Double]) -> (position: Point2, spreadCm: Double)? {
        let obs = Self.strongest(obsAll)
        guard obs.count >= 3, !cells.isEmpty else { return nil }
        var scored = cells.filter { $0.samples >= 5 }.map { ($0, cellLogLikelihood($0, obs)) }
        guard let best = scored.map(\.1).max() else { return nil }
        scored = scored.filter { $0.1 > best - 6 }
        var w = 0.0, x = 0.0, y = 0.0
        for (c, ll) in scored { let e = exp(ll - best); w += e; x += e * c.x; y += e * c.y }
        let p = Point2(x / w, y / w)
        var v = 0.0
        for (c, ll) in scored { let e = exp(ll - best); v += e * Point2(c.x, c.y).distance(to: p) * Point2(c.x, c.y).distance(to: p) }
        return (p, (v / w).squareRoot())
    }

    /// 按价签位置估：听到的最强几个价签的位置，按信号强度加权平均。
    public func estimateByTags(_ obsAll: [String: Double], k: Int = 6) -> (position: Point2, spreadCm: Double)? {
        let obs = Self.strongest(obsAll, k: k).compactMap { o in tags[o.0].map { ($0, o.1) } }
        guard obs.count >= 2 else { return nil }
        var w = 0.0, x = 0.0, y = 0.0
        for (t, r) in obs { let e = pow(10, (r + 100) / 10); w += e; x += e * t.x; y += e * t.y }
        let p = Point2(x / w, y / w)
        var v = 0.0
        for (t, r) in obs { let e = pow(10, (r + 100) / 10); let d = Point2(t.x, t.y).distance(to: p); v += e * d * d }
        return (p, max((v / w).squareRoot(), 200))
    }

    /// 合起来的粗定位：两种都有时按各自的离散度加权
    public func estimate(_ obs: [String: Double]) -> (position: Point2, spreadCm: Double)? {
        let a = estimateByCells(obs), b = estimateByTags(obs)
        switch (a, b) {
        case let (a?, b?):
            let wa = 1 / max(a.spreadCm, 100), wb = 1 / max(b.spreadCm, 100)
            let p = Point2((a.position.x * wa + b.position.x * wb) / (wa + wb), (a.position.y * wa + b.position.y * wb) / (wa + wb))
            return (p, max(min(a.spreadCm, b.spreadCm), a.position.distance(to: b.position) / 2))
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

/// 从建图采集会话攒蓝牙指纹（位置用 SurveyMapBuilder 对齐、贴好通道的轨迹）。
public final class BLEFingerprintBuilder {
    public let cellCm: Double
    private var cells: [Int: (x: Double, y: Double, n: Int, tags: [String: (n: Int, sum: Double)])] = [:]
    private var tagAcc: [String: (w: Double, x: Double, y: Double, maxR: Double, n: Int)] = [:]
    /// 每个价签「听到它的位置」的二阶矩（强信号加权）：固定的价签只在一小片区域里听得到，
    /// 跟着人走的手机、手表到哪儿都一样响，范围会大得离谱 → 不当价签用
    private var tagSpread: [String: (w: Double, xx: Double, yy: Double)] = [:]
    private let cols: Int
    /// 价签名单（门店系统导出的价签 ID）。给了就只收名单里的
    public var whitelist: Set<String>?
    /// 听到范围（强信号位置的标准差）超过这个（cm）就认为不是固定设备
    public var maxSpreadCm = 1500.0

    /// 累积状态（增量建图时存盘，下次接着加）
    public struct State: Codable {
        public struct CellAcc: Codable { var x: Double; var y: Double; var n: Int; var tagN: [String: Int]; var tagSum: [String: Double] }
        public struct TagAcc: Codable { var w: Double; var x: Double; var y: Double; var maxR: Double; var n: Int }
        var cellCm: Double
        var cols: Int
        var cells: [Int: CellAcc]
        var tags: [String: TagAcc]
        var spread: [String: [Double]]?
    }

    public func state() -> State {
        State(cellCm: cellCm, cols: cols,
              cells: cells.mapValues { c in .init(x: c.x, y: c.y, n: c.n, tagN: c.tags.mapValues(\.n), tagSum: c.tags.mapValues(\.sum)) },
              tags: tagAcc.mapValues { .init(w: $0.w, x: $0.x, y: $0.y, maxR: $0.maxR, n: $0.n) },
              spread: tagSpread.mapValues { [$0.w, $0.xx, $0.yy] })
    }

    public init(state s: State) {
        cellCm = s.cellCm
        cols = s.cols
        cells = s.cells.mapValues { c in
            (c.x, c.y, c.n, Dictionary(uniqueKeysWithValues: c.tagN.map { ($0.key, (n: $0.value, sum: c.tagSum[$0.key] ?? 0)) }))
        }
        tagAcc = s.tags.mapValues { ($0.w, $0.x, $0.y, $0.maxR, $0.n) }
        tagSpread = (s.spread ?? [:]).compactMapValues { $0.count == 3 ? ($0[0], $0[1], $0[2]) : nil }
    }

    public init(widthCm: Double, heightCm: Double, cellCm: Double = 200) {
        self.cellCm = cellCm
        cols = max(Int((widthCm / cellCm).rounded(.up)), 1)
    }

    /// 只要价签读数，强度在 −100 dBm 以上
    public func add(position p: Point2, id: String, rssi: Double) {
        guard rssi >= -100, rssi < 0, p.x >= 0, p.y >= 0 else { return }
        if let wl = whitelist, !wl.contains(id) { return }
        let i = Int(p.x / cellCm), j = Int(p.y / cellCm)
        let k = j * cols + i
        var c = cells[k] ?? ((Double(i) + 0.5) * cellCm, (Double(j) + 0.5) * cellCm, 0, [:])
        c.n += 1
        var t = c.tags[id] ?? (0, 0)
        t.n += 1; t.sum += rssi
        c.tags[id] = t
        cells[k] = c
        // 价签位置：强信号权重大（-60 dBm 比 -90 dBm 大 1000 倍）
        let w = pow(10, (rssi + 100) / 10)
        var a = tagAcc[id] ?? (0, 0, 0, -200, 0)
        a.w += w; a.x += w * p.x; a.y += w * p.y; a.maxR = max(a.maxR, rssi); a.n += 1
        tagAcc[id] = a
        if rssi >= -85 {
            var sp = tagSpread[id] ?? (0, 0, 0)
            sp.w += 1; sp.xx += p.x * p.x; sp.yy += p.y * p.y
            tagSpread[id] = sp
        }
    }

    /// 一个会话：蓝牙读数按时间插值到轨迹上（离最近的轨迹点超过 0.5 s 的不要）
    public func add(samples: [BLESample], track: [(tMs: Int64, p: Point2)]) -> Int {
        guard track.count >= 2 else { return 0 }
        let times = track.map(\.tMs)
        var used = 0
        for s in samples {
            var lo = 0, hi = times.count - 1
            guard s.tMs >= times[lo] - 500, s.tMs <= times[hi] + 500 else { continue }
            while hi - lo > 1 { let m = (lo + hi) / 2; if times[m] <= s.tMs { lo = m } else { hi = m } }
            let a = track[lo], b = track[hi]
            guard min(abs(s.tMs - a.tMs), abs(s.tMs - b.tMs)) <= 500 else { continue }
            let f = b.tMs > a.tMs ? min(max(Double(s.tMs - a.tMs) / Double(b.tMs - a.tMs), 0), 1) : 0
            add(position: Point2(a.p.x + (b.p.x - a.p.x) * f, a.p.y + (b.p.y - a.p.y) * f), id: s.id, rssi: s.rssi)
            used += 1
        }
        return used
    }

    public var sampleCount: Int { cells.values.reduce(0) { $0 + $1.n } }

    /// 强信号（≥ −85 dBm）出现位置的标准差（cm）；强读数少于 5 次不判断
    public func spreadCm(_ id: String) -> Double? {
        guard let sp = tagSpread[id], sp.w >= 5, let a = tagAcc[id] else { return nil }
        // 用同一批强读数的均值近似：E[x²] − E[x]²（均值用加权中心，偏差不大）
        let mx = a.x / a.w, my = a.y / a.w
        let vx = max(sp.xx / sp.w - mx * mx, 0), vy = max(sp.yy / sp.w - my * my, 0)
        return (vx + vy).squareRoot()
    }

    /// 被当成「不是固定设备」丢掉的
    public var rejectedMoving: [String] { tagAcc.keys.filter { (spreadCm($0) ?? 0) > maxSpreadCm } }

    /// 从文本里找价签 ID（XX-XX-XX-XX），给名单用：CSV、TXT、门店系统导出的表格另存为 CSV 都行
    public static func parseIdList(_ text: String) -> Set<String> {
        var out = Set<String>()
        let pattern = try! NSRegularExpression(pattern: "\\b[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}\\b")
        let ns = text as NSString
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.insert(ns.substring(with: m.range).uppercased())
        }
        return out
    }

    public func build() -> BLEFingerprintMap {
        let cs = cells.values.map { c in
            BLEFingerprintMap.Cell(x: c.x, y: c.y, tags: c.tags.mapValues { $0.sum / Double($0.n) }, samples: c.n)
        }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        var tags: [String: BLEFingerprintMap.Tag] = [:]
        for (id, a) in tagAcc where a.w > 0 {
            if let sp = spreadCm(id), sp > maxSpreadCm { continue }   // 到哪儿都听得到：多半是跟着人走的设备
            tags[id] = .init(x: a.x / a.w, y: a.y / a.w, maxRssi: a.maxR, samples: a.n)
        }
        return BLEFingerprintMap(cellCm: cellCm, cells: cs, tags: tags)
    }
}

extension SurveySessionLoader {
    /// 读会话里的 ble.csv（只要有价签编号的行）。没有这个文件返回空。
    public static func loadBLE(_ dir: URL) -> [BLESample] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("ble.csv"), encoding: .utf8) else { return [] }
        var out: [BLESample] = []
        for line in text.split(separator: "\n").dropFirst() {
            let r = line.split(separator: ",", omittingEmptySubsequences: false)
            guard r.count >= 4, let t = Int64(r[0]), !r[2].isEmpty, let rssi = Double(r[3]) else { continue }
            out.append(BLESample(tMs: t, id: String(r[2]), rssi: rssi))
        }
        return out
    }
}
