import Foundation

/// 房间扫描（Apple RoomPlan）的结果，换成和门店地图同一种 JSON（`mapElementList` 等），
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
        public init() {}
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

        // 2. 地面：没有就用墙端点的凸包
        var floors = input.floors
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
        let polys: [[Double]] = floors.map { f in f.flatMap { p -> [Double] in let q = toMap(p); return [r1(q.x), r1(q.y)] } }
        let root: [String: Any] = [
            "width": r1((maxX - minX) * 100 + 2 * m), "height": r1((maxY - minY) * 100 + 2 * m),
            "floorName": name, "source": "roomplan", "rotatedDeg": r1(theta * 180 / Double.pi),
            "mapElementList": elements, "floorPolygons": polys,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return (data, try StoreDataLoader.loadMap(data))
    }

    /// 凸包（Andrew 单调链），逆时针。
    static func convexHull(_ pts: [Point2]) -> [Point2] {
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
