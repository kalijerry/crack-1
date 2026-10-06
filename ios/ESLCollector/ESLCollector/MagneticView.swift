import ARKit
import HPASSKit
import SceneKit
import SwiftUI

/// 持有 AR 叠加场景（引用类型，SwiftUI 重绘时不重建）。
@MainActor
final class AROverlayModel: ObservableObject {
    let scene = AROverlayScene()
}
import UniformTypeIdentifiers

// MARK: - 页面

/// 地磁定位：地图点位 → 实时定位（定点即走）；高级里保留按点位建磁场图和粒子滤波定位。
@MainActor
struct MagneticView: View {
    enum Step: String, CaseIterable, Identifiable {
        case map = "地图", survey = "采集", live = "定位", advanced = "实验功能"
        var id: String { rawValue }
        /// 顶部分段只放主流程；「实验功能」从地图页进入
        static var main: [Step] { [.map, .survey, .live] }
    }

    @StateObject private var engine = MagneticEngine()
    @StateObject private var survey = SurveyEngine()
    @StateObject private var mapService = SurveyMapService()
    @ObservedObject private var store = MagMapStore.shared
    @ObservedObject private var storeData = StoreDataStore.shared

    @State private var step: Step = .map
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var startId = ""
    @State private var unknownStart = false
    @State private var checkId = ""
    @State private var confirmClearPoints = false
    @State private var confirmClearCal = false
    @State private var confirmResetCoverage = false
    @State private var surveyNote = ""
    enum Camera3D: String, CaseIterable, Identifiable {
        case follow = "跟随", overview = "总览", top = "俯视"
        var id: String { rawValue }
    }
    @StateObject private var model3D = Store3DModel()
    @State private var show3D = false
    @State private var camera3D: Camera3D = .follow
    @State private var shelfHeight3D = 1.8
    /// 3D 里的货架偏移校准面板是否打开
    @State private var calibrateShelves = false
    @State private var shelfStepCm = 10.0
    @State private var mapUpText = ""
    @StateObject private var arModel = AROverlayModel()
    @State private var showAR = false
    @State private var arAngle = 0.0
    @State private var arDX = 0.0
    @State private var arDY = 0.0
    @State private var arNote = ""
    @State private var arSaved = 0
    @State private var shelfQuery = ""
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("步骤", selection: $step) {
                    ForEach(Step.main) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .disabled(engine.phase != .idle || survey.isRunning)
                .onChange(of: step) { AppLog.tap("地磁·步骤", $0.rawValue) }

                canvasArea
                    .padding(.horizontal)
                    .frame(height: min(max(UIScreen.main.bounds.height * 0.42, 260), 420))

                Form {
                    if let err = engine.lastError ?? store.lastError {
                        Section { Text(err).foregroundStyle(.red) }
                    }
                    switch step {
                    case .map: mapPanel
                    case .live:
                        arSection
                        livePanel
                    case .survey:
                        arSection
                        surveyPanel
                    case .advanced:
                        Section {
                            Button("返回地图") { step = .map }
                            Text("这里是早期的对照功能：按点位走一遍建磁场图，以及只用计步的定位（误差大）。日常请用「采集」和「定位」。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        calibratePanel
                        locatePanel
                    }
                }
            }
            .navigationTitle("地磁定位")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
        }
        .onAppear {
            store.adopt(map: storeData.map)
            if mapUpText.isEmpty, let v = store.mapUpBearingDeg { mapUpText = Fmt.f(v, 0) }
            if startId.isEmpty { startId = store.points.first?.id ?? "" }
        }
        .onChange(of: storeData.map?.crosses.count) { _ in store.adopt(map: storeData.map) }
        .onAppear { survey.coverage.configure(crosses: store.crosses); mapService.refresh() }
        .onChange(of: survey.isRunning) { running in if !running { mapService.refresh() } }
        .onChange(of: survey.lastSessionDir) { _ in exportURL = nil; exportError = nil }
    }

    // MARK: 画布

    /// 画布用的地图：有门店地图就用它，没有就是一块带 1 m 方格的小测试区。
    private var canvasMap: StoreMap? {
        if let m = storeData.map, m.width > 0 { return m }
        return StoreMap(width: store.widthCm, height: store.heightCm, shelves: [], crosses: [])
    }

    private var canvas: some View {
        let isSurvey = step == .survey
        let showsTrack = step != .map
        let live = step == .live && engine.phase == .live
        let surveying = isSurvey && survey.isRunning
        return MapCanvas(map: canvasMap,
                         fingerprints: [],
                         trail: isSurvey ? survey.trail : (showsTrack ? engine.trail : []),
                         position: isSurvey ? survey.position : (showsTrack ? engine.position : nil),
                         headingRad: isSurvey ? survey.headingRad : engine.headingRad,
                         uncertaintyCm: isSurvey ? 0 : engine.uncertaintyCm,
                         route: step == .live ? engine.navRoute : nil,
                         showFingerprints: false,
                         markPoints: store.points,
                         targetId: showsTrack && !isSurvey ? engine.targetId : nil,
                         highlightId: calibrationHighlight,
                         gridCm: storeData.map == nil ? 100 : nil,
                         crossStates: isSurvey ? survey.coverage.states : [],
                         crossBinCm: SurveyCoverage.binCm,
                         showHeading: isSurvey ? (survey.stage != .needPosition)
                             : (!live || engine.isTracking || engine.headingEditing),
                         positionStale: !isSurvey && engine.locState == .lost,
                         headingEditing: isSurvey ? survey.headingEditing : (live && engine.headingEditing),
                         onLongPress: longPressAction,
                         onDoubleTap: surveying ? { survey.toggleHeadingEdit() }
                             : (live ? { engine.toggleHeadingEdit() } : nil),
                         onHeadingPoint: surveying ? { survey.pointHeading(toward: $0) }
                             : (live ? { engine.pointHeading(toward: $0) } : nil))
    }

