import Foundation
import HPASSKit

/// 一个场地数据文件的本地状态。
struct StoreFileInfo {
    var exists: Bool
    var bytes: Int64
    var modified: Date?
    /// 解析结果摘要，例如「167 个货架 / 24 条通道」
    var summary: String
    /// 解析失败时的原因
    var error: String?
}

/// 场地数据的本地仓库：地图、指纹、标签三个文件。
///
/// 文件存放在 Documents/store-data/ 下，可以由下载模块写入，也可以通过「文件」App 拖进来。
/// 数据本身不进代码仓库。
@MainActor
final class StoreDataStore: ObservableObject {
    static let shared = StoreDataStore()

    enum FileKind: String, CaseIterable, Identifiable {
        case map, fingerprint, tags = "esl"     // 原始值是已存数据里的键，不能改

        var id: String { rawValue }

        /// 界面上显示的种类：不用蓝牙时只有地图
        static var visible: [FileKind] { Features.bluetooth ? allCases : [.map] }

        var fileName: String {
            switch self {
            case .map: return "map.json"
            case .fingerprint: return "fingerprint.json"
            case .tags: return "esl.json"
            }
        }

        var title: String {
            switch self {
            case .map: return "地图"
            case .fingerprint: return "指纹库"
            case .tags: return "标签/物品"
            }
        }
    }

    /// 已经套用了货架偏移的地图。所有页面都用它。
    @Published private(set) var map: StoreMap?
    /// 货架图层整体偏移（cm，地图坐标）。在 3D 里实时校准，存在本机。
    @Published private(set) var shelfOffset = Point2(0, 0)
    /// 文件里原样的地图（没套偏移）
    private var rawMap: StoreMap?
    private static let shelfOffsetKey = "shelfOffsetCm.v1"
    @Published private(set) var fingerprints: [FingerprintPoint] = []
    @Published private(set) var tagItems: [TagItem] = []
    @Published private(set) var goods: [GoodsItem] = []
    @Published private(set) var files: [String: StoreFileInfo] = [:]
    /// 数据自检结果，空表示没问题
    @Published private(set) var issues: [String] = []
    @Published private(set) var lastError: String?

    var isReady: Bool { map != nil && !fingerprints.isEmpty && !tagItems.isEmpty }

    var tagToShelf: [String: String] { StoreDataLoader.tagToShelf(tagItems) }

    /// 地图变了没有（尺寸、货架、通道、地面）。换成房间地图时通道数可能不变（都是 0），所以不能只看通道数。
    var mapSignature: String {
        guard let m = map else { return "" }
        return "\(Int(m.width))x\(Int(m.height))/\(m.shelves.count)/\(m.crosses.count)/\(m.floor.count)/\(m.floorName ?? "")"
    }

    // MARK: 标签位置表（CSV：标签 → 通道 / 段 / 层 / 条码）

    private var tagLocURL: URL { Self.rootURL.appendingPathComponent("esl-locations.csv") }
    private var tagLocCache: (sig: String, locs: [TagLocation])?
    @Published private(set) var tagLocCount = 0

    /// 按当前地图对上货架的标签位置（地图换了重新对）
    var tagLocations: [TagLocation] {
        if let c = tagLocCache, c.sig == mapSignature { return c.locs }
        guard let t = try? String(contentsOf: tagLocURL, encoding: .utf8) else { return [] }
        let locs = TagLocations.parse(t, map: map)
        tagLocCache = (mapSignature, locs)
        return locs
    }

    var hasTagLocations: Bool { FileManager.default.fileExists(atPath: tagLocURL.path) }

