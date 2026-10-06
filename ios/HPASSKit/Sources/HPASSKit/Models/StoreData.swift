import Foundation

// MARK: - 地图

/// 货架（地图元素 shapeType == "MapShelf"）。x/y/width/height 单位 cm，rotation 单位度。
public struct ShelfRect: Hashable {
    public var code: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var rotation: Double
    public var subsection: Int
    /// 实物高度（cm）。门店地图里没有（nil，3D 用统一的货架高度）；房间扫描出来的家具有。
    public var heightCm: Double?

    public init(code: String, x: Double, y: Double, width: Double, height: Double, rotation: Double, subsection: Int = 1,
                heightCm: Double? = nil) {
        self.heightCm = heightCm
        self.code = code
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.subsection = subsection
    }
}

/// 通道（地图元素 shapeType == "MapCross"）：中心线段 a→b，lineWidth 为通道宽度。单位 cm。
public struct CrossSegment: Hashable {
    public var code: String
    public var a: Point2
    public var b: Point2
    public var lineWidth: Double

    public init(code: String, a: Point2, b: Point2, lineWidth: Double) {
        self.code = code
        self.a = a
        self.b = b
        self.lineWidth = lineWidth
    }
}

/// 解析后的门店楼层地图。
public struct StoreMap {
    public var mapId: Int?
    public var floorId: Int?
    public var floorName: String?
    public var width: Double
    public var height: Double
    public var shelves: [ShelfRect]
    public var crosses: [CrossSegment]
    /// 其他元素（MapPillar 等）仅用于绘制：shapeType + 外接矩形
    public var others: [(shapeType: String, x: Double, y: Double, width: Double, height: Double, rotation: Double)]
    /// 能走的地面（多边形，cm）。房间扫描的地图没有通道，用它当可走区域；门店地图为空。
    public var floor: [[Point2]] = []
    /// 房间扫描的地图：ARKit 世界坐标（扫描时的、也是视觉特征地图的）→ 地图坐标。视觉重定位后直接用它算位置。
    public var arAlign: MapARTransform?

    public init(mapId: Int? = nil, floorId: Int? = nil, floorName: String? = nil,
                width: Double, height: Double, shelves: [ShelfRect], crosses: [CrossSegment],
                others: [(shapeType: String, x: Double, y: Double, width: Double, height: Double, rotation: Double)] = []) {
        self.mapId = mapId
        self.floorId = floorId
        self.floorName = floorName
        self.width = width
        self.height = height
        self.shelves = shelves
        self.crosses = crosses
        self.others = others
    }
}

// MARK: - 指纹

/// 指纹点上某货架（按 type 区分）的 RSSI 区间。
public struct ShelfRange: Hashable {
    public var shelfCode: String
    public var minRSSI: Int
    public var maxRSSI: Int
    /// 0 = ESL/AP 侧上报，1 = 手机蓝牙扫描
    public var type: Int

    public init(shelfCode: String, minRSSI: Int, maxRSSI: Int, type: Int) {
        self.shelfCode = shelfCode
        self.minRSSI = minRSSI
        self.maxRSSI = maxRSSI
        self.type = type
    }
}

/// 指纹点。x/y 单位 cm。
public struct FingerprintPoint: Hashable {
    public var id: String
    public var x: Double
    public var y: Double
    public var ranges: [ShelfRange]
    public var neighbours: [String]

    public init(id: String, x: Double, y: Double, ranges: [ShelfRange], neighbours: [String]) {
        self.id = id
        self.x = x
        self.y = y
        self.ranges = ranges
        self.neighbours = neighbours
    }

    public var position: Point2 { Point2(x, y) }
}

// MARK: - 价签 / 商品

/// 价签。shelfCode 已按 Handy+ 规则规范化（见 StoreDataLoader.normalizeShelfCode）。
public struct EslItem: Hashable {
    public var id: String
    public var shelfCode: String
    public var rawShelfCode: String?
    public var x: Double?
    public var y: Double?
    public var sku: String?
    public var itemName: String?
    public var ean: String?

