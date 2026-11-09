import Foundation

/// 地图原点平移：新内容伸到 x < 0 或 y < 0（接着扫往左 / 往上扩）时，整张图平移一次，让坐标重新从留白开始。
///
/// 只处理地图本身：map.json（元素、单元、floor / obstacle 多边形、connectors、geoRef 的 lon0/lat0、geoAnchor、
/// arAlign.pRef、宽高、originOffsetCm 累加）和特征地图旁注（`WorldMapSidecar.shifted`，frameId 不变）。
/// 磁场图 / 涂色 / 蓝牙这些按格子存的本机数据在几何一变时本来就会被清掉（尺寸对不上），不搬运；
/// 采集会话文件不改写：会话 meta 记着录制时的偏移，读的时候按差值换算（`SurveySessionLoader`）。
///
/// 平移量必须是 `stepCm`（50 cm，磁场格 50 cm、涂色格 25 cm 的公倍数）的整数倍。
public enum MapFrameShift {
    public static let stepCm = 50.0

    public enum ShiftError: Error, CustomStringConvertible {
        case notMultiple(Point2)
        public var description: String {
            switch self { case .notMultiple(let p): return "原点平移量 \(p) 不是 \(Int(MapFrameShift.stepCm)) cm 的整数倍" }
        }
    }

    /// 内容范围的最小坐标是 (minX, minY) 时，为了留出 marginCm 留白需要的平移（向上取到 stepCm 的整数倍；不需要时为 0）
    public static func requiredShift(minX: Double, minY: Double, marginCm: Double = RoomMapBuilder.marginCm) -> Point2 {
        func need(_ m: Double) -> Double {
            guard m < marginCm - 0.05 else { return 0 }
            return ((marginCm - m) / stepCm).rounded(.up) * stepCm
        }
        return Point2(need(minX), need(minY))
    }

    static func check(_ s: Point2) throws {
        func ok(_ v: Double) -> Bool { abs(v / stepCm - (v / stepCm).rounded()) < 1e-9 }
        guard ok(s.x), ok(s.y) else { throw ShiftError.notMultiple(s) }
    }

    /// map.json 整体平移（新坐标 = 旧坐标 + shift）
    public static func apply(mapJSON: Data, shift: Point2) throws -> Data {
        try check(shift)
        var root = try MapGeometry.root(mapJSON)
        apply(&root, shift: shift)
        return try MapGeometry.data(root)
    }

    /// 同上，直接改字典
    public static func apply(_ root: inout [String: Any], shift s: Point2) {
        let t = MapARTransform(pRef: s, aRef: .zero, phi: 0)
        let r1 = MapGeometry.r1
        func shiftPoly(_ v: Any?) -> [Double] { MapGeometry.flat(MapGeometry.polygon(v).map { $0 + s }) }
        if let els = root["mapElementList"] as? [[String: Any]] {
            root["mapElementList"] = els.map { MapGeometry.transform(element: $0, by: t) }
        }
        if var units = root["units"] as? [[String: Any]] {
            for i in units.indices { units[i]["polygon"] = shiftPoly(units[i]["polygon"]) }
            root["units"] = units
        }
        for k in ["floorPolygons", "obstaclePolygons"] {
            if let polys = root[k] as? [Any] { root[k] = polys.map { shiftPoly($0) } }
        }
        if var conns = root["connectors"] as? [[String: Any]] {
            for i in conns.indices {
                if let x = MapGeometry.num(conns[i]["x"]), let y = MapGeometry.num(conns[i]["y"]) {
                    conns[i]["x"] = r1(x + s.x); conns[i]["y"] = r1(y + s.y)
                }
                if conns[i]["polygon"] != nil { conns[i]["polygon"] = shiftPoly(conns[i]["polygon"]) }
            }
            root["connectors"] = conns
        }
        if let g = GeoRef(dict: root["geoRef"] as? [String: Any]) { root["geoRef"] = g.transformed(by: t).dict }
        if var a = root["geoAnchor"] as? [String: Any], let x = MapGeometry.num(a["x"]), let y = MapGeometry.num(a["y"]) {
            a["x"] = r1(x + s.x); a["y"] = r1(y + s.y)
            root["geoAnchor"] = a
        }
        if let al = MapGeometry.arAlign(root) { root["arAlign"] = MapGeometry.alignDict(al.translated(by: s)) }
        if let w = MapGeometry.num(root["width"]) { root["width"] = r1(w + s.x) }
        if let h = MapGeometry.num(root["height"]) { root["height"] = r1(h + s.y) }
        let o = root["originOffsetCm"] as? [Any] ?? []
        let ox = (o.count >= 2 ? MapGeometry.num(o[0]) : nil) ?? 0, oy = (o.count >= 2 ? MapGeometry.num(o[1]) : nil) ?? 0
        root["originOffsetCm"] = [ox + s.x, oy + s.y]
    }
}
