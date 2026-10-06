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
    @Published var selected: Set<String> = []
    @Published private(set) var running = false
    @Published private(set) var lines: [String] = []
    @Published private(set) var lastError: String?
    private var known: Set<String> = []

    /// 重新扫描会话目录；新出现的建图会话默认选上。
    func refresh() {
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
        items = dirs.filter { $0.hasDirectoryPath && SurveySessionLoader.isSurvey($0) && belongs($0) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { Item(url: $0, sizeBytes: SessionsView.dirSize($0),
                        hasMesh: fm.fileExists(atPath: $0.appendingPathComponent("mesh.ply").path)) }
        for it in items where !known.contains(it.id) { selected.insert(it.id) }
        known = Set(items.map(\.id))
        selected = selected.intersection(known)
    }

    /// 用选中的会话建图，成功后直接启用（替换当前的磁场数据）。
    func build(crosses: [CrossSegment], widthCm: Double, heightCm: Double) {
        guard !running else { return }
        let urls = items.filter { selected.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { lastError = "先选至少一个建图会话"; return }
        running = true
        lastError = nil
        lines = ["正在建图：\(urls.count) 个会话……"]
        AppLog.i("建图", "手机上生成磁场图：\(urls.count) 个会话")
        Task.detached(priority: .userInitiated) {
            let b = SurveyMapBuilder(widthCm: widthCm, heightCm: heightCm, crosses: crosses)
            var out: [String] = []
            var total = 0
            for u in urls {
                do {
                    let s = try SurveySessionLoader.load(u)
                    let r = b.add(s)
                    total += r.samplesUsed
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
            let field = total > 0 ? b.build() : nil
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
                let names = urls.map { $0.lastPathComponent.replacingOccurrences(of: "ios_survey_", with: "") }
                MagMapStore.shared.applyBuilt(f, source: "\(urls.count) 个会话（\(names.joined(separator: "、"))），\(df.string(from: Date())) 生成")
                self.lines.append("完成：有数据的格子 \(valid) 个（补齐后 \(f.coveredCells)），已启用")
                AppLog.i("建图", "手机上生成磁场图完成：样本 \(total)，有效格 \(valid)，补齐后 \(f.coveredCells)")
            }
        }
    }
}
