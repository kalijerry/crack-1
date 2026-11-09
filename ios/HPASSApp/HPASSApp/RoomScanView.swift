import ARKit
import HPASSKit
import RoomPlan
import SceneKit
import simd
import SwiftUI

/// 家具类别的中文名（RoomPlan 的类别英文名 → 中文）
enum RoomCategory {
    static func label(_ en: String) -> String {
        [
            "bed": "床", "table": "桌子", "sofa": "沙发", "chair": "椅子", "storage": "柜子",
            "television": "电视", "toilet": "马桶", "bathtub": "浴缸", "sink": "水槽",
            "refrigerator": "冰箱", "washerDryer": "洗衣机", "stove": "灶台", "oven": "烤箱",
            "dishwasher": "洗碗机", "fireplace": "壁炉", "stairs": "楼梯",
        ][en] ?? en
    }
}

/// 一张房间地图的目录（地图库里的 `maps/<id>/`，或旧版的 `room-scans/<名字>/`）：读 map.json 里的场馆 / 楼层信息。
struct RoomScanItem: Identifiable {
    let dir: URL
    var id: String { dir.lastPathComponent }
    var mapURL: URL { dir.appendingPathComponent("map.json") }
    var usdzURL: URL { dir.appendingPathComponent("room.usdz") }
    /// map.json 里的场馆 / 楼层信息（老的单房间扫描没有）
    var venueId: String?
    var venueName: String?
    var ordinal: Int?
    var floorName: String?
    var hasGeoRef = false
    var unitCount = 0

