import Foundation
import HPASSKit

/// 地图的扫描段：一张地图可以分几次扫（接着扫扩大范围、重扫某块精细化），每次是一段。
///
/// 目录（在地图目录里，只做加法）：
/// - `scans.json`：扫描段注册表（`ScanRegistry`）
/// - `scans/<scanId>/map.json`：这一段单独生成的地图（自己的坐标系），写入后不再修改；
///   同目录还有原始 `captured_room.json`、`room.usdz`、这一段结束时的特征地图（`worldmap.arexperience` + 说明）
/// - `map.json`：按注册表合成的结果（`MapComposer`），建图采集、定位、显示、上传都只读它
///
/// 老地图（没有 scans.json，含云端装的）第一次需要时生成注册表：`scans/base/map.json` = 当时 map.json 的拷贝。
/// 设计和规则见 docs/scan-and-map-management.md。
extension MapLibrary {
    enum ScanError: LocalizedError {
        case lastScan, noMap
        var errorDescription: String? {
            switch self {
            case .lastScan: return "这是这张地图唯一启用的扫描段，不能关掉或删除；不要这张地图了就删除整张地图"
            case .noMap: return "找不到这张地图"
            }
        }
    }

    func registryURL(_ id: String) -> URL { dir(id).appendingPathComponent(ScanRegistry.fileName) }
    func scansDir(_ id: String) -> URL { dir(id).appendingPathComponent("scans", isDirectory: true) }
    func scanDir(_ id: String, _ scanId: String) -> URL { scansDir(id).appendingPathComponent(scanId, isDirectory: true) }

    /// 读注册表（不生成）
    func storedRegistry(_ id: String) -> ScanRegistry? {
        (try? Data(contentsOf: registryURL(id))).flatMap(ScanRegistry.decode)
    }

    /// 读注册表；老地图没有就按当前 map.json 生成一个基准段（不改 map.json）
    func registry(_ id: String) throws -> ScanRegistry {
        if let r = storedRegistry(id) { return r }
        guard entries.contains(where: { $0.id == id }) else { throw ScanError.noMap }
        let fm = FileManager.default
        let json = try Data(contentsOf: mapURL(id))
        let side = WorldMapKeeper.readSidecar(id)
        let r = try ScanRegistry.legacy(mapId: id, mapJSON: json, sidecar: side, newFrameId: UUID().uuidString, nowMs: Fmt.nowMs())
        let sd = scanDir(id, "base")
        try fm.createDirectory(at: sd, withIntermediateDirectories: true)
        try json.write(to: sd.appendingPathComponent("map.json"), options: .atomic)
        try r.encoded().write(to: registryURL(id), options: .atomic)
        // 在用的特征地图和这张地图的 AR 对齐一致：说明里记上基准坐标系的 frameId（之后原点平移了也认得）
        if var s = side, s.frameId == nil, let a = (try? StoreDataLoader.loadMap(json))?.arAlign, s.isCompatible(with: a) {
            s.frameId = r.frameId
            try? s.encoded().write(to: WorldMapKeeper.sidecarURL(id), options: .atomic)
        }
        AppLog.i("地图库", "「\(entries.first { $0.id == id }?.name ?? id)」第一次管理扫描段：当前地图记为基准段")
        return r
    }

    /// 注册表里各段的 map.json
    func scanJSONs(_ id: String, _ r: ScanRegistry) -> [String: Data] {
        var out: [String: Data] = [:]
        for s in r.scans {
            if let d = try? Data(contentsOf: scanDir(id, s.id).appendingPathComponent("map.json")) { out[s.id] = d }
        }
        return out
    }

    /// 按注册表重新合成并写回。几何改动（加段、关掉 / 删除段、改单元、改楼层）都走这里。
    /// 在用的地图立刻生效；云端那份标记为要重新上传。
    @discardableResult
    func recompose(_ id: String, registry: ScanRegistry) throws -> MapComposer.Result {
        let res = try MapComposer.compose(registry: registry, scans: scanJSONs(id, registry))
        _ = try StoreDataLoader.loadMap(res.json)            // 能读才写
        try res.json.write(to: mapURL(id), options: .atomic)
        try res.registry.encoded().write(to: registryURL(id), options: .atomic)
        if let s = res.originShift { applyOriginShift(id, s) }
        Telemetry.shared.invalidateUploadedMap(id)
        if id == activeId {
            try StoreDataStore.shared.save(res.json, as: .map)
            if res.originShift != nil { MagMapStore.shared.reloadFromDisk() }
            MagMapStore.shared.adopt(map: StoreDataStore.shared.map)
            Telemetry.shared.mapChanged()
        }
        geometryRevision += 1
        return res
    }

