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

    // 实时定位（标点即走）
    var tracking = false
    var magAccuracy = -1
    var stepBase = 0
}

/// 地磁模式：校准（现场建磁场图）和定位（惯导 + 磁场地图的粒子滤波）。
///
/// 自己持有一个 `MotionRecorder`，与采集页、蓝牙定位页互相独立，**请不要同时运行**。
/// 这个模式不用蓝牙。
@MainActor
final class MagneticEngine: ObservableObject {
    enum Phase { case idle, calibrating, localizing, live }

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

    // 实时定位（标点即走）
    @Published private(set) var magAccuracy = -1
    @Published private(set) var isTracking = false
    @Published private(set) var headingEditing = false
    @Published private(set) var uncertaintyCm: Double = 0
    /// 用磁罗盘持续修正航向。钢货架附近罗盘常偏，默认关，只靠陀螺。
    @Published var useCompassHeading = false
    /// 有磁场地图时，用地磁粒子滤波纠偏。
    @Published var useMagCorrection = false

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

    // MARK: - 实时定位：校准传感器 → 长按定点 → 双击设朝向 → 走

    /// 打开传感器。此时就能看磁场精度和步数；定点、设好朝向后才开始推算位置。
    func startLive() {
        guard phase == .idle else { return }
        guard motion.isAvailable else {
            lastError = "设备运动传感器不可用"
            return
        }
        lastError = nil
        let store = MagMapStore.shared
        // 先用一个放在地图中心的引擎跑计步，便于在原地踏步检查
        let warmup = makeFusion(at: Point2(store.widthCm / 2, store.heightCm / 2), heading: nil)
        let writer = Self.makeTrackWriter()
        trackFileName = writer?.name
        queue.sync {
            pipe.fusion = warmup
            pipe.localizer = nil
            pipe.tracking = false
            pipe.stepBase = 0
            pipe.lastFusedPos = nil
            pipe.lastOut = nil
            pipe.estimate = nil
            pipe.pendingCheck = nil
            pipe.trackWriter = writer?.writer
        }
        position = nil
        trail = []
        checks = []
        estimate = nil
        stepCount = 0
        uncertaintyCm = 0
        isTracking = false
        headingEditing = false
        hint = nil
        targetId = nil
        startMotion(mode: .live)
        AppLog.i("地磁", "实时定位：打开传感器，罗盘修正 \(useCompassHeading ? "开" : "关")，地磁纠偏 \(useMagCorrection ? "开" : "关")")
    }

    func stopLive() {
        guard phase == .live else { return }
        stopMotion()
        queue.async { [pipe] in
            pipe.trackWriter?.close()
            pipe.trackWriter = nil
            pipe.tracking = false
        }
        isTracking = false
        headingEditing = false
        AppLog.i("地磁", "实时定位停止，修正 \(checks.count) 次")
    }

    /// 长按地图：我现在在这里。走动中长按 = 修正位置，同时记下修正前的误差。
    func setAnchor(_ p: Point2) {
        guard phase == .live else { return }
        let store = MagMapStore.shared
        // 离点位 50 cm 以内就吸附到点位上
        var target = p
        var label = "x \(Int(p.x)) y \(Int(p.y))"
        if let near = store.points.min(by: { $0.position.distance(to: p) < $1.position.distance(to: p) }),
           near.position.distance(to: p) <= 50 {
            target = near.position
            label = "点位 \(near.id)"
        }
        if isTracking, let cur = position {
            let err = cur.distance(to: target)
            checks.append(MagCheck(pointId: label, errorCm: err))
            AppLog.i("地磁", "修正位置到 \(label)：修正前估计 \(cur)，偏差 \(Fmt.f(err, 0)) cm")
            restartTracking(at: target, heading: headingRad, checkLabel: label)
        } else {
            AppLog.i("地磁", "定点：\(label)")
        }
        position = target
        if isTracking { trail.append(target) } else { trail = [target] }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        refreshHint()
    }

    /// 双击地图：开始 / 结束设朝向。结束时如果还没开始推算，就从这里开始。
    func toggleHeadingEdit() {
        guard phase == .live else { return }
        guard let p = position else {
            lastError = "先长按地图，设定你现在的位置"
            return
        }
        lastError = nil
        if !headingEditing {
            headingEditing = true
            AppLog.tap("地磁·设朝向", "开始")
            return
        }
        headingEditing = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let deg = Int((headingRad * 180 / Double.pi).rounded())
        if isTracking {
            let h = headingRad
            queue.async { [pipe] in pipe.fusion?.setHeading(h) }
            AppLog.i("地磁", "重新设朝向：\(deg)°")
        } else {
            restartTracking(at: p, heading: headingRad, checkLabel: nil)
            isTracking = true
            AppLog.i("地磁", "开始推算：起点 \(p)，朝向 \(deg)°")
        }
    }

