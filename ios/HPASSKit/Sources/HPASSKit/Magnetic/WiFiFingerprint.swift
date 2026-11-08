import Foundation

/// 一条 Wi-Fi 读数（wifi.csv 的一行，格式见 docs/data-format.md）：扫描上报时刻、AP 的 BSSID、信号强度（dBm）、频率（MHz）。
/// 只有 Android 能扫 Wi-Fi（iOS 第三方 App 拿不到），定位只在评估加 `--wifi` 时用。
public struct WiFiSample: Equatable {
    public var tMs: Int64
    public var bssid: String
    public var rssi: Double
    public var freqMHz: Int
    public init(tMs: Int64, bssid: String, rssi: Double, freqMHz: Int = 0) {
        self.tMs = tMs; self.bssid = bssid; self.rssi = rssi; self.freqMHz = freqMHz
    }
}

/// 一次 Wi-Fi 扫描：同一个上报时刻的所有 AP。
public struct WiFiScan: Equatable {
    public var tMs: Int64
    /// BSSID → dBm（同一次扫描里同一个 AP 出现多次取最强的）
    public var rssi: [String: Double]
    public init(tMs: Int64, rssi: [String: Double]) { self.tMs = tMs; self.rssi = rssi }

    /// 读数按上报时刻分组成扫描，按时间排序
    public static func group(_ samples: [WiFiSample]) -> [WiFiScan] {
        var by: [Int64: [String: Double]] = [:]
        for s in samples { by[s.tMs, default: [:]][s.bssid] = max(by[s.tMs]?[s.bssid] ?? -.infinity, s.rssi) }
        return by.keys.sorted().map { WiFiScan(tMs: $0, rssi: by[$0]!) }
    }
}

extension SurveySessionLoader {
    /// 读会话里的 wifi.csv（t_ms,bssid,rssi,freq）。没有这个文件返回空；坏行跳过。
    public static func loadWiFi(_ dir: URL) -> [WiFiSample] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("wifi.csv"), encoding: .utf8) else { return [] }
        var out: [WiFiSample] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let r = line.split(separator: ",", omittingEmptySubsequences: false)
            guard r.count >= 3, let t = Int64(r[0].trimmingCharacters(in: .whitespaces)), !r[1].isEmpty,
                  let rssi = Double(r[2].trimmingCharacters(in: .whitespaces)) else { continue }
            let f = r.count >= 4 ? Int(r[3].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
            out.append(WiFiSample(tMs: t, bssid: r[1].trimmingCharacters(in: .whitespaces).lowercased(), rssi: rssi, freqMHz: f))
        }
        return out
    }
}

/// Wi-Fi 指纹：建图会话里每次扫描连同扫描时刻的位置（和蓝牙指纹一样，按对齐好的轨迹插值）存一条；
/// 定位用 kNN：和每条指纹比信号强度（两边任一边没听到的 AP 记 `missingDbm`），取最像的 k 条按 1/(距离+1) 加权平均。
public struct WiFiFingerprintMap {
    public struct Entry {
        public var position: Point2
        /// (AP 编号, dBm)，按编号排序
        var aps: [(Int, Double)]
    }
    public private(set) var entries: [Entry]
    /// BSSID → 编号
    private var index: [String: Int]
    /// 没听到的 AP 当成这么强（dBm）
    public var missingDbm: Double = -100
    /// 一次扫描少于这么多个 AP 不定位（建图时也不收）
    public var minAPs: Int = 3

    init(entries: [Entry], index: [String: Int]) { self.entries = entries; self.index = index }

    public var isEmpty: Bool { entries.isEmpty }

    /// 两次扫描的距离：两边听到的 AP 的并集上，信号差的均方根（dB）。
    /// `extra` = 只有 a 听到、指纹库里谁都没听到过的 AP（平方和、个数），对每条指纹一样，但也算进并集。
    static func distance(_ a: [(Int, Double)], _ b: [(Int, Double)], missing: Double,
                         extra: (sum: Double, n: Int) = (0, 0)) -> Double {
        var i = 0, j = 0, n = extra.n, s = extra.sum
        while i < a.count || j < b.count {
            let d: Double
            if j >= b.count || (i < a.count && a[i].0 < b[j].0) { d = a[i].1 - missing; i += 1 }
            else if i >= a.count || b[j].0 < a[i].0 { d = b[j].1 - missing; j += 1 }
            else { d = a[i].1 - b[j].1; i += 1; j += 1 }
            s += d * d; n += 1
        }
        return n > 0 ? (s / Double(n)).squareRoot() : .infinity
    }

