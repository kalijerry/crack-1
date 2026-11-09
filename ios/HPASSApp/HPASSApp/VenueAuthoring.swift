import CoreLocation
import CoreMotion
import HPASSKit
import SwiftUI
import UIKit
import Vision

// 用 RoomPlan 扫描自己生成 IMDF 场馆地图的辅助部分：
// - 场馆 / 楼层设置（同一栋楼的多层扫描归到一个场馆）
// - GeoCapture：入口处记一次 GPS + 真北朝向
// - FloorTracker：气压计（CMAltimeter）+ FloorDetector 跟踪当前楼层序号
// - UnitEditorView：扫完后点选房间，选 IMDF 类别、填名字（可拍门牌识别）
// - VenueExporter：一个场馆的多层 map.json → IMDF 压缩包
// 操作说明见 docs/roomplan-imdf-authoring.md。

/// 当前场馆（UserDefaults）。扫描时写进 map.json 的 venueId / venueName / ordinal。
enum VenueSettings {
    static let idKey = "venue.id", nameKey = "venue.name", categoryKey = "venue.category", ordinalKey = "venue.ordinal"

    static var id: String {
        if let v = UserDefaults.standard.string(forKey: idKey), !v.isEmpty { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: idKey)
        return v
    }

    static var name: String {
        let n = UserDefaults.standard.string(forKey: nameKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "我的场馆" : n
    }

    static var category: String { UserDefaults.standard.string(forKey: categoryKey) ?? "businesscampus" }

    static var ordinal: Int {
        get { UserDefaults.standard.integer(forKey: ordinalKey) }
        set { UserDefaults.standard.set(newValue, forKey: ordinalKey) }
    }

    /// 开一个新场馆（换了一栋楼）
    static func startNew(name: String) {
        UserDefaults.standard.set(UUID().uuidString, forKey: idKey)
        UserDefaults.standard.set(name, forKey: nameKey)
        ordinal = 0
    }

    /// IMDF venue category 里常用的几个
    static let categories: [(id: String, label: String)] = [
        ("businesscampus", "办公园区 / 写字楼"), ("shoppingcenter", "商场"), ("retailstore", "零售店"),
        ("hotel", "酒店"), ("university", "学校"), ("healthcarefacility", "医院"), ("museum", "博物馆"),
        ("airport", "机场"), ("trainstation", "火车站"), ("parkingfacility", "停车场"),
        ("conventioncenter", "会展中心"), ("governmentfacility", "政府机构"),
    ]
}

/// 入口处记一次 GPS + 朝向。只在扫描页打开时运行。
@MainActor
final class GeoCapture: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLHeading?
    private let manager = CLLocationManager()
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.headingOrientation = .portrait
            manager.startUpdatingHeading()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    /// 真北朝向（度）；没有真北（没定位）时退回磁北
    var headingDeg: Double? {
        guard let h = heading else { return nil }
        if h.trueHeading >= 0 { return h.trueHeading }
        return h.magneticHeading >= 0 ? h.magneticHeading : nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in
            // 只在精度变好或者旧数据过期（> 10 s）时替换
            if let old = self.location, old.horizontalAccuracy >= 0, l.horizontalAccuracy > old.horizontalAccuracy,
               l.timestamp.timeIntervalSince(old.timestamp) < 10 { return }
            self.location = l
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading h: CLHeading) {
        Task { @MainActor in self.heading = h }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }
}

/// 气压计跟踪楼层：CMAltimeter 的相对高度喂给 FloorDetector，楼层变化写回当前楼层序号。
@MainActor
final class FloorTracker: ObservableObject {
    @Published private(set) var ordinal: Int
    @Published private(set) var lastChange: String?
    let available = CMAltimeter.isRelativeAltitudeAvailable()
    private let altimeter = CMAltimeter()
    private var detector: FloorDetector
    private var running = false

    static func config() -> FloorDetector.Config {
        var c = FloorDetector.Config()
        c.floorHeightM = 4.0          // 写字楼 3.5～4、商场 4.5～6；不准时手动改楼层
        return c
    }

    init() {
        let o = VenueSettings.ordinal
        ordinal = o
        detector = FloorDetector(startFloor: o, config: Self.config())
    }

    func start() {
        guard available, !running else { return }
        running = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let t = Int64(data.timestamp * 1000), h = data.relativeAltitude.doubleValue
            Task { @MainActor in self?.feed(tMs: t, meters: h) }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        altimeter.stopRelativeAltitudeUpdates()
    }

    /// 手动设楼层（第一次进楼、或者气压判断错了）
    func set(_ o: Int) {
        ordinal = o
        detector.setFloor(o)
        VenueSettings.ordinal = o
    }

