import ARKit
import HPASSKit
import RoomPlan
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

/// 一次扫描的结果（存在 Documents/room-scans/<名字>/）。一次扫描 = 一层楼里连续扫的一个或多个房间。
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

    /// 加进地图库时的编号
    var libraryId: String? {
        (try? String(contentsOf: dir.appendingPathComponent("library_id.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 房间扫描：用 Apple RoomPlan（激光雷达）扫出墙、门、窗、家具，生成 2D / 3D 地图。
///
/// iOS 17 起可以在同一个 AR 会话里连续扫多个房间和走廊（每扫完一个先不停 AR），最后用
/// `StructureBuilder` 拼成一个 `CapturedStructure`，每个房间是一个单元；iOS 16 只能一次扫一个房间。
/// 扫描时可以在入口记一次 GPS + 朝向（算 geoRef），气压计跟踪楼层序号；扫完后点选房间填类别和名字，
/// 一个场馆的多层扫描能导出成 IMDF。操作说明见 docs/roomplan-imdf-authoring.md。
///
/// 结果存成和门店地图同一种 JSON（墙 / 门 / 窗 / 家具 / 单元 / 地面多边形），「设为当前地图」之后，
/// 地磁定位页的建图采集、涂色、定位都直接在这里用（可走区域 = 可走单元 − 家具）。
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

@MainActor
final class RoomScanModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, processingRoom, betweenRooms, building, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: StoreMap?
    @Published private(set) var resultItem: RoomScanItem?
    @Published private(set) var summary = ""
    @Published private(set) var items: [RoomScanItem] = []
    @Published private(set) var roomCount = 0
    @Published private(set) var entrance: RoomMapBuilder.GeoAnchor?
    @Published private(set) var entranceMessage: String?
    var name = ""

    let geo = GeoCapture()
    let floors = FloorTracker()

    private let delegate = RoomCaptureDelegate()
    private(set) lazy var captureView: RoomCaptureView = {
        let v = RoomCaptureView(frame: .zero)
        v.delegate = delegate
        return v
    }()
    private var rooms: [CapturedRoom] = []
    private var pendingWorldMap: Data?

    static var isSupported: Bool { RoomCaptureSession.isSupported }
    /// iOS 17 起能连续扫多个房间（StructureBuilder）
    static var supportsMultiRoom: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    static var rootURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("room-scans", isDirectory: true)
    }

    init() {
        refresh()
        delegate.onResult = { [weak self] room, error in
            Task { @MainActor in self?.handle(room, error: error) }
        }
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

    func start() {
        guard Self.isSupported else { phase = .failed("这台设备不支持房间扫描（需要激光雷达）"); return }
        SensorArbiter.shared.claim("房间扫描") { [weak self] in self?.cancel() }
        result = nil
        resultItem = nil
        rooms = []
        roomCount = 0
        entrance = nil
        entranceMessage = nil
        pendingWorldMap = nil
        geo.start()
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
        AppLog.i("房间扫描", "开始扫描（楼层 \(floors.ordinal)）")
    }

    /// 当前这个房间扫完：iOS 17 先不停 AR（下一个房间接着在同一个坐标系里扫），iOS 16 直接结束
    func finishRoom() {
        guard phase == .scanning else { return }
        phase = .processingRoom
        if #available(iOS 17.0, *) {
            captureView.captureSession.stop(pauseARSession: false)
        } else {
            // 先存视觉特征地图（定位时用来认出这个房间），再停扫描
            captureWorldMap { [weak self] in self?.captureView.captureSession.stop() }
        }
    }

    /// 接着扫下一个房间 / 走廊（iOS 17）
    func nextRoom() {
        guard phase == .betweenRooms else { return }
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
    }

    /// 这一层全部扫完：存视觉特征地图、停 AR，把各个房间拼起来
    func finishAll() {
        guard phase == .betweenRooms, !rooms.isEmpty else { return }
        phase = .building
        captureWorldMap { [weak self] in
            guard let self else { return }
            self.captureView.captureSession.arSession.pause()
            Task { await self.finalize() }
        }
    }

    private func captureWorldMap(then: @escaping () -> Void) {
        pendingWorldMap = nil
        captureView.captureSession.arSession.getCurrentWorldMap { [weak self] map, err in
            let data = map.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
            Task { @MainActor in
                guard let self else { return }
                self.pendingWorldMap = data
                if data == nil { AppLog.w("房间扫描", "没拿到视觉特征地图：\(err?.localizedDescription ?? "未知原因")，视觉定位不可用") }
                then()
            }
        }
    }

    func cancel() {
        switch phase {
        case .scanning, .processingRoom: captureView.captureSession.stop()
        case .betweenRooms, .building: captureView.captureSession.arSession.pause()
        default: break
        }
        rooms = []
        roomCount = 0
        phase = .idle
        SensorArbiter.shared.release("房间扫描")
    }

    /// 在入口记一次 GPS + 朝向：手机竖着拿、摄像头对着要走进去的方向（或平放、顶部朝前）
    func markEntrance() {
        guard let frame = captureView.captureSession.arSession.currentFrame else {
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

            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd_HHmmss"
            let stamp = df.string(from: Date())
            let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? "\(floors.ordinal)F \(stamp)" : name
            let (json, map) = try RoomMapBuilder.build(input, name: title)
            let dir = Self.rootURL.appendingPathComponent("room_\(stamp)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.write(to: dir.appendingPathComponent("map.json"))
            try? export(dir.appendingPathComponent("room.usdz"))
            if let raw = rawJSON { try? raw.write(to: dir.appendingPathComponent("captured_room.json")) }
            if let wm = pendingWorldMap {
                try? wm.write(to: dir.appendingPathComponent(MapLibrary.worldMapFile))
                // 记下这份特征地图对应的 AR 对齐（之后的会话认出房间才能刷新它）
                WorldMapKeeper.noteScanned(dir: dir, align: map.arAlign, bytes: wm.count)
            }
            result = map
            resultItem = RoomScanItem(dir: dir)
            // 直接加进地图库并切换过去：到「地磁定位」页就是这里
            addToLibrary(RoomScanItem(dir: dir), name: title)
            let furniture = Dictionary(grouping: input.objects, by: \.category)
                .map { "\(RoomCategory.label($0.key)) \($0.value.count)" }.sorted().joined(separator: "、")
            let area = WalkableMap(floor: map.floor, obstacles: map.physicalShelves, widthCm: map.width, heightCm: map.height).walkableAreaM2
            summary = "房间 \(max(input.rooms.count, 1)) 个、墙 \(input.walls.count) 面、门 \(input.doors.count)、窗 \(input.windows.count)；"
                + "家具：\(furniture.isEmpty ? "无" : furniture)；可走 \(Fmt.f(area, 1)) m²；"
                + "地图 \(Fmt.f(map.width / 100, 1)) × \(Fmt.f(map.height / 100, 1)) m；楼层 \(floors.ordinal)；"
                + (entrance != nil ? "有地理坐标；" : "没有地理坐标（导出 IMDF 前要补）；")
                + (pendingWorldMap != nil ? "视觉定位可用" : "没有视觉特征地图（视觉定位不可用）")
            rooms = []
            phase = .done
            refresh()
            AppLog.i("房间扫描", "完成：\(dir.lastPathComponent)，\(summary)")
        } catch {
            phase = .failed("生成地图失败：\(error)")
            AppLog.e("房间扫描", "生成地图失败：\(error)")
        }
    }

    @Published private(set) var libraryMessage: String?

    /// 加进地图库（已经在库里就只切换）
    func addToLibrary(_ it: RoomScanItem, name: String? = nil) {
        let lib = MapLibrary.shared
        do {
            if let id = it.libraryId, lib.entries.contains(where: { $0.id == id }) {
                try lib.activate(id)
            } else {
                let d = try Data(contentsOf: it.mapURL)
                let n = name ?? (try? StoreDataLoader.loadMap(d))?.floorName ?? it.id
                let wm = it.dir.appendingPathComponent(MapLibrary.worldMapFile)
                let side = it.dir.appendingPathComponent(WorldMapSidecar.fileName)
                let extra = FileManager.default.fileExists(atPath: wm.path)
                    ? [wm] + (FileManager.default.fileExists(atPath: side.path) ? [side] : []) : []
                let e = try lib.importAndActivate(data: d, name: n, kind: "room", extraFiles: extra)
                try? Data(e.id.utf8).write(to: it.dir.appendingPathComponent("library_id.txt"))
            }
            libraryMessage = "已加入地图库并切换到这里。到「地磁定位」页建图采集、定位。"
        } catch {
            libraryMessage = "加入地图库失败：\(error.localizedDescription)"
        }
    }

    /// 打开以前扫过的一次
    func open(_ it: RoomScanItem) {
        guard let d = try? Data(contentsOf: it.mapURL), let m = try? StoreDataLoader.loadMap(d) else { return }
        result = m
        resultItem = RoomScanItem(dir: it.dir)
        summary = "\(m.floorName ?? it.id)：单元 \(it.unitCount) 个，家具 \(m.physicalShelves.count) 件，"
            + "地图 \(Fmt.f(m.width / 100, 1)) × \(Fmt.f(m.height / 100, 1)) m"
            + (it.ordinal.map { "，楼层 \($0)" } ?? "") + (it.hasGeoRef ? "，有地理坐标" : "，没有地理坐标")
        phase = .done
    }

    /// 单元改过之后刷新
    func reload(_ it: RoomScanItem) {
        refresh()
        if resultItem?.id == it.id { open(RoomScanItem(dir: it.dir)) }
    }

    func delete(_ it: RoomScanItem) {
        try? FileManager.default.removeItem(at: it.dir)
        if resultItem?.id == it.id { result = nil; resultItem = nil; phase = .idle }
        refresh()
    }

    @Published private(set) var exportURL: URL?
    @Published private(set) var exportMessage: String?
    /// 上面两个是哪个场馆的
    @Published private(set) var exportVenueId: String?

    /// 一个场馆（venueId）的全部扫描 → IMDF 压缩包
    func exportVenue(_ venueId: String) {
        exportVenueId = venueId
        let its = items.filter { $0.venueId == venueId }
        let missing = its.filter { !$0.hasGeoRef }.map { $0.floorName ?? $0.id }
        guard missing.isEmpty else {
            exportURL = nil
            exportMessage = "这几次扫描没有地理坐标：\(missing.joined(separator: "、"))。用网页编辑器两点对准补上 geoRef 后再导入，或重新扫描时在入口记录位置。"
            return
        }
        let name = its.compactMap(\.venueName).first ?? VenueSettings.name
        do {
            exportURL = try VenueExporter.export(items: its, venueName: name, category: VenueSettings.category)
            let levels = Set(its.compactMap(\.ordinal)).count
            exportMessage = "已导出 \(name)：\(levels) 层，\(its.count) 次扫描"
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

    /// 每个房间一个单元：地面多边形取最大的那块（没有地面时用墙端点凸包），类别按 RoomPlan 的房间类型建议
    @available(iOS 17.0, *)
    static func units(_ rooms: [CapturedRoom]) -> [RoomMapBuilder.Room] {
        var out: [RoomMapBuilder.Room] = []
        for (i, r) in rooms.enumerated() {
            var poly = r.floors.map(floorPolygon).filter { $0.count >= 3 }
                .max { abs(polyArea($0)) < abs(polyArea($1)) } ?? []
            if poly.count < 3 {
                var pts: [Point2] = []
                for w in r.walls {
                    let it = item("wall", w.transform, w.dimensions)
                    let u = Point2(cos(it.yaw), sin(it.yaw)) * (it.width / 2)
                    pts.append(it.center + u)
                    pts.append(it.center - u)
                }
                poly = RoomMapBuilder.convexHull(pts)
            }
            guard poly.count >= 3 else { continue }
            let section = r.sections.first.map { String(describing: $0.label) }
            let hasStairs = r.objects.contains { String(describing: $0.category) == "stairs" }
            let cat = hasStairs ? "stairs" : (IMDFUnitCategory.suggest(roomPlanSection: section) ?? "room")
            out.append(RoomMapBuilder.Room(id: "R\(i + 1)", floor: poly, category: cat))
        }
        return out
    }

    @available(iOS 17.0, *)
    static func floorPolygon(_ f: CapturedRoom.Surface) -> [Point2] {
        f.polygonCorners.map { (pc: simd_float3) -> Point2 in
            let local = simd_float4(pc.x, pc.y, pc.z, 1)
            let w: simd_float4 = f.transform * local
            return Point2(Double(w.x), Double(w.z))
        }
    }

    static func polyArea(_ p: [Point2]) -> Double {
        var s = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; s += a.x * b.y - b.x * a.y }
        return s / 2
    }
}

/// RoomPlan 自带的扫描界面（实时显示扫到的墙和家具，扫完显示 3D 结果）
struct RoomCaptureContainer: UIViewRepresentable {
    let model: RoomScanModel
    func makeUIView(context: Context) -> RoomCaptureView { model.captureView }
    func updateUIView(_ v: RoomCaptureView, context: Context) {}
}

struct RoomScanView: View {
    @StateObject private var model = RoomScanModel()
    @ObservedObject private var lib = MapLibrary.shared
    @StateObject private var model3D = Store3DModel()
    @State private var show3D = false
    @AppStorage(VenueSettings.nameKey) private var venueName = ""
    @AppStorage(VenueSettings.categoryKey) private var venueCategory = "businesscampus"
    @State private var newVenueName = ""
    @State private var showNewVenue = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .scanning, .processingRoom, .betweenRooms, .building:
                    scanning
                default:
                    list
                }
            }
            .navigationTitle("房间扫描")
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    private var scanning: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureContainer(model: model).ignoresSafeArea()
            VStack(spacing: 8) {
                ScanStatusBar(model: model, floors: model.floors)
                switch model.phase {
                case .processingRoom, .building:
                    HStack { ProgressView(); Text(model.phase == .building ? "正在拼接、生成地图……" : "正在处理这个房间……") }
                        .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                case .betweenRooms:
                    Text("已扫 \(model.roomCount) 个房间。走到下一个房间 / 走廊门口，点「扫下一个」；这一层扫完点「这层扫完」。")
                        .font(.footnote).padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("取消", role: .cancel) { model.cancel() }.buttonStyle(.bordered)
                        Button("记录入口") { model.markEntrance() }.buttonStyle(.bordered)
                        Button("扫下一个") { model.nextRoom() }.buttonStyle(.bordered)
                        Button("这层扫完") { model.finishAll() }.buttonStyle(.borderedProminent)
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

    struct VenueGroup: Identifiable {
        var venueId: String
        var name: String
        var items: [RoomScanItem]
        var id: String { venueId }
    }

    private var groupedItems: [VenueGroup] {
        var order: [String] = []
        var groups: [String: [RoomScanItem]] = [:]
        for it in model.items {
            let k = it.venueId ?? ""
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(it)
        }
        return order.map { k in
            let its = (groups[k] ?? []).sorted { ($0.ordinal ?? 0, $0.id) < ($1.ordinal ?? 0, $1.id) }
            return VenueGroup(venueId: k, name: its.compactMap(\.venueName).first ?? (k.isEmpty ? "单独的房间" : "场馆"), items: its)
        }
    }

    private var list: some View {
        List {
            if !RoomScanModel.isSupported {
                Text("这台设备不支持房间扫描（需要带激光雷达的 iPhone / iPad Pro）。").foregroundStyle(.orange)
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

            Section {
                TextField("名称（例如 3 楼东区）", text: $model.name)
                Button {
                    model.start()
                } label: {
                    Label("开始扫描", systemImage: "viewfinder").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!RoomScanModel.isSupported)
                if case .failed(let e) = model.phase { Text(e).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text(RoomScanModel.supportsMultiRoom
                     ? "用激光雷达扫出墙、门、窗和家具。可以一口气扫一层里的多个房间和走廊，最后自动拼成一张图。扫完后给每个房间选类别、起名字。"
                     : "用激光雷达扫出墙、门、窗和家具，自动生成 2D 平面图和 3D 模型（iOS 17 起支持一次扫多个房间）。")
            }

            if let m = model.result, let it = model.resultItem {
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
                    .onChange(of: model.resultItem?.id) { _ in if let r = model.result { model3D.ensure(map: r) } }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(model.summary).font(.footnote)
                    NavigationLink {
                        UnitEditorView(item: it) { model.reload(it) }
                    } label: {
                        Label("房间类别和名称（\(it.unitCount) 个单元）", systemImage: "square.split.2x2")
                    }
                    if let id = it.libraryId, id == lib.activeId {
                        Label("当前在用这张地图", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button { model.addToLibrary(it) } label: {
                            Label(it.libraryId.map { id in lib.entries.contains { $0.id == id } } == true
                                  ? "切换到这里" : "加入地图库并切换", systemImage: "arrow.triangle.swap")
                        }
                    }
                    if FileManager.default.fileExists(atPath: it.usdzURL.path) {
                        ShareLink(item: it.usdzURL) { Label("导出 3D 模型（USDZ）", systemImage: "cube") }
                    }
                    ShareLink(item: it.mapURL) { Label("导出 2D 地图（JSON）", systemImage: "map") }
                    if let msg = model.libraryMessage { Text(msg).font(.footnote).foregroundStyle(.green) }
                } header: { Text(m.floorName ?? it.id) }
            }

            MapLibrarySection()

            ForEach(groupedItems) { g in
                Section {
                    ForEach(g.items) { it in
                        Button { model.open(it) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.floorName ?? it.id)
                                Text([it.ordinal.map { "楼层 \($0)" }, "\(it.unitCount) 个单元",
                                      it.hasGeoRef ? "有地理坐标" : "无地理坐标"].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button("删除", role: .destructive) { model.delete(it) } }
                    }
                    if !g.venueId.isEmpty {
                        Button {
                            model.exportVenue(g.venueId)
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
                } header: { Text(g.venueId.isEmpty ? g.name : "场馆：\(g.name)") }
            }
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
    }
}

/// 扫描画面顶部：楼层、入口记录状态
private struct ScanStatusBar: View {
    @ObservedObject var model: RoomScanModel
    @ObservedObject var floors: FloorTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("楼层 \(floors.ordinal)" + (model.roomCount > 0 ? " · 已扫 \(model.roomCount) 个房间" : ""))
                .font(.footnote.weight(.semibold))
            if let m = model.entranceMessage {
                Text(m).font(.caption)
            } else if model.entrance == nil {
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