    /// 装上从后台拿到的标签位置表（正常模式），不再往回传
    func installTagLocations(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), !TagLocations.parse(text, map: map).isEmpty else {
            throw StoreDataError.unsupportedFormat("后台的标签位置表读不出来")
        }
        try FileManager.default.createDirectory(at: Self.rootURL, withIntermediateDirectories: true)
        try data.write(to: tagLocURL, options: .atomic)
        let locs = TagLocations.parse(text, map: map)
        try locs.map(\.id).joined(separator: "\n").write(to: tagIdsURL, atomically: true, encoding: .utf8)
        tagLocCache = nil
        tagLocCount = locs.count
        loadTagIds()
        AppLog.i("场地数据", "从后台装上标签位置表：\(locs.count) 个")
    }

    /// 导入标签位置表：同时当标签名单用，连着后台就传上去（云端融合用它当蓝牙底图）
    func importTagLocations(from source: URL) throws -> (total: Int, onShelf: Int) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        guard let text = String(data: data, encoding: .utf8) else { throw StoreDataError.unsupportedFormat("不是 UTF-8 文本") }
        let locs = TagLocations.parse(text, map: map)
        guard !locs.isEmpty else { throw StoreDataError.unsupportedFormat("没找到 ESL_ID 列") }
        try FileManager.default.createDirectory(at: Self.rootURL, withIntermediateDirectories: true)
        try data.write(to: tagLocURL, options: .atomic)
        try locs.map(\.id).joined(separator: "\n").write(to: tagIdsURL, atomically: true, encoding: .utf8)
        tagLocCache = nil
        tagLocCount = locs.count
        loadTagIds()
        let onShelf = locs.filter { $0.position != nil }.count
        AppLog.i("场地数据", "导入标签位置表：\(locs.count) 个，对上地图障碍物 \(onShelf) 个")
        Task { await Telemetry.shared.uploadTagLocations(data) }
        return (locs.count, onShelf)
    }

    // MARK: 标签名单（蓝牙粗定位只收名单里的标签）

    private var tagIdsURL: URL { Self.rootURL.appendingPathComponent("esl-ids.txt") }
    @Published private(set) var tagIdCount = 0
    /// 标签名单；没导入为 nil（不过滤，只按厂商 ID 和「听到范围」判断）
    private(set) var tagIds: Set<String>?

    func loadTagIds() {
        guard let t = try? String(contentsOf: tagIdsURL, encoding: .utf8) else { tagIds = nil; tagIdCount = 0; return }
        let s = BLEFingerprintBuilder.parseIdList(t)
        tagIds = s.isEmpty ? nil : s
        tagIdCount = s.count
    }

    /// 导入标签名单：任何文本里的 XX-XX-XX-XX 都算（CSV、TXT、表格另存的 CSV）
    func importTagIds(from source: URL) throws -> Int {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: source, encoding: .utf8)
        let ids = BLEFingerprintBuilder.parseIdList(text)
        guard !ids.isEmpty else { throw StoreDataError.unsupportedFormat("文件里没找到标签 ID（格式 XX-XX-XX-XX）") }
        try FileManager.default.createDirectory(at: Self.rootURL, withIntermediateDirectories: true)
        try ids.sorted().joined(separator: "\n").write(to: tagIdsURL, atomically: true, encoding: .utf8)
        loadTagIds()
        AppLog.i("场地数据", "导入标签名单：\(ids.count) 个")
        return ids.count
    }

    func clearTagIds() {
        try? FileManager.default.removeItem(at: tagIdsURL)
        loadTagIds()
    }

    /// 当前地图是不是房间扫描生成的
    var currentMapIsRoom: Bool { map.map { $0.crosses.isEmpty && !$0.floor.isEmpty } ?? false }

    static var rootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("store-data", isDirectory: true)
    }

    func url(for kind: FileKind) -> URL {
        Self.rootURL.appendingPathComponent(kind.fileName)
    }

    private init() {
        defer {
            loadTagIds()
            tagLocCount = FileManager.default.fileExists(atPath: tagLocURL.path) ? tagLocations.count : 0
        }
        if let a = UserDefaults.standard.array(forKey: Self.shelfOffsetKey) as? [Double], a.count == 2 {
            shelfOffset = Point2(a[0], a[1])
        }
        reload()
    }

    /// 设置货架整体偏移，立刻生效并保存。
    func setShelfOffset(_ d: Point2) {
        let r = Point2((d.x * 10).rounded() / 10, (d.y * 10).rounded() / 10)
        guard r != shelfOffset else { return }
        shelfOffset = r
        UserDefaults.standard.set([r.x, r.y], forKey: Self.shelfOffsetKey)
        map = rawMap?.withShelfOffset(r)
    }

    /// 偏移调完之后记一条日志（调的过程中不记，避免刷屏）。
    func logShelfOffset() {
        AppLog.i("场地数据", "障碍物偏移：x \(Int(shelfOffset.x)) cm，y \(Int(shelfOffset.y)) cm")
    }

    // MARK: 写入

    /// 保存一个场地数据文件并重新解析。
    func save(_ data: Data, as kind: FileKind) throws {
        try FileManager.default.createDirectory(at: Self.rootURL, withIntermediateDirectories: true)
        try data.write(to: url(for: kind), options: .atomic)
        if kind == .map { MapLibrary.shared.syncActive(data) }
        AppLog.i("场地数据", "已保存 \(kind.title)：\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        reload()
    }

    /// 从「文件」App 选中的文件导入（处理安全作用域）。
    func importFile(at source: URL, as kind: FileKind) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        if kind == .map {
            // 地图导入成地图库里的一张新地图并切换过去，不覆盖现在这张
            let m = try StoreDataLoader.loadMap(data)
            let isRoom = m.crosses.isEmpty && !m.floor.isEmpty
            let name = m.floorName ?? source.deletingPathExtension().lastPathComponent
            try MapLibrary.shared.importAndActivate(data: data, name: name, kind: isRoom ? "room" : "store")
        } else {
            try save(data, as: kind)
        }
    }

    func delete(_ kind: FileKind) {
        try? FileManager.default.removeItem(at: url(for: kind))
        AppLog.w("场地数据", "已删除 \(kind.title)")
        reload()
    }

    func deleteAll() {
        for k in FileKind.allCases { try? FileManager.default.removeItem(at: url(for: k)) }
        AppLog.w("场地数据", "已清空全部场地数据")
        reload()
    }

    // MARK: 解析

    func reload() {
        lastError = nil
        var info: [String: StoreFileInfo] = [:]

        // 地图
        info[FileKind.map.rawValue] = parse(.map) { data in
            let m = try StoreDataLoader.loadMap(data)
            self.rawMap = m
            self.map = m.withShelfOffset(self.shelfOffset)
            return "\(m.shelves.count) 个障碍物 / \(m.crosses.count) 条通道" +
                (m.floorName.map { " / 楼层 \($0)" } ?? "")
        } onMissing: {
            self.rawMap = nil
            self.map = nil
        }

        // 指纹
        info[FileKind.fingerprint.rawValue] = parse(.fingerprint) { data in
            let pts = try StoreDataLoader.loadFingerprints(data)
            self.fingerprints = pts
            let ranges = pts.reduce(0) { $0 + $1.ranges.count }
            let avg = pts.isEmpty ? 0 : ranges / pts.count
            return "\(pts.count) 个指纹点 / 平均 \(avg) 条障碍物区间"
        } onMissing: {
            self.fingerprints = []
        }

        // 标签
        info[FileKind.tags.rawValue] = parse(.tags) { data in
            let g = try StoreDataLoader.loadGoods(data)
            self.goods = g
            self.tagItems = g.flatMap(\.positions)
            let skus = g.filter { !$0.sku.isEmpty }.count
            return "\(self.tagItems.count) 个标签" + (skus > 0 ? " / \(skus) 个物品" : "")
        } onMissing: {
            self.goods = []
            self.tagItems = []
        }

        files = info
        validate()
    }

    private func parse(_ kind: FileKind,
                      _ body: (Data) throws -> String,
                      onMissing: () -> Void) -> StoreFileInfo {
        let u = url(for: kind)
        let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
        guard FileManager.default.fileExists(atPath: u.path) else {
            onMissing()
            return StoreFileInfo(exists: false, bytes: 0, modified: nil, summary: "未导入", error: nil)
        }
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs?[.modificationDate] as? Date
        do {
            let data = try Data(contentsOf: u)
            let summary = try body(data)
            return StoreFileInfo(exists: true, bytes: bytes, modified: modified, summary: summary, error: nil)
        } catch {
            onMissing()
            let msg = (error as? StoreDataError).map(String.init(describing:)) ?? error.localizedDescription
            AppLog.e("场地数据", "\(kind.title) 解析失败：\(msg)")
            return StoreFileInfo(exists: true, bytes: bytes, modified: modified, summary: "解析失败", error: msg)
        }
    }

    /// 用定位模块的自检检查数据一致性（指纹区间、邻接表、标签货架对应关系等）。
    func validate() {
        guard !fingerprints.isEmpty, !tagItems.isEmpty else {
            issues = []
            return
        }
        let positioner = FingerprintPositioner(points: fingerprints, tagToShelf: tagToShelf)
        issues = positioner.validate()
        if issues.isEmpty {
            AppLog.i("场地数据", "自检通过：\(fingerprints.count) 个指纹点，\(tagItems.count) 个标签")
        } else {
            AppLog.w("场地数据", "自检发现 \(issues.count) 个问题，详见场地数据页")
        }
    }
}
