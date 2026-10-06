import CoreBluetooth
import Foundation
import UIKit

struct TagStat: Identifiable {
    let id: String
    let avgRssi: Double
    let count: Int
}

/// 跨线程共享的状态（BLE / IMU 回调线程写，UI 定时器读）。
private final class SharedState {
    private let lock = NSLock()
    private var point = ""
    private var recent: [(t: Int64, id: String, rssi: Int)] = []
    private var imuCount = 0
    private var lastMagAcc = -1

    var currentPoint: String {
        get { lock.lock(); defer { lock.unlock() }; return point }
        set { lock.lock(); point = newValue; lock.unlock() }
    }

    func addReading(t: Int64, id: String, rssi: Int) {
        lock.lock()
        recent.append((t, id, rssi))
        lock.unlock()
    }

    func addImu(magAcc: Int) {
        lock.lock()
        imuCount += 1
        lastMagAcc = magAcc
        lock.unlock()
    }

    /// 返回：最近 1 秒读数数、最近 1 秒唯一价签数、最近 2 秒最强 10 个价签、自上次以来 IMU 样本数、磁场精度。
    func snapshot(now: Int64) -> (Int, Int, [TagStat], Int, Int) {
        lock.lock()
        recent.removeAll { now - $0.t > 2000 }
        let lastSec = recent.filter { now - $0.t <= 1000 }
        var agg: [String: (sum: Int, n: Int)] = [:]
        for r in recent {
            let a = agg[r.id] ?? (0, 0)
            agg[r.id] = (a.sum + r.rssi, a.n + 1)
        }
        let imu = imuCount
        imuCount = 0
        let mag = lastMagAcc
        lock.unlock()

        let top = agg.map { TagStat(id: $0.key, avgRssi: Double($0.value.sum) / Double($0.value.n), count: $0.value.n) }
            .sorted { $0.avgRssi > $1.avgRssi }
            .prefix(10)
        return (lastSec.count, Set(lastSec.map(\.id)).count, Array(top), imu, mag)
    }

    func reset() {
        lock.lock()
        recent.removeAll()
        imuCount = 0
        point = ""
        lock.unlock()
    }
}

/// 录制时顺带把 IMU 和原始磁力计转给别的模块（建图时的地磁定位）。回调在传感器线程上，接收方自己换队列。
final class SensorTap: @unchecked Sendable {
    private let lock = NSLock()
    private var _imu: (@Sendable (IMUSample) -> Void)?
    private var _raw: (@Sendable (Int64, (Double, Double, Double)) -> Void)?

    var imu: (@Sendable (IMUSample) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _imu }
        set { lock.lock(); _imu = newValue; lock.unlock() }
    }
    var raw: (@Sendable (Int64, (Double, Double, Double)) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _raw }
        set { lock.lock(); _raw = newValue; lock.unlock() }
    }
}

@MainActor
final class Recorder: ObservableObject {
    // 录制
    @Published var isRecording = false
    @Published var deviceLabel = "16pro"
    @Published var onlyESL = true
    @Published var elapsed: TimeInterval = 0
    @Published var bleState = "未知"
    @Published var lastError: String?

    // 实时统计
    @Published var blePerSec = 0
    @Published var uniqueTagsPerSec = 0
    @Published var imuHz = 0
    @Published var magAccuracy = -1
    @Published var topTags: [TagStat] = []
    @Published var bleRows = 0
    @Published var imuRows = 0
    @Published var magRawHz = 0
    @Published var magRawRows = 0
    /// 额外写进 meta.json 的字段（建图采集用）。
    var extraMeta: [String: Any] = [:]
    var currentSessionDir: URL? { sessionDir }
    /// 向 SensorArbiter 申请传感器时用的名字；为空表示由外层（建图采集）自己申请
    var arbiterName = "采集"
    /// 保护壳 / MagSafe 附件 / 手持姿态等备注，写入 meta.json（地磁对这些很敏感）。
    @Published var setupNote = ""

    // 打点
    @Published var pointId = "1"
    @Published var xText = ""
    @Published var yText = ""
    @Published var markDuration = 60
    @Published var markingPoint: String?
    @Published var markRemaining = 0
    @Published var markCount = 0

