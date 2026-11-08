import Foundation

/// 房间扫描（Apple RoomPlan）的结果，换成和场地地图同一种 JSON（`mapElementList` 等），
/// 这样 2D / 3D 显示、可走区域、建图采集、定位都能直接用。
///
/// 输入是 ARKit 世界坐标（米，水平面取 (x, z)，与地图 (x, y) 同手性）；输出是地图坐标（cm，y 向下）。
/// 会把整个房间转一下，让墙大多横平竖直（RoomPlan 的世界系朝向是随手机开始扫描时的方向）。
public enum RoomMapBuilder {
    /// 扫描出来的一个东西：墙 / 门 / 窗 / 家具。
    public struct Item {
        /// 类别（家具：bed、table、sofa…；墙等由所在的数组决定）
        public var category: String
        /// 中心，ARKit (x, z)，米
        public var center: Point2
        /// 沿自身 x 轴的长度（米）：墙、门、窗是长度，家具是宽
        public var width: Double
        /// 沿自身 z 轴的长度（米）：家具是深度，墙是厚度（RoomPlan 给 0，按 10 cm 画）
        public var depth: Double
        /// 高度（米）
        public var height: Double
        /// 自身 x 轴在 (x, z) 平面里的方向（弧度）= atan2(col0.z, col0.x)
        public var yaw: Double

        public init(category: String, center: Point2, width: Double, depth: Double, height: Double, yaw: Double) {
            self.category = category; self.center = center; self.width = width; self.depth = depth
            self.height = height; self.yaw = yaw
        }
    }

    public struct Input {
        public var walls: [Item] = []
        public var doors: [Item] = []
        public var windows: [Item] = []
        public var openings: [Item] = []
        public var objects: [Item] = []
        /// 地面多边形，ARKit (x, z)，米。iOS 17 起 RoomPlan 有；没有时用墙端点的凸包
        public var floors: [[Point2]] = []
        /// 多房间扫描（iOS 17 StructureBuilder）：每个房间 / 走廊一个单元。非空时代替 `floors`
        public var rooms: [Room] = []
        /// 楼层序号（IMDF level.ordinal，0 = 地面层）
        public var ordinal: Int?
        /// 所属场馆（同一栋楼的多层扫描归到一起，导出时合成一个 IMDF）
        public var venueId: String?
        public var venueName: String?
        /// 入口处记的 GPS + 真北朝向，用来算 `geoRef`
        public var geoAnchor: GeoAnchor?
        public init() {}
    }

    /// 一个房间 / 走廊 / 电梯厅：地面多边形 + 编号，扫完后在手机上选 IMDF 类别、填名字
    public struct Room {
        public var id: String
        /// 地面多边形，ARKit (x, z)，米
        public var floor: [Point2]
        /// IMDF unit category（room / walkway / restroom / elevator / stairs …）
        public var category: String
        public var name: String?
        public init(id: String, floor: [Point2], category: String = "room", name: String? = nil) {
            self.id = id; self.floor = floor; self.category = category; self.name = name
        }
    }

    /// 入口处的一次 GPS + 朝向记录（ARKit 世界坐标下的位置和手机朝向）
    public struct GeoAnchor {
        /// 记录时手机位置，ARKit (x, z)，米
        public var arPosition: Point2
        /// 手机朝向在 ARKit (x, z) 平面里的方向（弧度）= atan2(dir.z, dir.x)
        public var arYaw: Double
        public var lon: Double
        public var lat: Double
        /// CLHeading.trueHeading（度，从正北顺时针）
        public var trueHeadingDeg: Double
        /// GPS 水平精度（米），只记录
        public var accuracyM: Double?
        public init(arPosition: Point2, arYaw: Double, lon: Double, lat: Double, trueHeadingDeg: Double, accuracyM: Double? = nil) {
            self.arPosition = arPosition; self.arYaw = arYaw; self.lon = lon; self.lat = lat
            self.trueHeadingDeg = trueHeadingDeg; self.accuracyM = accuracyM
        }
    }

    /// 四周留白（cm）
    public static let marginCm = 100.0

