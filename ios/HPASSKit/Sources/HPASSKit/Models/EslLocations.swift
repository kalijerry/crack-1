import Foundation

/// 门店系统导出的价签位置表（esl_locations_<门店>.csv）：价签编号 → 通道 / 段 / 层 / 序号 / 商品条码 / 货架图。
///
/// 通道 A002 + 段 07 对应地图里的货架 Shelf-002-07（个别漏补零的写成 Shelf-26-14）。实测 1266 店：
/// 23995 个价签，20513 个有位置，18550 个能对上地图货架。表里有些位置不准，所以：
/// - 当蓝牙粗定位的**底图**：没采集过的地方也有价签位置；采集学到的位置更准，有就用学到的；
/// - 寻找模式：按价签 / 条码 / 货架图名找到货架，再用这个价签的实时信号找到它。
public struct EslLocation: Hashable {
    public var id: String
    public var aisle: String
    public var bay: String
    public var level: String
    public var seq: String
    public var productCode: String
    public var plano: String
    /// 对上的地图货架（nil = 表里没位置或地图里没有这个货架）
    public var shelfCode: String?
    public var position: Point2?

    public var label: String {
        aisle.isEmpty ? "（表里没有位置）" : "\(aisle) 段 \(bay) 层 \(level)" + (seq.isEmpty ? "" : " #\(seq)")
    }
}

public enum EslLocations {
    /// 解析 CSV（带不带 BOM、\r\n 都行；列按表头名找）。传入地图时顺便对上货架位置。
    public static func parse(_ text: String, map: StoreMap?) -> [EslLocation] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let head = lines.first else { return [] }
        let cols = splitCSV(head.replacingOccurrences(of: "\u{FEFF}", with: ""))
        func col(_ keys: [String]) -> Int? { cols.firstIndex { c in keys.contains { c.localizedCaseInsensitiveContains($0) } } }
        guard let iId = col(["ESL_ID", "eslId"]) else { return [] }
        let iAisle = col(["Aisle"]), iBay = col(["Bay"]), iShelf = cols.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "Shelf" }
        let iSeq = col(["ShelfSeq"]), iProd = col(["productCode", "条码"]), iPlano = col(["planoName", "货架图"])
        var shelves: [String: ShelfRect] = [:]
        for s in map?.shelves ?? [] { shelves[s.code] = s }
        var out: [EslLocation] = []
        for line in lines.dropFirst() {
            let c = splitCSV(line)
            func v(_ i: Int?) -> String { i.flatMap { $0 < c.count ? c[$0].trimmingCharacters(in: .whitespaces) : nil } ?? "" }
            let id = v(iId).uppercased()
            guard !id.isEmpty else { continue }
            var e = EslLocation(id: id, aisle: v(iAisle), bay: v(iBay), level: v(iShelf), seq: v(iSeq),
                                productCode: v(iProd), plano: v(iPlano), shelfCode: nil, position: nil)
            if let a = Int(e.aisle.filter(\.isNumber)), let b = Int(e.bay.filter(\.isNumber)) {
                for code in [String(format: "Shelf-%03d-%02d", a, b), String(format: "Shelf-%d-%02d", a, b)] {
                    if let s = shelves[code] { e.shelfCode = code; e.position = Point2(s.x, s.y); break }
                }
            }
            out.append(e)
        }
        return out
    }

    /// 蓝牙底图：默认用表里的位置（货架中心）。实测只用表做蓝牙粗定位中位 1.6～3.4 m，比采集学到的（偏向人走的路线）还准；
    /// 只有学到的位置和表差 > mismatchCm 且读数够多（表很可能错了 / 价签挪了）时才用学到的；表里没有的价签用学到的。
    public static func seededBLEMap(_ locs: [EslLocation], learned: BLEFingerprintMap?, mismatchCm: Double = 1000,
                                    minSamples: Int = 5) -> BLEFingerprintMap {
        var tags: [String: BLEFingerprintMap.Tag] = [:]
        for e in locs { if let p = e.position { tags[e.id] = .init(x: p.x, y: p.y, maxRssi: -70, samples: 0) } }
        for (id, t) in learned?.tags ?? [:] {
            if let table = tags[id] {
                if t.samples >= minSamples && Point2(table.x, table.y).distance(to: Point2(t.x, t.y)) > mismatchCm { tags[id] = t }
            } else {
                tags[id] = t
            }
        }
        return BLEFingerprintMap(cellCm: learned?.cellCm ?? 200, cells: learned?.cells ?? [], tags: tags)
    }

    /// 学到的位置和表里位置差得多的价签（表可能不对，或者价签挪了）
    public static func mismatches(_ locs: [EslLocation], learned: BLEFingerprintMap, minSamples: Int = 5,
                                  thresholdCm: Double = 1000) -> [(id: String, shelf: String, distanceCm: Double)] {
        locs.compactMap { e in
            guard let p = e.position, let t = learned.tags[e.id], t.samples >= minSamples else { return nil }
            let d = p.distance(to: Point2(t.x, t.y))
            return d > thresholdCm ? (e.id, e.shelfCode ?? "", d) : nil
        }.sorted { $0.distanceCm > $1.distanceCm }
    }

    /// 简单 CSV 拆分（支持双引号包起来的字段）
    static func splitCSV(_ line: String) -> [String] {
        var out: [String] = [], cur = "", q = false
        for ch in line {
            if ch == "\"" { q.toggle() } else if ch == "," && !q { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        out.append(cur)
        return out
    }
}
