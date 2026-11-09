import Foundation

/// 一张地图的扫描段注册表（`Documents/maps/<mapId>/scans.json`）。
///
/// 一张地图可以分几次扫：每次扫描是一个「段」，各自 build 出自己的 map.json（自己的坐标系），
/// 存在 `scans/<scanId>/map.json`，写入后不再修改；`toMap` 把这一段的坐标变换到合成地图坐标。
/// 合成地图（地图目录里的 map.json）由 `MapComposer.compose` 按注册表重新生成：加段 = 接着扫，
/// 关掉一段 = 撤销那次扫描（追加的东西消失、被它替换掉的旧东西回来），所以注册表本身就是撤销机制。
///
/// 全部是返回新值的纯函数，不碰文件系统；读写文件由 App 负责。
public struct ScanRegistry: Codable, Equatable {
    public static let fileName = "scans.json"
    public static let currentVersion = 1

    /// 段怎么对到地图上的
    public enum Alignment: String, Codable {
        /// 第一段：它的 AR 坐标系就是地图的基准坐标系
        case base
        /// 视觉重定位认出了已扫区域，和基准同一个 AR 坐标系
        case worldmap
        /// 自动几何对齐（墙 / 门）
        case geometry
        /// 手动两点对齐
        case manual
    }

    /// 合成方式
    public enum Mode: String, Codable {
        /// 追加：保留旧的，重复的墙 / 门窗 / 家具去重，只补缺的
        case append
        /// 替换：先删掉这一段足迹（单元外扩 30 cm）里的旧东西，再放新的
        case replace
    }

    public struct Quality: Codable, Equatable {
        /// 新段墙体和已有墙体重合的长度（cm）
        public var overlapCm: Double
        /// 重合部分的平均偏差（cm）
        public var residualCm: Double
        public var maxResidualCm: Double?
        /// 几何对齐有歧义（次优解得分接近最优）
        public var ambiguous: Bool
        public init(overlapCm: Double, residualCm: Double, maxResidualCm: Double? = nil, ambiguous: Bool = false) {
            self.overlapCm = overlapCm; self.residualCm = residualCm; self.maxResidualCm = maxResidualCm; self.ambiguous = ambiguous
        }
    }

    public struct UnitLabel: Codable, Equatable {
        public var category: String?
        public var name: String?
        public init(category: String? = nil, name: String? = nil) { self.category = category; self.name = name }
    }

    public struct ScanRecord: Codable, Equatable {
        public var id: String
        public var name: String?
        public var createdMs: Int64
        public var enabled: Bool
        /// roomplan / legacy（老地图懒生成的基准段）/ import
        public var source: String
        public var osMajor: Int?
        public var roomCount: Int?
        /// 这一段扫描时的 AR 坐标系就是地图的基准坐标系（base / worldmap）。几何 / 手动对齐的段不是
        public var inBaseFrame: Bool
        /// 这一段 map.json 坐标 → 合成地图坐标（刚体，cm）
        public var toMap: WorldMapSidecar.Align
        public var alignment: Alignment
        public var quality: Quality?
        public var mode: Mode
        /// replace 时被替换掉的单元（合成时记下，只作说明）
        public var replaces: [String]?
        /// 本段局部单元编号 → 全局编号（加入时一次性分配，之后稳定）
        public var unitIds: [String: String]

        public init(id: String, name: String? = nil, createdMs: Int64, enabled: Bool = true, source: String = "roomplan",
                    osMajor: Int? = nil, roomCount: Int? = nil, inBaseFrame: Bool, toMap: MapARTransform,
                    alignment: Alignment, quality: Quality? = nil, mode: Mode = .append, replaces: [String]? = nil,
                    unitIds: [String: String] = [:]) {
            self.id = id; self.name = name; self.createdMs = createdMs; self.enabled = enabled; self.source = source
            self.osMajor = osMajor; self.roomCount = roomCount; self.inBaseFrame = inBaseFrame
            self.toMap = WorldMapSidecar.Align(toMap); self.alignment = alignment; self.quality = quality
            self.mode = mode; self.replaces = replaces; self.unitIds = unitIds
        }

        public var transform: MapARTransform { toMap.transform }