    /// 地图原点平移了（新内容伸到了左边 / 上边）：特征地图说明一起平移（frameId 不变）；
    /// 按格子存的定位数据（磁场图、涂色、方向图、蓝牙）对不上了，清掉，等重新采集 / 云端重新生成。点位一起平移。
    private func applyOriginShift(_ id: String, _ s: Point2) {
        let fm = FileManager.default
        let sideURL = WorldMapKeeper.sidecarURL(id)
        if let side = (try? Data(contentsOf: sideURL)).flatMap(WorldMapSidecar.decode) {
            try? side.shifted(by: s).encoded().write(to: sideURL, options: .atomic)
        }
        let ws = workspaceDir(id)
        let mm = ws.appendingPathComponent("magmap.json")
        if let d = try? Data(contentsOf: mm), var root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            root.removeValue(forKey: "magField")
            root.removeValue(forKey: "magStats")
            if let pts = root["markPoints"] as? [[String: Any]] {
                root["markPoints"] = pts.map { p -> [String: Any] in
                    var q = p
                    if let x = (p["x"] as? NSNumber)?.doubleValue { q["x"] = Int((x + s.x).rounded()) }
                    if let y = (p["y"] as? NSNumber)?.doubleValue { q["y"] = Int((y + s.y).rounded()) }
                    return q
                }
            }
            if let out = try? JSONSerialization.data(withJSONObject: root) { try? out.write(to: mm, options: .atomic) }
        }
        for f in ["survey-paint.bin", "survey-coverage.json", "ble-fingerprint.json", "build-state.json", "live-monitor.json"] {
            try? fm.removeItem(at: ws.appendingPathComponent(f))
        }
        try? fm.removeItem(at: cloudPaintURL(id))
        try? fm.removeItem(at: cloudDirectionURL(id))
        AppLog.w("地图库", "地图原点平移了 (\(Int(s.x)), \(Int(s.y))) cm（新扫的地方伸到了左边 / 上边）："
                 + "本机磁场图、涂色已清空，点位已跟着平移；采集上传后等云端重新生成")
    }

    // MARK: 段操作

    func setScanEnabled(_ id: String, _ scanId: String, _ on: Bool) throws {
        let r = try registry(id)
        if !on, r.scans.filter(\.enabled).map(\.id) == [scanId] { throw ScanError.lastScan }
        try recompose(id, registry: r.settingEnabled(scanId, on, nowMs: Fmt.nowMs()))
        AppLog.i("地图库", "扫描段 \(scanId)：\(on ? "启用" : "关掉")")
    }

    func removeScan(_ id: String, _ scanId: String) throws {
        let r = try registry(id)
        let rest = r.removing(scanId, nowMs: Fmt.nowMs())
        guard rest.scans.contains(where: \.enabled) else { throw ScanError.lastScan }
        try recompose(id, registry: rest)
        try? FileManager.default.removeItem(at: scanDir(id, scanId))
        AppLog.w("地图库", "删除了扫描段 \(scanId)")
    }

    func renameScan(_ id: String, _ scanId: String, _ name: String) throws {
        let r = try registry(id)
        let n = name.trimmingCharacters(in: .whitespaces)
        try r.renamingScan(scanId, n.isEmpty ? nil : n).encoded().write(to: registryURL(id), options: .atomic)
        geometryRevision += 1
    }

    /// 改一个单元（房间）的类别 / 名字：记进注册表再重新合成（直接改 map.json 会在下次合成时被覆盖）
    func relabelUnit(_ id: String, unit: String, category: String, name: String) throws {
        let r = try registry(id)
        try recompose(id, registry: r.relabel(unit: unit, category: category, name: name, nowMs: Fmt.nowMs()))
    }

    /// 改楼层名 / 楼层序号
    func setLevel(_ id: String, floorName: String, ordinal: Int) throws {
        var r = try registry(id)
        if !floorName.isEmpty { r.name = floorName }
        r.ordinal = ordinal
        try recompose(id, registry: r.bumpedVersion(nowMs: Fmt.nowMs()))
    }

    // MARK: 扫描结果入库

    /// 接着扫时 ARKit 要载入的特征地图：最近一段在基准坐标系里扫的段自己存的那份（完整，不受上传大小限制），
    /// 没有就用地图目录里在用的那份。
    func relocalizationWorldMap(_ id: String) -> URL? {
        let fm = FileManager.default
        if let r = storedRegistry(id) {
            for s in r.ordered.reversed() where s.enabled && s.inBaseFrame {
                let u = scanDir(id, s.id).appendingPathComponent(Self.worldMapFile)
                if fm.fileExists(atPath: u.path) { return u }
            }
        }
        return worldMapURL(id)
    }

    /// 第一次扫描生成新地图：`scans/<scanId>/` 里已经写好这一段的文件。合成、加进地图库并切换过去。
    @discardableResult
    func createFromScan(mapId id: String, name: String, scanId: String, frameId: String,
                        osMajor: Int?, roomCount: Int?) throws -> Entry {
        let scanJSON = try Data(contentsOf: scanDir(id, scanId).appendingPathComponent("map.json"))
        let reg = try ScanRegistry.newMap(mapId: id, frameId: frameId, scanId: scanId, scanJSON: scanJSON,
                                          createdMs: Fmt.nowMs(), name: name, osMajor: osMajor, roomCount: roomCount)
        let res = try MapComposer.compose(registry: reg, scans: [scanId: scanJSON])
        try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        try res.json.write(to: mapURL(id), options: .atomic)
        try res.registry.encoded().write(to: registryURL(id), options: .atomic)
        let e = Entry(id: id, name: name, kind: "room", created: Date())
        upsert(e)
        installScanWorldMap(id, scanId: scanId, registry: res.registry, source: "scan")
        try activate(id)
        geometryRevision += 1
        AppLog.i("地图库", "新建地图「\(name)」（扫描段 \(scanId)）")
        return e
    }

    /// 接着扫 / 重扫的一段确认合并：加进注册表、重新合成；这一段在基准坐标系里时，它结束时的特征地图
    /// （覆盖新旧区域）顶替在用的那份。之后切换到这张地图。
    @discardableResult
    func commitScan(_ id: String, record: ScanRegistry.ScanRecord) throws -> MapComposer.Result {
        let r = try registry(id)
        let res = try recompose(id, registry: r.adding(record, nowMs: Fmt.nowMs()))
        if record.inBaseFrame { installScanWorldMap(id, scanId: record.id, registry: res.registry, source: "scan-append") }
        if id != activeId { try activate(id) }
        AppLog.i("地图库", "扫描段 \(record.id) 合并进「\(entries.first { $0.id == id }?.name ?? id)」：\(record.alignment.rawValue) / \(record.mode.rawValue)")
        return res
    }

    /// 放弃一段（合并预览里点了放弃）：删掉它的目录
    func discardScan(_ id: String, _ scanId: String) {
        try? FileManager.default.removeItem(at: scanDir(id, scanId))
    }

    /// 这一段另存为一张新地图（认不出、也对不上的时候）：把段目录搬到新地图下
    @discardableResult
    func detachScanAsNewMap(from id: String, scanId: String, name: String) throws -> Entry {
        let newId = newMapId(kind: "room")
        let fm = FileManager.default
        try fm.createDirectory(at: scansDir(newId), withIntermediateDirectories: true)
        try fm.moveItem(at: scanDir(id, scanId), to: scanDir(newId, scanId))
        let json = try Data(contentsOf: scanDir(newId, scanId).appendingPathComponent("map.json"))
        let frameId = ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any])?["frameId"] as? String ?? UUID().uuidString
        return try createFromScan(mapId: newId, name: name, scanId: scanId, frameId: frameId, osMajor: nil, roomCount: nil)
    }

    /// 段目录里的特征地图复制成地图在用的那份（说明：基准坐标系 frameId、合成地图的 arAlign、还没上传）。
    /// 在用的那份要随会话上传、打进云端包，超过上限就不复制（段目录里的完整那份仍可用来接着扫）。
    private func installScanWorldMap(_ id: String, scanId: String, registry r: ScanRegistry, source: String) {
        let src = scanDir(id, scanId).appendingPathComponent(Self.worldMapFile)
        guard let data = try? Data(contentsOf: src), let align = r.frameAlign?.transform else { return }
        if let p = WorldMapPolicy.sizeProblem(data.count) {
            AppLog.w(WorldMapKeeper.tag, "这一段的特征地图\(p)，不顶替在用的那份（接着扫仍会用段里的完整那份）")
            return
        }
        let side = WorldMapSidecar(createdMs: Fmt.nowMs(), source: source, mapId: id, arAlign: align, bytes: data.count,
                                   uploaded: false, frameId: r.frameId)
        do {
            try data.write(to: dir(id).appendingPathComponent(Self.worldMapFile), options: .atomic)
            try side.encoded().write(to: WorldMapKeeper.sidecarURL(id), options: .atomic)
        } catch {
            AppLog.w(WorldMapKeeper.tag, "保存特征地图失败：\(error.localizedDescription)")
        }
    }

    /// 录会话时写进 meta.json 的地图信息：读会话时据此换算原点平移（老会话没有，按 [0, 0]）
    var sessionMapMeta: [String: Any] {
        guard let id = activeId, let d = try? Data(contentsOf: mapURL(id)),
              let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        var m: [String: Any] = [:]
        if let o = root["originOffsetCm"] as? [Any], o.count >= 2 { m["map_origin_offset_cm"] = o }
        if let v = root["geometryVersion"] as? NSNumber { m["map_geometry_version"] = v }
        if let f = root["frameId"] as? String { m["map_frame_id"] = f }
        return m
    }
}
