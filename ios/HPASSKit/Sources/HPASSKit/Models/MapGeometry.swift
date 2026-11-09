import Foundation

/// map.json 元素的几何读写层：把 `mapElementList` / `units` 里的东西换成带类型的几何（线段、旋转矩形、多边形），
/// 做刚体变换后再写回同样的格式（保留原有键，坐标保留 1 位小数）。扫描段合成（`MapComposer`）、
/// 几何对齐（`RigidAlign2D`）、原点平移（`MapFrameShift`）都用它，不各自手写三角函数。
///
/// 约定（和 `RoomMapBuilder` / `StoreDataLoader` 一致）：
/// - MapWall / MapDoor / MapWindow / MapOpening：(x, y) 是**中心**，`width` 是长度，`height` 是厚度，
///   `rotation`（度，y 向下顺时针）是长度方向；
/// - MapShelf 以及 MapTableFeature / Rect / MapPillar：(x, y) 是**左上角**，绕左上角转；
/// - 其余带 x / y 的元素按中心；MapCross 的 `points` 是 [x0, y0, x1, y1]。
public enum MapGeometry {
    /// 按中心解释、有长度方向的线状元素
    public static let linearTypes: Set<String> = ["MapWall", "MapDoor", "MapWindow", "MapOpening"]
    /// 按左上角解释的矩形元素
    public static let topLeftTypes: Set<String> = ["MapShelf", "MapTableFeature", "Rect", "MapPillar"]
    /// 由单元派生、合成时重新生成的元素
    public static let derivedTypes: Set<String> = ["MapLabel", "MapConnector"]

    // MARK: 数字 / 角度

    public static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    /// 保留 1 位小数（和 RoomMapBuilder 写出的一致）
    public static func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    /// 角度归一到 (−180, 180]
    public static func wrapDeg(_ d: Double) -> Double { MapARTransform.wrapDeg(d) }

