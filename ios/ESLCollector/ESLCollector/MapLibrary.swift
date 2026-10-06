import Foundation
import HPASSKit
import SwiftUI

/// 地图库：门店地图、扫描的房间……可以随时切换。
///
/// 每张地图有自己的一套「工作区」：磁场图和点位（magmap.json）、采集进度（survey-coverage.json）、
/// 涂色（survey-paint.bin）、磁场图来源说明。切换时把当前这套收进旧地图的目录，再把新地图那套放回来，
/// 所以换来换去不会互相覆盖。建图采集会话里记着地图编号，生成磁场图时只列出当前地图的会话。
///
/// 目录：Documents/maps/<id>/map.json、meta.json、workspace/…
@MainActor
final class MapLibrary: ObservableObject {
    static let shared = MapLibrary()

    struct Entry: Identifiable, Codable, Equatable {
        var id: String
        var name: String
        /// store = 门店地图（通道），room = 房间扫描
        var kind: String
        var created: Date
        var isRoom: Bool { kind == "room" }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var activeId: String?
    @Published private(set) var lastError: String?

    var active: Entry? { entries.first { $0.id == activeId } }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("maps", isDirectory: true)
    }
    private static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// 工作区文件（都在 Documents 根目录，按地图收放）
    private static let workspaceFiles = ["magmap.json", "survey-coverage.json", "survey-paint.bin", "ble-fingerprint.json", "build-state.json"]
    private static let fieldSourceKey = "magFieldSource"
    private static let activeKey = "mapLibraryActive"

    private func dir(_ id: String) -> URL { Self.root.appendingPathComponent(id, isDirectory: true) }
    func mapURL(_ id: String) -> URL { dir(id).appendingPathComponent("map.json") }
    static let worldMapFile = "worldmap.arexperience"
    /// 这张地图的视觉特征地图（房间扫描时存的）；没有为 nil
    func worldMapURL(_ id: String) -> URL? {
        let u = dir(id).appendingPathComponent(Self.worldMapFile)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    var activeWorldMapURL: URL? { activeId.flatMap(worldMapURL) }

    private init() {
        load()
        migrateIfNeeded()
    }

    private func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        entries = dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")) else { return nil }
            return try? dec.decode(Entry.self, from: data)
        }.sorted { $0.created < $1.created }
        activeId = UserDefaults.standard.string(forKey: Self.activeKey)
        if let a = activeId, !entries.contains(where: { $0.id == a }) { activeId = nil }
    }

    /// 第一次用地图库：把现在「门店数据」里的地图收进来当第一张，当前工作区就归它
    private func migrateIfNeeded() {
        guard entries.isEmpty else { return }
        let cur = StoreDataStore.shared.url(for: .map)
        guard let data = try? Data(contentsOf: cur), let m = try? StoreDataLoader.loadMap(data) else { return }
        let isRoom = m.crosses.isEmpty && !m.floor.isEmpty
        if let e = try? add(data: data, name: m.floorName ?? (isRoom ? "房间" : "门店地图"), kind: isRoom ? "room" : "store") {
            setActive(e.id)
            AppLog.i("地图库", "已把当前地图收进地图库：\(e.name)")
        }
    }

    // MARK: 增删改

    /// 加一张地图（不切换）。
    @discardableResult
    func add(data: Data, name: String, kind: String, extraFiles: [URL] = []) throws -> Entry {
        _ = try StoreDataLoader.loadMap(data)            // 先确认能解析
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        var id = "\(kind)_\(df.string(from: Date()))"
        while entries.contains(where: { $0.id == id }) { id += "_1" }
        let e = Entry(id: id, name: name, kind: kind, created: Date())
        try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        try data.write(to: mapURL(id))
        for f in extraFiles { try? FileManager.default.copyItem(at: f, to: dir(id).appendingPathComponent(f.lastPathComponent)) }
        try writeMeta(e)
        entries.append(e)
        AppLog.i("地图库", "加入地图：\(name)（\(kind == "room" ? "房间" : "门店")）")
        return e
    }

    /// 加一张地图并切换过去。
    @discardableResult
    func importAndActivate(data: Data, name: String, kind: String, extraFiles: [URL] = []) throws -> Entry {
        let e = try add(data: data, name: name, kind: kind, extraFiles: extraFiles)
        try activate(e.id)
        return e
    }

    func rename(_ id: String, to name: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        entries[i].name = n
        try? writeMeta(entries[i])
    }

    /// 删除（当前在用的不能删）。会话文件不删。
    func delete(_ id: String) {
        guard id != activeId else { lastError = "当前在用的地图不能删除，先切换到别的地图"; return }
        try? FileManager.default.removeItem(at: dir(id))
        entries.removeAll { $0.id == id }
        AppLog.w("地图库", "已删除地图 \(id)")
    }

    /// 门店数据页下载 / 更新了地图：同步进当前这张
    func syncActive(_ data: Data) {
        guard let a = activeId else { return }
        if (try? Data(contentsOf: mapURL(a))) != data { try? data.write(to: mapURL(a)) }
    }

    // MARK: 切换

    func activate(_ id: String) throws {
        guard id != activeId else { return }
        guard let e = entries.first(where: { $0.id == id }) else { return }
        let data = try Data(contentsOf: mapURL(id))
        if let old = activeId { stashWorkspace(to: old) }
        restoreWorkspace(from: id)
        MagMapStore.shared.reloadFromDisk()
        setActive(id)
        try StoreDataStore.shared.save(data, as: .map)
        lastError = nil
        AppLog.i("地图库", "切换地图：\(e.name)")
    }

    private func setActive(_ id: String) {
        activeId = id
        UserDefaults.standard.set(id, forKey: Self.activeKey)
    }

    private func stashWorkspace(to id: String) {
        let fm = FileManager.default
        let ws = dir(id).appendingPathComponent("workspace", isDirectory: true)
        try? fm.removeItem(at: ws)
        try? fm.createDirectory(at: ws, withIntermediateDirectories: true)
        for f in Self.workspaceFiles {
            let src = Self.docs.appendingPathComponent(f)
            if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: ws.appendingPathComponent(f)) }
        }
        if let s = UserDefaults.standard.string(forKey: Self.fieldSourceKey) {
            try? Data(s.utf8).write(to: ws.appendingPathComponent("field-source.txt"))
        }
    }

    private func restoreWorkspace(from id: String) {
        let fm = FileManager.default
        let ws = dir(id).appendingPathComponent("workspace", isDirectory: true)
        for f in Self.workspaceFiles {
            let dst = Self.docs.appendingPathComponent(f)
            try? fm.removeItem(at: dst)
            let src = ws.appendingPathComponent(f)
            if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: dst) }
        }
        let s = (try? Data(contentsOf: ws.appendingPathComponent("field-source.txt"))).flatMap { String(data: $0, encoding: .utf8) }
        UserDefaults.standard.set(s, forKey: Self.fieldSourceKey)
    }

    private func writeMeta(_ e: Entry) throws {
        try JSONEncoder().encode(e).write(to: dir(e.id).appendingPathComponent("meta.json"))
    }
}

