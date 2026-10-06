import HPASSKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 页面

/// 地磁定位：地图点位 → 实时定位（定点即走）；高级里保留按点位建磁场图和粒子滤波定位。
@MainActor
struct MagneticView: View {
    enum Step: String, CaseIterable, Identifiable {
        case map = "地图点位", live = "实时定位", survey = "建图采集", advanced = "高级"
        var id: String { rawValue }
    }

    @StateObject private var engine = MagneticEngine()
    @StateObject private var survey = SurveyEngine()
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("步骤", selection: $step) {
                    ForEach(Step.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .disabled(engine.phase != .idle || survey.isRunning)
                .onChange(of: step) { AppLog.tap("地磁·步骤", $0.rawValue) }

                canvas
                    .padding(.horizontal)
                    .frame(height: min(max(UIScreen.main.bounds.height * 0.42, 260), 420))

                Form {
                    if let err = engine.lastError ?? store.lastError {
                        Section { Text(err).foregroundStyle(.red) }
                    }
                    switch step {
                    case .map: mapPanel
                    case .live: livePanel
                    case .survey: surveyPanel
                    case .advanced:
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
            if startId.isEmpty { startId = store.points.first?.id ?? "" }
        }
        .onChange(of: storeData.map?.crosses.count) { _ in store.adopt(map: storeData.map) }
        .onAppear { survey.coverage.configure(crosses: store.crosses) }
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
                         showFingerprints: false,
                         markPoints: store.points,
                         targetId: showsTrack && !isSurvey ? engine.targetId : nil,
                         highlightId: calibrationHighlight,
                         gridCm: storeData.map == nil ? 100 : nil,
                         crossCoverage: isSurvey ? survey.coverage.fractions : [],
                         showHeading: isSurvey ? (survey.stage != .needPosition)
                             : (!live || engine.isTracking || engine.headingEditing),
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
            } else {
                row("地图尺寸", "\(Fmt.f(store.widthCm / 100, 1)) × \(Fmt.f(store.heightCm / 100, 1)) m（没有货架数据）")
                Text("还没有货架和通道。在这里导入完整的门店地图 JSON，或到「门店数据」页导入。").font(.footnote).foregroundStyle(.orange)
            }
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
                bigButton("开始建图采集", name: "建图·开始") { survey.start(note: surveyNote) }
                    .disabled(!store.usesStoreMap)
            } else {
                Text(surveyInstruction).font(.callout)
                bigButton("结束采集", name: "建图·结束") { survey.stop() }.tint(.red)
            }
            if let err = survey.lastError { Text(err).font(.footnote).foregroundStyle(.red) }
        } header: { Text("建图采集") } footer: {
            if !survey.isRunning {
                Text("手机保持竖着、摄像头朝前下方（像 AR 那样）。每走约 30 m，或到路口，长按地图修正一次位置。录制的是全部传感器 + ARKit 位姿，回电脑用 tools/magmap.py 建磁场图。")
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
                row("已走 / 距上次修正", "\(Int(survey.totalWalkedM)) m / \(Int(survey.walkedSinceAnchorM)) m")
                row("修正次数", "\(survey.anchorCount)")
                if let n = survey.sessionName { row("会话", n).font(.footnote) }
                if survey.walkedSinceAnchorM > SurveyEngine.anchorEveryM {
                    Text("已经走了超过 \(Int(SurveyEngine.anchorEveryM)) m，找个路口或已知点长按地图修正。")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
        }

        Section {
            let total = survey.coverage.totalMeters
            let done = survey.coverage.coveredMeters
            row("已覆盖（双向算满）", "\(Int(done)) / \(Int(total)) m")
            ProgressView(value: total > 0 ? done / total : 0)
            Text("地图上通道颜色：红 = 没走，橙 = 走了一部分或只走了一个方向，绿 = 双向都走完。")
                .font(.footnote).foregroundStyle(.secondary)
            if !survey.isRunning {
                Button("清空采集进度", role: .destructive) { confirmResetCoverage = true }
                    .confirmationDialog("清空采集进度？已录的会话文件不受影响。", isPresented: $confirmResetCoverage, titleVisibility: .visible) {
                        Button("清空", role: .destructive) { survey.resetCoverage() }
                    }
            }
        } header: { Text("采集进度") }
    }

    private var surveyInstruction: String {
        switch survey.stage {
        case .needPosition: return "长按地图：我现在在这里。找一个路口或已知点位站着。"
        case .needHeading: return "双击地图，然后在地图上点或拖动，让橙色箭头指向你要走的方向，再双击确定。"
        case .aligning: return "朝箭头方向直线走 1.5 m，App 会自动对齐 ARKit 轨迹。"
        case .tracking: return "沿通道走。到路口、或约 30 m 一次，长按地图修正位置。要换方向时双击重设朝向。"
        case .idle: return ""
        }
    }

    // MARK: 实时定位：校准传感器 → 长按定点 → 双击设朝向 → 走

    @ViewBuilder private var livePanel: some View {
        if engine.phase != .live {
            Section {
                Text("1. 打开传感器，拿手机在空中画 8 字，直到磁场精度变成「高」。\n2. 长按地图：我现在在这里。\n3. 双击地图开始设朝向，在地图上点或拖动让箭头指向你面朝的方向，再双击确定。\n4. 走起来，看地图上的点跟着动。")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("用罗盘修正航向", isOn: $engine.useCompassHeading)
                Toggle("地磁纠偏（需要已有磁场数据）", isOn: $engine.useMagCorrection)
                    .disabled(store.field == nil)
                bigButton("打开传感器，开始", name: "实时·开始") { engine.startLive() }
                    .disabled(engine.phase != .idle)
                if store.field != nil && store.usesStoreMap {
                    Text("已有磁场地图：打开传感器后，可以用「自动定位」，不用手动定点。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("实时定位") } footer: {
                Text("罗盘在钢货架旁常偏几十度，默认关闭，只用陀螺仪推算航向。")
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

            Section {
                if !engine.isTracking && store.field != nil && store.usesStoreMap && engine.position == nil {
                    bigButton("自动定位（不知道我在哪）", name: "实时·自动定位") { engine.startColdSearch() }
                }
                Text(liveInstruction).font(.callout)
                if let p = engine.position {
                    row("位置", "x \(Int(p.x))  y \(Int(p.y)) cm")
                    row("朝向", "\(Int((engine.headingRad * 180 / Double.pi).rounded()))°")
                }
                if engine.isTracking && !engine.searching {
                    row("不确定度", "± \(Int(engine.uncertaintyCm)) cm")
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

    private var liveInstruction: String {
        if engine.searching { return "正在找你在哪：沿通道直行 20～30 米，不要原地转圈。找到后地图上会出现蓝点。" }
        if engine.position == nil { return "长按地图：我现在在这里（离点位 50 cm 内会自动吸附到点位）。" }
        if engine.headingEditing { return "在地图上点或拖动，让橙色箭头指向你面朝的方向，然后双击确定。" }
        if !engine.isTracking { return "双击地图，开始设朝向。" }
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
            Picker("目标", selection: Binding(get: { engine.targetId ?? "" },
                                             set: { engine.setTarget($0.isEmpty ? nil : $0) })) {
                Text("无").tag("")
                ForEach(store.points, id: \.id) { Text("点位 \($0.id)").tag($0.id) }
            }
            Toggle("到达后自动切到下一个点位", isOn: $engine.autoAdvance)
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
        } header: { Text("导航") }
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
                Text("已知起点：站在所选点位上，面朝下一个点位（最后一个点位则面朝上一个）再点开始。")
            }
        }

        if engine.phase == .localizing {
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