    public init(id: String, shelfCode: String, rawShelfCode: String? = nil, x: Double? = nil, y: Double? = nil,
                sku: String? = nil, itemName: String? = nil, ean: String? = nil) {
        self.id = id
        self.shelfCode = shelfCode
        self.rawShelfCode = rawShelfCode
        self.x = x
        self.y = y
        self.sku = sku
        self.itemName = itemName
        self.ean = ean
    }
}

/// 商品及其所有价签位置（导航目标）。
public struct GoodsItem: Hashable {
    public var sku: String
    public var itemName: String?
    public var ean: String?
    public var positions: [EslItem]

    public init(sku: String, itemName: String? = nil, ean: String? = nil, positions: [EslItem]) {
        self.sku = sku
        self.itemName = itemName
        self.ean = ean
        self.positions = positions
    }
}

// MARK: - 加载

public enum StoreDataError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case unsupportedFormat(String)

    public var description: String {
        switch self {
        case .invalidJSON(let s): return "JSON 解析失败：\(s)"
        case .unsupportedFormat(let s): return "不支持的数据格式：\(s)"
        }
    }
}

/// 门店数据文件解析。兼容 Handy+ / MapServer 的几种格式：
/// - 地图：{ width, height, mapElementList: [...] }，元素按 shapeType 区分
/// - 指纹：[FingerprintPoint] 或 [{floorId, fingerprintList: [FingerprintPoint]}]，整体可能被再包一层 JSON 字符串
/// - 价签：[EslItem]（getAllEslPositionByStoreCode 风格）或 [{sku, itemName, ean, eslPositionList: [...]}]（商品位置风格）
public enum StoreDataLoader {

    /// Handy+ HsLocationImpl.getShelfEslMapping：含 "#" 时替换为 "_"，否则追加 "_1"。
    public static func normalizeShelfCode(_ code: String) -> String {
        code.contains("#") ? code.replacingOccurrences(of: "#", with: "_") : code + "_1"
    }

    // MARK: 地图

    /// 矩形元素的 (x, y) 指的是哪个点。
    ///
    /// 这家服务端的地图是 Konva 风格：货架 / 桌台 / 方块的 (x, y) 是**矩形左上角**，
    /// `rotation`（度，顺时针，y 向下）是**绕这个左上角**转；圆形和路点才是中心。
    /// 用「中心」去解释它们，货架整体会偏出去、压到通道上（实测 67 m 通道被压住；
    /// 按左上角解释，压住的长度是 0）。
    public enum RectAnchor {
        case center
        case topLeft
    }

    /// 把「左上角 + 绕左上角旋转」的矩形换算成「中心 + 绕中心旋转」，模块内其余代码都按中心用。
    static func centerOfRect(x: Double, y: Double, width w: Double, height h: Double, rotationDeg: Double) -> Point2 {
        let r = rotationDeg * Double.pi / 180
        let c = cos(r), s = sin(r)           // u = (c, s) 沿 width，v = (−s, c) 沿 height
        return Point2(x + c * w / 2 - s * h / 2, y + s * w / 2 + c * h / 2)
    }

    /// 按左上角解释的「其他元素」类型（其余类型，如 Circle、MapRoadPoint，本来就是中心）。
    private static let topLeftOtherTypes: Set<String> = ["MapTableFeature", "Rect", "MapPillar"]