    /// 设朝向时点 / 拖到的位置：箭头从我的位置指向这里。
    func pointHeading(toward t: Point2) {
        guard headingEditing, let p = position, p.distance(to: t) > 10 else { return }
        headingRad = atan2(t.x - p.x, t.y - p.y)
        refreshHint()
    }

    private func makeFusion(at p: Point2, heading: Double?) -> FusionEngine {
        var cfg = FusionConfig()
        cfg.useCorridorConstraint = false
        cfg.useMagneticHeading = useCompassHeading
        let f = FusionEngine(corridors: [], config: cfg)
        f.setInitialPosition(p, headingRad: heading)
        return f
    }

    /// 在 p 以朝向 heading 重新开始推算（换一个新引擎，步数累加）。
    private func restartTracking(at p: Point2, heading: Double, checkLabel: String?) {
        let fusion = makeFusion(at: p, heading: heading)
        var localizer: MagneticLocalizer?
        if useMagCorrection, let field = MagMapStore.shared.field {
            localizer = MagneticLocalizer(field: field)
            localizer?.reset(start: p, spreadCm: 50)
        }
        queue.sync {
            pipe.stepBase += pipe.lastOut?.stepCount ?? 0
            if !pipe.tracking { pipe.stepBase = 0 }
            pipe.fusion = fusion
            pipe.localizer = localizer
            pipe.lastFusedPos = nil
            pipe.lastOut = nil
            pipe.tracking = true
            if let c = checkLabel { pipe.pendingCheck = c }
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
        case .live:
            pipe.magAccuracy = s.magAccuracy
            guard let fusion = pipe.fusion, let out = fusion.process(sample) else {
                publishLive(pipe: pipe, tMs: s.tMs)
                return
            }
            pipe.lastOut = out
            guard pipe.tracking else {
                publishLive(pipe: pipe, tMs: s.tMs)
                return
            }
            let delta = pipe.lastFusedPos.map { out.position - $0 } ?? .zero
            pipe.lastFusedPos = out.position
            var shown = out.position
            var unc = out.uncertaintyCm
            var est: MagneticEstimate?
            if let loc = pipe.localizer {
                let e = loc.step(delta: delta, feature: feat)
                est = e
                shown = e.position
                unc = e.uncertaintyCm
            }
            let steps = pipe.stepBase + out.stepCount
            if let w = pipe.trackWriter {
                let check = pipe.pendingCheck ?? ""
                pipe.pendingCheck = nil
                w.append([
                    "\(out.tMs)", Fmt.f(shown.x, 1), Fmt.f(shown.y, 1),
                    Fmt.f(unc, 1), Fmt.f(est?.confidence ?? -1, 3),
                    Fmt.f(out.position.x, 1), Fmt.f(out.position.y, 1), Fmt.f(out.headingDeg, 1),
                    "\(steps)",
                    Fmt.f(feat?.total ?? 0, 2), Fmt.f(feat?.vertical ?? 0, 2), Fmt.f(feat?.horizontal ?? 0, 2),
                    Fmt.csv(check),
                ].joined(separator: ","))
            }
            let heading = out.headingRad, acc = pipe.magAccuracy
            Task { @MainActor in
                self.magAccuracy = acc
                self.applyFix(position: shown, uncertainty: unc, heading: heading, steps: steps, feature: feat, estimate: est)
            }
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
            Task { @MainActor in
                self.applyFix(position: est.position, uncertainty: est.uncertaintyCm, heading: heading,
                              steps: steps, feature: feat, estimate: est)
            }
        }
    }

    /// 校准时刷新实时磁场读数，最多 5 Hz。
    private nonisolated func publishLive(pipe: MagPipeline, tMs: Int64) {
        guard tMs - pipe.lastPublishMs >= 200 else { return }
        pipe.lastPublishMs = tMs
        let f = pipe.latest, n = pipe.calSamples.count
        let acc = pipe.magAccuracy, steps = pipe.stepBase + (pipe.lastOut?.stepCount ?? 0)
        let tracking = pipe.tracking
        Task { @MainActor in
            self.feature = f
            if self.phase == .calibrating { self.calSampleCount = n }
            if self.phase == .live {
                self.magAccuracy = acc
                if !tracking { self.stepCount = steps }
            }
        }
    }

    private func applyFix(position p: Point2, uncertainty: Double, heading: Double, steps: Int,
                          feature f: MagneticFeature?, estimate est: MagneticEstimate?) {
        guard phase == .localizing || (phase == .live && isTracking) else { return }
        estimate = est
        uncertaintyCm = uncertainty
        if !headingEditing { headingRad = heading }
        stepCount = steps
        feature = f
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
        if arrived, autoAdvance, phase == .localizing || phase == .live {
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
