import Foundation
import HPASSKit
import UIKit

/// 一次「我现在在点位 X」的验证结果。
struct MagCheck: Identifiable {
    let id = UUID()
    let pointId: String
    let errorCm: Double
}

/// 导航提示：到目标点的距离，以及需要转多少度（正 = 向左转，与 HPASSKit 的航向约定一致）。
struct MagNavHint {
    var targetId: String
    var distanceCm: Double
    var turnRad: Double
    var arrived: Bool
}

/// 流水线内核：只允许在引擎的串行队列上访问。
private final class MagPipeline {
    let extractor = MagneticFeatureExtractor()
    var fusion: FusionEngine?
    var localizer: MagneticLocalizer?
    var mode: MagneticEngine.Phase = .idle

    var latest: MagneticFeature?
    var calSamples: [MagneticFieldBuilder.TimedFeature] = []
    var lastCalSampleMs: Int64 = 0

    var lastFusedPos: Point2?
    var lastOut: FusionOutput?
    var estimate: MagneticEstimate?
    var lastPublishMs: Int64 = 0
    var pendingCheck: String?
    var trackWriter: CSVWriter?
}

/// 地磁模式：校准（现场建磁场图）和定位（惯导 + 磁场地图的粒子滤波）。
///
/// 自己持有一个 `MotionRecorder`，与采集页、蓝牙定位页互相独立，**请不要同时运行**。
/// 这个模式不用蓝牙。
@MainActor
final class MagneticEngine: ObservableObject {
    enum Phase { case idle, calibrating, localizing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var feature: MagneticFeature?
    @Published private(set) var lastError: String?

    // 校准
    @Published private(set) var calIndex = 0            // 当前所在 / 刚离开的点位下标
    @Published private(set) var calMoving = false       // 已离开 calIndex，正在走向下一个点位
    @Published private(set) var calSampleCount = 0
    @Published private(set) var calUsedPoints: [MarkPoint] = []

    // 定位
    @Published private(set) var estimate: MagneticEstimate?
    @Published private(set) var position: Point2?
    @Published private(set) var headingRad: Double = 0
    @Published private(set) var stepCount = 0
    @Published private(set) var trail: [Point2] = []
    @Published private(set) var checks: [MagCheck] = []
    @Published private(set) var targetId: String?
    @Published private(set) var hint: MagNavHint?
    @Published var autoAdvance = true
    @Published private(set) var trackFileName: String?

    static let trailCapacity = 600
    private static let arriveCm: Double = 100

    private let motion = MotionRecorder()
    private nonisolated let queue = DispatchQueue(label: "mag.pipeline", qos: .userInitiated)
    private let pipe = MagPipeline()
    private var calWaypoints: [MagneticFieldBuilder.Waypoint] = []
    private var route: [MarkPoint] = []

    // MARK: - 校准

    /// 开始一遍校准：按点位顺序走。先站在第一个点位上，然后依次「离开 / 到达」。
    func startCalibration() {
        let store = MagMapStore.shared
        guard phase == .idle else { return }
        guard store.points.count >= 2 else {
            lastError = "至少需要 2 个点位才能校准"
            return
        }
        guard motion.isAvailable else {
            lastError = "设备运动传感器不可用"
            return
        }
        lastError = nil
        route = store.points
        calUsedPoints = route
        calIndex = 0
        calMoving = false
        calSampleCount = 0
        calWaypoints = [.init(tMs: Fmt.nowMs(), position: route[0].position)]
        startMotion(mode: .calibrating)
        AppLog.i("地磁", "开始校准：\(route.count) 个点位，从点位 \(route[0].id) 起")
    }

    /// 离开当前点位（开始走向下一个）。
    func calibrationDepart() {
        guard phase == .calibrating, !calMoving, calIndex < route.count - 1 else { return }
        calWaypoints.append(.init(tMs: Fmt.nowMs(), position: route[calIndex].position))
        calMoving = true
        AppLog.tap("校准·离开", "点位 \(route[calIndex].id)")
    }

    /// 到达下一个点位。
    func calibrationArrive() {
        guard phase == .calibrating, calMoving else { return }
        calIndex += 1
        calWaypoints.append(.init(tMs: Fmt.nowMs(), position: route[calIndex].position))
        calMoving = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        AppLog.tap("校准·到达", "点位 \(route[calIndex].id)")
    }

    var calibrationFinishable: Bool {
        phase == .calibrating && !calMoving && calIndex == route.count - 1
    }

