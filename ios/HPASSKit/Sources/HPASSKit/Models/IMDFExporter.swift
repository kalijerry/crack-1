import CryptoKit
import Foundation

/// 一个场馆的多层 map.json → IMDF 压缩包（manifest + address / venue / building / footprint / level / unit /
/// opening / fixture / anchor / occupant 的 GeoJSON，WGS84）。
///
/// 规则和 `tools/venue/imdf_export.py` 完全一致（要素 id 也一样，都是 uuid5），导出后可以用
/// `tools/venue/imdf_convert.py` 读回来：
/// - 每个 map.json 要有 `geoRef`；同一 `ordinal` 的多个文件合成一层；
/// - `units` → unit（没有 units 时 floorPolygons 当 room、obstaclePolygons 当 structure）；
/// - MapDoor / MapOpening → opening（pedestrian）；MapShelf（扫描出的家具）→ fixture（furniture）；
/// - 每个单元一个 anchor（单元中心）；room 等类别的有名单元另外生成 occupant；
/// - level 轮廓 = 该层所有单元顶点的凸包；venue / footprint = 所有层的凸包。
public enum IMDFExporter {
    public struct Options {
        public var venueName: String?
        /// IMDF venue category（businesscampus / shoppingcenter / hotel / university …）
        public var venueCategory: String?
        public var language = "zh-Hans"
        public init(venueName: String? = nil, venueCategory: String? = nil, language: String = "zh-Hans") {
            self.venueName = venueName; self.venueCategory = venueCategory; self.language = language
        }
    }

    public enum ExportError: Error, CustomStringConvertible {
        case noLevels
        case missingGeoRef(String)
        case empty
        public var description: String {
            switch self {
            case .noLevels: return "没有楼层"
            case .missingGeoRef(let n): return "楼层 \(n) 没有地理坐标（geoRef）：扫描时在入口记录位置，或在网页编辑器里两点对准"
            case .empty: return "所有楼层都没有单元多边形"
            }
        }
    }

    public static let featureFiles = ["address", "venue", "building", "footprint", "level", "unit", "opening",
                                      "fixture", "anchor", "occupant"]
    static let namespace = UUID(uuidString: "6f1c2b0e-5d0a-4b8e-9a51-2f3c0d6e7a10")!

    /// uuid5（RFC 4122，SHA-1），和 Python 的 uuid.uuid5 结果一样。
    public static func uuid5(_ ns: UUID, _ name: String) -> String {
        var bytes = withUnsafeBytes(of: ns.uuid) { Array($0) }
        bytes += Array(name.utf8)
        var h = Array(Array(Insecure.SHA1.hash(data: bytes)).prefix(16))
        h[6] = (h[6] & 0x0F) | 0x50
        h[8] = (h[8] & 0x3F) | 0x80
        let hex = h.map { String(format: "%02x", $0) }.joined()
        let i = hex.startIndex
        func s(_ a: Int, _ b: Int) -> Substring { hex[hex.index(i, offsetBy: a)..<hex.index(i, offsetBy: b)] }
        return "\(s(0, 8))-\(s(8, 12))-\(s(12, 16))-\(s(16, 20))-\(s(20, 32))"
    }

    struct UnitIn { var id: String; var category: String; var name: String?; var poly: [Point2] }