    init(dir: URL) {
        self.dir = dir
        if let d = try? Data(contentsOf: dir.appendingPathComponent("map.json")),
           let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            venueId = root["venueId"] as? String
            venueName = root["venueName"] as? String
            ordinal = (root["ordinal"] as? NSNumber)?.intValue
            floorName = root["floorName"] as? String
            hasGeoRef = root["geoRef"] is [String: Any]
            unitCount = (root["units"] as? [Any])?.count ?? 0
        }
    }

    /// 旧版扫描加进地图库时记下的编号
    var libraryId: String? {
        (try? String(contentsOf: dir.appendingPathComponent("library_id.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 扫进哪张地图
enum ScanTarget: Hashable, Identifiable {
    /// 新建一张地图（第一次扫）
    case newMap
    /// 接着扫进已有的地图（扩大范围，或重扫某块精细化）
    case append(String)

    var id: String {
        switch self {
        case .newMap: return "new"
        case .append(let m): return "append-" + m
        }
    }
    var mapId: String? { if case .append(let m) = self { return m }; return nil }

    /// 默认：在用的是房间地图就接着扫它，否则新建
    @MainActor static var preferred: ScanTarget {
        let lib = MapLibrary.shared
        if let a = lib.active, a.isRoom { return .append(a.id) }
        return .newMap
    }
}

/// RoomCaptureView 的代理（协议要求 NSCoding，单独放一个小对象，不和界面状态混在一起）
final class RoomCaptureDelegate: NSObject, RoomCaptureViewDelegate {
    var onResult: ((CapturedRoom, Error?) -> Void)?

    override init() { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        onResult?(processedResult, error)
    }
}

/// 接着扫之前「认出已扫区域」：载入地图的视觉特征地图，ARKit 经过「重定位中」又恢复正常、并且位姿连续 1 秒
/// 没有跳变才算认稳（ARKit 刚认出时可能先给一个错的匹配，零点几秒后再跳到对的位置）。回调都在 ARKit 的队列上，
/// 结果切回主线程。
final class ScanRelocalizer: NSObject, ARSessionDelegate {
    /// 认稳了
    var onConfirmed: (() -> Void)?
    /// 跟踪状态的提示文字
    var onHint: ((String) -> Void)?

    private var sawRelocalizing = false
    private var pending = false
    private var confirmed = false
    private var stable = 0
    private var frames = 0
    private var last: SIMD3<Float>?
    /// 30 Hz 下连续这么多帧没有跳变
    static let stableNeeded = 30
    /// 相邻两帧跳这么远（米）= ARKit 又校正了一次坐标系
    static let jumpM: Float = 0.5

    func reset() {
        sawRelocalizing = false; pending = false; confirmed = false; stable = 0; frames = 0; last = nil
    }

    private func hint(_ s: String) {
        let cb = onHint
        DispatchQueue.main.async { cb?(s) }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .limited(.relocalizing):
            sawRelocalizing = true
            hint("正在找已扫过的地方：对着墙角、门窗、家具慢慢转")
        case .limited(.initializing):
            hint("正在启动相机……")
        case .limited(.excessiveMotion):
            hint("转得太快了，慢一点")
        case .limited(.insufficientFeatures):
            hint("画面里能认的东西太少：对着家具、门窗多的方向；太暗就开灯")
        case .normal:
            if sawRelocalizing && !confirmed {
                pending = true
                stable = 0
                hint("认出来了，正在确认，拿稳别动……")
            }
        case .notAvailable:
            hint("相机跟踪不可用")
        default:
            break
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frames += 1
        guard frames % 2 == 0, pending else { return }            // 60 Hz → 30 Hz
        guard case .normal = frame.camera.trackingState else { last = nil; stable = 0; return }
        let m = frame.camera.transform
        let p = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        if let l = last, simd_distance(p, l) > Self.jumpM { stable = 0 }
        last = p
        stable += 1
        if stable >= Self.stableNeeded {
            pending = false
            confirmed = true
            let cb = onConfirmed
            DispatchQueue.main.async { cb?() }
        }
    }
}

/// 房间扫描：用 Apple RoomPlan（激光雷达）扫出墙、门、窗、家具，生成 2D / 3D 地图。
///
/// 一张地图可以分几次扫（扫描段，见 `MapScans.swift` 和 docs/scan-and-map-management.md）：
/// - **新建地图**：第一段，它的 AR 坐标系就是地图的坐标系；
/// - **接着扫**（扩大范围 / 重扫精细化）：iOS 17 先载入地图的视觉特征地图，在已扫过的地方认出位置，
///   用户走到新房间门口再点「开始扫」，RoomPlan 在同一个 AR 会话里扫，结果直接落在地图坐标里；
///   认不出（或 iOS 16、没有特征地图）就照常扫，扫完按墙和门自动对齐，对不上手动两点对齐。
///   每段扫完都进合并预览，用户确认后才合进地图。
///
/// iOS 17 起可以在同一个 AR 会话里连续扫多个房间（每扫完一个先不停 AR），最后用 `StructureBuilder`
/// 拼成一个 `CapturedStructure`，每个房间是一个单元；iOS 16 只能一次扫一个房间。
/// 扫描时可以在入口记一次 GPS + 朝向（算 geoRef），气压计跟踪楼层序号；扫完后点选房间填类别和名字，
/// 一个场馆的多层扫描能导出成 IMDF。操作说明见 docs/roomplan-imdf-authoring.md。
@MainActor
final class RoomScanModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// 接着扫：正在认出已扫区域
        case relocalizing
        /// 接着扫：认出了（或决定先扫后对齐），等用户走到新地方点「开始扫」
        case readyToScan
        case scanning, processingRoom, betweenRooms, building
        /// 接着扫的一段扫完，等用户在合并预览里确认
        case merging
        case done
        case failed(String)
    }

    @Published var target: ScanTarget
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: StoreMap?
    /// 扫完 / 合并后的地图编号
    @Published private(set) var resultMapId: String?
    @Published private(set) var summary = ""
    /// 旧版扫描记录（Documents/room-scans）
    @Published private(set) var items: [RoomScanItem] = []
    @Published private(set) var roomCount = 0
    @Published private(set) var entrance: RoomMapBuilder.GeoAnchor?
    @Published private(set) var entranceMessage: String?
    var name = ""

    /// RoomPlan 的界面（每次开始扫新建一个：接着扫时挂在自建的 AR 会话上）
    @Published private(set) var captureView: RoomCaptureView?
    /// 接着扫时自建的 AR 会话（认出已扫区域期间显示相机画面）
    @Published private(set) var arSession: ARSession?
    @Published private(set) var relocStarted: Date?
    @Published private(set) var relocHint: String?
    /// 认出 / 没认出之后给用户的下一步提示
    @Published private(set) var guidance: String?
    /// 这一段和地图同一个 AR 坐标系（视觉认出、RoomPlan 也没有重置坐标系）
    @Published private(set) var inBaseFrame = false
    /// 接着扫时载入的特征地图的生成时间（合并时判断段里的特征地图能不能顶替在用的）
    private var relocSourceMs: Int64?
    /// 等合并的一段
    @Published var pendingMerge: PendingMerge?
    @Published private(set) var mergeError: String?
    /// 接着扫的目标地图的基准 AR 对齐（合并预览「改回视觉认出的位置」用）
    private(set) var targetFrameAlign: MapARTransform?

    let geo = GeoCapture()
    let floors = FloorTracker()

    private let delegate = RoomCaptureDelegate()
    private let relocalizer = ScanRelocalizer()
    private let relocQueue = DispatchQueue(label: "scan.relocalize", qos: .userInitiated)
    private var relocTimer: Timer?
    private var continuityTimer: Timer?
    private var continuityLast: SIMD3<Float>?
    private var continuityTicks = 0
    private var rooms: [CapturedRoom] = []
    private var pendingWorldMap: Data?
    private var mappingWarned = false

    static var isSupported: Bool { RoomCaptureSession.isSupported }
    /// iOS 17 起能连续扫多个房间（StructureBuilder），也能把 RoomPlan 挂在自建的 AR 会话上（接着扫时视觉认出）
    static var supportsMultiRoom: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    /// 旧版扫描结果的目录（新的扫描直接存进地图库的 maps/<id>/scans/）
    static var rootURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("room-scans", isDirectory: true)
    }

    /// - Parameter target: nil = 在用的是房间地图就接着扫它，否则新建
    init(target: ScanTarget?) {
        self.target = target ?? .preferred
        refresh()
        delegate.onResult = { [weak self] room, error in
            Task { @MainActor in self?.handle(room, error: error) }
        }
        relocalizer.onConfirmed = { [weak self] in Task { @MainActor in self?.relocalized() } }
        relocalizer.onHint = { [weak self] h in Task { @MainActor in self?.relocHint = h } }
    }

    func refresh() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.rootURL, includingPropertiesForKeys: nil)) ?? []
        items = dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("map.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { RoomScanItem(dir: $0) }
    }

    /// 页面打开时：GPS / 朝向 / 气压计开始跑（楼层要在走动中一直跟踪）
    func appear() {
        geo.start()
        floors.start()
    }

    func disappear() {
        if phase == .idle || phase == .done { geo.stop() }
    }

    var targetName: String? {
        target.mapId.flatMap { id in MapLibrary.shared.entries.first { $0.id == id }?.name }
    }

    /// 接着扫的目标地图（认房间时显示已扫范围）
    var targetMapJSON: Data? {
        target.mapId.flatMap { try? Data(contentsOf: MapLibrary.shared.mapURL($0)) }
    }

    // MARK: 开始

    func start() {
        guard Self.isSupported else { phase = .failed("这台设备不支持房间扫描（需要激光雷达）"); return }
        if let id = target.mapId, !MapLibrary.shared.entries.contains(where: { $0.id == id }) {
            phase = .failed("找不到要接着扫的地图（可能已经删除了）")
            return
        }
        SensorArbiter.shared.claim("房间扫描") { [weak self] in self?.cancel() }
        result = nil
        resultMapId = nil
        rooms = []
        roomCount = 0
        entrance = nil
        entranceMessage = nil
        pendingWorldMap = nil
        pendingMerge = nil
        mergeError = nil
        mappingWarned = false
        inBaseFrame = false
        relocSourceMs = nil
        guidance = nil
        relocHint = nil
        targetFrameAlign = nil
        geo.start()
        guard let id = target.mapId else {
            AppLog.i("房间扫描", "新建地图：开始扫描（楼层 \(floors.ordinal)）")
            beginCapture()
            return
        }
        let lib = MapLibrary.shared
        targetFrameAlign = (try? lib.registry(id))?.frameAlign?.transform
        if #available(iOS 17.0, *), let src = lib.relocalizationSource(id), let wm = ARKitLogger.loadWorldMap(src.url) {
            relocSourceMs = src.createdMs
            startRelocalization(wm)
            return
        }
        guidance = (Self.supportsMultiRoom ? "这张地图没有视觉特征地图，认不出已扫过的地方。"
                                           : "这台手机是 iOS 16，不能靠画面认出已扫过的地方。")
            + "照常扫，扫完后按墙和门自动对齐。所以请先把门口、走廊这些已经扫过的地方再扫一小段，再扫新的地方。"
        phase = .readyToScan
        AppLog.i("房间扫描", "接着扫「\(targetName ?? id)」：不能视觉认出，扫完后几何对齐")
    }

    @available(iOS 17.0, *)
    private func startRelocalization(_ wm: ARWorldMap) {
        let s = ARSession()
        relocalizer.reset()
        s.delegate = relocalizer
        s.delegateQueue = relocQueue
        let cfg = ARWorldTrackingConfiguration()
        cfg.worldAlignment = .gravity                 // 和保存特征地图时一样，否则认不出
        cfg.planeDetection = [.horizontal]
        cfg.initialWorldMap = wm
        s.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        arSession = s
        relocStarted = Date()
        relocHint = "正在启动相机……"
        phase = .relocalizing
        relocTimer?.invalidate()
        relocTimer = Timer.scheduledTimer(withTimeInterval: WorldMapPolicy.relocalizeTimeoutSec, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.giveUpRelocalization(timedOut: true) }
        }
        AppLog.i("房间扫描", "接着扫「\(targetName ?? "")」：载入特征地图，等认出已扫区域")
    }

    private func relocalized() {
        guard phase == .relocalizing else { return }
        relocTimer?.invalidate()
        inBaseFrame = true
        phase = .readyToScan
        guidance = "已认出！现在走到还没扫过的房间（或者要重扫的地方）门口，再点「开始扫」。走过去时手机照常举着，不会丢位置。"
        Haptics.success()
        let sec = relocStarted.map { Int(Date().timeIntervalSince($0)) } ?? 0
        AppLog.i("房间扫描", "认出了已扫区域（\(sec) 秒），等用户走到新地方开始扫")
    }

    /// 认不出（超时或用户不想等）：不用特征地图，照常扫，扫完后按墙和门对齐
    func giveUpRelocalization(timedOut: Bool) {
        guard phase == .relocalizing else { return }
        relocTimer?.invalidate()
        arSession?.pause()
        arSession = nil
        inBaseFrame = false
        phase = .readyToScan
        guidance = (timedOut ? "\(Int(WorldMapPolicy.relocalizeTimeoutSec)) 秒还没认出来（光线太暗、房间变动大、或者站的地方没扫过）。" : "")
            + "照常扫，扫完后按墙和门自动对齐（对不上可以手动点两个对应点）。请先把门口、走廊这些已经扫过的地方再扫一小段，再扫新的地方。"
        AppLog.w("房间扫描", timedOut ? "超时没认出已扫区域，改为扫完后几何对齐" : "用户选择先扫、后对齐")
    }

    /// 开始让 RoomPlan 扫（新建：直接开始；接着扫：认出之后用户走到新地方再点）
    func beginCapture() {
        let v: RoomCaptureView
        if #available(iOS 17.0, *), inBaseFrame, let s = arSession {
            // 交给 RoomPlan：同一个 AR 会话、同一个坐标系
            s.delegate = nil
            let before = s.currentFrame?.camera.transform
            v = RoomCaptureView(frame: .zero, arSession: s)
            v.delegate = delegate
            captureView = v
            v.captureSession.run(configuration: RoomCaptureSession.Configuration())
            watchContinuity(before: before)
        } else {
            arSession?.pause()
            arSession = nil
            inBaseFrame = false
            v = RoomCaptureView(frame: .zero)
            v.delegate = delegate
            captureView = v
            v.captureSession.run(configuration: RoomCaptureSession.Configuration())
        }
        phase = .scanning
    }

    /// RoomPlan 第一次在认出了位置的会话上开始扫：看坐标系是不是被它重置了（位姿跳变、回到「启动中」）。
    /// 被重置了这一段就不算在地图坐标系里，扫完改用几何对齐，不会把错位的几何合进去。
    private func watchContinuity(before: simd_float4x4?) {
        continuityLast = before.map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        continuityTicks = 0
        continuityTimer?.invalidate()
        continuityTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.continuityTick() }
        }
    }

    private func continuityTick() {
        guard inBaseFrame, let s = captureView?.captureSession.arSession else { stopContinuity(); return }
        continuityTicks += 1
        if let f = s.currentFrame {
            var reset = false
            switch f.camera.trackingState {
            case .limited(.initializing), .notAvailable: reset = true
            default: break
            }
            let m = f.camera.transform
            let p = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            if let l = continuityLast, simd_distance(p, l) > ScanRelocalizer.jumpM { reset = true }
            continuityLast = p
            if reset {
                inBaseFrame = false
                entranceMessage = "扫描重新开始了坐标系：这一段扫完后改用墙和门自动对齐。请把一些已经扫过的地方（门口、走廊）也扫进来。"
                AppLog.w("房间扫描", "RoomPlan 开始时坐标系跳了，这一段改为几何对齐")
                stopContinuity()
                return
            }
        }
        if continuityTicks >= 30 { stopContinuity() }
    }

    private func stopContinuity() {
        continuityTimer?.invalidate()
        continuityTimer = nil
    }

    /// 当前这个房间扫完：iOS 17 先不停 AR（下一个房间接着在同一个坐标系里扫），iOS 16 直接结束
    func finishRoom() {
        guard phase == .scanning, let v = captureView else { return }
        phase = .processingRoom
        if #available(iOS 17.0, *) {
            v.captureSession.stop(pauseARSession: false)
        } else {
            // 先存视觉特征地图（定位时用来认出这个房间），再停扫描
            captureWorldMap { v.captureSession.stop() }
        }
    }

    /// 接着扫下一个房间 / 走廊（iOS 17）
    func nextRoom() {
        guard phase == .betweenRooms, let v = captureView else { return }
        v.captureSession.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
    }

    /// 这一段全部扫完：存视觉特征地图、停 AR，把各个房间拼起来
    func finishAll() {
        guard phase == .betweenRooms, !rooms.isEmpty, let v = captureView else { return }
        // 特征地图不够（下次接着扫要靠它认出这里）：提醒一次再转一圈
        if !mappingWarned, let f = v.captureSession.arSession.currentFrame,
           !(f.worldMappingStatus == .mapped || f.worldMappingStatus == .extending) {
            mappingWarned = true
            entranceMessage = "画面特征还不够（下次接着扫要靠它认出这里）：举着手机对着刚扫的地方慢慢转一圈，再点「这段扫完」。"
            return
        }
        phase = .building
        stopContinuity()
        captureWorldMap { [weak self] in
            guard let self else { return }
            v.captureSession.arSession.pause()
            Task { await self.finalize() }
        }
    }

    private func captureWorldMap(then: @escaping () -> Void) {
        pendingWorldMap = nil
        guard let v = captureView else { then(); return }
        v.captureSession.arSession.getCurrentWorldMap { [weak self] map, err in
            let data = map.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
            Task { @MainActor in
                guard let self else { return }
                self.pendingWorldMap = data
                if data == nil { AppLog.w("房间扫描", "没拿到视觉特征地图：\(err?.localizedDescription ?? "未知原因")，视觉定位 / 接着扫认位置不可用") }
                then()
            }
        }
    }

    func cancel() {
        relocTimer?.invalidate()
        stopContinuity()
        switch phase {
        case .scanning, .processingRoom: captureView?.captureSession.stop()
        case .betweenRooms, .building: captureView?.captureSession.arSession.pause()
        default: break
        }
        arSession?.pause()
        arSession = nil
        captureView = nil
        rooms = []
        roomCount = 0
        phase = .idle
        SensorArbiter.shared.release("房间扫描")
    }

    /// 在入口记一次 GPS + 朝向：手机竖着拿、摄像头对着要走进去的方向（或平放、顶部朝前）
    func markEntrance() {
        guard let frame = captureView?.captureSession.arSession.currentFrame else {
            entranceMessage = "AR 还没准备好，等画面稳定再点"
            return
        }
        guard let loc = geo.location, loc.horizontalAccuracy >= 0 else {
            entranceMessage = "还没有 GPS 定位：到门口、离窗近一点，等几秒再点"
            return
        }
        guard let heading = geo.headingDeg else {
            entranceMessage = "还没有朝向：手机画个 8 字校准指南针再点"
            return
        }
        let t = frame.camera.transform
        let fwd = -t.columns.2, top = -t.columns.0
        // 竖着拿：用摄像头朝向；平放：用手机顶部朝向（和 CLHeading 的参考方向一致）
        let dir = abs(fwd.y) < 0.8 ? fwd : top
        entrance = RoomMapBuilder.GeoAnchor(
            arPosition: Point2(Double(t.columns.3.x), Double(t.columns.3.z)),
            arYaw: atan2(Double(dir.z), Double(dir.x)),
            lon: loc.coordinate.longitude, lat: loc.coordinate.latitude,
            trueHeadingDeg: heading, accuracyM: loc.horizontalAccuracy)
        entranceMessage = "已记录入口：GPS ±\(Fmt.f(loc.horizontalAccuracy, 0)) m，朝向 \(Fmt.f(heading, 0))°"
            + (loc.horizontalAccuracy > 15 ? "。精度较差，之后可在网页编辑器两点对准修正" : "")
        AppLog.i("房间扫描", entranceMessage ?? "")
    }

    private func handle(_ room: CapturedRoom, error: Error?) {
        if let error {
            if !rooms.isEmpty, Self.supportsMultiRoom {
                // 多房间时这一个处理失败：前面的还在，可以重扫这一个或者直接结束
                phase = .betweenRooms
                entranceMessage = "这个房间处理失败：\(error.localizedDescription)，可以再扫一次"
                AppLog.w("房间扫描", "第 \(rooms.count + 1) 个房间处理失败：\(error.localizedDescription)")
                return
            }
            SensorArbiter.shared.release("房间扫描")
            phase = .failed("处理失败：\(error.localizedDescription)")
            AppLog.e("房间扫描", "处理失败：\(error.localizedDescription)")
            return
        }
        rooms.append(room)
        roomCount = rooms.count
        if Self.supportsMultiRoom {
            phase = .betweenRooms
            AppLog.i("房间扫描", "第 \(rooms.count) 个房间扫完")
        } else {
            phase = .building
            Task { await finalize() }
        }
    }

    // MARK: 生成这一段、入库

    private func finalize() async {
        defer { SensorArbiter.shared.release("房间扫描") }
        do {
            var input: RoomMapBuilder.Input
            var export: (URL) throws -> Void
            var rawJSON: Data?
            if #available(iOS 17.0, *) {
                do {
                    let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                    input = Self.input(from: structure)
                    export = { try structure.export(to: $0) }
                    rawJSON = try? JSONEncoder().encode(structure.rooms)
                } catch {
                    // 拼接失败（房间之间没对上）：同一个 AR 会话里坐标系本来就一致，直接合在一起
                    AppLog.w("房间扫描", "StructureBuilder 失败：\(error.localizedDescription)，直接合并 \(rooms.count) 个房间")
                    input = Self.input(merging: rooms)
                    let first = rooms[0]
                    export = { try first.export(to: $0) }
                    rawJSON = try? JSONEncoder().encode(rooms)
                }
            } else {
                input = Self.input(from: rooms[0])
                let first = rooms[0]
                export = { try first.export(to: $0) }
                rawJSON = try? JSONEncoder().encode(first)
            }
            input.ordinal = floors.ordinal
            input.venueId = VenueSettings.id
            input.venueName = VenueSettings.name
            input.geoAnchor = entrance

            let lib = MapLibrary.shared
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd_HHmmss"
            let stamp = df.string(from: Date())
            let scanId = "s\(stamp)"
            let now = Fmt.nowMs()
            let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            let roomN = max(input.rooms.count, 1)
            let typed = name.trimmingCharacters(in: .whitespaces)

            /// 这一段的文件：map.json、原始 captured_room.json、USDZ、这一段结束时的特征地图 + 说明
            func writeScan(_ dir: URL, json: Data, map: StoreMap, frameId: String) throws {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try json.write(to: dir.appendingPathComponent("map.json"), options: .atomic)
                try? export(dir.appendingPathComponent("room.usdz"))
                if let raw = rawJSON { try? raw.write(to: dir.appendingPathComponent("captured_room.json")) }
                if let wm = pendingWorldMap {
                    try? wm.write(to: dir.appendingPathComponent(MapLibrary.worldMapFile))
                    WorldMapKeeper.noteScanned(dir: dir, align: map.arAlign, bytes: wm.count, frameId: frameId)
                }
            }

            let furniture = Dictionary(grouping: input.objects, by: \.category)
                .map { "\(RoomCategory.label($0.key)) \($0.value.count)" }.sorted().joined(separator: "、")
            let scanSummary = "这一段：房间 \(roomN) 个、墙 \(input.walls.count) 面、门 \(input.doors.count)、窗 \(input.windows.count)；"
                + "家具：\(furniture.isEmpty ? "无" : furniture)；楼层 \(floors.ordinal)；"
                + (entrance != nil ? "有地理坐标；" : "")
                + (pendingWorldMap != nil ? "存了视觉特征地图" : "没有视觉特征地图（视觉定位 / 下次认位置不可用）")

            switch target {
            case .newMap:
                let title = typed.isEmpty ? "\(floors.ordinal)F \(stamp)" : typed
                let id = lib.newMapId(kind: "room")
                let fid = UUID().uuidString
                let (json, map) = try RoomMapBuilder.build(input, name: title, frameId: fid, geometryVersion: now)
                try writeScan(lib.scanDir(id, scanId), json: json, map: map, frameId: fid)
                try lib.createFromScan(mapId: id, name: title, scanId: scanId, frameId: fid, osMajor: osMajor, roomCount: roomN)
                finished(mapId: id, note: scanSummary)
                AppLog.i("房间扫描", "新建地图「\(title)」：\(scanSummary)")
            case .append(let id):
                let reg = try lib.registry(id)
                let fid = inBaseFrame ? reg.frameId : UUID().uuidString
                let (json, map) = try RoomMapBuilder.build(input, name: typed.isEmpty ? "扫描段" : typed, frameId: fid, geometryVersion: now)
                try writeScan(lib.scanDir(id, scanId), json: json, map: map, frameId: fid)
                let existing = try Data(contentsOf: lib.mapURL(id))
                pendingMerge = PendingMerge.prepare(
                    mapId: id, mapName: targetName ?? id, scanId: scanId, scanName: typed.isEmpty ? nil : typed,
                    scanJSON: json, existingJSON: existing, frameAlign: reg.frameAlign?.transform,
                    relocalized: inBaseFrame, osMajor: osMajor, roomCount: roomN, relocSourceMs: relocSourceMs)
                summary = scanSummary
                rooms = []
                captureView = nil
                arSession = nil
                phase = .merging
                AppLog.i("房间扫描", "接着扫「\(targetName ?? id)」的一段扫完（\(inBaseFrame ? "视觉认出" : "待几何对齐")）：\(scanSummary)")
            }
        } catch {
            phase = .failed("生成地图失败：\(error)")
            AppLog.e("房间扫描", "生成地图失败：\(error)")
        }
    }

    private func finished(mapId id: String, note: String) {
        let lib = MapLibrary.shared
        resultMapId = id
        result = (try? Data(contentsOf: lib.mapURL(id))).flatMap { try? StoreDataLoader.loadMap($0) }
        if let m = result {
            let area = WalkableMap(floor: m.floor, obstacles: m.physicalShelves, widthCm: m.width, heightCm: m.height).walkableAreaM2
            summary = note + "。整张地图：\(Fmt.f(m.width / 100, 1)) × \(Fmt.f(m.height / 100, 1)) m，可走 \(Fmt.f(area, 1)) m²。"
                + "已切换到这张地图：到「建图」采集、到「导航」定位。"
        } else {
            summary = note
        }
        rooms = []
        captureView = nil
        arSession = nil
        name = ""
        target = .append(id)            // 下一次默认接着扫这张
        phase = .done
    }

    // MARK: 合并预览的操作

    func confirmMerge() {
        guard let m = pendingMerge else { return }
        do {
            try MapLibrary.shared.commitScan(m.mapId, record: m.record, relocSourceMs: m.relocSourceMs)
            Haptics.success()
            pendingMerge = nil
            mergeError = nil
            finished(mapId: m.mapId, note: summary + "；已合并（\(m.mode == .replace ? "替换这块" : "追加补充")）")
        } catch {
            mergeError = "合并失败：\(error.localizedDescription)"
            AppLog.e("房间扫描", mergeError ?? "")
        }
    }

    func discardMerge() {
        guard let m = pendingMerge else { return }
        MapLibrary.shared.discardScan(m.mapId, m.scanId)
        pendingMerge = nil
        phase = .idle
        AppLog.w("房间扫描", "放弃了这一段扫描（\(m.scanId)）")
    }

    func saveMergeAsNewMap(name: String) {
        guard let m = pendingMerge else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        do {
            let e = try MapLibrary.shared.detachScanAsNewMap(from: m.mapId, scanId: m.scanId, name: n.isEmpty ? "新地图" : n)
            pendingMerge = nil
            finished(mapId: e.id, note: summary + "；另存为新地图「\(e.name)」")
        } catch {
            mergeError = "另存失败：\(error.localizedDescription)"
        }
    }

    // MARK: 旧版扫描记录（Documents/room-scans）

    @Published private(set) var libraryMessage: String?

    /// 旧版扫描加进地图库（已经在库里就只切换；库里那张删掉了就重新加入）
    func addToLibrary(_ it: RoomScanItem) {
        let lib = MapLibrary.shared
        do {
            if let id = it.libraryId, lib.entries.contains(where: { $0.id == id }) {
                try lib.activate(id)
            } else {
                let d = try Data(contentsOf: it.mapURL)
                let n = (try? StoreDataLoader.loadMap(d))?.floorName ?? it.id
                let wm = it.dir.appendingPathComponent(MapLibrary.worldMapFile)
                let side = it.dir.appendingPathComponent(WorldMapSidecar.fileName)
                let extra = FileManager.default.fileExists(atPath: wm.path)
                    ? [wm] + (FileManager.default.fileExists(atPath: side.path) ? [side] : []) : []
                let e = try lib.importAndActivate(data: d, name: n, kind: "room", extraFiles: extra)
                try? Data(e.id.utf8).write(to: it.dir.appendingPathComponent("library_id.txt"))
            }
            libraryMessage = "已加入地图库并切换到这里。"
        } catch {
            libraryMessage = "加入地图库失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func delete(_ it: RoomScanItem) {
        try? FileManager.default.removeItem(at: it.dir)
        refresh()
    }

    @Published private(set) var exportURL: URL?
    @Published private(set) var exportMessage: String?
    /// 上面两个是哪个场馆的
    @Published private(set) var exportVenueId: String?

    /// 一个场馆（venueId）的全部房间地图 → IMDF 压缩包
    func exportVenue(_ venueId: String, items its: [RoomScanItem]) {
        exportVenueId = venueId
        let missing = its.filter { !$0.hasGeoRef }.map { $0.floorName ?? $0.id }
        guard missing.isEmpty else {
            exportURL = nil
            exportMessage = "这几张地图没有地理坐标：\(missing.joined(separator: "、"))。用网页编辑器两点对准补上 geoRef 后再导入，或扫描时在入口记录位置。"
            return
        }
        let name = its.compactMap(\.venueName).first ?? VenueSettings.name
        do {
            exportURL = try VenueExporter.export(items: its, venueName: name, category: VenueSettings.category)
            let levels = Set(its.compactMap(\.ordinal)).count
            exportMessage = "已导出 \(name)：\(levels) 层，\(its.count) 张地图"
            AppLog.i("房间扫描", exportMessage ?? "")
        } catch {
            exportURL = nil
            exportMessage = "导出失败：\(error)"
        }
    }

    // MARK: RoomPlan → 平面数据

    static func item(_ cat: String, _ t: simd_float4x4, _ d: simd_float3) -> RoomMapBuilder.Item {
        let c: simd_float4 = t.columns.3
        let x: simd_float4 = t.columns.0
        let center = Point2(Double(c.x), Double(c.z))
        let yaw: Double = atan2(Double(x.z), Double(x.x))
        let w = Double(d.x), dep = Double(d.z), h = Double(d.y)
        return RoomMapBuilder.Item(category: cat, center: center, width: w, depth: dep, height: h, yaw: yaw)
    }

    static func fill(_ inp: inout RoomMapBuilder.Input, walls: [CapturedRoom.Surface], doors: [CapturedRoom.Surface],
                     windows: [CapturedRoom.Surface], openings: [CapturedRoom.Surface], objects: [CapturedRoom.Object]) {
        inp.walls += walls.map { item("wall", $0.transform, $0.dimensions) }
        inp.doors += doors.map { item("door", $0.transform, $0.dimensions) }
        inp.windows += windows.map { item("window", $0.transform, $0.dimensions) }
        inp.openings += openings.map { item("opening", $0.transform, $0.dimensions) }
        inp.objects += objects.map { item(String(describing: $0.category), $0.transform, $0.dimensions) }
    }

    /// 单房间（iOS 16 的路径）
    static func input(from room: CapturedRoom) -> RoomMapBuilder.Input {
        var inp = RoomMapBuilder.Input()
        fill(&inp, walls: room.walls, doors: room.doors, windows: room.windows, openings: room.openings, objects: room.objects)
        if #available(iOS 17.0, *) {
            inp.floors = room.floors.map(floorPolygon).filter { $0.count >= 3 }
        }
        return inp
    }

    /// 多房间拼好的结构：墙门窗家具取整体的，每个房间一个单元
    @available(iOS 17.0, *)
    static func input(from s: CapturedStructure) -> RoomMapBuilder.Input {
        var inp = RoomMapBuilder.Input()
        fill(&inp, walls: s.walls, doors: s.doors, windows: s.windows, openings: s.openings, objects: s.objects)
        inp.rooms = units(s.rooms)
        if inp.rooms.isEmpty { inp.floors = s.floors.map(floorPolygon).filter { $0.count >= 3 } }
        return inp
    }

    /// StructureBuilder 失败时：同一个 AR 会话里的房间坐标系一致，直接合并
    @available(iOS 17.0, *)
    static func input(merging rooms: [CapturedRoom]) -> RoomMapBuilder.Input {
        var inp = RoomMapBuilder.Input()
        for r in rooms {
            fill(&inp, walls: r.walls, doors: r.doors, windows: r.windows, openings: r.openings, objects: r.objects)
        }
        inp.rooms = units(rooms)
        return inp
    }

    /// 每个房间一个单元（几何规则在核心库 `RoomMapBuilder.roomUnit`：地面取最大的那块，没有地面用墙端点凸包，
    /// 类别按 RoomPlan 的房间类型建议）
    @available(iOS 17.0, *)
    static func units(_ rooms: [CapturedRoom]) -> [RoomMapBuilder.Room] {
        rooms.enumerated().compactMap { i, r in
            RoomMapBuilder.roomUnit(
                floors: r.floors.map(floorPolygon),
                walls: r.walls.map { item("wall", $0.transform, $0.dimensions) },
                sectionLabel: r.sections.first.map { String(describing: $0.label) },
                hasStairs: r.objects.contains { String(describing: $0.category) == "stairs" },
                index: i)
        }
    }

    @available(iOS 17.0, *)
    static func floorPolygon(_ f: CapturedRoom.Surface) -> [Point2] {
        f.polygonCorners.map { (pc: simd_float3) -> Point2 in
            let local = simd_float4(pc.x, pc.y, pc.z, 1)
            let w: simd_float4 = f.transform * local
            return Point2(Double(w.x), Double(w.z))
        }
    }
}