    public static func loadMap(_ data: Data, rectAnchor: RectAnchor = .topLeft) throws -> StoreMap {
        guard let root = try unwrap(data) as? [String: Any] else {
            throw StoreDataError.unsupportedFormat("地图根节点不是对象")
        }
        let elements = root["mapElementList"] as? [[String: Any]] ?? []
        var shelves: [ShelfRect] = []
        var crosses: [CrossSegment] = []
        var others: [(shapeType: String, x: Double, y: Double, width: Double, height: Double, rotation: Double)] = []
        for e in elements {
            let type = e["shapeType"] as? String ?? ""
            switch type {
            case "MapShelf":
                let w = num(e["width"]) ?? 0, h = num(e["height"]) ?? 0, rot = num(e["rotation"]) ?? 0
                var c = Point2(num(e["x"]) ?? 0, num(e["y"]) ?? 0)
                if rectAnchor == .topLeft { c = centerOfRect(x: c.x, y: c.y, width: w, height: h, rotationDeg: rot) }
                shelves.append(ShelfRect(code: e["code"] as? String ?? "",
                                         x: c.x, y: c.y, width: w, height: h, rotation: rot,
                                         subsection: Int(num(e["subsection"]) ?? 1),
                                         heightCm: num(e["heightCm"])))
            case "MapCross":
                let pts = (e["points"] as? [Any] ?? []).compactMap(num)
                guard pts.count >= 4 else { continue }
                crosses.append(CrossSegment(code: e["code"] as? String ?? "",
                                            a: Point2(pts[0], pts[1]), b: Point2(pts[2], pts[3]),
                                            lineWidth: num(e["lineWidth"]) ?? 0))
            default:
                if let x = num(e["x"]), let y = num(e["y"]) {
                    let w = num(e["width"]) ?? 0, h = num(e["height"]) ?? 0, rot = num(e["rotation"]) ?? 0
                    var c = Point2(x, y)
                    if rectAnchor == .topLeft && topLeftOtherTypes.contains(type) {
                        c = centerOfRect(x: x, y: y, width: w, height: h, rotationDeg: rot)
                    }
                    others.append((type, c.x, c.y, w, h, rot))
                }
            }
        }
        var map = StoreMap(mapId: (num(root["mapId"])).map { Int($0) },
                           floorId: (num(root["floorId"])).map { Int($0) },
                           floorName: root["floorName"] as? String,
                           width: num(root["width"]) ?? 0, height: num(root["height"]) ?? 0,
                           shelves: shelves, crosses: crosses, others: others)
        // 房间扫描生成的地图：floorPolygons = [[x0, y0, x1, y1, …], …]（cm）
        if let polys = root["floorPolygons"] as? [[Any]] {
            map.floor = polys.map { arr in
                let v = arr.compactMap(num)
                return stride(from: 0, to: v.count - 1, by: 2).map { Point2(v[$0], v[$0 + 1]) }
            }.filter { $0.count >= 3 }
        }
        if let a = root["arAlign"] as? [String: Any], let phi = num(a["phi"]), let x = num(a["pRefX"]), let y = num(a["pRefY"]) {
            map.arAlign = MapARTransform(pRef: Point2(x, y), aRef: Point2(num(a["aRefX"]) ?? 0, num(a["aRefY"]) ?? 0), phi: phi)
        }
        return map
    }

    // MARK: 指纹

    /// - Parameter floorId: 多楼层文件时只取该楼层；nil 表示全部合并（与 Handy+ 一致）。
    public static func loadFingerprints(_ data: Data, floorId: Int? = nil) throws -> [FingerprintPoint] {
        guard let list = try unwrap(data) as? [[String: Any]] else {
            throw StoreDataError.unsupportedFormat("指纹根节点不是数组")
        }
        var rawPoints: [[String: Any]] = []
        for item in list {
            if let fl = item["fingerprintList"] as? [[String: Any]] {
                if let floorId, let f = num(item["floorId"]), Int(f) != floorId { continue }
                rawPoints += fl
            } else {
                rawPoints.append(item)
            }
        }
        return rawPoints.map { p in
            let ranges = (p["data"] as? [[String: Any]] ?? []).map { d in
                ShelfRange(shelfCode: d["shelfCode"] as? String ?? "",
                           minRSSI: Int(num(d["minRSSI"]) ?? -100),
                           maxRSSI: Int(num(d["maxRSSI"]) ?? 0),
                           type: Int(num(d["type"]) ?? 0))
            }
            let neighbours = (p["neighbourIds"] as? [Any] ?? []).map(str)
            return FingerprintPoint(id: str(p["num"] ?? ""), x: num(p["x"]) ?? 0, y: num(p["y"]) ?? 0,
                                    ranges: ranges, neighbours: neighbours)
        }
    }

