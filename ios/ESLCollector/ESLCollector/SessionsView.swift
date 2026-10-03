import SwiftUI
import UIKit

struct SessionItem: Identifiable {
    let url: URL
    let sizeBytes: Int64
    var id: String { url.lastPathComponent }
}

struct SessionsView: View {
    @State private var items: [SessionItem] = []
    @State private var share: ShareTarget?
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red)
            }
            if items.isEmpty {
                Text("还没有会话").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.id).font(.system(.footnote, design: .monospaced))
                        Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("导出") { export(item) }
                        .buttonStyle(.bordered)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("历史会话")
        .onAppear(perform: reload)
        .sheet(item: $share) { target in
            ActivityView(items: [target.url])
        }
    }

    private func reload() {
        let fm = FileManager.default
        let root = Recorder.sessionsRoot
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        items = dirs.filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { SessionItem(url: $0, sizeBytes: Self.dirSize($0)) }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            try? FileManager.default.removeItem(at: items[i].url)
        }
        reload()
    }

    private func export(_ item: SessionItem) {
        do {
            share = ShareTarget(url: try Self.zip(item.url))
        } catch {
            self.error = "打包失败：\(error.localizedDescription)"
        }
    }

    /// 借助 NSFileCoordinator 的 .forUploading 选项把目录打成 zip，无需第三方库。
    static func zip(_ dir: URL) throws -> URL {
        var coordError: NSError?
        var result: Result<URL, Error>?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &coordError) { tmp in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(dir.lastPathComponent + ".zip")
            do {
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: tmp, to: dst)
                result = .success(dst)
            } catch {
                result = .failure(error)
            }
        }
        if let coordError { throw coordError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    static func dirSize(_ dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { sum, f in
            sum + Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

struct ShareTarget: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
