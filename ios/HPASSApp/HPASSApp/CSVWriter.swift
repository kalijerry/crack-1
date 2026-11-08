import Foundation

/// 追加写 CSV：在私有串行队列上缓冲，满 64KB 或手动 flush 时落盘。
final class CSVWriter {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private var buffer = ""
    private var closed = false
    private(set) var rowCount = 0

    init(url: URL, header: String) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        queue = DispatchQueue(label: "csv.\(url.lastPathComponent)")
        buffer = header + "\n"
    }

    func append(_ line: String) {
        queue.async {
            // 停止录制后扫描/传感器线程可能还有残留回调，直接丢弃
            guard !self.closed else { return }
            self.buffer += line
            self.buffer += "\n"
            self.rowCount += 1
            if self.buffer.utf8.count > 64_000 { self.flushLocked() }
        }
    }

    func flush() {
        queue.async { self.flushLocked() }
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            flushLocked()
            closed = true
            try? handle.close()
        }
    }

    private func flushLocked() {
        guard !closed, !buffer.isEmpty else { return }
        handle.write(Data(buffer.utf8))
        buffer = ""
    }
}

enum Fmt {
    static func f(_ v: Double, _ digits: Int = 4) -> String {
        String(format: "%.\(digits)f", v)
    }

    /// CSV 字段转义：含逗号、引号或换行时加引号。
    static func csv(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