/// 切换地图的菜单（地磁页、门店数据页、房间扫描页都用）
struct MapPickerMenu: View {
    @ObservedObject private var lib = MapLibrary.shared
    var disabled = false
    @State private var error: String?

    var body: some View {
        Menu {
            ForEach(lib.entries) { e in
                Button {
                    do { try lib.activate(e.id) } catch { self.error = error.localizedDescription }
                } label: {
                    if e.id == lib.activeId {
                        Label(e.name, systemImage: "checkmark")
                    } else {
                        Label(e.name, systemImage: e.isRoom ? "cube.transparent" : "building.2")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: lib.active?.isRoom == true ? "cube.transparent" : "map")
                Text(lib.active?.name ?? "选择地图").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.footnote.weight(.semibold))
        }
        .disabled(disabled || lib.entries.isEmpty)
        .alert("切换失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
}

/// 地图库管理：列表、切换、改名、删除
struct MapLibrarySection: View {
    @ObservedObject private var lib = MapLibrary.shared
    @State private var renaming: MapLibrary.Entry?
    @State private var newName = ""

    var body: some View {
        Section {
            if lib.entries.isEmpty {
                Text("地图库是空的：导入门店地图，或者到「房间扫描」扫一个房间。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(lib.entries) { e in
                HStack {
                    Image(systemName: e.isRoom ? "cube.transparent" : "building.2").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(e.name)
                        Text(e.isRoom ? "房间扫描" : "门店地图").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.id == lib.activeId {
                        Text("在用").font(.caption.bold()).foregroundStyle(.green)
                    } else {
                        Button("切换") { try? lib.activate(e.id) }.buttonStyle(.bordered)
                    }
                }
                .swipeActions {
                    if e.id != lib.activeId { Button("删除", role: .destructive) { lib.delete(e.id) } }
                    Button("改名") { renaming = e; newName = e.name }.tint(.blue)
                }
            }
            if let err = lib.lastError { Text(err).font(.footnote).foregroundStyle(.red) }
        } header: { Text("地图库") } footer: {
            Text("每张地图有自己的磁场图、点位、采集进度和采集会话，切换不会互相覆盖。左滑改名 / 删除。")
        }
        .alert("改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("保存") { if let r = renaming { lib.rename(r.id, to: newName) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }
}
