import HPASSKit
import SwiftUI

/// 「建图」Tab：分步引导采集（准备 → 定起点 → 采集 → 完成）。
///
/// 用 `AppEngines.shared.survey`，采集逻辑不变；只把原来混在一个长表单里的东西拆成清楚的步骤，
/// 原始数值（采样率、跟踪状态、修正次数……）留在「设置 → 开发者 → 高级控制台」。
@MainActor
struct MappingView: View {
    @Binding var tab: AppTab

    @ObservedObject private var survey = AppEngines.shared.survey
    @ObservedObject private var store = MagMapStore.shared
    @ObservedObject private var storeData = StoreDataStore.shared
    @ObservedObject private var tel = Telemetry.shared
    @ObservedObject private var mode = AppMode.shared

    @State private var note = ""
    @State private var showOptions = false
    @State private var summary: Summary?
    @State private var startFraction: Double?
    @State private var showRoomScan = false
    @State private var confirmStop = false
    @State private var mapFollow = true

    /// 一次采集结束后的成果
    struct Summary: Equatable {
        var walkedM: Double
        var fromFraction: Double
        var toFraction: Double
        var session: String?
        var error: String?
    }

    private static let steps = ["准备", "定起点", "采集", "完成"]

    private var demo: Bool { DemoMode.isOn }

    private var stepIndex: Int {
        if summary != nil { return 3 }
        if demo { return 2 }
        switch survey.stage {
        case .idle: return 0
        case .needPosition, .autoLocating, .needHeading, .aligning: return 1
        case .tracking: return 2
        }
    }