    private var longPressAction: ((Point2) -> Void)? {
        switch step {
        case .map:
            return { p in
                let mp = store.addPoint(at: p)
                if startId.isEmpty { startId = mp.id }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        case .live:
            return engine.phase == .live && !engine.headingEditing ? { engine.setAnchor($0) } : nil
        case .survey:
            return survey.isRunning && !survey.headingEditing ? { survey.anchor(at: $0) } : nil
        case .advanced:
            return nil
        }
    }

    // MARK: 2D / 3D

    /// 3D 里没有长按定点、双击设朝向，这些只在 2D 里做。
    private var canvasArea: some View {
        ZStack(alignment: .topTrailing) {
            if showAR, let session = arSessionNow {
                ZStack(alignment: .bottomLeading) {
                    AROverlayView(session: session, overlay: arModel.scene)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    if arAlignmentNow == nil {
                        Text("还没对齐：先在 2D 里定点、设朝向，再朝箭头方向直走 1.5 m")
                            .font(.footnote.weight(.semibold)).padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }
                }
            } else if show3D, let sc = model3D.scene {
                ZStack(alignment: .bottom) {
                    Store3DView(scene: sc, follow: camera3D == .follow)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    if calibrateShelves { shelfCalibrationPad.padding(8) }
                }
            } else {
                canvas
            }
            VStack(alignment: .trailing, spacing: 6) {
                if !showAR {
                    LoggedButton(name: "2D/3D", detail: show3D ? "→2D" : "→3D") { toggle3D() } label: {
                        Text(show3D ? "2D" : "3D").font(.footnote.bold()).frame(width: 40, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if arSessionNow != nil {
                    LoggedButton(name: "AR", detail: showAR ? "关" : "开") {
                        showAR.toggle()
                        if showAR { syncAR(force: true) }
                    } label: {
                        Text(showAR ? "地图" : "AR").font(.footnote.bold()).frame(width: 40, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                if show3D && storeData.map != nil {
                    LoggedButton(name: "3D·校准货架", detail: calibrateShelves ? "关" : "开") {
                        calibrateShelves.toggle()
                        // 按地图方向挪，俯视时屏幕方向和地图方向一致，最好对
                        if calibrateShelves { camera3D = .top } else { storeData.logShelfOffset() }
                    } label: {
                        Text(calibrateShelves ? "完成" : "校准").font(.footnote.bold()).frame(width: 40, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(calibrateShelves ? .green : .indigo)
                }
                if show3D {
                    Picker("视角", selection: $camera3D) {
                        ForEach(Camera3D.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .buttonStyle(.bordered)
                    .onChange(of: camera3D) { _ in applyCamera3D() }
                }
            }
            .padding(8)
        }
        .onChange(of: show3D) { on in if on { sync3D(full: true) } else if calibrateShelves { calibrateShelves = false; storeData.logShelfOffset() } }
        .onChange(of: storeData.shelfOffset) { _ in
            store.adopt(map: storeData.map)   // 深度射线投射用新的货架位置
            sync3D(full: false)
            syncAR(force: true)
        }
        .onChange(of: survey.arAlignment) { _ in syncAR() }
        .onChange(of: engine.arAlignment) { _ in syncAR() }
        .onChange(of: survey.arFloorY) { _ in syncAR() }
        .onChange(of: engine.arFloorY) { _ in syncAR() }
        .onChange(of: survey.position) { _ in syncAR() }
        .onChange(of: engine.position) { _ in syncAR() }
        .onChange(of: arAngle) { _ in syncAR() }
        .onChange(of: arDX) { _ in syncAR() }
        .onChange(of: arDY) { _ in syncAR() }
        .onChange(of: arSessionNow == nil) { gone in if gone { showAR = false } }
        .onChange(of: engine.position) { _ in sync3D(full: false) }
        .onChange(of: survey.position) { _ in sync3D(full: false) }
        .onChange(of: engine.trail.count) { _ in sync3D(full: false) }
        .onChange(of: survey.coverage.revision) { _ in sync3D(full: false) }
        .onChange(of: store.points) { _ in sync3D(full: true) }
        .onChange(of: store.sampleCount) { _ in sync3D(full: true) }
        .onChange(of: step) { _ in sync3D(full: true) }
    }

    // MARK: 货架偏移校准

    /// 3D 底部的方向键：按地图方向整体挪货架，立刻看到效果。通道不动。
    private var shelfCalibrationPad: some View {
        let d = storeData.shelfOffset
        func nudge(_ dx: Double, _ dy: Double) -> some View {
            Button {
                storeData.setShelfOffset(Point2(d.x + dx * shelfStepCm, d.y + dy * shelfStepCm))
            } label: {
                Image(systemName: dx < 0 ? "arrow.left" : dx > 0 ? "arrow.right" : dy < 0 ? "arrow.up" : "arrow.down")
                    .font(.body.bold()).frame(width: 44, height: 36)
            }
            .buttonStyle(.bordered)
        }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("货架整体偏移").font(.footnote.bold())
                Text("x \(Fmt.f(d.x, 0)) cm  y \(Fmt.f(d.y, 0)) cm").font(.footnote.monospacedDigit())
                Picker("步长", selection: $shelfStepCm) {
                    Text("5").tag(5.0); Text("10").tag(10.0); Text("50").tag(50.0)
                }
                .pickerStyle(.segmented).frame(width: 130)
                Text("按地图方向（俯视），单位 cm").font(.caption2).foregroundStyle(.secondary)
                Button("归零") { storeData.setShelfOffset(Point2(0, 0)) }
                    .font(.footnote).disabled(d.x == 0 && d.y == 0)
            }
            VStack(spacing: 4) {
                nudge(0, -1)
                HStack(spacing: 4) { nudge(-1, 0); nudge(1, 0) }
                nudge(0, 1)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: AR 叠加

    /// 当前页面正在用的 ARKit 会话（建图采集 / 实时定位开着视觉里程计时才有）。
    private var arSessionNow: ARSession? {
        if step == .survey && survey.isRunning { return survey.arSession }
        if step == .live && engine.phase == .live && engine.arRunningNow { return engine.arSession }
        return nil
    }

    private var arAlignmentNow: MapARTransform? {
        step == .survey ? survey.arAlignment : engine.arAlignment
    }

    private var arPositionNow: Point2? { step == .survey ? survey.position : engine.position }

    /// 把对齐、地面高度、微调、附近内容推给 AR 叠加。
    private func syncAR(force: Bool = false) {
        guard showAR, let session = arSessionNow else { return }
        let s = arModel.scene
        s.shelfHeightM = shelfHeight3D
        // 地面：优先用识别出来的地面；还没识别到就按手机离地约 1.3 m 估
        let floor = (step == .survey ? survey.arFloorY : engine.arFloorY)
            ?? session.currentFrame.map { Double($0.camera.transform.columns.3.y) - 1.3 } ?? -1.3
        s.setTransform(arAlignmentNow, floorY: floor)
        guard let p = arPositionNow else { return }
        s.setNudge(angleDeg: arAngle, dxCm: arDX, dyCm: arDY, pivot: p)
        if let m = canvasMap { s.setLocal(center: p, map: m, points: store.points, force: force) }
        s.setTrail(step == .survey ? survey.trail : engine.trail)
    }

    @ViewBuilder private var arSection: some View {
        if showAR {
            Section {
                Text("橙色线框是地图里的货架，青色线是通道中心线，蓝色杆是点位。拖下面的滑块，让线框和真实货架对齐，然后点「记录偏移」。偏移量就是地图在这里错了多少。")
                    .font(.footnote).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("旋转 \(Fmt.f(arAngle, 1))°（逆时针为正）")
                    Slider(value: $arAngle, in: -10...10, step: 0.5)
                }
                VStack(alignment: .leading) {
                    Text("左右平移（地图 x）\(Int(arDX)) cm")
                    Slider(value: $arDX, in: -200...200, step: 5)
                }
                VStack(alignment: .leading) {
                    Text("上下平移（地图 y）\(Int(arDY)) cm")
                    Slider(value: $arDY, in: -200...200, step: 5)
                }
                Stepper("货架高度 \(Fmt.f(shelfHeight3D, 1)) m", value: $shelfHeight3D, in: 0.8...3.0, step: 0.2)
                    .onChange(of: shelfHeight3D) { _ in syncAR(force: true) }
                TextField("备注（例如：第 3 排货架）", text: $arNote)
                HStack {
                    Button("归零") { arAngle = 0; arDX = 0; arDY = 0 }
                        .buttonStyle(.bordered)
                    Spacer()
                    LoggedButton(name: "AR·记录偏移", detail: "\(arAngle)° \(arDX) \(arDY)") {
                        guard let p = arPositionNow else { return }
                        ARCheckLog.append(position: p, angleDeg: arAngle, dxCm: arDX, dyCm: arDY,
                                          shelfHeightM: shelfHeight3D, note: arNote)
                        arSaved = ARCheckLog.count
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: { Text("记录偏移").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent)
                    .disabled(arPositionNow == nil)
                }
                if arSaved > 0 || ARCheckLog.count > 0 {
                    ShareLink("导出偏移记录（\(max(arSaved, ARCheckLog.count)) 条）", item: ARCheckLog.fileURL)
                }
            } header: { Text("AR 校对") }
        }
    }

    private func toggle3D() {
        if !show3D { model3D.ensure(map: canvasMap ?? StoreMap(width: store.widthCm, height: store.heightCm, shelves: [], crosses: []), shelfOffset: storeData.shelfOffset) }
        show3D.toggle()
        if show3D { sync3D(full: true); applyCamera3D() }
    }

    private func applyCamera3D() {
        guard let s = model3D.scene else { return }
        switch camera3D {
        case .follow: s.setCamera(.follow)
        case .overview: s.setCamera(.overview)
        case .top: s.setCamera(.top)
        }
    }

    /// 把当前状态推给 3D 场景。`full` = 连点位、磁场图、采集进度一起刷新。
    private func sync3D(full: Bool) {
        guard show3D else { return }
        let map = canvasMap ?? StoreMap(width: store.widthCm, height: store.heightCm, shelves: [], crosses: [])
        let s = model3D.ensure(map: map, shelfOffset: storeData.shelfOffset)
        let isSurvey = step == .survey
        s.setPose(position: isSurvey ? survey.position : engine.position,
                  headingRad: isSurvey ? survey.headingRad : engine.headingRad,
                  uncertaintyCm: isSurvey ? 0 : engine.uncertaintyCm)
        s.setTrail(isSurvey ? survey.trail : engine.trail)
        if full {
            s.setPoints(store.points, highlight: calibrationHighlight)
            model3D.updateField(store.field, signature: store.sampleCount &* 31 &+ store.validCells)
        }
        // 采集进度：建图采集页看；实时定位页也画上，能看出哪里有磁场数据
        if step != .map { model3D.updateCoverage(crosses: store.crosses, coverage: survey.coverage, force: full) }
        s.setShelfHeight(shelfHeight3D)
        s.setShelfOffset(storeData.shelfOffset)
        if camera3D == .follow { s.followAvatar() }
    }

    private var calibrationHighlight: String? {
        guard step == .advanced, engine.phase == .calibrating else { return nil }
        let pts = engine.calUsedPoints
        let i = engine.calMoving ? engine.calIndex + 1 : engine.calIndex
        return pts.indices.contains(i) ? pts[i].id : nil
    }

    // MARK: 步骤 1：地图点位

    @ViewBuilder private var mapPanel: some View {
        Section {
            if let m = storeData.map {
                row("地图尺寸", "\(Fmt.f(m.width / 100, 1)) × \(Fmt.f(m.height / 100, 1)) m")
                row("货架 / 通道", "\(m.shelves.count) / \(m.crosses.count)")
                if storeData.shelfOffset != Point2(0, 0) {
                    HStack {
                        row("货架偏移（3D 里校准）", "x \(Fmt.f(storeData.shelfOffset.x, 0))  y \(Fmt.f(storeData.shelfOffset.y, 0)) cm")
                        Button("归零") { storeData.setShelfOffset(Point2(0, 0)); storeData.logShelfOffset() }
                            .buttonStyle(.borderless)
                    }
                }
            } else {
                row("地图尺寸", "\(Fmt.f(store.widthCm / 100, 1)) × \(Fmt.f(store.heightCm / 100, 1)) m（没有货架数据）")
                Text("还没有货架和通道。在这里导入完整的门店地图 JSON，或到「门店数据」页导入。").font(.footnote).foregroundStyle(.orange)
            }
            HStack {
                Text("地图朝向（上方指向）")
                Spacer()
                TextField("例如 316", text: $mapUpText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .onSubmit { store.setMapUpBearing(Double(mapUpText.trimmingCharacters(in: .whitespaces))) }
                    .onChange(of: mapUpText) { t in
                        // 输入即保存：不用非得按键盘上的完成
                        let v = Double(t.trimmingCharacters(in: .whitespaces))
                        if let v, v >= 0, v < 360 { store.setMapUpBearing(v) } else if t.isEmpty { store.setMapUpBearing(nil) }
                    }
                Text("°")
            }
            Text("地图上方指向的罗盘方位（0 = 北，90 = 东）。填了之后，自动定位会先按这个方向猜，更快找到你；不填也能用，只是慢一些。")
                .font(.footnote).foregroundStyle(.secondary)
            NavigationLink { DataManagerView() } label: {
                Label("数据管理（会话、轨迹、网格、AR 记录）", systemImage: "externaldrive")
            }
            LoggedButton(name: "实验功能", detail: "进入") { step = .advanced } label: {
                Label("实验功能：按点位建图 / 只用计步定位", systemImage: "flask")
            }
            Stepper("3D 货架高度 \(Fmt.f(shelfHeight3D, 1)) m", value: $shelfHeight3D, in: 0.8...3.0, step: 0.2)
                .onChange(of: shelfHeight3D) { _ in sync3D(full: false) }
            Text("右上角的「3D」按钮切换立体视图：单指转、双指缩放和平移。立体视图里不能定点，回到 2D 操作。")
                .font(.footnote).foregroundStyle(.secondary)
            Text(store.usesStoreMap
                 ? "地图来自「门店数据」页。长按地图空白处放点（按住不动约半秒再松手），点位用作起点、目标和路线建图的锚点。双指可缩放、单指拖动平移。"
                 : "还没有门店地图，现在是 10×10 m 测试区。长按方格图空白处放点，点位按编号连线。")
                .font(.footnote).foregroundStyle(.secondary)
            LoggedButton(name: "导入地图", detail: "JSON") { showImporter = true } label: {
                Label("导入地图 JSON（网页编辑器导出的）", systemImage: "square.and.arrow.down")
            }
            if let m = importMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
            if FileManager.default.fileExists(atPath: MagMapStore.fileURL.path), !store.points.isEmpty {
                ShareLink("导出地图（含点位和磁场数据）", item: MagMapStore.fileURL)
            }
        } header: {
            Text("地图 \(Int(store.widthCm / 100)) × \(Int(store.heightCm / 100)) m"
                 + (store.usesStoreMap ? "，\(store.crosses.count) 条通道" : ""))
        }

        Section {
            if store.points.isEmpty {
                Text("还没有点位。").foregroundStyle(.secondary)
            }
            ForEach(store.points, id: \.id) { p in
                HStack {
                    Text("点位 \(p.id)").fontWeight(.semibold)
                    Spacer()
                    Text("x \(Int(p.x))  y \(Int(p.y)) cm").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .onDelete { idx in
                for i in idx.sorted(by: >) where store.points.indices.contains(i) { store.deletePoint(id: store.points[i].id) }
            }
            if !store.points.isEmpty {
                Button("清空全部点位", role: .destructive) { confirmClearPoints = true }
                    .confirmationDialog("清空全部点位？校准数据保留。", isPresented: $confirmClearPoints, titleVisibility: .visible) {
                        Button("清空", role: .destructive) { store.clearPoints() }
                    }
            }
        } header: { Text("点位 \(store.points.count)（左滑删除）") }
    }

    // MARK: 建图采集

    @ViewBuilder private var surveyPanel: some View {
        let rec = survey.recorder
        Section {
            if !survey.isRunning {
                if !store.usesStoreMap {
                    Text("建图采集需要门店地图：先到「门店数据」页导入地图。").foregroundStyle(.orange)
                }
                TextField("备注：保护壳 / 手持姿态 / 营业状态", text: $surveyNote)
                    .autocorrectionDisabled()
                Toggle("LiDAR 实景扫描（结束时导出网格，文件较大）", isOn: $survey.scanMesh)
                    .disabled(!ARKitLogger.supportsMesh)
                if store.field != nil {
                    Toggle("同时测地磁定位精度", isOn: $survey.evaluate)
                }
                bigButton("开始建图采集", name: "建图·开始") { survey.start(note: surveyNote) }
                    .disabled(!store.usesStoreMap)
            } else {
                Text(surveyInstruction).font(.callout)
                if survey.stage == .needPosition && survey.canUseShadow {
                    bigButton("自动定位起点（不用长按）", name: "建图·自动起点") { survey.startAutoLocate() }
                        .tint(.indigo)
                }
                if let s = survey.shadowStatus { Text(s).font(.footnote).foregroundStyle(.indigo) }
                if survey.position != nil && survey.stage != .needPosition && survey.stage != .autoLocating {
                    bigButton(survey.headingEditing ? "确定朝向" : "设朝向", name: "建图·朝向") { survey.toggleHeadingEdit() }
                }
                bigButton("结束采集", name: "建图·结束") { survey.stop() }.tint(.red)
            }
            if let err = survey.lastError { Text(err).font(.footnote).foregroundStyle(.red) }
        } header: { Text("建图采集") } footer: {
            if !survey.isRunning {
                Text("手机保持竖着、摄像头朝前下方（像 AR 那样）。起点长按定点、设朝向、直走 1.5 m 就行；途中长按修正是可选的（软件会自动把轨迹贴到通道上）。采完在下面「生成磁场图」一键生成。")
            }
        }

        if survey.isRunning {
            Section("状态") {
                HStack {
                    Text("ARKit 跟踪")
                    Spacer()
                    Text(survey.trackingState == 2 ? "正常" : (survey.trackingState == 1 ? "受限" : "不可用"))
                        .fontWeight(.semibold)
                        .foregroundStyle(survey.trackingState == 2 ? .green : .red)
                }
                HStack {
                    Text("磁场精度")
                    Spacer()
                    Text(Self.accuracyText(rec.magAccuracy)).fontWeight(.semibold)
                        .foregroundStyle(rec.magAccuracy >= 2 ? .green : .orange)
                }
                row("原始磁力计", "\(rec.magRawHz) Hz · IMU \(rec.imuHz) Hz")
                HStack {
                    Text("步行速度")
                    Spacer()
                    Text("\(Fmt.f(survey.speedMS, 1)) m/s").fontWeight(.semibold)
                        .foregroundStyle(survey.speedMS > SurveyEngine.maxSpeedMS ? .red : .primary)
                }
                if survey.lowSampleRate {
                    Text("传感器采样率只有 \(rec.imuHz) Hz（要 \(SurveyEngine.minImuHz) Hz 以上），这段不算采集进度。保持 App 在前台、别开别的定位功能。")
                        .font(.footnote).foregroundStyle(.red)
                }
                if survey.speedMS > SurveyEngine.maxSpeedMS {
                    Text("走太快了，这段不算采集进度。正常步速（约 1 m/s）就好。").font(.footnote).foregroundStyle(.red)
                }
                row("已走 / 距上次修正", "\(Int(survey.totalWalkedM)) m / \(Int(survey.walkedSinceAnchorM)) m")
                row("修正次数 / 自动贴通道", "\(survey.anchorCount) / \(survey.lockFixes)")
                if survey.evaluate {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("地磁定位精度（采集轨迹当参考）").font(.footnote.bold())
                        Text(survey.evalSummary ?? "开始走之后显示").font(.footnote.monospacedDigit())
                    }
                }
                Toggle("自动贴通道（实时）", isOn: $survey.corridorLock)
                if let p = survey.position, let todo = survey.coverage.nearestTodo(from: p) {
                    row("最近没采完", "\(todo.code) · \(Int(todo.distanceM)) m" + (todo.oneWay ? " · 差一个方向" : ""))
                        .font(.footnote)
                }
                if let n = survey.sessionName { row("会话", n).font(.footnote) }
                if survey.walkedSinceAnchorM > SurveyEngine.anchorEveryM && !survey.corridorLock {
                    Text("已经走了 \(Int(SurveyEngine.anchorEveryM)) m 以上没修正。可以在下一个路口长按修正一次（可选）。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }

        if !survey.isRunning {
            Section {
                if mapService.items.isEmpty {
                    Text("还没有建图采集会话。").foregroundStyle(.secondary)
                }
                ForEach(mapService.items) { it in
                    Toggle(isOn: Binding(get: { mapService.selected.contains(it.id) },
                                         set: { on in if on { mapService.selected.insert(it.id) } else { mapService.selected.remove(it.id) } })) {
                        VStack(alignment: .leading) {
                            Text(it.id).font(.footnote.monospaced())
                            Text(ByteCountFormatter.string(fromByteCount: it.sizeBytes, countStyle: .file) + (it.hasMesh ? " · 含 LiDAR 网格" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                bigButton(mapService.running ? "正在生成……" : "用选中的会话生成磁场图并启用", name: "建图·手机生成") {
                    mapService.build(crosses: store.crosses, widthCm: store.widthCm, heightCm: store.heightCm)
                }
                .disabled(mapService.running || mapService.selected.isEmpty || !store.usesStoreMap)
                ForEach(mapService.lines, id: \.self) { Text($0).font(.footnote) }
                if let e = mapService.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
            } header: { Text("生成磁场图（手机上）") } footer: {
                Text("会自动把采集轨迹贴到通道中心线上，途中没长按修正也能用；用原始磁力计减偏置，不受系统重新校准影响。同一块区域多采几次、都选上，地图更完整。电脑上的 tools/magmap.py 仍可用来做质检。")
            }
        }

        if !survey.isRunning, let dir = survey.lastSessionDir {
            Section {
                Text(dir.lastPathComponent).font(.footnote.monospaced())
                if let url = exportURL {
                    ShareLink("导出这次会话（zip）", item: url)
                } else {
                    bigButton("打包上次采集的会话", name: "建图·打包") {
                        do { exportURL = try SessionsView.zip(dir); exportError = nil }
                        catch { exportError = "打包失败：\(error.localizedDescription)" }
                    }
                }
                if let e = exportError { Text(e).font(.footnote).foregroundStyle(.red) }
            } header: { Text("导出给电脑建图") } footer: {
                Text("导出的 zip 用隔空投送或「文件」发到电脑，在电脑上运行 tools/magmap.py，生成磁场图后再导入这里。也可以在「采集 → 历史会话」里找到所有会话。")
            }
        }

        Section {
            let total = survey.coverage.totalMeters
            let done = survey.coverage.coveredMeters
            row("已覆盖（双向算满）", "\(Int(done)) / \(Int(total)) m")
            ProgressView(value: total > 0 ? done / total : 0)
            let oneWay = survey.coverage.oneWayMeters
            if oneWay > 0 {
                row("只走了一个方向", "\(Int(oneWay)) m").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                legendRow(color: .secondary.opacity(0.5), dashed: false, band: false, text: "淡灰细线：还没走")
                legendRow(color: .orange, dashed: false, band: true, text: "橙色：只走了一个方向，要反方向再走一遍")
                legendRow(color: .green, dashed: false, band: true, text: "绿带 + 绿色实线：双向采完，还是孤立的一段")
                legendRow(color: .primary, dashed: true, band: true, text: "绿带 + 黑色虚线：双向采完，已和别的路段关联")
            }
            .font(.footnote)
            if !survey.isRunning {
                Button("清空采集进度", role: .destructive) { confirmResetCoverage = true }
                    .confirmationDialog("清空采集进度？已录的会话文件不受影响。", isPresented: $confirmResetCoverage, titleVisibility: .visible) {
                        Button("清空", role: .destructive) { survey.resetCoverage() }
                    }
            }
        } header: { Text("采集进度") }
    }

    /// 采集进度图例的一行：一小段示意线 + 说明。
    private func legendRow(color: Color, dashed: Bool, band: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if band {
                    Capsule().fill((color == .primary ? Color.green : color).opacity(0.3)).frame(width: 34, height: 10)
                }
                Path { p in p.move(to: CGPoint(x: 0, y: 5)); p.addLine(to: CGPoint(x: 34, y: 5)) }
                    .stroke(color, style: StrokeStyle(lineWidth: band ? 2 : 1, dash: dashed ? [5, 4] : []))
                    .frame(width: 34, height: 10)
            }
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var surveyInstruction: String {
        switch survey.stage {
        case .needPosition: return "长按地图：我现在在这里。找一个路口或已知点位站着。已经有磁场图的区域也可以点「自动定位起点」直接走。"
        case .autoLocating: return "沿采集过的通道正常往前走，地磁定位成功后会自动设好起点和方向（震动提示）。想手动也可以随时长按地图。"
        case .needHeading: return "点「设朝向」（或双击地图），在地图上点或拖动，让橙色箭头指向你要走的方向，再点「确定朝向」（或再双击）。"
        case .aligning: return "朝箭头方向直线走 1.5 m，App 会自动对齐 ARKit 轨迹。"
        case .tracking: return "沿通道走。长按修正是可选的：到路口时修一下更准，不修也能建图（会自动贴到通道上）。"
        case .idle: return ""
        }
    }

    // MARK: 实时定位：校准传感器 → 长按定点 → 双击设朝向 → 走

    @ViewBuilder private var livePanel: some View {
        if engine.phase != .live {
            Section {
                Text("1. 打开传感器（手机竖着拿，摄像头朝前）。\n2. 不知道在哪：点「自动定位」，沿通道走 10～20 米。\n   知道在哪：长按地图定点，点「设朝向」让箭头指向前方再确定。\n3. 走起来，蓝点跟着动；没把握时不显示，丢了会变灰冻结。")
                    .font(.footnote).foregroundStyle(.secondary)
                bigButton("打开传感器，开始", name: "实时·开始") { engine.startLive() }
                    .disabled(engine.phase != .idle)
                DisclosureGroup("设置（默认就能用）") {
                    Toggle("视觉里程计（摄像头 + ARKit，取代计步）", isOn: $engine.useVisualOdometry)
                    Toggle("地磁纠偏（需要已有磁场数据）", isOn: $engine.useMagCorrection)
                        .disabled(store.field == nil)
                    Picker("激光雷达测货架距离", selection: $engine.depthMode) {
                        ForEach(DepthMode.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!ARKitLogger.supportsLiDAR)
                    Toggle("用计步器的距离校正步长", isOn: $engine.usePedometerScale)
                    Toggle("用罗盘修正航向", isOn: $engine.useCompassHeading)
                }
                if store.field == nil {
                    Text("还没有磁场图：只能靠视觉里程计推算，没有地磁纠偏。先去「采集」页采集并生成磁场图。")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if store.field != nil && store.usesStoreMap {
                    Text("已有磁场地图：打开传感器后，可以用「自动定位」，不用手动定点。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("实时定位") } footer: {
                Text("视觉里程计要手机竖着拿、摄像头朝前，耗电发热，丢跟踪时自动退回计步。激光雷达「只记录」不影响定位，只把测到的左右货架距离存进文件，用来和地图核对；核对没问题再选「参与定位」。罗盘在钢货架旁常偏几十度，默认关闭。")
            }
        } else {
            Section {
                HStack {
                    Text("磁场精度")
                    Spacer()
                    Text(Self.accuracyText(engine.magAccuracy))
                        .fontWeight(.semibold)
                        .foregroundStyle(engine.magAccuracy >= 2 ? .green : (engine.magAccuracy == 1 ? .orange : .red))
                }
                row("步数", "\(engine.stepCount)")
                if engine.magAccuracy < 2 {
                    Text("拿手机在空中画几次 8 字，直到精度变「高」。原地踏几步，看步数会不会增加。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("① 传感器") }

            Section("传感器状态") {
                HStack {
                    Text("磁场可信度")
                    Spacer()
                    Text("\(Int((engine.magTrust * 100).rounded()))%").fontWeight(.semibold)
                        .foregroundStyle(engine.magTrust >= 0.8 ? .green : (engine.magTrust > 0 ? .orange : .red))
                }
                row("持握", engine.posture.title)
                if !engine.magSourceText.isEmpty { row("磁场来源", engine.magSourceText).font(.footnote) }
                if engine.useVisualOdometry {
                    HStack {
                        Text("视觉里程计")
                        Spacer()
                        Text(visualOdometryText).fontWeight(.semibold)
                            .foregroundStyle(engine.vioAligned ? .green : (engine.vioTracking == 2 ? .orange : .secondary))
                    }
                    if engine.isTracking && !engine.posture.suitsCamera {
                        Text("手机太平或反扣，摄像头看不到前方，视觉里程计会丢跟踪。请竖起一点，摄像头朝前。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                if !engine.lateralText.isEmpty { row("货架距离（激光雷达）", engine.lateralText) }
                if let r = engine.pedometerRatio { row("计步器 / 惯导距离", Fmt.f(r, 2)) }
                if !engine.activityText.isEmpty { row("运动类型", engine.activityText) }
                if engine.cartSuspected {
                    Text("在移动但没有脚步，像是推着车。计步推算会偏短，定位精度下降。").font(.footnote).foregroundStyle(.orange)
                }
                if engine.thermal == .serious || engine.thermal == .critical {
                    Text("手机发热，视觉里程计可能降频。可以停一会儿，或关掉激光雷达。").font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                if !engine.isTracking && store.field != nil && store.usesStoreMap && engine.position == nil {
                    bigButton("自动定位（不知道我在哪）", name: "实时·自动定位") { engine.startColdSearch() }
                }
                Text(liveInstruction).font(.callout)
                if let t = engine.locStateText {
                    Text(t).font(.callout.weight(.semibold))
                        .foregroundStyle(engine.locState == .lost ? .orange : .blue)
                }
                if let p = engine.position {
                    row("位置", "x \(Int(p.x))  y \(Int(p.y)) cm")
                    row("朝向", "\(Int((engine.headingRad * 180 / Double.pi).rounded()))°")
                }
                if engine.isTracking && !engine.searching {
                    row("不确定度", "± \(Int(engine.uncertaintyCm)) cm")
                }
                if engine.position != nil && !engine.searching {
                    // 双击不好用时的备用：用按钮开始 / 确定朝向
                    bigButton(engine.headingEditing ? "确定朝向" : (engine.isTracking ? "重设朝向" : "设朝向"),
                              name: "实时·朝向") { engine.toggleHeadingEdit() }
                }
                if engine.searching, let e = engine.estimate {
                    row("搜索中", "置信度 \(Int((e.confidence * 100).rounded()))%")
                }
                bigButton("停止", name: "实时·停止") { engine.stopLive() }
                    .tint(.red)
            } header: { Text(engine.isTracking ? "③ 走" : "② 定点与朝向") }

            if engine.isTracking {
                navSection

                Section {
                    if engine.checks.isEmpty {
                        Text("走到一个你确定的位置，长按地图把点拉过去，这里会记下拉之前偏了多少。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(engine.checks.suffix(8).reversed()) { c in
                        HStack {
                            Text(c.pointId)
                            Spacer()
                            Text("\(Int(c.errorCm)) cm").monospacedDigit()
                                .foregroundStyle(c.errorCm <= 100 ? .green : (c.errorCm <= 200 ? .orange : .red))
                        }
                    }
                    if !engine.checks.isEmpty {
                        let errs = engine.checks.map(\.errorCm)
                        row("平均 / 最大", "\(Int(errs.reduce(0, +) / Double(errs.count))) / \(Int(errs.max() ?? 0)) cm")
                    }
                    if let n = engine.trackFileName { row("轨迹文件", n).font(.footnote) }
                } header: { Text("修正记录（准不准）") }
            }
        }
    }

    private var visualOdometryText: String {
        if engine.vioTracking == 0 { return engine.isTracking ? "不可用" : "定点后启动" }
        if engine.vioAligned { return "已对齐，在用" }
        if engine.vioTracking == 2 { return "对齐中 \(Int(engine.vioProgress * 100))%（直走 1.5 m）" }
        return "跟踪受限，用计步顶上"
    }

    private var liveInstruction: String {
        if engine.searching { return "正在找你在哪：沿通道直行 20～30 米，不要原地转圈。找到后地图上会出现蓝点。" }
        if engine.position == nil { return "长按地图：我现在在这里（离点位 50 cm 内会自动吸附到点位）。" }
        if engine.headingEditing { return "在地图上点或拖动，让橙色箭头指向你面朝的方向，然后点「确定朝向」（或再双击地图）。" }
        if !engine.isTracking { return "点「设朝向」（或双击地图），开始设朝向。" }
        return "走起来。到了确定的位置可以长按修正，双击可以重新设朝向。"
    }

    private static func accuracyText(_ a: Int) -> String {
        switch a {
        case 2: return "高"
        case 1: return "中"
        case 0: return "低"
        default: return "未校准"
        }
    }

    @ViewBuilder private var navSection: some View {
        Section {
            // 搜货架编号，沿通道导航
            TextField("货架编号，例如 Shelf-012", text: $shelfQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            ForEach(shelfMatches, id: \.code) { s in
                Button {
                    engine.navigate(to: Point2(s.x, s.y), label: s.code)
                    shelfQuery = ""
                } label: {
                    HStack { Text(s.code).font(.callout.monospaced()); Spacer(); Image(systemName: "location.north.line") }
                }
            }
            if let label = engine.navLabel {
                HStack(spacing: 16) {
                    Image(systemName: Self.turnSymbol(engine.navHint?.direction))
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(engine.navHint == nil ? .green : .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(navText).font(.headline)
                        Text(label).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("结束") { engine.stopNavigation() }.buttonStyle(.bordered)
                }
            }
            // 点位导航（直线方向）
            Picker("到点位（直线方向）", selection: Binding(get: { engine.targetId ?? "" },
                                             set: { engine.setTarget($0.isEmpty ? nil : $0) })) {
                Text("无").tag("")
                ForEach(store.points, id: \.id) { Text("点位 \($0.id)").tag($0.id) }
            }
            if engine.targetId != nil {
                Toggle("到达后自动切到下一个点位", isOn: $engine.autoAdvance)
            }
            if let h = engine.hint {
                HStack(spacing: 16) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(h.arrived ? .green : .blue)
                        .rotationEffect(.radians(-h.turnRad))
                    VStack(alignment: .leading) {
                        Text(h.arrived ? "已到达点位 \(h.targetId)" : turnText(h.turnRad))
                            .font(.headline)
                        Text("距点位 \(h.targetId) \(Fmt.f(h.distanceCm / 100, 1)) m")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("导航") } footer: {
            Text("搜货架编号会沿通道规划路线（地图上绿线），按转弯提示走；到点位是直线方向，只用来测试。")
        }
    }

    private var shelfMatches: [ShelfRect] {
        let q = shelfQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2, let m = storeData.map else { return [] }
        return Array(m.shelves.filter { $0.kind == .standard && $0.code.lowercased().contains(q) }.prefix(8))
    }

    private var navText: String {
        guard let h = engine.navHint else { return "已到达" }
        let remain = "还有 \(Fmt.f(h.remainingDistance / 100, 0)) m"
        guard let turn = h.distanceToNextTurn, h.direction != .straight else { return "直走，" + remain }
        let dir: String
        switch h.direction {
        case .left: dir = "左转"
        case .right: dir = "右转"
        case .uturn: dir = "掉头"
        case .straight: dir = "直走"
        }
        return "前方 \(Fmt.f(turn / 100, 0)) m \(dir)，" + remain
    }

    private static func turnSymbol(_ d: TurnDirection?) -> String {
        switch d {
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .uturn: return "arrow.uturn.down"
        case .straight: return "arrow.up"
        case nil: return "checkmark.circle"
        }
    }

    // MARK: 高级：按点位走一遍建磁场图（地磁校准）

    @ViewBuilder private var calibratePanel: some View {
        Section {
            row("点位", "\(store.points.count) 个")
            row("已累计样本", "\(store.sampleCount)")
            row("有效格子", store.field == nil ? "无" : "\(store.validCells) / \(Int(store.widthCm / 50) * Int(store.heightCm / 50))")
            if let f = engine.feature {
                row("实时磁场 |B| / Bz / Bh",
                    "\(Fmt.f(f.total, 1)) / \(Fmt.f(f.vertical, 1)) / \(Fmt.f(f.horizontal, 1)) µT")
            }
        } header: { Text("状态") }

        Section {
            if engine.phase == .calibrating {
                let pts = engine.calUsedPoints
                let here = pts.indices.contains(engine.calIndex) ? pts[engine.calIndex].id : "?"
                if engine.calMoving {
                    let next = pts.indices.contains(engine.calIndex + 1) ? pts[engine.calIndex + 1].id : "?"
                    Text("正在走向点位 \(next)，保持匀速、手持看屏。").font(.footnote).foregroundStyle(.secondary)
                    bigButton("到达点位 \(next)", name: "校准·到达") { engine.calibrationArrive() }
                } else if engine.calibrationFinishable {
                    Text("已到最后一个点位 \(here)。").font(.footnote).foregroundStyle(.secondary)
                    bigButton("完成这一遍（\(engine.calSampleCount) 个样本）", name: "校准·完成") {
                        engine.finishCalibration(keep: true)
                    }
                } else {
                    let next = pts.indices.contains(engine.calIndex + 1) ? pts[engine.calIndex + 1].id : "?"
                    Text("站在点位 \(here) 上，站稳后点按钮，再走向点位 \(next)。").font(.footnote).foregroundStyle(.secondary)
                    bigButton("离开点位 \(here)，走向点位 \(next)", name: "校准·离开") { engine.calibrationDepart() }
                }
                LoggedButton(name: "校准·放弃", role: .destructive) { engine.finishCalibration(keep: false) } label: {
                    Text("放弃这一遍")
                }
            } else {
                bigButton(store.sampleCount == 0 ? "开始校准（先站到点位 1）" : "再校准一遍", name: "校准·开始") {
                    engine.startCalibration()
                }
                .disabled(store.points.count < 2)
                if store.sampleCount > 0 {
                    Button("清空校准数据", role: .destructive) { confirmClearCal = true }
                        .confirmationDialog("清空已累计的磁场数据？点位保留。", isPresented: $confirmClearCal, titleVisibility: .visible) {
                            Button("清空", role: .destructive) { store.clearCalibration() }
                        }
                }
            }
        } header: { Text("建磁场图（按点位走一遍）") } footer: {
            Text("按编号顺序沿点位之间的直线走。建议正反各走一遍。保持看屏姿势，不要戴磁吸壳或支架。校准和定位用同一姿势才准。")
        }
    }

    // MARK: 高级：用磁场地图定位（粒子滤波）

    @ViewBuilder private var locatePanel: some View {
        Section {
            if store.field == nil {
                Text("还没有磁场数据，请先完成地磁校准。").foregroundStyle(.secondary)
            } else if engine.phase == .localizing {
                bigButton("停止定位", name: "地磁·停止") { engine.stopLocalizing() }
                    .tint(.red)
            } else {
                Picker("起点", selection: $startId) {
                    ForEach(store.points, id: \.id) { Text("点位 \($0.id)").tag($0.id) }
                }
                .disabled(unknownStart)
                Toggle("未知起点（测试冷启动）", isOn: $unknownStart)
                bigButton("开始定位", name: "地磁·开始") {
                    engine.startLocalizing(startId: startId.isEmpty ? store.points.first?.id : startId,
                                           unknownStart: unknownStart)
                }
            }
        } header: { Text("用磁场图定位") } footer: {
            if engine.phase != .localizing {
                Text("已知起点：站在所选点位上，面朝下一个点位（最后一个点位则面朝上一个）再点开始。未知起点：沿通道正常走 10～20 米，找到之前不显示位置。开了视觉里程计会准很多，手机竖着拿、摄像头朝前。")
            }
        }

        if engine.phase == .localizing {
            if let t = engine.locStateText {
                Section { Text(t).font(.callout.weight(.semibold)).foregroundStyle(engine.locState == .lost ? .orange : .blue) }
            }
            Section("实时") {
                if let p = engine.position { row("位置", "x \(Int(p.x))  y \(Int(p.y)) cm") }
                if let e = engine.estimate {
                    row("不确定度", "± \(Int(e.uncertaintyCm)) cm")
                    row("置信度", "\(Int((e.confidence * 100).rounded()))%")
                }
                row("步数", "\(engine.stepCount)")
                if let f = engine.feature {
                    row("磁场 |B| / Bz / Bh", "\(Fmt.f(f.total, 1)) / \(Fmt.f(f.vertical, 1)) / \(Fmt.f(f.horizontal, 1))")
                }
                if let n = engine.trackFileName { row("轨迹文件", n).font(.footnote) }
            }

            navSection

            Section {
                Picker("我现在站在", selection: $checkId) {
                    Text("选择点位").tag("")
                    ForEach(store.points, id: \.id) { Text("点位 \($0.id)").tag($0.id) }
                }
                bigButton("记录这一刻的误差", name: "地磁·验证") {
                    if !checkId.isEmpty { engine.recordCheck(pointId: checkId) }
                }
                .disabled(checkId.isEmpty)
                ForEach(engine.checks.suffix(8).reversed()) { c in
                    HStack {
                        Text("点位 \(c.pointId)")
                        Spacer()
                        Text("\(Int(c.errorCm)) cm").monospacedDigit()
                            .foregroundStyle(c.errorCm <= 100 ? .green : (c.errorCm <= 200 ? .orange : .red))
                    }
                }
                if engine.checks.count > 0 {
                    let errs = engine.checks.map(\.errorCm)
                    row("平均 / 最大", "\(Int(errs.reduce(0, +) / Double(errs.count))) / \(Int(errs.max() ?? 0)) cm")
                }
            } header: { Text("验证准不准") } footer: {
                Text("走到某个点位上站稳，选它再点按钮，App 会记下当时估计位置与真实位置的差，并写进轨迹文件。")
            }
        }
    }

    // MARK: 小部件

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func bigButton(_ title: String, name: String, action: @escaping () -> Void) -> some View {
        LoggedButton(name: name, detail: title, action: action) {
            Text(title).frame(maxWidth: .infinity).fontWeight(.semibold)
        }
        .buttonStyle(.borderedProminent)
    }

    private func turnText(_ rad: Double) -> String {
        let deg = Int((abs(rad) * 180 / Double.pi).rounded())
        if deg < 15 { return "直行" }
        return (rad > 0 ? "向左转 " : "向右转 ") + "\(deg)°"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            importMessage = "导入失败：\(e.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try store.importMap(data)
                // 导入的是完整门店地图（有货架或通道）时，同时作为门店数据的地图，画面上才有货架
                var withShelves = ""
                if let m = try? StoreDataLoader.loadMap(data), !(m.shelves.isEmpty && m.crosses.isEmpty) {
                    try storeData.save(data, as: .map)
                    store.adopt(map: storeData.map)
                    withShelves = "，货架 \(m.shelves.count)、通道 \(m.crosses.count)"
                }
                startId = store.points.first?.id ?? ""
                importMessage = "已导入 \(store.points.count) 个点位" + withShelves + (store.field == nil ? "" : "，含磁场数据")
            } catch {
                importMessage = "导入失败：\(error)"
                AppLog.e("地磁", "导入失败：\(error)")
            }
        }
    }
}