    static func docUnits(_ doc: [String: Any]) -> [UnitIn] {
        func pts(_ v: Any?) -> [Point2] {
            let f = RoomMapBuilder.numbers(v)
            return stride(from: 0, to: f.count - 1, by: 2).map { Point2(f[$0], f[$0 + 1]) }
        }
        if let units = doc["units"] as? [[String: Any]] {
            return units.enumerated().compactMap { (i, u) -> UnitIn? in
                let p = pts(u["polygon"])
                guard p.count >= 3 else { return nil }
                let n = (u["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return UnitIn(id: (u["id"] as? String) ?? "unit\(i + 1)", category: ((u["category"] as? String) ?? "room").lowercased(),
                              name: (n?.isEmpty ?? true) ? nil : n, poly: p)
            }
        }
        var out: [UnitIn] = []
        for (key, cat) in [("floorPolygons", "room"), ("obstaclePolygons", "structure")] {
            for (i, v) in (doc[key] as? [Any] ?? []).enumerated() {
                let p = pts(v)
                if p.count >= 3 { out.append(UnitIn(id: "\(key)\(i + 1)", category: cat, name: nil, poly: p)) }
            }
        }
        return out
    }

    static func signedArea(_ r: [Point2]) -> Double {
        var s = 0.0
        for i in r.indices { let a = r[i], b = r[(i + 1) % r.count]; s += a.x * b.y - b.x * a.y }
        return s / 2
    }

    static func r9(_ v: Double) -> Double { (v * 1e9).rounded() / 1e9 }

    /// 经纬度点（x = lon，y = lat）→ GeoJSON 外环：逆时针、闭合
    static func ring(_ ll: [Point2]) -> [[Double]] {
        var p = ll
        if p.count > 1, p.first == p.last { p.removeLast() }
        if signedArea(p) < 0 { p.reverse() }
        if let f = p.first { p.append(f) }
        return p.map { [r9($0.x), r9($0.y)] }
    }

    static func polygon(_ ll: [Point2]) -> [String: Any] { ["type": "Polygon", "coordinates": [ring(ll)]] }
    static func point(_ p: Point2) -> [String: Any] { ["type": "Point", "coordinates": [r9(p.x), r9(p.y)]] }

    static func feature(_ id: String, _ type: String, _ geometry: Any?, _ props: [String: Any?]) -> [String: Any] {
        ["id": id, "type": "Feature", "feature_type": type, "geometry": geometry ?? NSNull(),
         "properties": props.mapValues { $0 ?? NSNull() }]
    }

    static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    /// MapDoor / MapOpening（中心 + 宽度 + 角度）→ 两个端点（cm）
    static func openingSegment(_ e: [String: Any]) -> (Point2, Point2) {
        let c = Point2(num(e["x"]) ?? 0, num(e["y"]) ?? 0), w = num(e["width"]) ?? 0
        let r = (num(e["rotation"]) ?? 0) * Double.pi / 180
        let u = Point2(cos(r), sin(r)) * (w / 2)
        return (c - u, c + u)
    }

    /// MapShelf（左上角 + 绕左上角转）→ 四个角（cm）
    static func shelfCorners(_ e: [String: Any]) -> [Point2] {
        let tl = Point2(num(e["x"]) ?? 0, num(e["y"]) ?? 0)
        let w = num(e["width"]) ?? 0, h = num(e["height"]) ?? 0
        let r = (num(e["rotation"]) ?? 0) * Double.pi / 180
        let u = Point2(cos(r), sin(r)), v = Point2(-sin(r), cos(r))
        return [tl, tl + u * w, tl + u * w + v * h, tl + v * h]
    }

    /// 多层 map.json（已解析的 JSON 对象）→ {feature_type: [feature]}
    public static func features(_ docs: [[String: Any]], options: Options = Options()) throws -> [String: [[String: Any]]] {
        guard !docs.isEmpty else { throw ExportError.noLevels }
        let docName = docs.compactMap { $0["venueName"] as? String }.first(where: { !$0.isEmpty })
        let name = options.venueName ?? docName ?? "场馆"
        let docCategory = docs.compactMap { $0["venueCategory"] as? String }.first(where: { !$0.isEmpty })
        let category = options.venueCategory ?? docCategory ?? "businesscampus"
        let lang = options.language
        func uid(_ parts: Any...) -> String { uuid5(namespace, ([name] + parts.map { "\($0)" }).joined(separator: "/")) }
        func labels(_ t: String?) -> Any? { t.map { [lang: $0] } }

        var feats: [String: [[String: Any]]] = Dictionary(uniqueKeysWithValues: featureFiles.map { ($0, []) })
        let addressId = uid("address"), venueId = uid("venue"), buildingId = uid("building")

        var byOrd: [Int: [(doc: [String: Any], geo: GeoRef)]] = [:]
        for d in docs {
            guard let g = GeoRef(dict: d["geoRef"] as? [String: Any]) else {
                throw ExportError.missingGeoRef((d["floorName"] as? String) ?? "?")
            }
            let o = Int(num(d["ordinal"]) ?? 0)
            byOrd[o, default: []].append((d, g))
        }

        var allPts: [Point2] = []
        for ordinal in byOrd.keys.sorted() {
            let levelDocs = byOrd[ordinal]!
            let levelName = levelDocs.compactMap { $0.doc["floorName"] as? String }.first(where: { !$0.isEmpty }) ?? "\(ordinal)F"
            let levelId = uid("level", ordinal)
            var levelPts: [Point2] = []
            var unitFeats: [[String: Any]] = []
            for (di, item) in levelDocs.enumerated() {
                let g = item.geo
                func ll(_ p: Point2) -> Point2 { let q = g.toLonLat(p); return Point2(q.lon, q.lat) }
                for u in docUnits(item.doc) {
                    let r = u.poly.map(ll)
                    levelPts += r
                    let c = ll(RoomMapBuilder.polygonCentroid(u.poly))
                    let unitId = uid("unit", ordinal, di, u.id)
                    unitFeats.append(feature(unitId, "unit", polygon(r), [
                        "category": u.category, "restriction": nil, "accessibility": nil,
                        "name": labels(u.name), "alt_name": nil, "level_id": levelId, "display_point": point(c)]))
                    let anchorId = uid("anchor", ordinal, di, u.id)
                    feats["anchor"]!.append(feature(anchorId, "anchor", point(c), ["address_id": nil, "unit_id": unitId]))
                    if u.name != nil, IMDFUnitCategory.occupantCategories.contains(u.category) {
                        feats["occupant"]!.append(feature(uid("occupant", ordinal, di, u.id), "occupant", nil, [
                            "name": labels(u.name), "alt_name": nil, "category": "unspecified", "anchor_id": anchorId,
                            "hours": nil, "phone": nil, "website": nil, "validity": nil, "correlation_id": nil]))
                    }
                }
                for (ei, e) in (item.doc["mapElementList"] as? [[String: Any]] ?? []).enumerated() {
                    let t = e["shapeType"] as? String
                    if t == "MapDoor" || t == "MapOpening" {
                        let (a, b) = openingSegment(e)
                        guard a.distance(to: b) >= 1 else { continue }
                        let la = ll(a), lb = ll(b), mid = ll((a + b) * 0.5)
                        let seg: [String: Any] = ["type": "LineString", "coordinates": [[r9(la.x), r9(la.y)], [r9(lb.x), r9(lb.y)]]]
                        feats["opening"]!.append(feature(uid("opening", ordinal, di, ei), "opening", seg, [
                                "category": "pedestrian", "accessibility": nil, "access_control": nil, "door": nil,
                                "name": nil, "alt_name": nil, "display_point": point(mid), "level_id": levelId]))
                    } else if t == "MapShelf" {
                        let corners = shelfCorners(e)
                        let r = corners.map(ll)
                        guard abs(signedArea(r)) >= 1e-14 else { continue }
                        feats["fixture"]!.append(feature(uid("fixture", ordinal, di, ei), "fixture", polygon(r), [
                            "category": "furniture", "name": labels(e["code"] as? String), "alt_name": nil,
                            "anchor_id": nil, "level_id": levelId,
                            "display_point": point(ll(RoomMapBuilder.polygonCentroid(corners)))]))
                    }
                }
            }
            guard !levelPts.isEmpty else { continue }
            let hull = RoomMapBuilder.convexHull(levelPts)
            allPts += hull
            feats["level"]!.append(feature(levelId, "level", polygon(hull), [
                "category": "unspecified", "restriction": nil, "ordinal": ordinal, "outdoor": false,
                "name": labels(levelName), "short_name": labels(levelName),
                "display_point": point(RoomMapBuilder.polygonCentroid(hull)), "address_id": nil,
                "building_ids": [buildingId]]))
            feats["unit"]! += unitFeats
        }
        guard !allPts.isEmpty else { throw ExportError.empty }

        let outline = RoomMapBuilder.convexHull(allPts)
        let oc = point(RoomMapBuilder.polygonCentroid(outline))
        feats["address"]!.append(feature(addressId, "address", nil, [
            "address": name, "unit": nil, "locality": "", "province": nil, "country": nil,
            "postal_code": nil, "postal_code_ext": nil, "postal_code_vanity": nil]))
        feats["venue"]!.append(feature(venueId, "venue", polygon(outline), [
            "category": category, "restriction": nil, "name": labels(name), "alt_name": nil,
            "hours": nil, "phone": nil, "website": nil, "display_point": oc, "address_id": addressId]))
        feats["building"]!.append(feature(buildingId, "building", nil, [
            "category": "unspecified", "restriction": nil, "name": labels(name), "alt_name": nil,
            "display_point": oc, "address_id": addressId]))
        feats["footprint"]!.append(feature(uid("footprint"), "footprint", polygon(outline), [
            "category": "ground", "name": nil, "building_ids": [buildingId]]))
        return feats
    }

    /// 压缩包里的文件（文件名 → 内容）
    public static func files(_ docs: [[String: Any]], options: Options = Options(), created: Date = Date()) throws -> [(name: String, data: Data)] {
        let feats = try features(docs, options: options)
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        let manifest: [String: Any] = ["version": "1.0.0", "created": df.string(from: created),
                                       "generated_by": "indoor_navigatoin IMDFExporter", "language": options.language,
                                       "extensions": NSNull()]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        var out: [(name: String, data: Data)] = [(name: "manifest.json", data: manifestData)]
        for k in featureFiles {
            let fc: [String: Any] = ["type": "FeatureCollection", "name": k, "features": feats[k] ?? []]
            let d = try JSONSerialization.data(withJSONObject: fc, options: [.sortedKeys])
            out.append((name: "\(k).geojson", data: d))
        }
        return out
    }

    /// 导出成 IMDF 压缩包（zip，不压缩）
    public static func archive(_ docs: [[String: Any]], options: Options = Options()) throws -> Data {
        let f = try files(docs, options: options)
        return ZipWriter.store(f)
    }

    /// 从 map.json 文件内容导出
    public static func archive(jsonFiles: [Data], options: Options = Options()) throws -> Data {
        let docs = try jsonFiles.map { d -> [String: Any] in
            guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                throw StoreDataError.unsupportedFormat("地图根节点不是对象")
            }
            return o
        }
        return try archive(docs, options: options)
    }
}

