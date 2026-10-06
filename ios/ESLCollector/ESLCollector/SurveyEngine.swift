import ARKit
import Combine
import Foundation
import HPASSKit
import UIKit

/// 各条通道的采集进度：每条通道按 1 m 分段，分别记「沿 a→b 方向走过」和「沿 b→a 方向走过」。
/// 存在 `Documents/survey-coverage.json`，换会话也保留。
@MainActor
final class SurveyCoverage: ObservableObject {
    static let binCm = 100.0

    @Published private(set) var revision = 0
    private var forward: [[Bool]] = []
    private var backward: [[Bool]] = []
    private var segments: [CrossSegment] = []
    private var lengths: [Double] = []

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("survey-coverage.json")
    }

    func configure(crosses: [CrossSegment]) {
        guard crosses.count != segments.count || zip(crosses, segments).contains(where: { $0.a != $1.a || $0.b != $1.b }) else { return }
        segments = crosses
        lengths = crosses.map { $0.a.distance(to: $0.b) }
        forward = lengths.map { [Bool](repeating: false, count: max(Int(($0 / Self.binCm).rounded(.up)), 1)) }
        backward = forward
        load()
        revision += 1
    }

    /// 地图位置 p（cm）、行进方向 dir（任意长度的位移向量）落在哪条通道上，标记那一段已走。
    func mark(position p: Point2, moving dir: Point2) {
        var changed = false
        for (i, c) in segments.enumerated() {
            let dx = c.b.x - c.a.x, dy = c.b.y - c.a.y
            let len2 = dx * dx + dy * dy
            guard len2 > 1 else { continue }
            let t = ((p.x - c.a.x) * dx + (p.y - c.a.y) * dy) / len2
            guard t >= -0.01, t <= 1.01 else { continue }
            let q = Point2(c.a.x + t * dx, c.a.y + t * dy)
            guard p.distance(to: q) <= max(c.lineWidth, 0) / 2 + 40 else { continue }
            let bin = min(max(Int(t * lengths[i] / Self.binCm), 0), forward[i].count - 1)
            let along = dir.x * dx + dir.y * dy
            if along >= 0 {
                if !forward[i][bin] { forward[i][bin] = true; changed = true }
            } else if !backward[i][bin] {
                backward[i][bin] = true; changed = true
            }
        }
        if changed { revision += 1 }
    }

    /// 0...1：两个方向各占一半。
    func fraction(_ i: Int) -> Double {
        guard forward.indices.contains(i) else { return 0 }
        let f = Double(forward[i].filter { $0 }.count) / Double(forward[i].count)
        let b = Double(backward[i].filter { $0 }.count) / Double(backward[i].count)
        return (f + b) / 2
    }

    var fractions: [Double] { segments.indices.map { fraction($0) } }

    /// 每条通道每 1 m 一段的状态：没采完 / 已采完但孤立 / 已采完且已和别的路段关联（共用路口）。
    var states: [[CoverageState]] {
        CoverageLinker.link(crosses: segments, done: doneBins, binCm: Self.binCm)
    }

    /// 每条通道每 1 m 一段：两个方向都走过才算采完。
    var doneBins: [[Bool]] {
        forward.indices.map { i in zip(forward[i], backward[i]).map { $0 && $1 } }
    }

    /// 已走过的通道长度（m），按「通道长度 × 覆盖率」累计；双向都走完才算满。
    var coveredMeters: Double { segments.indices.reduce(0) { $0 + fraction($1) * lengths[$1] / 100 } }
    var totalMeters: Double { lengths.reduce(0, +) / 100 }

    func reset() {
        for i in forward.indices {
            forward[i] = [Bool](repeating: false, count: forward[i].count)
            backward[i] = forward[i]
        }
        revision += 1
        save()
    }

    func save() {
        struct File: Codable { var f: [[Int]]; var b: [[Int]] }
        let file = File(f: forward.map { $0.map { $0 ? 1 : 0 } }, b: backward.map { $0.map { $0 ? 1 : 0 } })
        if let d = try? JSONEncoder().encode(file) { try? d.write(to: Self.fileURL, options: .atomic) }
    }

    private func load() {
        struct File: Codable { var f: [[Int]]; var b: [[Int]] }
        guard let d = try? Data(contentsOf: Self.fileURL), let file = try? JSONDecoder().decode(File.self, from: d),
              file.f.count == forward.count, file.b.count == backward.count else { return }
        for i in forward.indices where file.f[i].count == forward[i].count && file.b[i].count == backward[i].count {
            forward[i] = file.f[i].map { $0 != 0 }
            backward[i] = file.b[i].map { $0 != 0 }
        }
    }
}