    private let ble = BLEScanner()
    private let motion = MotionRecorder()
    let tap = SensorTap()
    /// 录制时是否扫蓝牙（建图采集不需要）
    var recordBLE = true
    private let shared = SharedState()
    private lazy var sensors = SensorLogger(motionManager: motion.manager)
    private var bleWriter: CSVWriter?
    private var imuWriter: CSVWriter?
    private var marksWriter: CSVWriter?
    private var sessionDir: URL?
    private var startMs: Int64 = 0
    private var startDate: Date?
    private var uiTimer: Timer?
    private var lastTick = Date()
    private var markStartMs: Int64 = 0
    private var markX = ""
    private var markY = ""
    private var markEnd: Date?

    nonisolated static var sessionsRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("sessions", isDirectory: true)
    }

    init() {
        ble.onState = { [weak self] state in
            Task { @MainActor in self?.bleState = Recorder.describe(state) }
        }
    }

    // MARK: - 录制

    func startRecording() {
        guard !isRecording else { return }
        if !arbiterName.isEmpty {
            SensorArbiter.shared.claim(arbiterName) { [weak self] in self?.stopRecording() }
        }
        lastError = nil
        do {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd_HHmmss"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            let label = Self.sanitize(deviceLabel.isEmpty ? "ios" : deviceLabel)
            let dir = Self.sessionsRoot.appendingPathComponent("ios_\(label)_\(fmt.string(from: Date()))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let bleW = try CSVWriter(url: dir.appendingPathComponent("ble.csv"),
                                     header: "t_ms,point_id,esl_id,rssi,src,mfg_hex")
            let imuW = try CSVWriter(url: dir.appendingPathComponent("imu.csv"),
                                     header: "t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg")
            let marksW = try CSVWriter(url: dir.appendingPathComponent("marks.csv"),
                                       header: "point_id,x_cm,y_cm,t_start_ms,t_end_ms,note")
            bleWriter = bleW
            imuWriter = imuW
            marksWriter = marksW
            sessionDir = dir
            startMs = Fmt.nowMs()
            startDate = Date()
            shared.reset()
            markCount = 0
            try writeMeta(endMs: nil)

            let shared = self.shared
            ble.onlyESL = onlyESL
            ble.onReading = { r in
                let point = shared.currentPoint
                bleW.append("\(r.tMs),\(Fmt.csv(point)),\(r.eslId ?? ""),\(r.rssi),\(r.src),\(r.mfgHex)")
                shared.addReading(t: r.tMs, id: r.eslId ?? r.src, rssi: r.rssi)
            }
            let tap = self.tap
            sensors.tap = tap
            motion.onSample = { s in
                tap.imu?(s)
                let line = [
                    "\(s.tMs)",
                    Fmt.f(s.acc.0), Fmt.f(s.acc.1), Fmt.f(s.acc.2),
                    Fmt.f(s.gyr.0, 5), Fmt.f(s.gyr.1, 5), Fmt.f(s.gyr.2, 5),
                    Fmt.f(s.mag.0, 3), Fmt.f(s.mag.1, 3), Fmt.f(s.mag.2, 3),
                    "\(s.magAccuracy)",
                    Fmt.f(s.quat.0, 6), Fmt.f(s.quat.1, 6), Fmt.f(s.quat.2, 6), Fmt.f(s.quat.3, 6),
                    Fmt.f(s.headingDeg, 2),
                ].joined(separator: ",")
                imuW.append(line)
                shared.addImu(magAcc: s.magAccuracy)
            }
            if recordBLE { ble.start() }
            motion.start(hz: 50)
            try sensors.start(dir: dir)
            try writeMeta(endMs: nil)
            if !motion.isAvailable {
                lastError = "设备运动传感器不可用"
                AppLog.e("采集", "设备运动传感器不可用")
            }
            AppLog.shared.startMirroring(to: dir)
            AppLog.i("采集", "开始录制：\(dir.lastPathComponent)，仅价签 \(onlyESL ? "是" : "否")")

            UIApplication.shared.isIdleTimerDisabled = true
            isRecording = true
            lastTick = Date()
            uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            lastError = "开始录制失败：\(error.localizedDescription)"
            AppLog.e("采集", "开始录制失败：\(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        if markingPoint != nil { endMark(note: "录制停止时结束") }
        ble.stop()
        motion.stop()
        sensors.stop()
        ble.onReading = nil
        motion.onSample = nil
        uiTimer?.invalidate()
        uiTimer = nil
        bleWriter?.close()
        imuWriter?.close()
        marksWriter?.close()
        try? writeMeta(endMs: Fmt.nowMs())
        bleWriter = nil
        imuWriter = nil
        marksWriter = nil
        UIApplication.shared.isIdleTimerDisabled = false
        isRecording = false
        if !arbiterName.isEmpty { SensorArbiter.shared.release(arbiterName) }
        AppLog.i("采集", "停止录制：BLE \(bleRows) 行，IMU \(imuRows) 行，打点 \(markCount) 次")
        AppLog.shared.stopMirroring()
    }

    // MARK: - 打点

    func startMark() {
        guard isRecording, markingPoint == nil else { return }
        let id = pointId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            lastError = "请先填写点位编号"
            return
        }
        lastError = nil
        markStartMs = Fmt.nowMs()
        markX = xText.trimmingCharacters(in: .whitespaces)
        markY = yText.trimmingCharacters(in: .whitespaces)
        markEnd = Date().addingTimeInterval(TimeInterval(markDuration))
        markRemaining = markDuration
        markingPoint = id
        shared.currentPoint = id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        AppLog.i("打点", "点位 \(id) 开始，计划 \(markDuration) 秒" +
                 (markX.isEmpty && markY.isEmpty ? "" : "，坐标 (\(markX), \(markY))"))
    }

    func endMark(note: String = "") {
        guard let id = markingPoint else { return }
        shared.currentPoint = ""
        marksWriter?.append([Fmt.csv(id), Fmt.csv(markX), Fmt.csv(markY),
                             "\(markStartMs)", "\(Fmt.nowMs())", Fmt.csv(note)].joined(separator: ","))
        marksWriter?.flush()
        markingPoint = nil
        markEnd = nil
        markRemaining = 0
        markCount += 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AppLog.i("打点", "点位 \(id) 结束" + (note.isEmpty ? "" : "（\(note)）"))
        // 纯数字编号自动 +1，方便连续打点
        if let n = Int(id) { pointId = String(n + 1) }
    }

    // MARK: - 内部

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if let start = startDate { elapsed = now.timeIntervalSince(start) }
        let (perSec, unique, top, imuCount, mag) = shared.snapshot(now: Fmt.nowMs())
        blePerSec = perSec
        uniqueTagsPerSec = unique
        topTags = top
        imuHz = dt > 0 ? Int((Double(imuCount) / dt).rounded()) : 0
        magAccuracy = mag
        magRawHz = dt > 0 ? Int((Double(sensors.takeMagCount()) / dt).rounded()) : 0
        magRawRows = sensors.magRawRows
        bleRows = bleWriter?.rowCount ?? 0
        imuRows = imuWriter?.rowCount ?? 0
        if let end = markEnd {
            markRemaining = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
            if now >= end { endMark() }
        }
        // 定期落盘，避免异常退出丢数据
        bleWriter?.flush()
        imuWriter?.flush()
        sensors.flush()
    }

    private func writeMeta(endMs: Int64?) throws {
        guard let dir = sessionDir else { return }
        var sys = utsname()
        uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        var meta: [String: Any] = [
            "platform": "ios",
            "device_label": deviceLabel,
            "model": model,
            "os_version": UIDevice.current.systemVersion,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "start_ms": startMs,
            "only_esl": onlyESL,
            "imu_target_hz": 50,
            "format_version": 2,
            "setup_note": setupNote,
            "mag_raw_target_hz": 100,
            "sensors_available": sensors.available,
            "mag_raw_convention": "uT, CMMagnetometerData: device frame, NOT bias-corrected; calibrated field is in imu.csv mx..mz",
            "imu_convention": "android: acc m/s^2 incl. gravity (+z up when flat), gyro rad/s, mag uT calibrated",
        ]
        for (k, v) in extraMeta { meta[k] = v }
        if let endMs { meta["end_ms"] = endMs }
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("meta.json"))
    }

    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    private static func describe(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "已开启"
        case .poweredOff: return "已关闭"
        case .unauthorized: return "未授权"
        case .unsupported: return "不支持"
        case .resetting: return "重置中"
        default: return "未知"
        }
    }
}