    // MARK: 价签 / 商品

    /// 读取价签列表（两种格式都返回扁平的价签列表）。
    public static func loadEslItems(_ data: Data) throws -> [EslItem] {
        try loadGoods(data).flatMap(\.positions)
    }

    /// 读取商品列表。扁平价签格式会按 sku 聚合（无 sku 的价签归入 sku = ""）。
    public static func loadGoods(_ data: Data) throws -> [GoodsItem] {
        guard let list = try unwrap(data) as? [[String: Any]] else {
            throw StoreDataError.unsupportedFormat("价签/商品根节点不是数组")
        }
        var goods: [GoodsItem] = []
        var flat: [String: GoodsItem] = [:]
        var flatOrder: [String] = []
        for item in list {
            if let positions = item["eslPositionList"] as? [[String: Any]] {
                let sku = str(item["sku"] ?? "")
                let name = item["itemName"] as? String
                let ean = item["ean"] as? String
                let esls = positions.compactMap { esl($0, sku: sku, name: name, ean: ean) }
                goods.append(GoodsItem(sku: sku, itemName: name, ean: ean, positions: esls))
            } else if let e = esl(item, sku: nil, name: nil, ean: nil) {
                let key = e.sku ?? ""
                if flat[key] == nil {
                    flat[key] = GoodsItem(sku: key, itemName: e.itemName, ean: e.ean, positions: [])
                    flatOrder.append(key)
                }
                flat[key]!.positions.append(e)
            }
        }
        return goods + flatOrder.compactMap { flat[$0] }
    }

    /// 价签 ID → 规范化货架编码。
    public static func eslToShelf(_ items: [EslItem]) -> [String: String] {
        var m: [String: String] = [:]
        for e in items where !e.id.isEmpty { m[e.id] = e.shelfCode }
        return m
    }

    // MARK: 内部

    private static func esl(_ d: [String: Any], sku: String?, name: String?, ean: String?) -> EslItem? {
        guard let id = d["id"].map(str), !id.isEmpty else { return nil }
        let raw = d["shelfCode"] as? String
        return EslItem(id: id,
                       shelfCode: normalizeShelfCode(raw ?? "null"),
                       rawShelfCode: raw,
                       x: num(d["x"]) ?? num(d["transX"]),
                       y: num(d["y"]) ?? num(d["transY"]),
                       sku: sku ?? (d["sku"].map(str)),
                       itemName: name ?? (d["itemName"] as? String),
                       ean: ean ?? (d["ean"] as? String))
    }

    /// 解析 JSON；若结果是字符串（被再编码一层），继续解析一次。
    static func unwrap(_ data: Data) throws -> Any {
        var obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw StoreDataError.invalidJSON(error.localizedDescription)
        }
        if let s = obj as? String, let inner = s.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) {
            do {
                obj = try JSONSerialization.jsonObject(with: inner, options: [.fragmentsAllowed])
            } catch {
                throw StoreDataError.invalidJSON("内层 JSON：\(error.localizedDescription)")
            }
        }
        // 服务端统一信封：{ code, message, success, data: … }，data 可能又是 JSON 字符串。
        if let dict = obj as? [String: Any], let inner = dict["data"],
           dict["success"] != nil || dict["code"] != nil || dict["message"] != nil {
            obj = inner
            if let s = obj as? String, let bytes = s.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) {
                do {
                    obj = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
                } catch {
                    throw StoreDataError.invalidJSON("data 字段里的 JSON：\(error.localizedDescription)")
                }
            }
        }
        return obj
    }

    /// 数字或数字字符串 → Double。
    static func num(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// 任意标量 → String（整数不带小数点）。
    static func str(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : n.stringValue
        default: return "\(v)"
        }
    }
}