    /// 结束这一遍，把数据并入地图。`keep == false` 表示放弃这一遍。
    func finishCalibration(keep: Bool) {
        guard phase == .calibrating else { return }
        let waypoints = calWaypoints
        stopMotion()
        guard keep else {
            AppLog.i("地磁", "放弃本遍校准")
            return
        }
        queue.async { [pipe] in
            let samples = pipe.calSamples
            pipe.calSamples = []
            Task { @MainActor in
                let used = MagMapStore.shared.addCalibration(waypoints: waypoints, samples: samples)
                if used == 0 { self.lastError = "这一遍没有有效数据（点位之间需要真的走过去）" }
            }
        }
    }

    // MARK: - 定位

    /// 开始定位。已知起点：站在 `startId` 点位上、面朝下一个点位（或上一个，如果它是最后一个）。
    /// `unknownStart` 为 true 时不给位置，粒子撒满全图，用来测试冷启动。
    func startLocalizing(startId: String?, unknownStart: Bool) {
        let store = MagMapStore.shared
        guard phase == .idle else { return }
        guard let field = store.field else {
            lastError = "还没有磁场数据，请先完成地磁校准"
            return
        }
        guard motion.isAvailable else {
            lastError = "设备运动传感器不可用"
            return
        }
        lastError = nil

        var start: Point2?
        var heading: Double?
        if !unknownStart, let sid = startId, let idx = store.points.firstIndex(where: { $0.id == sid }) {
            let p = store.points[idx]
            let other = idx + 1 < store.points.count ? store.points[idx + 1]
                : (idx > 0 ? store.points[idx - 1] : nil)
            start = p.position
            if let o = other { heading = atan2(o.x - p.x, o.y - p.y) }
        }
        route = store.points

        var cfgF = FusionConfig()
        cfgF.useCorridorConstraint = false
        let fusion = FusionEngine(corridors: [], config: cfgF)
        fusion.setInitialPosition(start ?? Point2(store.widthCm / 2, store.heightCm / 2), headingRad: heading)
        let localizer = MagneticLocalizer(field: field)
        localizer.reset(start: start)

        let writer = Self.makeTrackWriter()
        trackFileName = writer?.name
        queue.sync {
            pipe.fusion = fusion
            pipe.localizer = localizer
            pipe.lastFusedPos = nil
            pipe.lastOut = nil
            pipe.estimate = nil
            pipe.pendingCheck = nil
            pipe.trackWriter = writer?.writer
        }
        trail = []
        checks = []
        estimate = nil
        position = start
        stepCount = 0
        hint = nil
        targetId = nil
        startMotion(mode: .localizing)
        AppLog.i("地磁", "开始定位：" + (start.map { "起点 \($0)" } ?? "未知起点") + "，粒子 \(MagneticConfig().particleCount)")
    }

    func stopLocalizing() {
        guard phase == .localizing else { return }
        stopMotion()
        queue.async { [pipe] in
            pipe.trackWriter?.close()
            pipe.trackWriter = nil
        }
        AppLog.i("地磁", "停止定位，验证 \(checks.count) 次")
    }

    func setTarget(_ id: String?) {
        targetId = id
        hint = nil
        refreshHint()
    }

    /// 「我现在就站在点位 id 上」：记录当前估计与真值的差。
    func recordCheck(pointId: String) {
        guard phase == .localizing, let p = position, let truth = MagMapStore.shared.point(id: pointId) else { return }
        let err = p.distance(to: truth.position)
        checks.append(MagCheck(pointId: pointId, errorCm: err))
        queue.async { [pipe] in pipe.pendingCheck = pointId }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AppLog.i("地磁", "验证 点位 \(pointId)：估计 \(p)，误差 \(Fmt.f(err, 0)) cm")
    }

    func clearError() { lastError = nil }

    // MARK: - 传感器与流水线

