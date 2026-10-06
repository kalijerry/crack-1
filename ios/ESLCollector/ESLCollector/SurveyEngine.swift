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
    /// 每段的状态：双向采完的按是否关联分「孤立 / 已关联」；只走了一个方向的标「单向」；其余「没采」。
    var states: [[CoverageState]] {
        var s = CoverageLinker.link(crosses: segments, done: doneBins, binCm: Self.binCm)
        for i in s.indices {
            for b in s[i].indices where s[i][b] == .none && (forward[i][b] || backward[i][b]) {
                s[i][b] = .partial
            }
        }
        return s
    }

    /// 只走了一个方向的长度（m）。
    var oneWayMeters: Double {
        forward.indices.reduce(0.0) { acc, i in
            acc + Double(zip(forward[i], backward[i]).filter { $0 != $1 }.count) * Self.binCm / 100
        }
    }

    /// 离 p 最近的没采完的一段：通道编号、直线距离（m）、是不是只差一个方向。
    func nearestTodo(from p: Point2) -> (code: String, distanceM: Double, oneWay: Bool)? {
        var best: (String, Double, Bool)?
        for i in segments.indices {
            let c = segments[i]
            let n = forward[i].count
            for b in 0..<n where !(forward[i][b] && backward[i][b]) {
                let t = min((Double(b) + 0.5) * Self.binCm / max(lengths[i], 1), 1)
                let q = Point2(c.a.x + (c.b.x - c.a.x) * t, c.a.y + (c.b.y - c.a.y) * t)
                let d = q.distance(to: p) / 100
                if best == nil || d < best!.1 { best = (c.code, d, forward[i][b] || backward[i][b]) }
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
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
    enum Stage { case idle, needPosition, autoLocating, needHeading, aligning, tracking }

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
    /// 在线贴通道：沿通道直走时自动把 ARKit 的朝向和横向偏差拉回通道（默认开）
    @Published var corridorLock = true
    @Published private(set) var lockFixes = 0
    /// 最近 2 秒的步行速度（m/s）
    @Published private(set) var speedMS = 0.0
    /// 太快的时候不记采集进度（磁场采样跟不上、ARKit 也容易丢）
    static let maxSpeedMS = 1.6

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
    private var lock: CorridorLock?

    // 地磁定位（和采集一起跑）：自动起点 + 精度测试
    /// 采集的同时测地磁定位精度（需要已经有磁场图）
    @Published var evaluate = false
    @Published private(set) var shadowStatus: String?
    @Published private(set) var evalSummary: String?
    private(set) var evaluator = LocalizationEvaluator()
    private let shadowQueue = DispatchQueue(label: "survey.shadow", qos: .userInitiated)
    private let shadowBox = ShadowBox()
    private var shadowWriter: CSVWriter?
    private var lastEvalPublish = Date.distantPast
    /// 自动起点：收敛后连续走这么远（cm）才认
    static let autoStartStableCm = 500.0
    private var speedRef: (t: Int64, a: Point2)?

    init() {
        // 把录制器的变化转发出来，界面只需要观察本对象
        cancellable = Publishers.Merge(recorder.objectWillChange, coverage.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        let box = shadowBox, sq = shadowQueue
        ar.onPose = { [weak self] t, x, z, state in
            Task { @MainActor in self?.handlePose(t: t, a: Point2(x, z), state: state) }
            sq.async {
                guard let sh = box.sh, let e = sh.pose(a: Point2(x, z), normal: state == 2) else { return }
                let stable = sh.stableCm, phi = sh.rotFit.phi, ea = sh.estimateA
                Task { @MainActor in self?.handleShadow(t: t, e, stable: stable, phi: phi, a: ea) }
            }
        }
        recorder.tap.imu = { s in
            let h = HPASSKit.IMUSample(tMs: s.tMs, ax: s.acc.0, ay: s.acc.1, az: s.acc.2,
                                       gx: s.gyr.0, gy: s.gyr.1, gz: s.gyr.2,
                                       mx: s.mag.0, my: s.mag.1, mz: s.mag.2)
            sq.async { box.sh?.imu(h) }
        }
        recorder.tap.raw = { t, v in sq.async { box.sh?.rawMag(tMs: t, v) } }
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

    /// IMU / 磁力计采样率太低（后台被系统限流、传感器被别的功能占用）时的提示
    var lowSampleRate: Bool { recorder.imuHz > 0 && recorder.imuHz < Self.minImuHz }
    static let minImuHz = 50

    /// 这一刻采到的数据能不能算进度：速度正常、采样率正常
    private var sampleQualityOK: Bool { speedMS <= Self.maxSpeedMS && !lowSampleRate }

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
        recorder.recordBLE = Features.bluetooth
        recorder.arbiterName = ""
        SensorArbiter.shared.claim("建图采集") { [weak self] in self?.stop() }
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
        lock = store.crosses.isEmpty ? nil : CorridorLock(crosses: store.crosses)
        evaluator = LocalizationEvaluator()
        evalSummary = nil
        shadowStatus = nil
        shadowWriter = nil
        if evaluate { startShadow(dir: dir) }
        lockFixes = 0
        speedMS = 0
        speedRef = nil
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
        stopShadow()
        if evaluate, let s = evalSummary { AppLog.i("建图", "地磁定位精度：\(s)") }
        anchorsWriter?.close()
        anchorsWriter = nil
        recorder.stopRecording()
        coverage.save()
        stage = .idle
        headingEditing = false
        SensorArbiter.shared.release("建图采集")
        UIApplication.shared.isIdleTimerDisabled = false
        AppLog.i("建图", "结束：走了 \(Fmt.f(totalWalkedM, 0)) m，修正 \(anchorCount) 次，自动贴通道 \(lockFixes) 次"
                 + (lock.map { "（累计转 \(Fmt.f($0.totalAbsAngle * 180 / Double.pi, 1))°）" } ?? ""))
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
        case .needPosition, .autoLocating, .needHeading:
            if stage == .autoLocating && !evaluate { stopShadow() }
            shadowStatus = nil
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
            lock?.reset()
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
        lock?.reset()
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
        guard state == 2 else { lock?.reset(); return }   // 跟踪受限时不更新位置，也不记覆盖
        if let r = speedRef {
            if t - r.t >= 2000 { speedMS = a.distance(to: r.a) / 100 / (Double(t - r.t) / 1000); speedRef = (t, a) }
        } else { speedRef = (t, a) }

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
        var p = Point2(pRef.x + d.x * c - d.y * s, pRef.y + d.x * s + d.y * c)
        if corridorLock, let fix = lock?.update(p) {
            // 绕当前位置转 dPhi 再平移：map = p' + R(phi + dPhi)(a' − a)
            phi += fix.dPhi
            p = p + fix.shift
            pRef = p
            aRef = a
            lockFixes += 1
            publishAlignment()
        }
        let step = lastMapPos.map { p - $0 } ?? .zero
        if step.length >= 15 {
            walkedSinceAnchorM += step.length / 100
            totalWalkedM += step.length / 100
            trail.append(p)
            if trail.count > 1500 { trail.removeFirst(trail.count - 1500) }
            if sampleQualityOK { coverage.mark(position: p, moving: step) }
            lastMapPos = p
            headingRad = atan2(step.x, step.y)
        }
        position = p
    }

    // MARK: 地磁定位（自动起点 / 精度测试）

    var canUseShadow: Bool { MagMapStore.shared.field != nil }

    /// 自动起点：不长按、不设朝向，直接沿采集过的通道走，地磁定到了就自动当起点。
    func startAutoLocate() {
        guard stage == .needPosition, let dir = recorder.currentSessionDir else { return }
        guard canUseShadow else { lastError = "还没有磁场图：自动起点只能在已经采过、生成过磁场图的区域用"; return }
        startShadow(dir: dir)
        stage = .autoLocating
        shadowStatus = "地磁定位中：沿采集过的通道正常往前走 10～20 m"
        AppLog.i("建图", "自动起点：开始地磁定位")
    }

    private func startShadow(dir: URL) {
        let store = MagMapStore.shared
        guard shadowBox.sh == nil, let field = store.field else { return }
        let walk = store.walkableMap()
        let raw = store.magSource == "raw"
        if shadowWriter == nil {
            shadowWriter = try? CSVWriter(url: dir.appendingPathComponent("shadow_loc.csv"),
                                          header: "t_ms,est_x_cm,est_y_cm,unc_cm,converged,ref_x_cm,ref_y_cm")
        }
        let box = shadowBox
        shadowQueue.async { box.sh = ShadowLocalizer(field: field, walkable: walk, useRawMag: raw) }
    }

    private func stopShadow() {
        let box = shadowBox
        shadowQueue.async { box.sh = nil }
        shadowWriter?.close()
        shadowWriter = nil
    }

    private func handleShadow(t: Int64, _ e: MagneticEstimate, stable: Double, phi: Double?, a: Point2?) {
        let ref = stage == .tracking ? position : nil
        shadowWriter?.append([
            "\(t)", Fmt.f(e.position.x, 1), Fmt.f(e.position.y, 1), Fmt.f(e.uncertaintyCm, 0), e.converged ? "1" : "0",
            ref.map { Fmt.f($0.x, 1) } ?? "", ref.map { Fmt.f($0.y, 1) } ?? "",
        ].joined(separator: ","))
        switch stage {
        case .autoLocating:
            if !e.converged {
                shadowStatus = "地磁定位中：沿采集过的通道正常往前走 10～20 m"
            } else if stable < Self.autoStartStableCm || phi == nil {
                shadowStatus = "已经定到，确认中（\(Int(stable / 100)) / \(Int(Self.autoStartStableCm / 100)) m）"
            } else if let phi, let a {
                autoStart(at: e.position, ar: a, phi: phi, uncertainty: e.uncertaintyCm)
            }
        case .tracking where evaluate:
            guard let r = ref else { return }
            evaluator.add(estimate: e, reference: r)
            if Date().timeIntervalSince(lastEvalPublish) > 1 {
                lastEvalPublish = Date()
                evalSummary = evaluator.summary
            }
        default:
            break
        }
    }

    private func autoStart(at p: Point2, ar a: Point2, phi newPhi: Double, uncertainty: Double) {
        pRef = p
        aRef = a
        phi = newPhi
        position = p
        lastMapPos = p
        trail = [p]
        walkedSinceAnchorM = 0
        lock?.reset()
        let note = "自动起点 ±\(Int(uncertainty)) cm"
        writeAnchor(kind: "start", map: p, ar: a, heading: nil, note: note)
        writeAnchor(kind: "align", map: p, ar: a, heading: newPhi, note: note)
        stage = .tracking
        shadowStatus = nil
        if !evaluate { stopShadow() }
        publishAlignment()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AppLog.i("建图", "自动起点：\(p)，旋转 \(Fmt.f(newPhi * 180 / Double.pi, 1))°，不确定度 \(Int(uncertainty)) cm")
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

/// 只在 shadowQueue 上读写
private final class ShadowBox: @unchecked Sendable {
    var sh: ShadowLocalizer?
}