    /// 换了一栋楼：楼层从 0 开始，检测器重来
    func reset() {
        detector = FloorDetector(startFloor: VenueSettings.ordinal, config: Self.config())
        ordinal = VenueSettings.ordinal
        lastChange = nil
    }

    private func feed(tMs: Int64, meters: Double) {
        guard let ch = detector.addRelativeAltitude(tMs: tMs, meters: meters) else { return }
        ordinal = detector.floor
        VenueSettings.ordinal = ordinal
        let how: String
        switch ch.mode {
        case .elevator: how = "电梯"
        case .escalator: how = "扶梯"
        case .stairs: how = "楼梯"
        }
        lastChange = "气压计：\(how)\(ch.deltaFloors > 0 ? "上" : "下") \(abs(ch.deltaFloors)) 层（\(Fmt.f(ch.deltaMeters, 1)) m）"
        AppLog.i("房间扫描", lastChange ?? "")
    }
}

/// 拍门牌 → 系统文字识别（Vision，全部在手机上做），返回识别到的几行字。
enum DoorSignReader {
    static func lines(in image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        let orientation = cgOrientation(image.imageOrientation)
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: ShelfSignReader.recognizeLines(cg, orientation: orientation))
            }
        }
    }

    static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

/// 系统相机（拍门牌用）
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onDone: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.onDone()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onDone() }
    }
}

/// 单元平面图：画出所有单元（按类别着色），点一下选中
struct UnitCanvas: View {
    let units: [RoomMapBuilder.Unit]
    @Binding var selected: String?

    struct Fit {
        var minX = 0.0, minY = 0.0, scale = 1.0, dx = 0.0, dy = 0.0
        init(_ units: [RoomMapBuilder.Unit], _ size: CGSize) {
            let pts = units.flatMap(\.polygon)
            guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(),
                  let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return }
            minX = x0; minY = y0
            scale = min(Double(size.width) / max(x1 - x0, 1), Double(size.height) / max(y1 - y0, 1)) * 0.92
            dx = (Double(size.width) - (x1 - x0) * scale) / 2
            dy = (Double(size.height) - (y1 - y0) * scale) / 2
        }
        func view(_ p: Point2) -> CGPoint { CGPoint(x: (p.x - minX) * scale + dx, y: (p.y - minY) * scale + dy) }
        func map(_ p: CGPoint) -> Point2 { Point2((Double(p.x) - dx) / scale + minX, (Double(p.y) - dy) / scale + minY) }
    }

    static func color(_ cat: String) -> Color {
        if IMDFUnitCategory.isConnector(cat) { return .orange }
        if !IMDFUnitCategory.isWalkable(cat) { return .gray }
        if cat.hasPrefix("restroom") { return .teal }
        if cat == "walkway" || cat == "lobby" { return .green }
        return .blue
    }

    var body: some View {
        GeometryReader { geo in
            let fit = Fit(units, geo.size)
            Canvas { ctx, _ in
                for u in units {
                    var path = Path()
                    path.addLines(u.polygon.map(fit.view))
                    path.closeSubpath()
                    let on = u.id == selected
                    ctx.fill(path, with: .color(Self.color(u.category).opacity(on ? 0.55 : 0.2)))
                    ctx.stroke(path, with: .color(on ? .accentColor : .secondary), lineWidth: on ? 2.5 : 0.8)
                    let c = fit.view(RoomMapBuilder.polygonCentroid(u.polygon))
                    ctx.draw(Text(u.name ?? IMDFUnitCategory.label(u.category)).font(.caption2), at: c)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { pt in
                let p = fit.map(pt)
                // 嵌套时选面积最小的那个
                let hit = units.filter { RoomMapBuilder.polygonContains($0.polygon, p) }
                    .min { abs(area($0.polygon)) < abs(area($1.polygon)) }
                selected = hit?.id
            }
        }
    }

    private func area(_ p: [Point2]) -> Double {
        var s = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; s += a.x * b.y - b.x * a.y }
        return s / 2
    }
}

/// 扫完以后：点选房间，选 IMDF 类别、填名字；改楼层序号 / 楼层名。
///
/// 改的是地图库里这张地图：类别 / 名字记进扫描段注册表（`unitLabels`），再重新合成 map.json
/// （直接改 map.json 会在下次接着扫、关掉一段时被覆盖）。
struct UnitEditorView: View {
    let mapId: String
    var onSaved: () -> Void = {}

