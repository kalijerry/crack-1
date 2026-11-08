import SwiftUI

/// 统一查看、导出、删除 App 里产生的数据：采集会话（含 LiDAR 网格）、定位轨迹、AR 偏移记录。
struct DataManagerView: View {
    private struct Entry: Identifiable {
        let url: URL
        let size: Int64
        let isDir: Bool
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    @State private var sessions: [Entry] = []
    @State private var tracks: [Entry] = []
    @State private var checks: [Entry] = []
    @State private var share: ShareTarget?
    @State private var error: String?
    @State private var confirmDelete: Entry?

    private static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("合计占用")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: (sessions + tracks + checks).reduce(0) { $0 + $1.size }, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            section("采集会话（建图采集带 ARKit / LiDAR）", sessions)
            section("定位轨迹（mag-tracks）", tracks)
            section("AR 偏移记录", checks)
        }
        .navigationTitle("数据管理")
        .onAppear(perform: reload)
        .sheet(item: $share) { ActivityView(items: [$0.url]) }
        .confirmationDialog("删除「\(confirmDelete?.name ?? "")」？不能恢复。", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let e = confirmDelete { try? FileManager.default.removeItem(at: e.url); AppLog.i("数据", "删除 \(e.name)") }
                confirmDelete = nil
                reload()
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [Entry]) -> some View {
        Section(title) {
            if items.isEmpty { Text("没有").foregroundStyle(.secondary) }
            ForEach(items) { e in
                HStack {
                    VStack(alignment: .leading) {
                        Text(e.name).font(.footnote.monospaced())
                        Text(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file) + detail(e))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("导出") { export(e) }.buttonStyle(.bordered)
                }
                .swipeActions { Button("删除", role: .destructive) { confirmDelete = e } }
            }
        }
    }

    private func detail(_ e: Entry) -> String {
        guard e.isDir else { return "" }
        let fm = FileManager.default
        var tags: [String] = []
        if fm.fileExists(atPath: e.url.appendingPathComponent("arkit_pose.csv").path) { tags.append("建图") }
        if fm.fileExists(atPath: e.url.appendingPathComponent("mesh.ply").path) { tags.append("LiDAR 网格") }
        return tags.isEmpty ? "" : " · " + tags.joined(separator: " · ")
    }

    private func export(_ e: Entry) {
        do {
            share = ShareTarget(url: e.isDir ? try SessionsView.zip(e.url) : e.url)
        } catch {
            self.error = "打包失败：\(error.localizedDescription)"
        }
    }

    private func reload() {
        sessions = list(Recorder.sessionsRoot)
        tracks = list(Self.docs.appendingPathComponent("mag-tracks"))
        checks = list(Self.docs.appendingPathComponent("ar-checks"))
    }

    private func list(_ dir: URL) -> [Entry] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])) ?? []
        return items.map { u -> Entry in
            let isDir = u.hasDirectoryPath
            let size = isDir ? Self.treeSize(u) : Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return Entry(url: u, size: size, isDir: isDir)
        }.sorted { $0.name > $1.name }
    }

    private static func treeSize(_ dir: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
