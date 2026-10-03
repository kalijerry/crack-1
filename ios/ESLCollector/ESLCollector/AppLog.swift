import Foundation
import SwiftUI

enum LogLevel: String, CaseIterable, Comparable {
    case debug = "调试"
    case info = "信息"
    case warn = "警告"
    case error = "错误"

    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    var color: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }

    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

struct LogEntry: Identifiable {
    let id: Int
    let tMs: Int64
    let level: LogLevel
    let category: String
    let message: String

    var timeText: String {
        let d = Date(timeIntervalSince1970: Double(tMs) / 1000)
        return LogEntry.formatter.string(from: d)
    }

    var line: String {
        "\(timeText) [\(level.rawValue)] \(category): \(message)"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// App 内日志。界面可见、可导出，录制期间同时写入会话目录。
///
/// 任意线程都可以调用 `AppLog.i(...)` 等静态方法，内部会切回主线程追加。
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    /// 内存里最多保留多少条，超出丢弃最旧的
    private static let capacity = 5000

    @Published private(set) var entries: [LogEntry] = []
    /// 录制期间镜像写入的文件；nil 表示只留在内存
    private var mirrorURL: URL?
    private var mirrorHandle: FileHandle?
    private var nextId = 0

    private init() {}

    // MARK: 写入

    nonisolated static func d(_ category: String, _ message: String) { append(.debug, category, message) }
    nonisolated static func i(_ category: String, _ message: String) { append(.info, category, message) }
    nonisolated static func w(_ category: String, _ message: String) { append(.warn, category, message) }
    nonisolated static func e(_ category: String, _ message: String) { append(.error, category, message) }

    /// 按钮/开关等界面操作。所有可点击控件都应调用它，便于复盘操作顺序。
    nonisolated static func tap(_ control: String, _ detail: String = "") {
        append(.info, "操作", detail.isEmpty ? control : "\(control) — \(detail)")
    }

    nonisolated private static func append(_ level: LogLevel, _ category: String, _ message: String) {
        let t = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        Task { @MainActor in
            shared.add(level: level, category: category, message: message, tMs: t)
        }
    }

    private func add(level: LogLevel, category: String, message: String, tMs: Int64) {
        let entry = LogEntry(id: nextId, tMs: tMs, level: level, category: category, message: message)
        nextId += 1
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        if let h = mirrorHandle, let data = (entry.line + "\n").data(using: .utf8) {
            try? h.write(contentsOf: data)
        }
    }

    // MARK: 镜像到会话目录

    /// 录制开始时调用，日志同时写入会话目录下的 log.txt。
    func startMirroring(to directory: URL) {
        stopMirroring()
        let url = directory.appendingPathComponent("log.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        mirrorHandle = try? FileHandle(forWritingTo: url)
        mirrorURL = url
        // 把已有的内存日志一并落盘，便于单独查看这次会话
        if let h = mirrorHandle {
            let text = entries.map(\.line).joined(separator: "\n") + "\n"
            if let d = text.data(using: .utf8) { try? h.write(contentsOf: d) }
        }
    }

    func stopMirroring() {
        try? mirrorHandle?.close()
        mirrorHandle = nil
        mirrorURL = nil
    }

    // MARK: 导出 / 清空

    var text: String {
        entries.map(\.line).joined(separator: "\n")
    }

    /// 写一份 log.txt 到临时目录，返回可分享的 URL。
    func exportToTemporaryFile() throws -> URL {
        let name = "eslcollector-log-\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try text.data(using: .utf8)?.write(to: url)
        return url
    }

    func clear() {
        entries.removeAll()
    }
}

/// 自动记录点击的按钮。界面里所有操作按钮都用它，保证日志完整。
struct LoggedButton<Label: View>: View {
    let name: String
    var detail: String = ""
    var role: ButtonRole?
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(role: role) {
            AppLog.tap(name, detail)
            action()
        } label: {
            label()
        }
    }
}

extension LoggedButton where Label == Text {
    init(_ title: String, detail: String = "", role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.name = title
        self.detail = detail
        self.role = role
        self.action = action
        self.label = { Text(title) }
    }
}