    private var running: Bool { demo || survey.isRunning }
    private var paintFraction: Double { demo ? 0.46 : (survey.coverage.paintGrid?.fraction ?? 0) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DSStepIndicator(steps: Self.steps, current: stepIndex)
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.vertical, DS.Spacing.s)
                if let s = summary {
                    ScrollView { summaryView(s).padding(DS.Spacing.l) }
                } else if running {
                    runningView
                } else {
                    ScrollView { prepareView.padding(DS.Spacing.l) }
                }
            }
            .background(DS.Palette.background.ignoresSafeArea())
            .navigationTitle("建图")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: stepIndex)
        }
        .sheet(isPresented: $showRoomScan) { RoomScanView() }
        .onAppear { AppEngines.shared.prepareIfNeeded() }
        .onChange(of: survey.isRunning) { isRunning in
            if isRunning {
                // 从别处开始的采集（精度测试、高级控制台）也记下起始覆盖率，结束时给成果卡片
                if startFraction == nil { startFraction = survey.coverage.paintGrid?.fraction ?? 0 }
            } else {
                if startFraction != nil { finishSummary() }
                if AppEngines.shared.accuracyTestRunning {
                    AppEngines.shared.accuracyTestRunning = false
                    survey.isTestSession = false
                }
                AppEngines.shared.mapService.refresh()
            }
        }
        .onChange(of: survey.stage) { s in
            if s == .tracking { Haptics.success() }
        }
        .onChange(of: survey.position) { _ in reportTelemetry() }
    }

    // MARK: 第 1 步：准备

    @ViewBuilder private var prepareView: some View {
        VStack(spacing: DS.Spacing.l) {
            coverageCard
            checklistCard
            if !survey.coverage.zoneStatus.isEmpty { zoneCard }
            optionsCard
            Button {
                start()
            } label: {
                Label("开始建图", systemImage: "figure.walk.motion")
            }
            .buttonStyle(.dsPrimaryTint(DS.Palette.mapping))
            .disabled(!store.usesStoreMap)
            .accessibilityHint(store.usesStoreMap ? "开始采集，按提示走一遍场地" : "需要先有一张场地地图")
            if mode.developer {
                Button {
                    showRoomScan = true
                } label: {
                    Label("扫描房间生成地图（激光雷达）", systemImage: "cube.transparent")
                }
                .buttonStyle(.dsSecondaryTint(DS.Palette.mapping))
            }
        }
    }

    private var coverageCard: some View {
        DSCard(title: "这张地图的建图进度", systemImage: "map", tint: DS.Palette.mapping) {
            HStack(spacing: DS.Spacing.l) {
                ProgressRing(value: paintFraction, lineWidth: 9, tint: DS.Palette.success, label: "已覆盖")
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    if let p = survey.coverage.paintGrid {
                        MetricTile(value: "\(Int(p.paintedAreaM2))", unit: "/ \(Int(p.walkableAreaM2)) m²", label: "已走过的面积")
                    }
                    let done = survey.coverage.zoneStatus.filter(\.done).count
                    if !survey.coverage.zoneStatus.isEmpty {
                        MetricTile(value: "\(done)", unit: "/ \(survey.coverage.zoneStatus.count)", label: "已完成区域")
                    }
                }
            }
            if store.usesStoreMap {
                previewMap
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                legend
            }
        }
    }

    /// 准备页的小地图：当前覆盖情况和本次区域，不能操作
    private var previewMap: some View {
        MapCanvas(map: AppEngines.shared.canvasMap,
                  fingerprints: [],
                  showFingerprints: false,
                  paintLayer: survey.coverage.paintLayer,
                  zoneSegments: survey.coverage.zoneSegments,
                  zoneEntry: survey.coverage.zoneEntry,
                  zoneLabels: survey.coverage.zoneLabels,
                  productStyle: true,
                  showsResetButton: false,
                  accessibilitySummary: "建图进度预览，已覆盖 \(Int(paintFraction * 100))%")
            .allowsHitTesting(false)
    }

    private var legend: some View {
        HStack(spacing: DS.Spacing.l) {
            legendDot(DS.Palette.success, "已覆盖")
            legendDot(DS.Palette.info, "本机刚采")
            legendDot(Color.purple, "本次区域")
        }
        .font(.caption)
        .foregroundStyle(DS.Palette.textSecondary)
    }

    private func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(c.opacity(0.7)).frame(width: 14, height: 8)
            Text(t)
        }
        .accessibilityElement(children: .combine)
    }

    private var checklistCard: some View {
        DSCard(title: "准备", systemImage: "checklist") {
            ChecklistRow(state: store.usesStoreMap ? .ok : .missing,
                         title: store.usesStoreMap ? "已选好地图" : "还没有场地地图",
                         detail: store.usesStoreMap ? (MapLibrary.shared.active?.name ?? "当前地图")
                                                    : "先到「地图库」下载或选择一张地图")
            ChecklistRow(state: ARKitLogger.isSupported ? .ok : .warning,
                         title: "相机辅助",
                         detail: ARKitLogger.isSupported ? "手机竖着拿、摄像头朝前下方，像拍视频一样"
                                                         : "这台设备不支持，采集精度会差一些")
            ChecklistRow(state: tel.enabled ? .ok : .warning,
                         title: tel.enabled ? "采集结果会自动上传" : "未连接云端",
                         detail: tel.enabled ? "云端生成新地图后自动更新到手机" : "在「设置 → 云端连接」里打开，否则只保存在本机")
            ChecklistRow(state: .ok, title: "正常步速", detail: "约 1 米/秒，太快的路段不计入进度")
            if !store.usesStoreMap {
                Button("打开地图库") { tab = .library }
                    .buttonStyle(.dsSecondary)
            }
        }
    }

    @ViewBuilder private var zoneCard: some View {
        let cov = survey.coverage
        DSCard(title: "本次区域", systemImage: "square.dashed", tint: .purple) {
            if let z = cov.currentZoneStatus {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(z.name).font(DS.Typography.headline)
                        Text(z.done ? "已完成，不用再采" : "已覆盖 \(Int(z.fraction * 100))% · 还需约 \(minutes(z.remainingCm)) 分钟")
                            .font(.footnote).foregroundStyle(DS.Palette.textSecondary)
                    }
                    Spacer()
                    Menu {
                        ForEach(cov.zoneStatus, id: \.id) { s in
                            Button {
                                Haptics.selection()
                                cov.selectZone(s.id)
                            } label: {
                                Text("\(s.name) · \(Int(s.fraction * 100))%" + (s.done ? " · 已完成" : ""))
                            }
                        }
                        Button("按推荐重新分配") { cov.assignZone(from: survey.position) }
                    } label: {
                        Text("更换").font(.footnote.weight(.semibold))
                    }
                }
                ProgressView(value: min(z.fraction / 0.85, 1)).tint(.purple)
            } else {
                Label("全部区域都完成了", systemImage: "checkmark.seal.fill").foregroundStyle(DS.Palette.success)
            }
        }
    }

    private var optionsCard: some View {
        DSCard {
            DisclosureGroup(isExpanded: $showOptions) {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    Toggle("用蓝牙标签辅助定起点", isOn: $survey.bleBase)
                    Toggle("识别位置标识牌（相机）", isOn: $survey.readSigns)
                    Toggle("激光雷达实景扫描（文件较大）", isOn: $survey.scanMesh)
                        .disabled(!ARKitLogger.supportsMesh)
                    if store.field != nil {
                        Toggle("测试走一圈（只测精度，不参与建图）", isOn: $survey.isTestSession)
                            .onChange(of: survey.isTestSession) { on in if on { survey.evaluate = true } }
                    }
                    TextField("备注（可选），例如：手机带壳、手持", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                .font(.callout)
                .padding(.top, DS.Spacing.s)
            } label: {
                Label("采集选项", systemImage: "slider.horizontal.3").font(DS.Typography.headline)
            }
        }
    }

    // MARK: 第 2、3 步：采集中

    private var runningView: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                surveyMap
                if survey.stage == .tracking || demo {
                    warningChips.padding(DS.Spacing.m)
                }
                VStack {
                    DSIconButton(systemImage: mapFollow ? "location.fill" : "location",
                                 label: mapFollow ? "正在跟随我的位置" : "跟随我的位置",
                                 active: mapFollow) { mapFollow = true }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(DS.Spacing.m)
            }
            .frame(maxHeight: .infinity)
            runningPanel
                .padding(DS.Spacing.l)
                .background(DS.Palette.surface.ignoresSafeArea(edges: .bottom))
        }
        .confirmationDialog("结束这次采集？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("结束并保存", role: .destructive) { stop() }
            Button("继续采集", role: .cancel) {}
        }
    }

    private var surveyMap: some View {
        let surveying = survey.isRunning
        return MapCanvas(map: demo ? DemoMode.map : AppEngines.shared.canvasMap,
                         fingerprints: [],
                         trail: demo ? DemoMode.trail : survey.trail,
                         position: demo ? DemoMode.position : survey.position,
                         headingRad: demo ? DemoMode.headingRad : survey.headingRad,
                         uncertaintyCm: 0,
                         rawEstimate: survey.bleBase ? survey.bleFix?.position : nil,
                         showFingerprints: false,
                         paintLayer: survey.coverage.paintLayer,
                         paintRadiusCm: surveying ? survey.coverage.paintLayer?.radiusCm : nil,
                         nextTarget: surveying ? survey.coverage.nextUnpainted : nil,
                         laneGuides: surveying ? survey.coverage.laneGuides : [],
                         zoneSegments: survey.coverage.zoneSegments,
                         zoneEntry: survey.coverage.zoneEntry,
                         zoneLabels: survey.coverage.zoneLabels,
                         nextLane: surveying ? survey.coverage.nextLane.map { ($0.from, $0.to) } : nil,
                         showHeading: demo || survey.stage != .needPosition,
                         headingEditing: survey.headingEditing,
                         onLongPress: anchorAction,
                         onDoubleTap: surveying ? { survey.toggleHeadingEdit() } : nil,
                         onHeadingPoint: surveying ? { survey.pointHeading(toward: $0) } : nil,
                         productStyle: true,
                         follow: mapFollow && (survey.stage == .tracking || demo),
                         followAnchor: CGPoint(x: 0.5, y: 0.5),
                         onUserInteract: { mapFollow = false },
                         smooth: true,
                         accessibilitySummary: survey.position == nil ? "还没有定起点" : "采集中，已覆盖 \(Int(paintFraction * 100))%")
    }

    /// 长按：我在这里（修正位置）
    private var anchorAction: ((Point2) -> Void)? {
        guard survey.isRunning, !survey.headingEditing else { return nil }
        return { p in
            survey.anchor(at: p)
            Haptics.heavy()
        }
    }

    @ViewBuilder private var warningChips: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            if survey.speedMS > SurveyEngine.maxSpeedMS {
                StatusPill(text: "走太快了，放慢一点", systemImage: "tortoise.fill", tone: .warning)
            }
            if survey.lowSampleRate {
                StatusPill(text: "传感器采样率低，保持 App 在前台", systemImage: "waveform.path.ecg", tone: .warning)
            }
            if survey.isRunning && survey.trackingState != 2 {
                StatusPill(text: "相机看不清，摄像头朝前", systemImage: "camera.metering.unknown", tone: .warning)
            }
            if survey.recorder.magAccuracy >= 0 && survey.recorder.magAccuracy < 2 {
                StatusPill(text: "在空中画几次 8 字校准", systemImage: "infinity", tone: .info)
            }
        }
        .padding(4)
    }

    @ViewBuilder private var runningPanel: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            switch demo ? SurveyEngine.Stage.tracking : survey.stage {
            case .needPosition:
                stageHeader("站着别动，正在确定起点", "也可以把摄像头对准附近的位置标识牌，或长按地图上你所在的位置。")
                if survey.canUseShadow {
                    Button {
                        Haptics.tap()
                        survey.startAutoLocate()
                    } label: { Label("走着自动定起点", systemImage: "location.magnifyingglass") }
                    .buttonStyle(.dsPrimaryTint(DS.Palette.mapping))
                }
                if let s = survey.shadowStatus { Text(s).font(.footnote).foregroundStyle(DS.Palette.textSecondary) }
            case .autoLocating:
                HStack(spacing: DS.Spacing.m) {
                    ProgressView()
                    stageHeader("正在自动定起点", "沿已经建过图的走廊正常往前走，定好后会震动提示。")
                }
            case .needHeading:
                stageHeader("设置你面朝的方向", "在地图上点一下你正前方，橙色箭头对准后点「确定」。")
                Button(survey.headingEditing ? "确定" : "设置朝向") {
                    Haptics.tap()
                    survey.toggleHeadingEdit()
                }
                .buttonStyle(.dsPrimaryTint(DS.Palette.mapping))
            case .aligning:
                stageHeader("朝箭头方向直走 1.5 米", "App 会自动对齐相机轨迹和地图。")
            case .tracking, .idle:
                trackingMetrics
            }
            HStack(spacing: DS.Spacing.m) {
                if survey.stage == .tracking && survey.position != nil {
                    Button(survey.headingEditing ? "确定朝向" : "调整朝向") { survey.toggleHeadingEdit() }
                        .buttonStyle(.dsSecondaryTint(DS.Palette.mapping))
                }
                Button("结束采集") { confirmStop = true }
                    .buttonStyle(.dsSecondaryTint(DS.Palette.danger))
            }
            if let e = survey.lastError {
                ErrorBanner(message: e)
            }
        }
    }

    private func stageHeader(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DS.Typography.title)
            Text(detail).font(.callout).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var trackingMetrics: some View {
        let zone = survey.coverage.currentZoneStatus
        return VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.l) {
                ProgressRing(value: demo ? 0.62 : (zone?.fraction ?? paintFraction), lineWidth: 8,
                             tint: DS.Palette.success, label: zone == nil ? "全场" : "本区域")
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    HStack {
                        MetricTile(value: "\(Int(demo ? 186 : survey.totalWalkedM))", unit: "m", label: "已走")
                        MetricTile(value: Fmt.f(demo ? 0.9 : survey.speedMS, 1), unit: "m/s", label: "步速",
                                   tint: survey.speedMS > SurveyEngine.maxSpeedMS ? DS.Palette.warning : DS.Palette.textPrimary)
                    }
                    if let z = zone {
                        Text(z.done ? "这个区域完成了，可以结束" : "还需约 \(minutes(z.remainingCm)) 分钟")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(z.done ? DS.Palette.success : DS.Palette.textSecondary)
                    }
                }
            }
            if let n = survey.coverage.nextLane, let p = survey.position {
                guideRow("arrow.up.forward.circle.fill",
                         "下一段：离你 \(Int(p.distance(to: n.from) / 100)) 米，沿橙色箭头走 \(Int(n.remainingCm / 100)) 米")
            } else if let p = survey.position, let tg = survey.coverage.nextUnpainted {
                guideRow("scope", "最近还没走到的地方在 \(Int(p.distance(to: tg) / 100)) 米外（橙色圈）")
            } else if demo {
                guideRow("arrow.up.forward.circle.fill", "下一段：离你 4 米，沿橙色箭头走 22 米")
            }
            if survey.coverage.zoneEntry != nil {
                guideRow("arrow.triangle.merge", "先到紫色圈，沿已走过的路段走 10～20 米再进本区域，方便和已有数据对齐")
            }
        }
    }

    private func guideRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: icon).foregroundStyle(DS.Palette.warning).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
    }

    // MARK: 第 4 步：完成

    @ViewBuilder private func summaryView(_ s: Summary) -> some View {
        VStack(spacing: DS.Spacing.l) {
            if let e = s.error {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "这次采集没有保存好",
                               message: e, actionTitle: "重新开始", action: { summary = nil })
            } else {
                VStack(spacing: DS.Spacing.m) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DS.Palette.success)
                        .accessibilityHidden(true)
                    Text("采集完成").font(DS.Typography.hero)
                    Text(s.session.map { "已保存采集记录 \($0)" } ?? "已保存采集记录")
                        .font(.footnote).foregroundStyle(DS.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, DS.Spacing.l)
                DSCard {
                    HStack {
                        MetricTile(value: "\(Int(s.walkedM))", unit: "m", label: "本次走了")
                        MetricTile(value: "\(Int(s.fromFraction * 100))→\(Int(s.toFraction * 100))", unit: "%", label: "覆盖率",
                                   tint: DS.Palette.success)
                    }
                }
                DSCard(title: tel.enabled ? "上传" : "只保存在本机", systemImage: tel.enabled ? "icloud.and.arrow.up" : "internaldrive") {
                    Text(tel.enabled ? (tel.lastUpload ?? "正在上传…云端生成新地图后，手机上的地图会自动更新。")
                                     : "打开「设置 → 云端连接」后，以后的采集会自动上传。")
                        .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("完成") {
                    Haptics.tap()
                    summary = nil
                }
                .buttonStyle(.dsPrimaryTint(DS.Palette.mapping))
                Button("去导航试试") {
                    summary = nil
                    tab = .navigate
                }
                .buttonStyle(.dsSecondaryTint(DS.Palette.mapping))
            }
        }
    }

    // MARK: 动作

    private func minutes(_ remainingCm: Double) -> Int { max(Int(remainingCm / 100 / 0.8 / 60), 1) }

    private func start() {
        Haptics.heavy()
        startFraction = survey.coverage.paintGrid?.fraction ?? 0
        survey.start(note: note)
        if !survey.isRunning {
            startFraction = nil
            Haptics.error()
        }
    }

    private func stop() {
        survey.stop()
    }

    private func finishSummary() {
        let s = Summary(walkedM: survey.totalWalkedM,
                        fromFraction: startFraction ?? 0,
                        toFraction: survey.coverage.paintGrid?.fraction ?? 0,
                        session: survey.sessionName ?? survey.lastSessionDir?.lastPathComponent,
                        error: survey.lastError)
        startFraction = nil
        summary = s
        if s.error == nil { Haptics.success() } else { Haptics.error() }
    }

    private func reportTelemetry() {
        guard !demo, tab == .mapping else { return }
        Telemetry.shared.state(mode: survey.isTestSession ? "survey-test" : "survey", position: survey.position,
                               uncertaintyCm: nil, headingRad: survey.headingRad,
                               loc: survey.stage == .tracking ? "tracking" : "searching",
                               paint: survey.coverage.paintGrid?.fraction,
                               extra: ["speed": (survey.speedMS * 10).rounded() / 10, "lockFixes": survey.lockFixes,
                                       "eval": survey.evalSummary ?? ""])
    }
}