    @ObservedObject private var lib = MapLibrary.shared
    @State private var json = Data()
    @State private var units: [RoomMapBuilder.Unit] = []
    @State private var selected: String?
    @State private var category = "room"
    @State private var name = ""
    @State private var floorName = ""
    @State private var ordinal = 0
    @State private var showCamera = false
    @State private var reading = false
    @State private var ocrLines: [String] = []
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                TextField("楼层名（例如 1F、B1）", text: $floorName)
                Stepper("楼层序号（ordinal）：\(ordinal)", value: $ordinal, in: -10...200)
                Button("保存楼层") { saveLevel() }
            } header: { Text("楼层") } footer: {
                Text("ordinal：地面层 0，往上 1、2…，地下 −1、−2…。扫描时由气压计自动记，不对就在这里改。")
            }

            Section {
                UnitCanvas(units: units, selected: $selected)
                    .frame(height: 280)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("点一个房间选中它。蓝 = 房间，绿 = 走廊 / 大堂，青 = 卫生间，橙 = 电梯 / 楼梯 / 扶梯（连接体），灰 = 不可走。")
            }

            if let id = selected {
                Section("单元 \(id)") {
                    Picker("类别", selection: $category) {
                        ForEach(0..<IMDFUnitCategory.common.count, id: \.self) { i in
                            Text("\(IMDFUnitCategory.common[i].label)  \(IMDFUnitCategory.common[i].id)").tag(IMDFUnitCategory.common[i].id)
                        }
                    }
                    if IMDFUnitCategory.isConnector(category) {
                        Label("连接体：导出时同一位置的上下层会连成一组", systemImage: "arrow.up.arrow.down")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    TextField("名称（例如 会议室 A、男卫生间）", text: $name)
                    Button {
                        showCamera = true
                    } label: {
                        Label(reading ? "正在识别…" : "拍门牌识别名称", systemImage: "text.viewfinder")
                    }
                    .disabled(reading)
                    if !ocrLines.isEmpty {
                        ForEach(ocrLines, id: \.self) { line in
                            Button(line) { name = name.isEmpty ? line : "\(name) \(line)" }.font(.callout)
                        }
                        Button("清空识别结果", role: .destructive) { ocrLines = [] }.font(.footnote)
                    }
                    Button("保存这个单元") { saveUnit(id) }.fontWeight(.semibold)
                }
            }

            Section("全部单元（\(units.count)）") {
                ForEach(units) { u in
                    Button {
                        selected = u.id
                    } label: {
                        HStack {
                            Circle().fill(UnitCanvas.color(u.category)).frame(width: 10, height: 10)
                            Text(u.name ?? "（未命名）").foregroundStyle(u.name == nil ? .secondary : .primary)
                            Spacer()
                            Text(IMDFUnitCategory.label(u.category)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let m = message { Text(m).font(.footnote).foregroundStyle(.green) }
        }
        .navigationTitle("房间类别和名称")
        .onAppear(perform: load)
        .onChange(of: selected) { id in
            guard let u = units.first(where: { $0.id == id }) else { return }
            category = u.category
            name = u.name ?? ""
            ocrLines = []
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(onImage: { img in
                reading = true
                Task {
                    let lines = await DoorSignReader.lines(in: img)
                    ocrLines = Array(lines.prefix(8))
                    reading = false
                    if lines.isEmpty { message = "没认出文字，靠近一点再拍" }
                }
            }, onDone: { showCamera = false })
            .ignoresSafeArea()
        }
    }

    private func load() {
        json = (try? Data(contentsOf: lib.mapURL(mapId))) ?? Data()
        units = RoomMapBuilder.units(json)
        let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        floorName = root?["floorName"] as? String ?? ""
        ordinal = (root?["ordinal"] as? NSNumber)?.intValue ?? 0
    }

    /// 改完重新读合成后的地图
    private func saved(_ text: String) {
        json = (try? Data(contentsOf: lib.mapURL(mapId))) ?? json
        units = RoomMapBuilder.units(json)
        message = text
        onSaved()
    }

    private func saveUnit(_ id: String) {
        do {
            try lib.relabelUnit(mapId, unit: id, category: category, name: name)
            saved("已保存：\(name.isEmpty ? id : name)（\(IMDFUnitCategory.label(category))）")
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }

    private func saveLevel() {
        let fn = floorName.trimmingCharacters(in: .whitespaces), o = ordinal
        do {
            try lib.setLevel(mapId, floorName: fn, ordinal: o)
            saved("楼层已保存：\(fn)（ordinal \(o)）")
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// 一个场馆的多层地图（地图库里各张房间地图的 map.json）→ IMDF 压缩包（Documents/imdf/<场馆名>.zip）
enum VenueExporter {
    static func export(items: [RoomScanItem], venueName: String, category: String?) throws -> URL {
        let files = items.compactMap { try? Data(contentsOf: $0.mapURL) }
        let data = try IMDFExporter.archive(jsonFiles: files, options: .init(venueName: venueName, venueCategory: category))
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imdf", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = String(venueName.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "venue" : safe)_imdf.zip")
        try data.write(to: url)
        return url
    }
}