/// RoomPlan 自带的扫描界面（实时显示扫到的墙和家具，扫完显示 3D 结果）
struct RoomCaptureContainer: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ v: RoomCaptureView, context: Context) {}
}

/// 认出已扫区域期间的相机画面
struct ARCameraView: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        v.scene = SCNScene()
        v.rendersCameraGrain = false
        return v
    }
    func updateUIView(_ v: ARSCNView, context: Context) {
        if v.session !== session { v.session = session }
    }
}

struct RoomScanView: View {
    @StateObject private var model: RoomScanModel
    @ObservedObject private var lib = MapLibrary.shared
    @StateObject private var model3D = Store3DModel()
    @State private var show3D = false
    @AppStorage(VenueSettings.nameKey) private var venueName = ""
    @AppStorage(VenueSettings.categoryKey) private var venueCategory = "businesscampus"
    @State private var newVenueName = ""
    @State private var showNewVenue = false
    @State private var confirmLegacyDelete: RoomScanItem?

    /// - Parameter target: 扫进哪张地图；nil = 在用的是房间地图就接着扫它，否则新建
    init(target: ScanTarget? = nil) {
        _model = StateObject(wrappedValue: RoomScanModel(target: target))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .relocalizing, .readyToScan, .scanning, .processingRoom, .betweenRooms, .building:
                    scanning
                case .merging:
                    ScanMergeView(model: model)
                default:
                    list
                }
            }
            .navigationTitle("房间扫描")
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    // MARK: 扫描中

    private var scanning: some View {
        ZStack(alignment: .bottom) {
            if let v = model.captureView {
                RoomCaptureContainer(view: v).id(ObjectIdentifier(v)).ignoresSafeArea()
            } else if let s = model.arSession {
                ARCameraView(session: s).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            VStack(spacing: 8) {
                ScanStatusBar(model: model, floors: model.floors)
                switch model.phase {
                case .relocalizing:
                    relocalizingPanel
                case .readyToScan:
                    readyPanel
                case .processingRoom, .building:
                    HStack { ProgressView(); Text(model.phase == .building ? "正在拼接、生成地图……" : "正在处理这个房间……") }
                        .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                case .betweenRooms:
                    Text("已扫 \(model.roomCount) 个房间。走到下一个房间 / 走廊门口，点「扫下一个」；这一段扫完点「这段扫完」。")
                        .font(.footnote).padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("取消", role: .cancel) { model.cancel() }.buttonStyle(.bordered)
                        Button("记录入口") { model.markEntrance() }.buttonStyle(.bordered)
                        Button("扫下一个") { model.nextRoom() }.buttonStyle(.bordered)
                        Button("这段扫完") { model.finishAll() }.buttonStyle(.borderedProminent)
                    }
                default:
                    Text(RoomScanModel.supportsMultiRoom
                         ? "慢慢绕房间走一圈，扫过每面墙、门窗和家具。一个房间扫完点「这间扫完」，再接着扫下一个。在入口处点「记录入口」记下 GPS 和朝向。"
                         : "慢慢绕房间走一圈：摄像头扫过每一面墙、门窗和家具。在入口处点「记录入口」记下 GPS 和朝向。")
                        .font(.footnote).padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("取消", role: .cancel) { model.cancel() }.buttonStyle(.bordered)
                        Button("记录入口") { model.markEntrance() }.buttonStyle(.bordered)
                        Button(RoomScanModel.supportsMultiRoom ? "这间扫完" : "扫完了") { model.finishRoom() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
        }
    }

    /// 认出已扫区域：怎么做、进度、已扫范围
    private var relocalizingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("第 1 步：先认出已经扫过的地方").font(.callout.weight(.semibold))
            Text("站在上次扫过的房间里（门口或墙角附近），举起手机对着墙角、门窗、家具慢慢转一圈。认出来之前先别走进新房间。")
                .font(.footnote)
            if let json = model.targetMapJSON {
                ScanPlanCanvas(layers: [ScanPlanCanvas.Layer(json: json, color: .gray)])
                    .frame(height: 110)
                    .accessibilityLabel("已经扫过的范围")
            }
            if let start = model.relocStarted {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let sec = min(max(0, ctx.date.timeIntervalSince(start)), WorldMapPolicy.relocalizeTimeoutSec)
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: sec, total: WorldMapPolicy.relocalizeTimeoutSec)
                        Text("正在认出已扫过的地方…… \(Int(sec)) / \(Int(WorldMapPolicy.relocalizeTimeoutSec)) 秒")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let h = model.relocHint { Text(h).font(.caption) }
            HStack {
                Button("取消", role: .cancel) { model.cancel() }.buttonStyle(.bordered)
                Spacer()
                Button("认不出，先扫后对齐") { model.giveUpRelocalization(timedOut: false) }.buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// 认出了（或决定先扫后对齐）：走到新地方再开始
    private var readyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.inBaseFrame ? "第 2 步：走到新地方，再开始扫" : "照常扫，扫完后自动对齐",
                  systemImage: model.inBaseFrame ? "checkmark.seal.fill" : "ruler")
                .font(.callout.weight(.semibold))
                .foregroundStyle(model.inBaseFrame ? Color.green : Color.orange)
            if let g = model.guidance { Text(g).font(.footnote) }
            HStack {
                Button("取消", role: .cancel) { model.cancel() }.buttonStyle(.bordered)
                Spacer()
                Button {
                    model.beginCapture()
                } label: {
                    Label("开始扫", systemImage: "viewfinder").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 列表

    struct VenueGroup: Identifiable {
        var venueId: String
        var name: String
        var items: [RoomScanItem]
        var id: String { venueId }
    }

    /// 地图库里的房间地图，按场馆分组（导出 IMDF 用）
    private var groupedMaps: [VenueGroup] {
        let its = lib.entries.filter(\.isRoom).map { RoomScanItem(dir: lib.mapDir($0.id)) }
        var order: [String] = []
        var groups: [String: [RoomScanItem]] = [:]
        for it in its {
            let k = it.venueId ?? ""
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(it)
        }
        return order.map { k in
            let g = (groups[k] ?? []).sorted { ($0.ordinal ?? 0, $0.id) < ($1.ordinal ?? 0, $1.id) }
            return VenueGroup(venueId: k, name: g.compactMap(\.venueName).first ?? (k.isEmpty ? "没有场馆的地图" : "场馆"), items: g)
        }
    }

    private var roomEntries: [MapLibrary.Entry] { lib.visibleEntries.filter(\.isRoom) }

    private var startFooter: String {
        switch model.target {
        case .newMap:
            return RoomScanModel.supportsMultiRoom
                ? "用激光雷达扫出墙、门、窗和家具。一段里可以连着扫几个房间和走廊。建议第一段从大门口或走廊开始。一次扫不完没关系：下次选「接着扫」，扫进同一张地图。"
                : "用激光雷达扫出墙、门、窗和家具，生成 2D 平面图和 3D 模型（iOS 17 起支持一次扫多个房间）。一次扫不完没关系：下次选「接着扫」。"
        case .append:
            return """
            接着扫（扩大范围）或重扫某块（精细化）：
            1. 先走到上次扫过的房间里（门口或墙角附近）再点开始。
            2. 举起手机对着墙角、门窗、家具慢慢转一圈，等「已认出」。
            3. 认出后走到还没扫过的房间门口（或要重扫的地方），再点「开始扫」。重扫时慢一点、贴近墙面和家具。
            4. 扫完点「这段扫完」，看合并预览：新房间选「追加补充」，重扫选「替换这块」，然后确认。
            认不出也没关系：照常扫，但要把门口、走廊这些已扫过的地方再扫一小段，扫完会按墙和门自动对齐，对不上可以手动点两个对应点。
            """
        }
    }

    private var list: some View {
        List {
            if !RoomScanModel.isSupported {
                Text("这台设备不支持房间扫描（需要带激光雷达的 iPhone / iPad Pro）。").foregroundStyle(.orange)
            }

            Section {
                Picker("扫进", selection: $model.target) {
                    Text("新建一张地图").tag(ScanTarget.newMap)
                    ForEach(roomEntries) { e in
                        Text("接着扫：\(e.name)").tag(ScanTarget.append(e.id))
                    }
                }
                TextField(model.target == .newMap ? "地图名（例如 办公室）" : "这一段的名字（可不填，例如 东侧会议室）", text: $model.name)
                Button {
                    model.start()
                } label: {
                    Label(model.target == .newMap ? "开始扫描" : "开始接着扫", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!RoomScanModel.isSupported)
                if case .failed(let e) = model.phase { Text(e).font(.footnote).foregroundStyle(.red) }
            } header: { Text("扫描") } footer: {
                Text(startFooter)
            }

            if let m = model.result, let id = model.resultMapId {
                resultSection(m, id: id)
            }

            Section {
                HStack {
                    Text("场馆").foregroundStyle(.secondary)
                    Text(venueName.isEmpty ? "我的场馆" : venueName)
                    Spacer()
                    Button("换一栋楼") { newVenueName = ""; showNewVenue = true }.font(.footnote)
                }
                Picker("场馆类型", selection: $venueCategory) {
                    ForEach(0..<VenueSettings.categories.count, id: \.self) { i in
                        Text(VenueSettings.categories[i].label).tag(VenueSettings.categories[i].id)
                    }
                }
                FloorRow(floors: model.floors)
            } header: { Text("场馆和楼层") } footer: {
                Text("同一栋楼的多层扫描归到一个场馆，导出成一个 IMDF。楼层由气压计自动跟踪（坐电梯 / 走楼梯换层时会自动加减），第一次进楼时设一下当前是第几层。")
            }

            ForEach(groupedMaps) { g in
                Section {
                    ForEach(g.items) { it in
                        NavigationLink {
                            MapDetailView(mapId: it.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(lib.entries.first { $0.id == it.id }?.name ?? it.floorName ?? it.id)
                                    if it.id == lib.activeId {
                                        Text("在用").font(.caption.bold()).foregroundStyle(.green)
                                    }
                                }
                                Text([it.ordinal.map { "楼层 \($0)" }, "\(it.unitCount) 个房间",
                                      it.hasGeoRef ? "有地理坐标" : "无地理坐标"].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !g.venueId.isEmpty {
                        Button {
                            model.exportVenue(g.venueId, items: g.items)
                        } label: {
                            Label("导出为 IMDF", systemImage: "square.and.arrow.up.on.square")
                        }
                        if model.exportVenueId == g.venueId {
                            if let url = model.exportURL {
                                ShareLink(item: url) { Label("分享 \(url.lastPathComponent)", systemImage: "doc.zipper") }
                            }
                            if let msg = model.exportMessage { Text(msg).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                } header: { Text(g.venueId.isEmpty ? "房间地图" : "房间地图 · 场馆：\(g.name)") } footer: {
                    Text("点一张地图看它的扫描段、接着扫、改房间名字、删除。")
                }
            }

            if !model.items.isEmpty { legacySection }
        }
        .alert("换一栋楼", isPresented: $showNewVenue) {
            TextField("场馆名", text: $newVenueName)
            Button("取消", role: .cancel) {}
            Button("开始") {
                let n = newVenueName.trimmingCharacters(in: .whitespaces)
                VenueSettings.startNew(name: n.isEmpty ? "场馆" : n)
                venueName = VenueSettings.name
                model.floors.reset()
            }
        } message: {
            Text("之后的扫描归到新场馆，楼层从 0（地面层）开始。")
        }
        .confirmationDialog("删除这条旧版扫描记录？", isPresented: Binding(get: { confirmLegacyDelete != nil },
                                                                 set: { if !$0 { confirmLegacyDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let it = confirmLegacyDelete { model.delete(it) }
                confirmLegacyDelete = nil
            }
        } message: {
            Text("只删这条旧版扫描记录（原始扫描文件），地图库里的地图不受影响。")
        }
    }

    private func resultSection(_ m: StoreMap, id: String) -> some View {
        Section {
            Picker("显示", selection: $show3D) {
                Text("2D 平面").tag(false)
                Text("3D").tag(true)
            }
            .pickerStyle(.segmented)
            Group {
                if show3D, let sc = model3D.scene {
                    Store3DView(scene: sc, follow: false)
                } else {
                    MapCanvas(map: m, fingerprints: [], showFingerprints: false)
                }
            }
            .frame(height: 320)
            .onAppear { model3D.ensure(map: m) }
            .onChange(of: lib.geometryRevision) { _ in if let r = model.result { model3D.ensure(map: r) } }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(model.summary).font(.footnote)
            NavigationLink {
                UnitEditorView(mapId: id)
            } label: {
                Label("房间类别和名称", systemImage: "square.split.2x2")
            }
            NavigationLink {
                MapDetailView(mapId: id)
            } label: {
                Label("地图详情和扫描段", systemImage: "square.stack.3d.up")
            }
            Button {
                model.target = .append(id)
                model.name = ""
                model.start()
            } label: {
                Label("再接着扫一段（扩大范围 / 重扫精细化）", systemImage: "plus.viewfinder")
            }
            .disabled(!RoomScanModel.isSupported)
        } header: { Text(lib.entries.first { $0.id == id }?.name ?? m.floorName ?? id) }
    }

    /// 旧版扫描记录（以前每次扫描单独存一份；新的扫描直接进地图库）
    private var legacySection: some View {
        Section {
            ForEach(model.items) { it in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.floorName ?? it.id)
                        Text([it.ordinal.map { "楼层 \($0)" }, "\(it.unitCount) 个房间"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let inLib = it.libraryId.map { id in lib.entries.contains { $0.id == id } } == true
                    if inLib, it.libraryId == lib.activeId {
                        Text("在用").font(.caption.bold()).foregroundStyle(.green)
                    } else {
                        Button(inLib ? "切换" : (it.libraryId != nil ? "重新加入" : "加入地图库")) { model.addToLibrary(it) }
                            .buttonStyle(.bordered)
                    }
                }
                .swipeActions { Button("删除", role: .destructive) { confirmLegacyDelete = it } }
            }
            if let msg = model.libraryMessage { Text(msg).font(.footnote).foregroundStyle(.green) }
        } header: { Text("旧版扫描记录") } footer: {
            Text("以前的版本每次扫描单独存一份。「重新加入」= 地图库里那张已经删掉了，可以再加回来。新的扫描直接存进地图库，在地图详情里管理。")
        }
    }
}

/// 扫描画面顶部：扫进哪张地图、楼层、入口记录状态
private struct ScanStatusBar: View {
    @ObservedObject var model: RoomScanModel
    @ObservedObject var floors: FloorTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let n = model.targetName {
                Text("接着扫：\(n)" + (model.phase == .relocalizing ? "" : (model.inBaseFrame ? " · 已认出位置" : " · 扫完后对齐")))
                    .font(.footnote.weight(.semibold))
            }
            Text("楼层 \(floors.ordinal)" + (model.roomCount > 0 ? " · 已扫 \(model.roomCount) 个房间" : ""))
                .font(.footnote.weight(.semibold))
            if let m = model.entranceMessage {
                Text(m).font(.caption)
            } else if model.entrance == nil, model.phase != .relocalizing, model.phase != .readyToScan {
                Text("还没记录入口位置（导出 IMDF 要用）").font(.caption).foregroundStyle(.secondary)
            }
            if let c = floors.lastChange { Text(c).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 当前楼层：气压计自动跟踪，也可以手动改
private struct FloorRow: View {
    @ObservedObject var floors: FloorTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Stepper("当前楼层（ordinal）：\(floors.ordinal)", value: Binding(get: { floors.ordinal }, set: { floors.set($0) }), in: -10...200)
            if !floors.available {
                Text("这台设备没有气压计，换层后请手动改楼层").font(.caption).foregroundStyle(.orange)
            } else if let c = floors.lastChange {
                Text(c).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