    private func startMotion(mode: Phase) {
        let pipe = self.pipe
        queue.sync {
            pipe.mode = mode
            pipe.extractor.reset()
            pipe.latest = nil
            pipe.calSamples = []
            pipe.lastCalSampleMs = 0
            pipe.lastPublishMs = 0
        }
        motion.onSample = { [weak self] s in
            guard let self else { return }
            self.queue.async { self.handleIMU(s, pipe: pipe) }
        }
        motion.start(hz: 50)
        phase = mode
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func stopMotion() {
        motion.stop()
        motion.onSample = nil
        queue.async { [pipe] in pipe.mode = .idle }
        phase = .idle
        feature = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private nonisolated func handleIMU(_ s: IMUSample, pipe: MagPipeline) {
        let sample = HPASSKit.IMUSample(tMs: s.tMs, ax: s.acc.0, ay: s.acc.1, az: s.acc.2,
                                        gx: s.gyr.0, gy: s.gyr.1, gz: s.gyr.2,
                                        mx: s.mag.0, my: s.mag.1, mz: s.mag.2)
        let feat = pipe.extractor.process(sample)
        pipe.latest = feat
        switch pipe.mode {
        case .idle:
            return
        case .calibrating:
            // 25 Hz 足够，省内存
            if let f = feat, s.tMs - pipe.lastCalSampleMs >= 40 {
                pipe.calSamples.append(.init(tMs: s.tMs, feature: f))
                pipe.lastCalSampleMs = s.tMs
            }
            publishLive(pipe: pipe, tMs: s.tMs)
        case .localizing:
            guard let fusion = pipe.fusion, let loc = pipe.localizer, let out = fusion.process(sample) else {
                publishLive(pipe: pipe, tMs: s.tMs)
                return
            }
            let delta = pipe.lastFusedPos.map { out.position - $0 } ?? .zero
            pipe.lastFusedPos = out.position
            pipe.lastOut = out
            let est = loc.step(delta: delta, feature: feat)
            pipe.estimate = est
            if let w = pipe.trackWriter {
                let check = pipe.pendingCheck ?? ""
                pipe.pendingCheck = nil
                w.append([
                    "\(out.tMs)", Fmt.f(est.position.x, 1), Fmt.f(est.position.y, 1),
                    Fmt.f(est.uncertaintyCm, 1), Fmt.f(est.confidence, 3),
                    Fmt.f(out.position.x, 1), Fmt.f(out.position.y, 1), Fmt.f(out.headingDeg, 1),
                    "\(out.stepCount)",
                    Fmt.f(feat?.total ?? 0, 2), Fmt.f(feat?.vertical ?? 0, 2), Fmt.f(feat?.horizontal ?? 0, 2),
                    check,
                ].joined(separator: ","))
            }
            let heading = out.headingRad, steps = out.stepCount
            Task { @MainActor in self.applyLocalization(est, heading: heading, steps: steps, feature: feat) }
        }
    }

    /// 校准时刷新实时磁场读数，最多 5 Hz。
    private nonisolated func publishLive(pipe: MagPipeline, tMs: Int64) {
        guard tMs - pipe.lastPublishMs >= 200 else { return }
        pipe.lastPublishMs = tMs
        let f = pipe.latest, n = pipe.calSamples.count
        Task { @MainActor in
            self.feature = f
            if self.phase == .calibrating { self.calSampleCount = n }
        }
    }

    private func applyLocalization(_ est: MagneticEstimate, heading: Double, steps: Int, feature f: MagneticFeature?) {
        guard phase == .localizing else { return }
        estimate = est
        headingRad = heading
        stepCount = steps
        feature = f
        let p = est.position
        position = p
        if let last = trail.last, last.distance(to: p) < 15 {
            // 太近不记
        } else {
            trail.append(p)
            if trail.count > Self.trailCapacity { trail.removeFirst(trail.count - Self.trailCapacity) }
        }
        refreshHint()
    }

    private func refreshHint() {
        guard let id = targetId, let p = position, let t = MagMapStore.shared.point(id: id) else {
            hint = nil
            return
        }
        let dx = t.x - p.x, dy = t.y - p.y
        let dist = (dx * dx + dy * dy).squareRoot()
        var turn = atan2(dx, dy) - headingRad
        turn = atan2(sin(turn), cos(turn))                 // 规范到 (−π, π]
        let arrived = dist <= Self.arriveCm
        hint = MagNavHint(targetId: id, distanceCm: dist, turnRad: turn, arrived: arrived)
        if arrived, autoAdvance, phase == .localizing {
            let pts = MagMapStore.shared.points
            if let i = pts.firstIndex(where: { $0.id == id }), i + 1 < pts.count {
                AppLog.i("地磁", "到达点位 \(id)，下一个目标 \(pts[i + 1].id)")
                targetId = pts[i + 1].id
                refreshHint()
            }
        }
    }

    // MARK: - 轨迹文件

    private static func makeTrackWriter() -> (writer: CSVWriter, name: String)? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("mag-tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let name = "mag_\(fmt.string(from: Date())).csv"
        guard let w = try? CSVWriter(url: dir.appendingPathComponent(name),
                                     header: "t_ms,x_cm,y_cm,unc_cm,conf,pdr_x,pdr_y,heading_deg,steps,b_total,b_vert,b_horiz,check") else {
            return nil
        }
        return (w, name)
    }
}