/// 最小的 zip 写入器：只用「存储」方式（不压缩），文件名 UTF-8。IMDF 只要求是标准 zip，
/// GeoJSON 不大，不压缩也没关系；iOS 没有自带的 zip 写入接口，所以自己写。
public enum ZipWriter {
    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    public static func store(_ files: [(name: String, data: Data)], date: Date = Date()) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { var x = UInt16(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: UInt32, _ d: inout Data) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let dosTime = ((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2)
        let dosDate = (max((c.year ?? 1980) - 1980, 0) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1)
        for f in files {
            let name = Data(f.name.utf8)
            let crc = crc32(f.data)
            let offset = UInt32(out.count)
            u32(0x0403_4B50, &out); u16(20, &out); u16(0x0800, &out); u16(0, &out)
            u16(dosTime, &out); u16(dosDate, &out)
            u32(crc, &out); u32(UInt32(f.data.count), &out); u32(UInt32(f.data.count), &out)
            u16(name.count, &out); u16(0, &out)
            out.append(name); out.append(f.data)

            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central)
            u16(dosTime, &central); u16(dosDate, &central)
            u32(crc, &central); u32(UInt32(f.data.count), &central); u32(UInt32(f.data.count), &central)
            u16(name.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central)
            central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out)
        u16(files.count, &out); u16(files.count, &out)
        u32(UInt32(central.count), &out); u32(cdOffset, &out); u16(0, &out)
        return out
    }
}