/// 建图采集：沿通道走，一边录全部传感器，一边用 ARKit 视觉里程计提供位置真值。
///
/// 流程与「实时定位」一致：长按地图 = 我在这里；双击设朝向；朝设定方向走出 1.5 m 后，
/// ARKit 轨迹自动对齐到地图。之后位置由 ARKit 给出，走到路口或已知点位时长按地图修正，
/// 每次修正都写进 `anchors.csv`，离线建图时用它们分段校正 ARKit 的漂移。
@MainActor
final class SurveyEngine: ObservableObject {
    enum Stage { case idle, needPosition, needHeading, aligning, tracking }

    /// 走出多远（cm）才用位移方向对齐朝向
    private static let alignCm = 150.0
    /// 建议每隔多少米修正一次位置
    static let anchorEveryM = 30.0
    /// 长按时吸附到路点 / 点位的半径（cm）
    private static let snapCm = 60.0

    let recorder = Recorder()
    let coverage = SurveyCoverage()

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var position: Point2?
    @Published private(set) var headingRad: Double = 0
    @Published private(set) var headingEditing = false
    @Published private(set) var trail: [Point2] = []
    @Published private(set) var trackingState = 0
    @Published private(set) var anchorCount = 0
    @Published private(set) var walkedSinceAnchorM = 0.0
    @Published private(set) var totalWalkedM = 0.0
    @Published private(set) var sessionName: String?
    /// LiDAR 实景扫描：建图时同时扫网格，结束时导出 mesh.ply（电脑上用 tools/meshcheck.py 量货架高度和偏移）
    @Published var scanMesh = false
    /// 地图 → ARKit 的变换（对齐之后才有），给 AR 叠加用
    @Published private(set) var arAlignment: MapARTransform?
    @Published private(set) var arFloorY: Double?
    var arSession: ARSession { ar.session }
    /// 上一次建图采集的会话目录（结束之后用来导出）
    @Published private(set) var lastSessionDir: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var lastSnap: String?

    private let ar = ARKitLogger()
    private var anchorsWriter: CSVWriter?
    private var cancellable: AnyCancellable?

    // 对齐参数：map = pRef + R(phi) · (a − aRef)，a 是 ARKit 的 (x, z)，单位 cm
    private var aRef = Point2.zero
    private var pRef = Point2.zero
    private var phi = 0.0
    private var targetHeading = 0.0
    private var latestA: Point2?
    private var lastMapPos: Point2?
    private var lastLogMs: Int64 = 0