    /// kNN 定位。返回加权位置、k 个邻居离它的均方根距离（cm，粗略的不确定度）；AP 太少 / 一个都不认识返回 nil。
    public func locate(_ scan: WiFiScan, k: Int = 5) -> (position: Point2, spreadCm: Double)? {
        guard scan.rssi.count >= minAPs, !entries.isEmpty else { return nil }
        // 建图时谁都没听到过的 AP：和每条指纹的差都是 (rssi − missing)，单独算一次
        var obs: [(Int, Double)] = [], extra = (sum: 0.0, n: 0)
        for (b, r) in scan.rssi {
            if let k = index[b] { obs.append((k, r)) } else { extra.sum += (r - missingDbm) * (r - missingDbm); extra.n += 1 }
        }
        guard !obs.isEmpty else { return nil }
        obs.sort { $0.0 < $1.0 }
        let kk = max(1, min(k, entries.count))
        var best: [(d: Double, i: Int)] = []
        best.reserveCapacity(kk + 1)
        for (i, e) in entries.enumerated() {
            let d = Self.distance(obs, e.aps, missing: missingDbm, extra: extra)
            if best.count < kk || d < best[best.count - 1].d {
                let at = best.firstIndex { d < $0.d } ?? best.count
                best.insert((d, i), at: at)
                if best.count > kk { best.removeLast() }
            }
        }
        var w = 0.0, x = 0.0, y = 0.0
        for b in best { let wi = 1 / (b.d + 1); w += wi; x += wi * entries[b.i].position.x; y += wi * entries[b.i].position.y }
        let p = Point2(x / w, y / w)
        var v = 0.0
        for b in best { let q = entries[b.i].position; v += (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) }
        return (p, (v / Double(best.count)).squareRoot())
    }
}

/// 从建图会话攒 Wi-Fi 指纹。位置和蓝牙指纹（BLEFingerprintBuilder）一样取对齐好的轨迹按时间插值。
public final class WiFiFingerprintBuilder {
    private var entries: [WiFiFingerprintMap.Entry] = []
    private var index: [String: Int] = [:]
    public var minAPs = 3
    /// 扫描时刻离最近的轨迹点超过这么久（ms）就不要
    public var maxGapMs: Int64 = 500

    public init() {}

    @discardableResult
    public func add(position p: Point2, scan: WiFiScan) -> Bool {
        guard scan.rssi.count >= minAPs else { return false }
        var aps: [(Int, Double)] = []
        for (b, r) in scan.rssi {
            let id: Int
            if let k = index[b] { id = k } else { id = index.count; index[b] = id }
            aps.append((id, r))
        }
        entries.append(.init(position: p, aps: aps.sorted { $0.0 < $1.0 }))
        return true
    }

    /// 一个会话：每次扫描按时间插值到轨迹上。返回收了几次扫描。
    @discardableResult
    public func add(scans: [WiFiScan], track: [(tMs: Int64, p: Point2)]) -> Int {
        guard track.count >= 2 else { return 0 }
        let times = track.map(\.tMs)
        var used = 0
        for s in scans {
            var lo = 0, hi = times.count - 1
            guard s.tMs >= times[lo] - maxGapMs, s.tMs <= times[hi] + maxGapMs else { continue }
            while hi - lo > 1 { let m = (lo + hi) / 2; if times[m] <= s.tMs { lo = m } else { hi = m } }
            let a = track[lo], b = track[hi]
            guard min(abs(s.tMs - a.tMs), abs(s.tMs - b.tMs)) <= maxGapMs else { continue }
            let f = b.tMs > a.tMs ? min(max(Double(s.tMs - a.tMs) / Double(b.tMs - a.tMs), 0), 1) : 0
            if add(position: Point2(a.p.x + (b.p.x - a.p.x) * f, a.p.y + (b.p.y - a.p.y) * f), scan: s) { used += 1 }
        }
        return used
    }

    public var count: Int { entries.count }

    public func build() -> WiFiFingerprintMap {
        var m = WiFiFingerprintMap(entries: entries, index: index)
        m.minAPs = minAPs
        return m
    }
}