    /// - Returns: 地图 JSON（可以直接存成 map.json）和解析好的地图。
    public static func build(_ input: Input, name: String) throws -> (json: Data, map: StoreMap) {
        // 1. 房间主方向：墙的方向按长度加权（模 90°），转到横平竖直
        var s4 = 0.0, c4 = 0.0
        for w in input.walls { s4 += w.width * sin(4 * w.yaw); c4 += w.width * cos(4 * w.yaw) }
        let theta = (s4 == 0 && c4 == 0) ? 0 : atan2(s4, c4) / 4
        let ct = cos(-theta), st = sin(-theta)
        func rot(_ p: Point2) -> Point2 { Point2(p.x * ct - p.y * st, p.x * st + p.y * ct) }

        // 2. 地面：多房间时每个房间一块；没有就用墙端点的凸包
        var floors = input.rooms.isEmpty ? input.floors : input.rooms.map(\.floor).filter { $0.count >= 3 }
        if floors.isEmpty {
            var pts: [Point2] = []
            for w in input.walls {
                let u = Point2(cos(w.yaw), sin(w.yaw)) * (w.width / 2)
                pts.append(w.center + u); pts.append(w.center - u)
            }
            let hull = convexHull(pts)
            if hull.count >= 3 { floors = [hull] }
        }

        // 3. 范围（转完之后，米）
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func grow(_ p: Point2) { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        func corners(_ it: Item) -> [Point2] {
            let u = Point2(cos(it.yaw), sin(it.yaw)), v = Point2(-sin(it.yaw), cos(it.yaw))
            let hw = it.width / 2, hd = max(it.depth, 0.1) / 2
            return [it.center + u * hw + v * hd, it.center + u * hw - v * hd, it.center - u * hw + v * hd, it.center - u * hw - v * hd]
        }
        for it in input.walls + input.doors + input.windows + input.openings + input.objects { corners(it).map(rot).forEach(grow) }
        for f in floors { f.map(rot).forEach(grow) }
        guard minX.isFinite else { throw StoreDataError.unsupportedFormat("扫描结果里没有墙也没有家具") }

        let m = marginCm
        func toMap(_ p: Point2) -> Point2 { let q = rot(p); return Point2((q.x - minX) * 100 + m, (q.y - minY) * 100 + m) }
        func deg(_ yaw: Double) -> Double {
            var d = (yaw - theta) * 180 / Double.pi
            while d <= -180 { d += 360 }
            while d > 180 { d -= 360 }
            return (d * 10).rounded() / 10
        }
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

        var elements: [[String: Any]] = []
        // 墙、门、窗、开口：按中心写（加载时这些类型按中心解释）
        func flat(_ items: [Item], _ type: String, thickness: Double) {
            for it in items {
                let c = toMap(it.center)
                elements.append(["shapeType": type, "x": r1(c.x), "y": r1(c.y), "width": r1(it.width * 100),
                                 "height": thickness, "rotation": deg(it.yaw), "heightCm": r1(it.height * 100)])
            }
        }
        flat(input.walls, "MapWall", thickness: 10)
        flat(input.doors, "MapDoor", thickness: 14)
        flat(input.windows, "MapWindow", thickness: 14)
        flat(input.openings, "MapOpening", thickness: 14)
        // 家具：按 MapShelf 写（Konva 风格：左上角 + 绕左上角转），编号 Room-类别-序号
        var counter: [String: Int] = [:]
        for it in input.objects {
            let c = toMap(it.center)
            let w = it.width * 100, h = it.depth * 100, rd = deg(it.yaw)
            let r = rd * Double.pi / 180
            let tl = Point2(c.x - (cos(r) * w / 2 - sin(r) * h / 2), c.y - (sin(r) * w / 2 + cos(r) * h / 2))
            counter[it.category, default: 0] += 1
            elements.append(["shapeType": "MapShelf", "code": "Room-\(it.category)-\(counter[it.category]!)",
                             "x": r1(tl.x), "y": r1(tl.y), "width": r1(w), "height": r1(h), "rotation": rd,
                             "heightCm": r1(it.height * 100)])
        }
        func flatPoly(_ f: [Point2]) -> [Double] { f.flatMap { p -> [Double] in let q = toMap(p); return [r1(q.x), r1(q.y)] } }
        // 单元：多房间时每个房间一个；单房间（或老数据）时每块地面一个 room，编号 R1、R2…
        let rooms: [Room] = input.rooms.isEmpty
            ? floors.enumerated().map { Room(id: "R\($0.offset + 1)", floor: $0.element) }
            : input.rooms.filter { $0.floor.count >= 3 }
        let units: [[String: Any]] = rooms.map { r in
            var u: [String: Any] = ["id": r.id, "category": r.category, "polygon": flatPoly(r.floor)]
            if let n = r.name, !n.isEmpty { u["name"] = n }
            return u
        }
        var root: [String: Any] = [
            "width": r1((maxX - minX) * 100 + 2 * m), "height": r1((maxY - minY) * 100 + 2 * m),
            "floorName": name, "source": "roomplan", "rotatedDeg": r1(theta * 180 / Double.pi),
            "mapElementList": elements, "units": units,
            // ARKit (x, z) cm → 地图：map = pRef + R(φ)·a，φ = −θ，pRef = 留白 − 范围起点
            "arAlign": ["phi": -theta, "pRefX": m - minX * 100, "pRefY": m - minY * 100, "aRefX": 0, "aRefY": 0],
        ]
        if let o = input.ordinal { root["ordinal"] = o }
        if let v = input.venueId { root["venueId"] = v }
        if let v = input.venueName { root["venueName"] = v }
        if let a = input.geoAnchor {
            // ARKit 里的方向 yaw 在地图里是 yaw − θ
            let p = toMap(a.arPosition)
            let g = GeoRef.fromAnchor(mapPoint: p, lon: a.lon, lat: a.lat, trueHeadingDeg: a.trueHeadingDeg,
                                      mapDirectionDeg: (a.arYaw - theta) * 180 / Double.pi, marginCm: 0)
            root["geoRef"] = g.dict
            var anchor: [String: Any] = ["lon": a.lon, "lat": a.lat, "trueHeadingDeg": a.trueHeadingDeg,
                                         "x": r1(p.x), "y": r1(p.y)]
            if let acc = a.accuracyM { anchor["accuracyM"] = acc }
            root["geoAnchor"] = anchor
        }
        applyUnits(&root)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return (data, try StoreDataLoader.loadMap(data))
    }

    // MARK: 单元（房间类别、名字）

    /// 按 `units` 重新生成派生字段：`floorPolygons`（可走单元）、`obstaclePolygons`（不可走单元）、
    /// `connectors`（电梯 / 楼梯 / 扶梯…，格式同 imdf_convert）、`mapElementList` 里的 MapLabel / MapConnector。
    /// 改了单元的类别或名字之后调用一次。没有 `units` 的老地图不动。
    public static func applyUnits(_ root: inout [String: Any]) {
        guard let units = root["units"] as? [[String: Any]] else { return }
        var walk: [[Double]] = [], obst: [[Double]] = [], conns: [[String: Any]] = []
        var elements = (root["mapElementList"] as? [[String: Any]] ?? []).filter {
            let t = $0["shapeType"] as? String
            return t != "MapLabel" && t != "MapConnector"
        }
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        for u in units {
            let flat = numbers(u["polygon"])
            let poly = stride(from: 0, to: flat.count - 1, by: 2).map { Point2(flat[$0], flat[$0 + 1]) }
            guard poly.count >= 3 else { continue }
            let id = u["id"] as? String ?? ""
            let cat = (u["category"] as? String ?? "room").lowercased()
            if !IMDFUnitCategory.isWalkable(cat) { obst.append(flat); continue }
            walk.append(flat)
            let c = polygonCentroid(poly)
            if IMDFUnitCategory.isConnector(cat) {
                var conn: [String: Any] = ["id": id, "category": cat, "x": r1(c.x), "y": r1(c.y), "polygon": flat]
                if let o = root["ordinal"] { conn["ordinal"] = o }
                conns.append(conn)
                elements.append(["shapeType": "MapConnector", "code": id, "category": cat,
                                 "x": r1(c.x), "y": r1(c.y), "width": 0, "height": 0, "rotation": 0])
            }
            if let n = u["name"] as? String, !n.isEmpty {
                elements.append(["shapeType": "MapLabel", "code": id, "text": n, "category": cat,
                                 "x": r1(c.x), "y": r1(c.y), "width": 0, "height": 0, "rotation": 0])
            }
        }
        root["floorPolygons"] = walk
        root["obstaclePolygons"] = obst
        root["connectors"] = conns
        root["mapElementList"] = elements
    }

    /// JSON 里的数字数组（NSNumber / Double / Int 都认）
    static func numbers(_ v: Any?) -> [Double] {
        (v as? [Any] ?? []).compactMap { x -> Double? in
            if let d = x as? Double { return d }
            if let n = x as? NSNumber { return n.doubleValue }
            if let i = x as? Int { return Double(i) }
            return nil
        }
    }

    /// 改一个单元的类别 / 名字（nil = 不改；名字给空串 = 删掉名字），返回新的 map.json。
    public static func relabel(_ json: Data, unitId: String, category: String? = nil, name: String? = nil) throws -> Data {
        try update(json) { root in
            var units = root["units"] as? [[String: Any]] ?? []
            guard let i = units.firstIndex(where: { ($0["id"] as? String) == unitId }) else { return }
            if let c = category { units[i]["category"] = c }
            if let n = name {
                let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { units[i].removeValue(forKey: "name") } else { units[i]["name"] = t }
            }
            root["units"] = units
        }
    }

    /// 改 map.json 的字段（楼层序号、楼层名、场馆、geoRef、单元…），派生字段跟着更新。
    public static func update(_ json: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw StoreDataError.unsupportedFormat("地图根节点不是对象")
        }
        change(&root)
        if let o = root["ordinal"], var conns = root["connectors"] as? [[String: Any]] {
            for i in conns.indices { conns[i]["ordinal"] = o }
            root["connectors"] = conns
        }
        applyUnits(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// map.json 里的单元（地图坐标，cm），给手机上点选房间用。
    public struct Unit: Identifiable, Equatable {
        public var id: String
        public var category: String
        public var name: String?
        public var polygon: [Point2]
    }

    public static func units(_ json: Data) -> [Unit] {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return [] }
        return (root["units"] as? [[String: Any]] ?? []).compactMap { u in
            let f = numbers(u["polygon"])
            let poly = stride(from: 0, to: f.count - 1, by: 2).map { Point2(f[$0], f[$0 + 1]) }
            guard poly.count >= 3, let id = u["id"] as? String else { return nil }
            return Unit(id: id, category: u["category"] as? String ?? "room", name: u["name"] as? String, polygon: poly)
        }
    }

    /// 多边形面积中心（退化时取顶点平均）
    public static func polygonCentroid(_ p: [Point2]) -> Point2 {
        var a = 0.0, cx = 0.0, cy = 0.0
        for i in p.indices {
            let q = p[i], r = p[(i + 1) % p.count]
            let c = q.x * r.y - r.x * q.y
            a += c; cx += (q.x + r.x) * c; cy += (q.y + r.y) * c
        }
        if abs(a) < 1e-9 {
            let n = Double(max(p.count, 1))
            return Point2(p.reduce(0) { $0 + $1.x } / n, p.reduce(0) { $0 + $1.y } / n)
        }
        return Point2(cx / (3 * a), cy / (3 * a))
    }

    /// 点是否在多边形内（射线法）
    public static func polygonContains(_ poly: [Point2], _ p: Point2) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// 凸包（Andrew 单调链），逆时针。
    public static func convexHull(_ pts: [Point2]) -> [Point2] {
        let p = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count >= 3 else { return p }
        func cross(_ o: Point2, _ a: Point2, _ b: Point2) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [Point2] = [], upper: [Point2] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