        /// 和基准同一个 AR 坐标系的段（视觉重定位认出来的）：段坐标 → AR →（地图 arAlign）→ 地图
        public static func toMapInBaseFrame(scanAlign: MapARTransform, frameAlign: MapARTransform) -> MapARTransform {
            scanAlign.inverse.compose(frameAlign)
        }
    }

    public var version: Int = ScanRegistry.currentVersion
    public var mapId: String
    /// 基准 AR 坐标系的身份；和 map.json、特征地图旁注一致
    public var frameId: String
    /// 基准 AR 坐标系 → 合成地图坐标（= 合成地图的 arAlign）；没有 AR 信息的地图为 nil
    public var frameAlign: WorldMapSidecar.Align?
    /// 累计原点平移（cm）
    public var originOffsetCm: [Double] = [0, 0]
    /// 每次几何改动递增（Unix 毫秒，单调）
    public var geometryVersion: Int64
    /// 合成地图的画布（cm，[宽, 高]），只增不减：关掉一段不缩小画布，磁场格 / 涂色尺寸不跟着变
    public var canvasCm: [Double]?
    /// 地图名（楼层名）；nil = 用第一段的
    public var name: String?
    public var scans: [ScanRecord]
    /// 用户填的类别 / 名字（按全局单元编号），和扫描段无关，重新合成时套回去
    public var unitLabels: [String: UnitLabel] = [:]

    public init(mapId: String, frameId: String, frameAlign: MapARTransform?, geometryVersion: Int64,
                scans: [ScanRecord] = [], name: String? = nil) {
        self.mapId = mapId; self.frameId = frameId; self.frameAlign = frameAlign.map(WorldMapSidecar.Align.init)
        self.geometryVersion = geometryVersion; self.scans = scans; self.name = name
    }

    public var originOffset: Point2 { Point2(originOffsetCm.first ?? 0, originOffsetCm.count > 1 ? originOffsetCm[1] : 0) }

