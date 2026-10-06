import Foundation
import HPASSKit

/// 地磁模式用的「一张地图」：10×10 m 的范围、手动定的点位、校准得到的磁场网格，全放在一个 JSON 里。
///
/// 文件在 `Documents/magmap.json`，格式兼容门店地图（`width` `height` `mapElementList`），
/// 额外字段：`markPoints`（点位）、`magField`（校准结果，定位用）、`magStats`（累积统计，继续校准用）。
@MainActor
final class MagMapStore: ObservableObject {
    static let shared = MagMapStore()

    @Published private(set) var widthCm: Double = 1000
    @Published private(set) var heightCm: Double = 1000
    @Published var floorName = "测试区 10×10 m"
    @Published private(set) var points: [MarkPoint] = []
    @Published private(set) var field: MagneticFieldMap?
    @Published private(set) var sampleCount = 0
    @Published private(set) var validCells = 0
    @Published private(set) var lastError: String?

    /// 门店地图里的通道（来自「门店数据」页导入的地图），用于通道约束。
    @Published private(set) var crosses: [CrossSegment] = []
    /// 地图的真实朝向：地图 +y 轴的磁罗盘方位角（度）。第一次「定点 + 设朝向」时自动记下，之后冷启动用。
    /// 地图朝向：地图「上方」（−y）指向的罗盘方位（度，顺时针，0 = 北）。由用户填写，例如 316。
    @Published private(set) var mapUpBearingDeg: Double?
    /// 融合引擎用的「地图 +y 轴的罗盘方位」= 上方 + 180°。
    var declinationDeg: Double? { mapUpBearingDeg.map { ($0 + 180).truncatingRemainder(dividingBy: 360) } }
    private var walkableCache: WalkableMap?
    private var shelves: [ShelfRect] = []
    private var raycasterCache: ShelfRaycaster?

    private var builder = MagneticFieldBuilder(widthCm: 1000, heightCm: 1000)
    /// 导入的地图里自带的磁场（没有累积统计，只能用来定位）。
    private var importedField: MagneticFieldMap?

