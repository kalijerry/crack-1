import SwiftUI

/// App 内日志查看器：按级别和关键字过滤，可导出为文本文件。
struct LogView: View {
    @ObservedObject private var log = AppLog.shared
    @State private var minLevel: LogLevel = .debug
    @State private var query = ""
    @State private var autoScroll = true
    @State private var share: ShareTarget?
    @State private var confirmClear = false
    @State private var error: String?

    private var filtered: [LogEntry] {
        log.entries.filter { e in
            guard e.level >= minLevel else { return false }
            guard !query.isEmpty else { return true }
            return e.message.localizedCaseInsensitiveContains(query)
                || e.category.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                list
            }
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    LoggedButton(name: "导出日志") {
                        exportLog()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    LoggedButton(name: "清空日志") {
                        confirmClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .confirmationDialog("清空当前日志？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { log.clear() }
                Button("取消", role: .cancel) {}
            }
            .sheet(item: $share) { ActivityView(items: [$0.url]) }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("级别", selection: $minLevel) {
                ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索内容或分类", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                Toggle("跟随", isOn: $autoScroll)
                    .labelsHidden()
                    .onChange(of: autoScroll) { v in AppLog.tap("日志跟随", v ? "开" : "关") }
                Text("跟随").font(.caption).foregroundStyle(.secondary)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if filtered.isEmpty {
                        Text(log.entries.isEmpty ? "暂无日志" : "没有符合条件的日志")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(filtered) { e in
                        HStack(alignment: .top, spacing: 6) {
                            Text(e.timeText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.category)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(e.message)
                                    .font(.system(size: 12))
                                    .foregroundStyle(e.level.color)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                        .id(e.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: filtered.count) { _ in
                guard autoScroll, let last = filtered.last else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func exportLog() {
        do {
            error = nil
            share = ShareTarget(url: try log.exportToTemporaryFile())
        } catch {
            self.error = "导出失败：\(error.localizedDescription)"
        }
    }
}