    // MARK: 编码

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ d: Data) -> ScanRegistry? { try? JSONDecoder().decode(ScanRegistry.self, from: d) }

    // MARK: 新建 / 迁移

    /// 第一次扫描（新建地图）：这一段就是基准，它的 AR 坐标系就是地图的坐标系，toMap = 恒等。
    public static func newMap(mapId: String, frameId: String, scanId: String, scanJSON: Data, createdMs: Int64,
                              name: String? = nil, osMajor: Int? = nil, roomCount: Int? = nil) throws -> ScanRegistry {
        let root = try MapGeometry.root(scanJSON)
        var r = ScanRegistry(mapId: mapId, frameId: frameId, frameAlign: MapGeometry.arAlign(root), geometryVersion: createdMs, name: name)
        if let w = MapGeometry.num(root["width"]), let h = MapGeometry.num(root["height"]) { r.canvasCm = [w, h] }
        r.scans = [ScanRecord(id: scanId, name: name, createdMs: createdMs, osMajor: osMajor, roomCount: roomCount,
                              inBaseFrame: true, toMap: .identity, alignment: .base)]
        return r
    }

    /// 没有注册表的老地图（含云端装的）：把当前 map.json 拷一份当基准段（toMap = 恒等），单元编号原样保留。
    /// frameId 取 map.json 的、旁注的，都没有就用 `newFrameId`。App 把 `scanId` 目录写成 map.json 的拷贝。
    public static func legacy(mapId: String, mapJSON: Data, sidecar: WorldMapSidecar?, newFrameId: String,
                              nowMs: Int64, scanId: String = "base") throws -> ScanRegistry {
        let root = try MapGeometry.root(mapJSON)
        let frameId = (root["frameId"] as? String) ?? sidecar?.frameId ?? newFrameId
        let gv = (MapGeometry.num(root["geometryVersion"])).map { Int64($0) } ?? nowMs
        var r = ScanRegistry(mapId: mapId, frameId: frameId, frameAlign: MapGeometry.arAlign(root), geometryVersion: gv,
                             name: root["floorName"] as? String)
        if let o = root["originOffsetCm"] as? [Any], o.count >= 2 {
            r.originOffsetCm = [MapGeometry.num(o[0]) ?? 0, MapGeometry.num(o[1]) ?? 0]
        }
        if let w = MapGeometry.num(root["width"]), let h = MapGeometry.num(root["height"]) { r.canvasCm = [w, h] }
        var ids: [String: String] = [:]
        for u in MapGeometry.units(root) { ids[u.id] = u.id }
        r.scans = [ScanRecord(id: scanId, name: nil, createdMs: 0, source: "legacy", inBaseFrame: true, toMap: .identity,
                              alignment: .base, unitIds: ids)]
        return r
    }

    // MARK: 操作（返回新值）

    /// 几何改动后的版本号：比旧的大，尽量等于当前时间
    public func bumpedVersion(nowMs: Int64) -> ScanRegistry {
        var r = self
        r.geometryVersion = max(geometryVersion + 1, nowMs)
        return r
    }

    public func adding(_ rec: ScanRecord, nowMs: Int64) -> ScanRegistry {
        var r = self
        r.scans.removeAll { $0.id == rec.id }
        r.scans.append(rec)
        return r.bumpedVersion(nowMs: nowMs)
    }

    public func settingEnabled(_ id: String, _ on: Bool, nowMs: Int64) -> ScanRegistry {
        var r = self
        guard let i = r.scans.firstIndex(where: { $0.id == id }), r.scans[i].enabled != on else { return self }
        r.scans[i].enabled = on
        return r.bumpedVersion(nowMs: nowMs)
    }

    public func removing(_ id: String, nowMs: Int64) -> ScanRegistry {
        var r = self
        guard r.scans.contains(where: { $0.id == id }) else { return self }
        r.scans.removeAll { $0.id == id }
        return r.bumpedVersion(nowMs: nowMs)
    }

    public func renamingScan(_ id: String, _ name: String?) -> ScanRegistry {
        var r = self
        if let i = r.scans.firstIndex(where: { $0.id == id }) { r.scans[i].name = name }
        return r
    }

    /// 改一个单元的类别 / 名字（nil = 不改；名字给空串 = 删掉名字）
    public func relabel(unit: String, category: String? = nil, name: String? = nil, nowMs: Int64) -> ScanRegistry {
        var r = self
        var l = r.unitLabels[unit] ?? UnitLabel()
        if let c = category { l.category = c }
        if let n = name {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            l.name = t
        }
        r.unitLabels[unit] = l
        return r.bumpedVersion(nowMs: nowMs)
    }

    /// 按时间顺序（同时间按编号）的段
    public var ordered: [ScanRecord] {
        scans.sorted { $0.createdMs != $1.createdMs ? $0.createdMs < $1.createdMs : $0.id < $1.id }
    }

    /// 所有段已经分配出去的全局单元编号
    public var assignedUnitIds: Set<String> { Set(scans.flatMap { $0.unitIds.values }) }

    /// 下一个没用过的全局单元编号 R<n>（n = 已用的 R 编号最大值 + 1）
    public static func nextUnitId(used: Set<String>) -> String {
        var n = 0
        for u in used where u.hasPrefix("R") { if let k = Int(u.dropFirst()) { n = max(n, k) } }
        var id = "R\(n + 1)"
        while used.contains(id) { n += 1; id = "R\(n + 1)" }
        return id
    }

    /// map.json 里的 `scans` 只读摘要
    public var summary: [[String: Any]] {
        ordered.map { s in
            var d: [String: Any] = ["id": s.id, "enabled": s.enabled, "alignment": s.alignment.rawValue, "mode": s.mode.rawValue]
            if let n = s.name { d["name"] = n }
            return d
        }
    }

    /// 原点平移：所有段的 toMap、基准 arAlign、画布一起平移，累计偏移加上
    public func shifted(by s: Point2) -> ScanRegistry {
        var r = self
        for i in r.scans.indices { r.scans[i].toMap = .init(r.scans[i].transform.translated(by: s)) }
        if let f = frameAlign { r.frameAlign = .init(f.transform.translated(by: s)) }
        let o = originOffset + s
        r.originOffsetCm = [o.x, o.y]
        if let c = canvasCm, c.count >= 2 { r.canvasCm = [c[0] + s.x, c[1] + s.y] }
        return r
    }
}