    nonisolated static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("magmap.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL) {
            do { try load(data) } catch {
                lastError = "读取已保存的地磁地图失败：\(error)"
                AppLog.e("地磁", lastError ?? "")
            }
        }
    }

    // MARK: 门店地图

    /// 采用「门店数据」页导入的地图：尺寸、通道。尺寸变了就清掉不再对得上的校准数据和点位。
    func adopt(map: StoreMap?) {
        guard let m = map, m.width > 0, m.height > 0 else { return }
        let sameSize = abs(m.width - widthCm) < 1 && abs(m.height - heightCm) < 1
        let sameCrosses = m.crosses.count == crosses.count
        crosses = m.crosses
        if !sameCrosses || m.shelves.count != shelves.count { walkableCache = nil; raycasterCache = nil }
        // 只有标准货架（Shelf-001…100）是实物；虚拟货架和 107 / 401 / Shelf-4-… 等不参与
        shelves = m.physicalShelves
        if sameSize { return }
        widthCm = m.width
        heightCm = m.height
        walkableCache = nil
        builder = MagneticFieldBuilder(widthCm: widthCm, heightCm: heightCm)
        importedField = nil
        points = points.filter { $0.x <= widthCm && $0.y <= heightCm }
        refreshField()
        save()
        AppLog.i("地磁", "采用门店地图：\(Int(widthCm)) × \(Int(heightCm)) cm，\(crosses.count) 条通道")
    }

    /// 可走区域（由通道栅格化，首次使用时生成并缓存）。没有通道时为 nil。
    func walkableMap() -> WalkableMap? {
        if let w = walkableCache { return w }
        guard !crosses.isEmpty else { return nil }
        let w = WalkableMap(crosses: crosses, widthCm: widthCm, heightCm: heightCm)
        walkableCache = w
        AppLog.i("地磁", "可走区域：\(w.walkableCellCount) 格，\(Int(w.walkableAreaM2)) m²")
        return w
    }

    /// 货架射线投射（深度相机横向距离用），首次使用时生成并缓存。没有货架时为 nil。
    func raycaster() -> ShelfRaycaster? {
        if let r = raycasterCache { return r }
        guard !shelves.isEmpty else { return nil }
        let r = ShelfRaycaster(shelves: shelves, widthCm: widthCm, heightCm: heightCm)
        raycasterCache = r
        AppLog.i("地磁", "货架射线投射：\(r.shelfCount) 个货架")
        return r
    }

    func setMapUpBearing(_ deg: Double?) {
        mapUpBearingDeg = deg.map { (($0.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) }
        save()
        AppLog.i("地磁", "地图朝向：" + (mapUpBearingDeg.map { "上方指向 \(Fmt.f($0, 0))°" } ?? "未设置"))
    }

    /// 用门店地图做底，还是没有门店地图时的小测试区。
    var usesStoreMap: Bool { !crosses.isEmpty }

    // MARK: 点位

    /// 在 p（cm）处放一个点，吸附到 10 cm，编号自动递增。
    @discardableResult
    func addPoint(at p: Point2) -> MarkPoint {
        let x = min(max((p.x / 10).rounded() * 10, 0), widthCm)
        let y = min(max((p.y / 10).rounded() * 10, 0), heightCm)
        var n = (points.compactMap { Int($0.id) }.max() ?? 0) + 1
        while points.contains(where: { $0.id == String(n) }) { n += 1 }
        let mp = MarkPoint(id: String(n), x: x, y: y)
        points.append(mp)
        save()
        AppLog.i("地磁", "放置点位 \(mp.id)：x \(Int(x)) y \(Int(y)) cm")
        return mp
    }

    func deletePoint(id: String) {
        points.removeAll { $0.id == id }
        save()
        AppLog.i("地磁", "删除点位 \(id)")
    }

    func clearPoints() {
        points = []
        save()
    }

    func point(id: String) -> MarkPoint? { points.first { $0.id == id } }

    // MARK: 校准结果

    /// 并入一遍校准数据，返回实际用到的样本数。
    @discardableResult
    func addCalibration(waypoints: [MagneticFieldBuilder.Waypoint],
                        samples: [MagneticFieldBuilder.TimedFeature]) -> Int {
        let used = builder.addTrack(waypoints: waypoints, samples: samples)
        refreshField()
        save()
        AppLog.i("地磁", "并入校准数据：\(used) 个样本，累计 \(builder.sampleCount)，有效格 \(validCells)/\(builder.totalCells)")
        return used
    }

    func clearCalibration() {
        builder.reset()
        importedField = nil
        refreshField()
        save()
        AppLog.i("地磁", "已清空校准数据")
    }

    private func refreshField() {
        if builder.sampleCount > 0 {
            field = builder.build()
        } else {
            field = importedField
        }
        sampleCount = builder.sampleCount
        validCells = field?.coveredCells ?? 0
    }

    // MARK: 导入 / 导出

    /// 导入地图 JSON（网页编辑器导出的，或本 App 导出的）。
    func importMap(_ data: Data) throws {
        let oldPoints = points
        try load(data)
        // 电脑上建出来的磁场图（magmap.json）通常不带点位；这时保留 App 里已经放好的点位，别清空
        if points.isEmpty && !oldPoints.isEmpty { points = oldPoints }
        save()
        AppLog.i("地磁", "导入地图：\(points.count) 个点位，" + (field == nil ? "无磁场数据" : "含磁场数据 \(validCells) 格"))
    }

    func exportData() throws -> Data {
        var root: [String: Any] = [
            "mapId": 1, "floorId": 1, "floorName": floorName,
            "width": widthCm, "height": heightCm,
            "mapElementList": [Any](),
            "markPoints": points.map { ["id": $0.id, "x": Int($0.x.rounded()), "y": Int($0.y.rounded())] as [String: Any] },
        ]
        if let d = mapUpBearingDeg { root["mapUpBearingDeg"] = d }
        if let f = field { root["magField"] = f.jsonObject() }
        if builder.sampleCount > 0 {
            let snap = try JSONEncoder().encode(builder.snapshot())
            root["magStats"] = try JSONSerialization.jsonObject(with: snap)
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private func save() {
        do { try exportData().write(to: Self.fileURL, options: .atomic) } catch {
            lastError = "保存地图失败：\(error.localizedDescription)"
            AppLog.e("地磁", lastError ?? "")
        }
    }

    private func load(_ data: Data) throws {
        let map = try StoreDataLoader.loadMap(data)
        guard map.width > 0, map.height > 0 else {
            throw StoreDataError.unsupportedFormat("地图缺少 width / height（单位 cm）")
        }
        widthCm = map.width
        heightCm = map.height
        floorName = map.floorName ?? floorName
        points = try StoreDataLoader.loadMarkPoints(data)
        if let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
           let d = root["mapUpBearingDeg"] as? Double {
            // 旧版本存过一个错误的「magDeclinationDeg」（常常是 0），不再读取
            mapUpBearingDeg = d
        }
        walkableCache = nil
        importedField = try StoreDataLoader.loadMagneticField(data)

        builder = MagneticFieldBuilder(widthCm: widthCm, heightCm: heightCm)
        if let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
           let stats = root["magStats"],
           let raw = try? JSONSerialization.data(withJSONObject: stats),
           let snap = try? JSONDecoder().decode(MagneticFieldBuilder.Snapshot.self, from: raw),
           let restored = MagneticFieldBuilder(snapshot: snap) {
            builder = restored
        }
        refreshField()
        lastError = nil
    }
}