    /// 两个方向（度）作为「直线」的夹角，0…90（不分正反）
    public static func lineAngleDiffDeg(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 180)
        if d > 90 { d = 180 - d }
        return d
    }

    // MARK: 线段（墙 / 门 / 窗 / 开口）

    public struct Segment: Equatable {
        public var type: String
        public var center: Point2
        public var length: Double
        /// 长度方向（度）
        public var rotationDeg: Double
        /// 厚度（元素的 height）
        public var thickness: Double
        public var heightCm: Double?

        public init(type: String, center: Point2, length: Double, rotationDeg: Double, thickness: Double, heightCm: Double? = nil) {
            self.type = type; self.center = center; self.length = length; self.rotationDeg = rotationDeg
            self.thickness = thickness; self.heightCm = heightCm
        }

        /// 两端点
        public init(type: String, a: Point2, b: Point2, thickness: Double, heightCm: Double? = nil) {
            let d = b - a
            self.init(type: type, center: (a + b) * 0.5, length: d.length,
                      rotationDeg: atan2(d.y, d.x) * 180 / Double.pi, thickness: thickness, heightCm: heightCm)
        }

        /// 单位方向向量
        public var direction: Point2 { let r = rotationDeg * Double.pi / 180; return Point2(cos(r), sin(r)) }
        public var a: Point2 { center - direction * (length / 2) }
        public var b: Point2 { center + direction * (length / 2) }

        /// 点到这条线段所在直线的有符号距离（法向 = 方向左转 90°）
        public func offset(of p: Point2) -> Double { let u = direction; return (p - a).cross(u) * -1 }
        /// 点在直线上的投影参数（从 a 起，cm）
        public func param(of p: Point2) -> Double { (p - a).dot(direction) }

        /// 沿线每 step cm 取一个点（含两端附近），返回点
        public func samples(step: Double) -> [Point2] {
            guard length > 0 else { return [center] }
            let n = max(Int((length / step).rounded(.down)), 1)
            let h = length / Double(n)
            return (0..<n).map { a + direction * (h * (Double($0) + 0.5)) }
        }

        public func transformed(by t: MapARTransform) -> Segment {
            var s = self
            s.center = t.toMap(center)
            s.rotationDeg = MapGeometry.wrapDeg(rotationDeg + t.angleDeg)
            return s
        }
    }

    /// 线状元素 → 线段；不是线状元素返回 nil
    public static func segment(_ e: [String: Any]) -> Segment? {
        guard let type = e["shapeType"] as? String, linearTypes.contains(type),
              let x = num(e["x"]), let y = num(e["y"]) else { return nil }
        return Segment(type: type, center: Point2(x, y), length: num(e["width"]) ?? 0, rotationDeg: num(e["rotation"]) ?? 0,
                       thickness: num(e["height"]) ?? 10, heightCm: num(e["heightCm"]))
    }

    /// 线段写回元素：在 `template` 的基础上改 x / y / width / height / rotation / heightCm
    public static func element(_ s: Segment, template: [String: Any] = [:]) -> [String: Any] {
        var e = template
        e["shapeType"] = s.type
        e["x"] = r1(s.center.x); e["y"] = r1(s.center.y)
        e["width"] = r1(s.length); e["height"] = s.thickness
        e["rotation"] = r1(wrapDeg(s.rotationDeg))
        if let h = s.heightCm { e["heightCm"] = r1(h) }
        return e
    }

    /// 地图里所有线状元素（可按类型过滤）
    public static func segments(_ root: [String: Any], types: Set<String> = linearTypes) -> [Segment] {
        (root["mapElementList"] as? [[String: Any]] ?? []).compactMap(segment).filter { types.contains($0.type) }
    }

    /// 两条线段所在直线上的区间并集：把 `s` 投到 `base` 的直线上，返回合并后的线段（位置、方向、厚度沿用 base，高度取大）。
    /// 区间不重叠且间隙大于 maxGapCm 时返回 nil。
    public static func unionOnLine(_ base: Segment, _ s: Segment, maxGapCm: Double) -> Segment? {
        let t1 = base.param(of: s.a), t2 = base.param(of: s.b)
        let lo = min(t1, t2), hi = max(t1, t2)
        let gap = max(lo - base.length, -hi, 0)
        guard gap <= maxGapCm else { return nil }
        let a = base.a + base.direction * min(0, lo), b = base.a + base.direction * max(base.length, hi)
        var out = base
        out.center = (a + b) * 0.5
        out.length = a.distance(to: b)
        if let h = s.heightCm { out.heightCm = max(base.heightCm ?? h, h) }
        return out
    }

    // MARK: 旋转矩形（家具）

    /// 左上角 + 绕左上角旋转 → 中心
    public static func rectCenter(topLeft p: Point2, width w: Double, height h: Double, rotationDeg: Double) -> Point2 {
        StoreDataLoader.centerOfRect(x: p.x, y: p.y, width: w, height: h, rotationDeg: rotationDeg)
    }

    /// 中心 → 左上角（`rectCenter` 的逆运算）
    public static func rectTopLeft(center c: Point2, width w: Double, height h: Double, rotationDeg: Double) -> Point2 {
        let r = rotationDeg * Double.pi / 180
        let cs = cos(r), sn = sin(r)
        return Point2(c.x - (cs * w / 2 - sn * h / 2), c.y - (sn * w / 2 + cs * h / 2))
    }

    public struct RectItem: Equatable {
        public var category: String
        public var center: Point2
        public var width: Double
        public var height: Double
        public var rotationDeg: Double
    }

    /// MapShelf（扫描出的家具）→ 中心表示；类别取编号 `Room-类别-序号` 的中段，否则用整个编号
    public static func rect(_ e: [String: Any]) -> RectItem? {
        guard let type = e["shapeType"] as? String, topLeftTypes.contains(type),
              let x = num(e["x"]), let y = num(e["y"]) else { return nil }
        let w = num(e["width"]) ?? 0, h = num(e["height"]) ?? 0, rot = num(e["rotation"]) ?? 0
        return RectItem(category: furnitureCategory(e) ?? type, center: rectCenter(topLeft: Point2(x, y), width: w, height: h, rotationDeg: rot),
                        width: w, height: h, rotationDeg: rot)
    }

    /// 房间扫描家具编号 `Room-类别-序号` 里的类别；不是这种编号返回 nil
    public static func furnitureCategory(_ e: [String: Any]) -> String? {
        guard let code = e["code"] as? String, code.hasPrefix("Room-") else { return nil }
        let parts = code.split(separator: "-")
        guard parts.count >= 3 else { return nil }
        return parts[1..<(parts.count - 1)].joined(separator: "-")
    }

    // MARK: 元素的刚体变换

    /// 一个元素做刚体变换（地图坐标 → 新地图坐标），其余键原样保留
    public static func transform(element e: [String: Any], by t: MapARTransform) -> [String: Any] {
        var e = e
        let type = e["shapeType"] as? String ?? ""
        let dDeg = t.angleDeg
        if let pts = e["points"] as? [Any] {
            let v = pts.compactMap(num)
            var out: [Double] = []
            for i in stride(from: 0, to: v.count - 1, by: 2) {
                let q = t.toMap(Point2(v[i], v[i + 1])); out += [r1(q.x), r1(q.y)]
            }
            e["points"] = out
        }
        guard let x = num(e["x"]), let y = num(e["y"]) else { return e }
        let rot = num(e["rotation"]) ?? 0
        if topLeftTypes.contains(type) {
            let w = num(e["width"]) ?? 0, h = num(e["height"]) ?? 0
            let c = t.toMap(rectCenter(topLeft: Point2(x, y), width: w, height: h, rotationDeg: rot))
            let nr = r1(wrapDeg(rot + dDeg))
            let tl = rectTopLeft(center: c, width: w, height: h, rotationDeg: nr)
            e["x"] = r1(tl.x); e["y"] = r1(tl.y); e["rotation"] = nr
        } else {
            let c = t.toMap(Point2(x, y))
            e["x"] = r1(c.x); e["y"] = r1(c.y)
            if e["rotation"] != nil && dDeg != 0 { e["rotation"] = r1(wrapDeg(rot + dDeg)) }
        }
        return e
    }

    /// 元素的参考点（中心），算范围、判断在不在某块区域里用
    public static func center(_ e: [String: Any]) -> Point2? {
        if let r = rect(e) { return r.center }
        if let pts = e["points"] as? [Any] {
            let v = pts.compactMap(num)
            if v.count >= 4 { return Point2((v[0] + v[2]) / 2, (v[1] + v[3]) / 2) }
        }
        guard let x = num(e["x"]), let y = num(e["y"]) else { return nil }
        return Point2(x, y)
    }

    /// 元素占到的点（线段两端、矩形四角、其他元素的中心），算范围用
    public static func extentPoints(_ e: [String: Any]) -> [Point2] {
        if let s = segment(e) { return [s.a, s.b] }
        if let r = rect(e) {
            let rr = r.rotationDeg * Double.pi / 180
            let u = Point2(cos(rr), sin(rr)) * (r.width / 2), v = Point2(-sin(rr), cos(rr)) * (r.height / 2)
            return [r.center + u + v, r.center + u - v, r.center - u + v, r.center - u - v]
        }
        if let pts = e["points"] as? [Any] {
            let v = pts.compactMap(num)
            return stride(from: 0, to: v.count - 1, by: 2).map { Point2(v[$0], v[$0 + 1]) }
        }
        return center(e).map { [$0] } ?? []
    }

    // MARK: 多边形

    /// [x0, y0, x1, y1, …] → 点
    public static func polygon(_ v: Any?) -> [Point2] {
        let f = (v as? [Any] ?? []).compactMap(num)
        return stride(from: 0, to: f.count - 1, by: 2).map { Point2(f[$0], f[$0 + 1]) }
    }

    public static func flat(_ poly: [Point2]) -> [Double] { poly.flatMap { [r1($0.x), r1($0.y)] } }

    /// 面积（绝对值，cm²）
    public static func area(_ p: [Point2]) -> Double {
        var s = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; s += a.x * b.y - b.x * a.y }
        return abs(s) / 2
    }

    public static func centroid(_ p: [Point2]) -> Point2 { RoomMapBuilder.polygonCentroid(p) }

    /// 点到多边形边界的距离
    public static func distanceToBoundary(_ p: Point2, _ poly: [Point2]) -> Double {
        var best = Double.infinity
        for i in poly.indices {
            best = min(best, distanceToSegment(p, poly[i], poly[(i + 1) % poly.count]))
        }
        return best
    }

    public static func distanceToSegment(_ p: Point2, _ a: Point2, _ b: Point2) -> Double {
        let d = b - a, l2 = d.dot(d)
        guard l2 > 1e-12 else { return p.distance(to: a) }
        let t = min(max((p - a).dot(d) / l2, 0), 1)
        return p.distance(to: a + d * t)
    }

    /// 点在多边形里，或者在多边形外但离边界不超过 marginCm（多边形外扩判定）
    public static func isWithin(_ poly: [Point2], _ p: Point2, marginCm: Double) -> Bool {
        guard poly.count >= 3 else { return false }
        if pointInPolygon(p, poly) { return true }
        return marginCm > 0 && distanceToBoundary(p, poly) <= marginCm
    }

    /// `poly` 的面积里有多大比例落在 `others` 的并集里（按 step cm 的格子采样近似）
    public static func shareInside(_ poly: [Point2], _ others: [[Point2]], step: Double = 20) -> Double {
        guard poly.count >= 3, !others.isEmpty else { return 0 }
        let xs = poly.map(\.x), ys = poly.map(\.y)
        var n = 0, k = 0
        var y = ys.min()! + step / 2
        while y < ys.max()! {
            var x = xs.min()! + step / 2
            while x < xs.max()! {
                let p = Point2(x, y)
                if pointInPolygon(p, poly) {
                    n += 1
                    if others.contains(where: { pointInPolygon(p, $0) }) { k += 1 }
                }
                x += step
            }
            y += step
        }
        return n == 0 ? 0 : Double(k) / Double(n)
    }

    /// 两个单元是不是同一个房间：任一方的质心落在另一方里，并且面积比在 [1/ratio, ratio] 之内
    public static func sameRoom(_ a: [Point2], _ b: [Point2], maxAreaRatio: Double = 2) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return false }
        let aa = area(a), ab = area(b)
        guard aa > 0, ab > 0, max(aa, ab) / min(aa, ab) <= maxAreaRatio else { return false }
        return pointInPolygon(centroid(a), b) || pointInPolygon(centroid(b), a)
    }

    // MARK: 单元

    public struct UnitPolygon: Equatable {
        public var id: String
        public var category: String
        public var name: String?
        public var polygon: [Point2]
        public init(id: String, category: String, name: String?, polygon: [Point2]) {
            self.id = id; self.category = category; self.name = name; self.polygon = polygon
        }
    }

    public static func units(_ root: [String: Any]) -> [UnitPolygon] {
        (root["units"] as? [[String: Any]] ?? []).compactMap { u in
            let poly = polygon(u["polygon"])
            guard poly.count >= 3, let id = u["id"] as? String else { return nil }
            return UnitPolygon(id: id, category: u["category"] as? String ?? "room", name: u["name"] as? String, polygon: poly)
        }
    }

    public static func unitDict(_ u: UnitPolygon) -> [String: Any] {
        var d: [String: Any] = ["id": u.id, "category": u.category, "polygon": flat(u.polygon)]
        if let n = u.name, !n.isEmpty { d["name"] = n }
        return d
    }

    // MARK: JSON

    public static func root(_ json: Data) throws -> [String: Any] {
        guard var r = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw StoreDataError.unsupportedFormat("地图根节点不是对象")
        }
        if let d = r["data"] as? [String: Any], r["mapElementList"] == nil { r = d }
        return r
    }

    public static func data(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// map.json 里的 arAlign
    public static func arAlign(_ root: [String: Any]) -> MapARTransform? {
        guard let a = root["arAlign"] as? [String: Any], let phi = num(a["phi"]), let x = num(a["pRefX"]), let y = num(a["pRefY"]) else { return nil }
        return MapARTransform(pRef: Point2(x, y), aRef: Point2(num(a["aRefX"]) ?? 0, num(a["aRefY"]) ?? 0), phi: phi)
    }

    public static func alignDict(_ t: MapARTransform) -> [String: Any] {
        ["phi": t.phi, "pRefX": t.pRef.x, "pRefY": t.pRef.y, "aRefX": t.aRef.x, "aRefY": t.aRef.y]
    }
}

extension GeoRef {
    /// 地图坐标做了刚体变换（新坐标 = t.toMap(旧坐标)）之后的 geoRef：同一个物理点的经纬度不变。
    public func transformed(by t: MapARTransform) -> GeoRef {
        var g = self
        g.rotationDeg = GeoRef.wrapDeg(rotationDeg - t.angleDeg)
        let ll = toLonLat(t.toAR(Point2(marginCm, marginCm)))
        g.lon0 = ll.lon
        g.lat0 = ll.lat
        return g
    }
}