    init() {
        // 把录制器的变化转发出来，界面只需要观察本对象
        cancellable = Publishers.Merge(recorder.objectWillChange, coverage.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        ar.onPose = { [weak self] t, x, z, state in
            Task { @MainActor in self?.handlePose(t: t, a: Point2(x, z), state: state) }
        }
        ar.onFloor = { [weak self] y in
            Task { @MainActor in self?.arFloorY = y }
        }
        ar.onError = { [weak self] msg in
            Task { @MainActor in
                self?.lastError = msg
                AppLog.e("建图", msg)
            }
        }
    }

    var isRunning: Bool { stage != .idle }

    // MARK: 开始 / 结束

    func start(note: String) {
        guard stage == .idle else { return }
        guard ARKitLogger.isSupported else {
            lastError = "这台设备不支持 ARKit 世界跟踪"
            return
        }
        let store = MagMapStore.shared
        coverage.configure(crosses: store.crosses)
        lastError = nil
        recorder.deviceLabel = "survey"
        recorder.setupNote = note
        recorder.extraMeta = [
            "survey": true,
            "map_width_cm": store.widthCm, "map_height_cm": store.heightCm,
            "arkit": true,
            "arkit_frame": "gravity-aligned, x right, y up, z toward viewer; map = pRef + R(phi)(a - aRef), a = (x, z) cm",
        ]
        recorder.startRecording()
        guard recorder.isRecording, let dir = recorder.currentSessionDir else {
            lastError = recorder.lastError ?? "录制没有启动"
            return
        }
        do {
            anchorsWriter = try CSVWriter(url: dir.appendingPathComponent("anchors.csv"),
                                          header: "t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note")
            try ar.start(dir: dir, wantsDepth: true, lateralFile: dir.appendingPathComponent("depth_lateral.csv"),
                         wantsMesh: scanMesh)
            arFloorY = nil
            arAlignment = nil
        } catch {
            lastError = "启动失败：\(error.localizedDescription)"
            recorder.stopRecording()
            return
        }
        sessionName = dir.lastPathComponent
        lastSessionDir = dir
        position = nil
        trail = []
        anchorCount = 0
        walkedSinceAnchorM = 0
        totalWalkedM = 0
        latestA = nil
        lastMapPos = nil
        stage = .needPosition
        UIApplication.shared.isIdleTimerDisabled = true
        AppLog.i("建图", "开始建图采集：\(dir.lastPathComponent)")
    }

    func stop() {
        guard stage != .idle else { return }
        if stage == .tracking, let p = position, let a = latestA {
            writeAnchor(kind: "end", map: p, ar: a, heading: nil, note: "")
        }
        if scanMesh, let dir = recorder.currentSessionDir {
            do {
                let n = try ar.exportMesh(to: dir.appendingPathComponent("mesh.ply"))
                recorder.extraMeta["lidar_mesh"] = n.vertices > 0
                AppLog.i("建图", "LiDAR 网格：\(n.vertices) 个顶点，\(n.faces) 个三角形")
            } catch {
                AppLog.e("建图", "导出网格失败：\(error.localizedDescription)")
            }
        }
        ar.stop()
        arAlignment = nil
        anchorsWriter?.close()
        anchorsWriter = nil
        recorder.stopRecording()
        coverage.save()
        stage = .idle
        headingEditing = false
        UIApplication.shared.isIdleTimerDisabled = false
        AppLog.i("建图", "结束：走了 \(Fmt.f(totalWalkedM, 0)) m，修正 \(anchorCount) 次")
    }

    // MARK: 交互

    /// 长按地图：我现在在这里（第一次 = 起点，之后 = 修正）。
    func anchor(at tapped: Point2) {
        guard stage != .idle else { return }
        guard let a = latestA else {
            lastError = "ARKit 还没有出位姿，等一两秒再试"
            return
        }
        let (p, snapLabel) = snap(tapped)
        lastSnap = snapLabel
        switch stage {
        case .needPosition, .needHeading:
            pRef = p
            aRef = a
            position = p
            lastMapPos = p
            trail = [p]
            writeAnchor(kind: "start", map: p, ar: a, heading: nil, note: snapLabel ?? "")
            stage = .needHeading
        case .aligning, .tracking:
            // 修正：不改旋转，只把位置拉到 p
            let before = position
            pRef = p
            aRef = a
            position = p
            lastMapPos = p
            trail.append(p)
            walkedSinceAnchorM = 0
            writeAnchor(kind: "reanchor", map: p, ar: a, heading: nil,
                        note: (snapLabel ?? "") + (before.map { " 修正前偏 \(Int($0.distance(to: p))) cm" } ?? ""))
            publishAlignment()
        case .idle:
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 双击：开始 / 结束设朝向。
    func toggleHeadingEdit() {
        guard stage == .needHeading || stage == .aligning || stage == .tracking else {
            if stage == .needPosition { lastError = "先长按地图，设定你现在的位置" }
            return
        }
        guard let p = position, let a = latestA else { return }
        if !headingEditing {
            headingEditing = true
            return
        }
        headingEditing = false
        targetHeading = headingRad
        // 以当前位置为新起点，朝这个方向走 1.5 m 后对齐
        pRef = p
        aRef = a
        stage = .aligning
        publishAlignment()
        writeAnchor(kind: "heading", map: p, ar: a, heading: headingRad, note: "")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func pointHeading(toward t: Point2) {
        guard headingEditing, let p = position, p.distance(to: t) > 10 else { return }
        headingRad = atan2(t.x - p.x, t.y - p.y)
    }

    func resetCoverage() { coverage.reset() }

    private func publishAlignment() {
        arAlignment = stage == .tracking ? MapARTransform(pRef: pRef, aRef: aRef, phi: phi) : nil
    }

    // MARK: ARKit 位姿

    private func handlePose(t: Int64, a: Point2, state: Int) {
        guard stage != .idle else { return }
        latestA = a
        if state != trackingState { trackingState = state }
        guard state == 2 else { return }            // 跟踪受限时不更新位置，也不记覆盖

        switch stage {
        case .aligning:
            let d = a - aRef
            guard d.length >= Self.alignCm else { return }
            let hm = Point2(sin(targetHeading), cos(targetHeading))
            phi = atan2(hm.y, hm.x) - atan2(d.y, d.x)
            stage = .tracking
            AppLog.i("建图", "朝向对齐完成，旋转 \(Fmt.f(phi * 180 / Double.pi, 1))°")
            publishAlignment()
        case .tracking:
            break
        default:
            return
        }
        guard stage == .tracking else { return }

        let d = a - aRef
        let c = cos(phi), s = sin(phi)
        let p = Point2(pRef.x + d.x * c - d.y * s, pRef.y + d.x * s + d.y * c)
        let step = lastMapPos.map { p - $0 } ?? .zero
        if step.length >= 15 {
            walkedSinceAnchorM += step.length / 100
            totalWalkedM += step.length / 100
            trail.append(p)
            if trail.count > 1500 { trail.removeFirst(trail.count - 1500) }
            coverage.mark(position: p, moving: step)
            lastMapPos = p
            headingRad = atan2(step.x, step.y)
        }
        position = p
    }

    // MARK: 工具

    /// 离路点 / 点位 60 cm 以内就吸附上去。
    private func snap(_ p: Point2) -> (Point2, String?) {
        var best: (Point2, String)?
        var bd = Self.snapCm
        for m in MagMapStore.shared.points where m.position.distance(to: p) <= bd {
            bd = m.position.distance(to: p)
            best = (m.position, "点位 \(m.id)")
        }
        if let map = StoreDataStore.shared.map {
            for o in map.others where o.shapeType == "MapRoadPoint" {
                let q = Point2(o.x, o.y)
                if q.distance(to: p) <= bd {
                    bd = q.distance(to: p)
                    best = (q, "路点")
                }
            }
        }
        return best.map { ($0.0, $0.1) } ?? (p, nil)
    }

    private func writeAnchor(kind: String, map p: Point2, ar a: Point2, heading: Double?, note: String) {
        anchorsWriter?.append([
            "\(Fmt.nowMs())", kind, Fmt.f(p.x, 1), Fmt.f(p.y, 1), Fmt.f(a.x, 1), Fmt.f(a.y, 1),
            heading.map { Fmt.f($0, 4) } ?? "", Fmt.csv(note),
        ].joined(separator: ","))
        anchorsWriter?.flush()
        anchorCount += 1
    }
}
