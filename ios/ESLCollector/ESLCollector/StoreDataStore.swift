import Foundation
import HPASSKit

/// 一个门店数据文件的本地状态。
struct StoreFileInfo {
    var exists: Bool
    var bytes: Int64
    var modified: Date?
    /// 解析结果摘要，例如「167 个货架 / 24 条通道」
    var summary: String
    /// 解析失败时的原因
    var error: String?
}

/// 门店数据的本地仓库：地图、指纹、价签三个文件。
///
/// 文件存放在 Documents/store-data/ 下，可以由下载模块写入，也可以通过「文件」App 拖进来。
/// 数据本身不进代码仓库。
@MainActor
final class StoreDataStore: ObservableObject {
    static let shared = StoreDataStore()

    enum FileKind: String, CaseIterable, Identifiable {
        case map, fingerprint, esl

        var id: String { rawValue }

        var fileName: String {
            switch self {
            case .map: return "map.json"
            case .fingerprint: return "fingerprint.json"
            case .esl: return "esl.json"
            }
        }

        var title: String {
            switch self {
            case .map: return "地图"
            case .fingerprint: return "指纹库"
            case .esl: return "价签/商品"
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
    @Published private(set) var eslItems: [EslItem] = []
    @Published private(set) var goods: [GoodsItem] = []
    @Published private(set) var files: [String: StoreFileInfo] = [:]
    /// 数据自检结果，空表示没问题
    @Published private(set) var issues: [String] = []
    @Published private(set) var lastError: String?

    var isReady: Bool { map != nil && !fingerprints.isEmpty && !eslItems.isEmpty }

    var eslToShelf: [String: String] { StoreDataLoader.eslToShelf(eslItems) }

    static var rootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("store-data", isDirectory: true)
    }

    func url(for kind: FileKind) -> URL {
        Self.rootURL.appendingPathComponent(kind.fileName)
    }

    private init() {
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
        AppLog.i("门店数据", "货架偏移：x \(Int(shelfOffset.x)) cm，y \(Int(shelfOffset.y)) cm")
    }

    // MARK: 写入

    /// 保存一个门店数据文件并重新解析。
    func save(_ data: Data, as kind: FileKind) throws {
        try FileManager.default.createDirectory(at: Self.rootURL, withIntermediateDirectories: true)
        try data.write(to: url(for: kind), options: .atomic)
        AppLog.i("门店数据", "已保存 \(kind.title)：\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        reload()
    }

    /// 从「文件」App 选中的文件导入（处理安全作用域）。
    func importFile(at source: URL, as kind: FileKind) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        try save(data, as: kind)
    }

    func delete(_ kind: FileKind) {
        try? FileManager.default.removeItem(at: url(for: kind))
        AppLog.w("门店数据", "已删除 \(kind.title)")
        reload()
    }

    func deleteAll() {
        for k in FileKind.allCases { try? FileManager.default.removeItem(at: url(for: k)) }
        AppLog.w("门店数据", "已清空全部门店数据")
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
            return "\(m.shelves.count) 个货架 / \(m.crosses.count) 条通道" +
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
            return "\(pts.count) 个指纹点 / 平均 \(avg) 条货架区间"
        } onMissing: {
            self.fingerprints = []
        }

        // 价签
        info[FileKind.esl.rawValue] = parse(.esl) { data in
            let g = try StoreDataLoader.loadGoods(data)
            self.goods = g
            self.eslItems = g.flatMap(\.positions)
            let skus = g.filter { !$0.sku.isEmpty }.count
            return "\(self.eslItems.count) 个价签" + (skus > 0 ? " / \(skus) 个商品" : "")
        } onMissing: {
            self.goods = []
            self.eslItems = []
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
            AppLog.e("门店数据", "\(kind.title) 解析失败：\(msg)")
            return StoreFileInfo(exists: true, bytes: bytes, modified: modified, summary: "解析失败", error: msg)
        }
    }

    /// 用定位模块的自检检查数据一致性（指纹区间、邻接表、价签货架对应关系等）。
    func validate() {
        guard !fingerprints.isEmpty, !eslItems.isEmpty else {
            issues = []
            return
        }
        let positioner = FingerprintPositioner(points: fingerprints, eslToShelf: eslToShelf)
        issues = positioner.validate()
        if issues.isEmpty {
            AppLog.i("门店数据", "自检通过：\(fingerprints.count) 个指纹点，\(eslItems.count) 个价签")
        } else {
            AppLog.w("门店数据", "自检发现 \(issues.count) 个问题，详见门店数据页")
        }
    }
}
