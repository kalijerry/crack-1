import Foundation
import HPASSKit

/// 在手机上把建图采集会话变成磁场图：选会话 → 后台建图（锚点对齐 + 自动贴通道 + 原始磁力计减偏置）→ 直接启用。
@MainActor
final class SurveyMapService: ObservableObject {
    struct Item: Identifiable, Equatable {
        let url: URL
        var id: String { url.lastPathComponent }
        let sizeBytes: Int64
        let hasMesh: Bool
    }

    @Published private(set) var items: [Item] = []
    /// 当前地图的测试会话（不参与生成磁场图）
    @Published private(set) var testItems: [Item] = []
    @Published var selected: Set<String> = []
    @Published private(set) var running = false
    @Published private(set) var lines: [String] = []
    @Published private(set) var lastError: String?
    /// 当前磁场图已经包含的会话（增量建图的累积状态里记着）
    @Published private(set) var included: Set<String> = []
    private var known: Set<String> = []

    static var stateURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("build-state.json")
    }

    static func loadState() -> MapBuildState? {
        guard let d = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(MapBuildState.self, from: d)
    }

    @Published private(set) var uploadStatus: String?

    /// 把当前地图的所有会话（建图 + 测试）里后台还没有的上传上去：云端融合只用后台有的会话
    func uploadAll() async {
        guard Telemetry.shared.enabled else { uploadStatus = "先连上云端后台"; return }
        let all = items + testItems
        var have = Set<String>()
        var listData: Data?
        if let r = Telemetry.shared.sessionsRequest() { listData = try? await URLSession.shared.data(for: r).0 }
        if let d = listData, let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            for o in arr { if let k = o["key"] as? String { have.insert(k.replacingOccurrences(of: "sessions/", with: "").replacingOccurrences(of: ".zip", with: "")) } }
        }
        let todo = all.filter { !have.contains($0.id) }
        var ok = 0
        for (i, it) in todo.enumerated() {
            uploadStatus = "上传中 \(i + 1) / \(todo.count)：\(it.id)"
            if await Telemetry.shared.upload(sessionDir: it.url) { ok += 1 }
        }
        uploadStatus = todo.isEmpty ? "后台已经有全部 \(all.count) 个会话" : "上传了 \(ok) / \(todo.count) 个，云端稍后自动融合"
    }

    /// 选中的会话里还没加进磁场图的
    var newSelected: [Item] { items.filter { selected.contains($0.id) && !included.contains($0.id) } }

    /// 重新扫描会话目录；新出现的建图会话默认选上。
    func refresh() {
        included = Set(Self.loadState()?.sessions ?? [])
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Recorder.sessionsRoot, includingPropertiesForKeys: nil)) ?? []
        let store = MagMapStore.shared
        let active = MapLibrary.shared.activeId
        // 只列当前地图的会话：会话里记了地图编号就按编号；旧会话没记，就按地图尺寸对
        func belongs(_ d: URL) -> Bool {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
            if let id = meta["map_id"] as? String, !id.isEmpty { return id == active }
            let w = meta["map_width_cm"] as? Double, h = meta["map_height_cm"] as? Double
            guard let w, let h else { return true }
            return abs(w - store.widthCm) < 1 && abs(h - store.heightCm) < 1
        }
        func isTest(_ d: URL) -> Bool {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return meta["purpose"] as? String == "test"
        }
        let mine = dirs.filter { $0.hasDirectoryPath && SurveySessionLoader.isSurvey($0) && belongs($0) }
        testItems = mine.filter(isTest).sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { Item(url: $0, sizeBytes: SessionsView.dirSize($0), hasMesh: false) }
        items = mine.filter { !isTest($0) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { Item(url: $0, sizeBytes: SessionsView.dirSize($0),
                        hasMesh: fm.fileExists(atPath: $0.appendingPathComponent("mesh.ply").path)) }
        for it in items where !known.contains(it.id) { selected.insert(it.id) }
        known = Set(items.map(\.id))
        selected = selected.intersection(known)
    }

    /// 建图，成功后直接启用。
    /// - append = true：接着当前磁场图的累积统计，只加还没加过的选中会话（旧会话删了也不影响）；
    /// - append = false：只用选中的会话从头重建。
    func build(crosses: [CrossSegment], widthCm: Double, heightCm: Double, append: Bool = false) {
        guard !running else { return }
        let prior = append ? Self.loadState() : nil
        let already = Set(prior?.sessions ?? [])
        let urls = items.filter { selected.contains($0.id) && !already.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { lastError = append ? "没有新会话可以追加" : "先选至少一个建图会话"; return }
        let whitelist = StoreDataStore.shared.eslIds
        running = true
        lastError = nil
        lines = ["正在建图：\(urls.count) 个会话……"]
        AppLog.i("建图", "手机上生成磁场图：\(urls.count) 个会话")
        Task.detached(priority: .userInitiated) {
            var b = SurveyMapBuilder(widthCm: widthCm, heightCm: heightCm, crosses: crosses)
            var bb = BLEFingerprintBuilder(widthCm: widthCm, heightCm: heightCm)
            if let p = prior, let fb = MagneticFieldBuilder(snapshot: p.field),
               abs(fb.widthCm - widthCm) < 1, abs(fb.heightCm - heightCm) < 1 {
                b = SurveyMapBuilder(field: fb, crosses: crosses)
                bb = BLEFingerprintBuilder(state: p.ble)
            }
            bb.whitelist = whitelist
            var bleUsed = 0
            var out: [String] = []
            var total = 0
            for u in urls {
                do {
                    let s = try SurveySessionLoader.load(u)
                    let r = b.add(s)
                    total += r.samplesUsed
                    // 蓝牙自动指纹：价签读数按时间放到对齐好的轨迹上
                    bleUsed += bb.add(samples: SurveySessionLoader.loadBLE(u), track: r.track)
                    var line = "\(u.lastPathComponent)：\(r.samplesUsed) 个样本"
                    if let a = r.corridorResidualBefore, let c = r.corridorResidualAfter {
                        line += "，离通道中心 \(Int(a)) → \(Int(c)) cm"
                    }
                    if r.magSource != "raw" { line += "，没有原始磁力计（用校准磁场）" }
                    for w in r.warnings { line += "；⚠️ \(w)" }
                    out.append(line)
                } catch {
                    out.append("\(u.lastPathComponent)：读取失败（\(error)）")
                }
            }
            let field = (total > 0 || prior != nil) ? b.build() : nil
            let doneNames = (prior?.sessions ?? []) + urls.map(\.lastPathComponent)
            let state = MapBuildState(field: b.field.snapshot(), ble: bb.state(), sessions: doneNames)
            let bleMap = bb.build()
            let ble: BLEFingerprintMap? = bleMap.tags.count >= 20 ? bleMap : nil
            out.append(ble.map { "蓝牙指纹：\($0.tags.count) 个价签，\(bleUsed) 条读数" + (whitelist != nil ? "（按价签名单）" : "")
                + (bb.rejectedMoving.isEmpty ? "" : "，\(bb.rejectedMoving.count) 个到处都听得到的设备不算") }
                ?? "蓝牙指纹：价签读数太少（\(bleUsed) 条），不启用")
            let valid = b.field.validCells()
            await MainActor.run {
                self.running = false
                self.lines = out
                guard let f = field else {
                    self.lastError = "没有可用的数据：确认采集时做了「长按定点 + 设朝向 + 直走 1.5 m」"
                    AppLog.w("建图", self.lastError ?? "")
                    return
                }
                let df = DateFormatter()
                df.dateFormat = "MM-dd HH:mm"
                let names = doneNames.map { $0.replacingOccurrences(of: "ios_survey_", with: "") }
                MagMapStore.shared.applyBuilt(f, source: "\(doneNames.count) 个会话（\(names.joined(separator: "、"))），\(df.string(from: Date())) " + (append ? "追加" : "生成"), ble: ble)
                if let d = try? JSONEncoder().encode(state) { try? d.write(to: Self.stateURL, options: .atomic) }
                self.included = Set(doneNames)
                // 不自动上传：云端（GitHub Actions）用后台所有会话融合出来的才是正式版本；
                // 手机上生成的只是本机预览，要给别人用可以在「门店数据 → 云端地图」手动上传
                self.lines.append("完成：有数据的格子 \(valid) 个（补齐后 \(f.coveredCells)），已启用")
                AppLog.i("建图", "手机上生成磁场图完成：样本 \(total)，有效格 \(valid)，补齐后 \(f.coveredCells)")
            }
        }
    }
}
