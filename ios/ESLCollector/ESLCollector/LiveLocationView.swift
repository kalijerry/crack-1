import HPASSKit
import SwiftUI
import UIKit

/// 点击地图时的含义。
private enum MapTapMode: String, CaseIterable, Identifiable {
    case none, start, target

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "不操作"
        case .start: return "设起点"
        case .target: return "设目标"
        }
    }
}

/// 实时定位 / 导航测试页。
@MainActor
struct LiveLocationView: View {

    @StateObject private var engine = LiveLocationEngine()
    @ObservedObject private var store = StoreDataStore.shared

    @State private var tapMode: MapTapMode = .none
    @State private var target: Point2?
    @State private var targetLabel = ""
    @State private var declinationText = "0"
    @State private var knownPointId = ""

    var body: some View {
        // 本页是 TabView 的根，自己带 NavigationStack（商品 / 指纹点选择要用 NavigationLink）
        NavigationStack {
            content
                .navigationTitle("实时定位")
        }
        // 生命周期挂在 NavigationStack 上：挂在内容上的话，push 子页面时也会触发 onDisappear
        .onAppear {
            declinationText = Fmt.f(engine.magneticDeclinationDeg, 1)
        }
        .onChange(of: engine.isRunning) { running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        // 这里是标签页，切到日志页也会触发 onDisappear。
        // 实地走测时需要边走边看日志，所以不在这里停止定位，只由「停止」按钮控制。
        .onDisappear {
            if !engine.isRunning {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private var content: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                MapCanvas(map: store.map,
                          fingerprints: store.fingerprints,
                          matchedPointId: engine.estimate?.pointId,
                          trail: engine.trail,
                          position: engine.displayPosition,
                          headingRad: engine.headingRad,
                          uncertaintyCm: uncertaintyCm,
                          rawEstimate: engine.estimate?.position,
                          route: engine.route,
                          onTap: { p in handleTap(p) })
                    .frame(height: max(geo.size.height * 0.46, 200))
                    .clipped()

                Divider()
                statusStrip
                Divider()

                Form {
                    if !store.isReady {
                        Section {
                            Text("请先在门店数据页导入地图、指纹和价签")
                                .foregroundStyle(.orange)
                        }
                    }
                    Group {
                        runSection
                        navSection
                        paramSection
                        calibrationSection
                    }
                    .disabled(!store.isReady)
                }
            }
        }
    }

    private var uncertaintyCm: Double {
        if engine.useIMU, let f = engine.fused { return f.uncertaintyCm }
        return engine.estimate?.uncertaintyCm ?? 0
    }

    // MARK: - 状态条

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(engine.displayPosition.map { "\(Int($0.x.rounded())), \(Int($0.y.rounded())) cm" } ?? "无定位")
                    .fontWeight(.semibold)
                Text("航向 \(Int((engine.headingRad * 180 / .pi).rounded()))°")
                Spacer()
                Text(engine.bleState).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("置信 \(Fmt.f(engine.estimate?.confidence ?? 0, 2))")
                Text("σ \(Int(uncertaintyCm.rounded()))cm")
                Text("读数 \(engine.readingsPerSecond)/s")
                Text("价签 \(engine.uniqueTagsPerSecond)/s")
                Text("步 \(engine.stepCount)")
            }
            HStack(spacing: 10) {
                Text("点位 \(engine.estimate?.pointId ?? "—")")
                Text(engine.wasConstrained ? "通道约束已生效" : "无通道约束")
                    .foregroundStyle(engine.wasConstrained ? Color.orange : Color.secondary)
                Spacer()
            }
            if let err = engine.lastError {
                Text(err).foregroundStyle(.red)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 运行

    private var runSection: some View {
        Section {
            LoggedButton(name: "实时定位开关",
                         detail: engine.isRunning ? "停止" : "开始 / 指纹 \(store.fingerprints.count) 点") {
                engine.isRunning ? engine.stop() : engine.start()
            } label: {
                Text(engine.isRunning ? "停止" : "开始")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .tint(engine.isRunning ? .red : .accentColor)
            .disabled(!store.isReady)

            Toggle("记录轨迹", isOn: Binding(
                get: { engine.isRecordingTrack },
                set: { on in
                    AppLog.tap("记录轨迹", on ? "开" : "关")
                    on ? engine.startTrackRecording() : engine.stopTrackRecording()
                }))
                .disabled(!engine.isRunning)

            Picker("点击地图", selection: $tapMode) {
                ForEach(MapTapMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: tapMode) { m in AppLog.tap("点击地图模式", m.title) }

            LoggedButton("清空轨迹") { engine.clearTrail() }
                .disabled(engine.trail.isEmpty)
        } header: {
            Text("运行")
        } footer: {
            Text(engine.isRunning
                 ? "实时定位有自己的一路蓝牙扫描，请勿与「录制」页同时开启，否则两边读数都会变稀。"
                 : "文件写在 Documents/live-tracks/ 下。")
        }
    }

    // MARK: - 导航

    private var navSection: some View {
        Section {
            if let h = engine.hint {
                HStack(spacing: 14) {
                    Image(systemName: Self.arrowName(h.direction))
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(h.direction == .straight ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.directionText(h.direction)).font(.headline)
                        Text("剩余 \(Int(h.remainingDistance.rounded())) cm")
                        if let d = h.distanceToNextTurn {
                            Text("下个转弯 \(Int(d.rounded())) cm")
                        } else {
                            Text("前方无转弯").foregroundStyle(.secondary)
                        }
                        if h.isOffRoute {
                            Text("已偏离路线 \(Int(h.distanceToRoute.rounded())) cm")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            }

            HStack {
                Text("目标")
                Spacer()
                Text(target.map { t in
                    targetLabel.isEmpty
                        ? "\(Int(t.x.rounded())), \(Int(t.y.rounded()))"
                        : "\(targetLabel) (\(Int(t.x.rounded())), \(Int(t.y.rounded())))"
                } ?? "未选择")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            NavigationLink("从商品选择目标") {
                GoodsPickerView(goods: store.goods) { item, p in
                    target = p
                    targetLabel = item.itemName ?? item.sku
                    AppLog.i("实时定位", "选择导航目标：\(item.sku) \(item.itemName ?? "") \(p)")
                }
            }
            .disabled(store.goods.isEmpty)

            if engine.isNavigating {
                LoggedButton("结束导航", role: .destructive) { engine.stopNavigation() }
            } else {
                LoggedButton("开始导航") {
                    guard let t = target else { return }
                    engine.startNavigation(to: t, label: targetLabel.isEmpty ? "地图点" : targetLabel)
                }
                .disabled(target == nil || !engine.isRunning)
            }
        } header: {
            Text("导航")
        } footer: {
            Text("也可以把上面的「点击地图」切到「设目标」，直接点地图选目标；路线会自动吸附到通道。")
        }
    }

    // MARK: - 参数

    private var paramSection: some View {
        Section {
            Stepper(value: $engine.rssiOffset, in: -25...25, step: 0.5) {
                HStack {
                    Text("RSSI 偏移")
                    Spacer()
                    Text(Fmt.f(engine.rssiOffset, 1) + " dB").foregroundStyle(.secondary)
                }
            }
            .onChange(of: engine.rssiOffset) { v in AppLog.tap("RSSI 偏移", Fmt.f(v, 1)) }

            Stepper(value: $engine.rssiScale, in: 0.85...1.15, step: 0.01) {
                HStack {
                    Text("RSSI 斜率")
                    Spacer()
                    Text(Fmt.f(engine.rssiScale, 2)).foregroundStyle(.secondary)
                }
            }
            .onChange(of: engine.rssiScale) { v in AppLog.tap("RSSI 斜率", Fmt.f(v, 2)) }

            Toggle("邻居图平滑（Viterbi）", isOn: $engine.useGraphSmoothing)
                .onChange(of: engine.useGraphSmoothing) { v in AppLog.tap("邻居图平滑", v ? "开" : "关") }

            Toggle("惯导融合", isOn: $engine.useIMU)
                .onChange(of: engine.useIMU) { v in AppLog.tap("惯导融合", v ? "开" : "关") }

            Toggle("通道约束", isOn: $engine.useCorridorConstraint)
                .onChange(of: engine.useCorridorConstraint) { v in AppLog.tap("通道约束", v ? "开" : "关") }

            HStack {
                Text("磁偏角")
                TextField("度", text: $declinationText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: declinationText) { s in
                        if let v = Double(s.trimmingCharacters(in: .whitespaces)), v.isFinite {
                            engine.magneticDeclinationDeg = v
                        }
                    }
                Text("°").foregroundStyle(.secondary)
            }
        } header: {
            Text("参数")
        } footer: {
            Text("磁偏角 = 地图 +y 轴的磁罗盘方位角（顺时针为正）。关闭惯导融合时地图上显示原始指纹定位结果。")
        }
    }

    // MARK: - 标定

    private var calibrationSection: some View {
        Section {
            LoggedButton("盲标定（最近 120 秒）") { engine.runBlindCalibration(seconds: 120) }
                .disabled(!engine.isRunning || engine.isCalibrating)

            NavigationLink("选择已知指纹点") {
                FingerprintPickerView(points: store.fingerprints) { p in
                    knownPointId = p.id
                    AppLog.i("实时定位", "标定点位选择 \(p.id) \(p.position)")
                }
            }
            .disabled(store.fingerprints.isEmpty)

            HStack {
                Text("已知点")
                Spacer()
                Text(knownPointId.isEmpty ? "未选择" : knownPointId).foregroundStyle(.secondary)
            }

            if let pid = engine.knownPointCapturing {
                LoggedButton("结束（点位 \(pid)）", role: .destructive) {
                    engine.finishKnownPointCapture()
                }
            } else {
                LoggedButton("开始（站在该点位上）") {
                    engine.startKnownPointCapture(pointId: knownPointId)
                }
                .disabled(knownPointId.isEmpty || !engine.isRunning)
            }

            if let c = engine.calibration {
                VStack(alignment: .leading, spacing: 2) {
                    Text("建议 offset \(Fmt.f(c.offset, 2)) dB · scale \(Fmt.f(c.scale, 3))")
                        .fontWeight(.semibold)
                    Text("得分 \(Fmt.f(c.scoreBefore, 3)) → \(Fmt.f(c.score, 3))，\(c.samples) 个时间窗")
                        .foregroundStyle(.secondary)
                    if let note = engine.calibrationNote {
                        Text(note).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .monospacedDigit()

                LoggedButton("应用建议偏移") { engine.applySuggestedCalibration() }
            } else if let note = engine.calibrationNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            if engine.isCalibrating {
                HStack {
                    ProgressView()
                    Text("正在网格搜索…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("标定")
        } footer: {
            Text("盲标定要求走过的区域被指纹库覆盖；得分几乎没变说明这次数据定不出偏移。")
        }
    }

    // MARK: - 交互

    @MainActor private func handleTap(_ p: Point2) {
        switch tapMode {
        case .none:
            break
        case .start:
            AppLog.tap("地图点击", "设起点 \(p)")
            engine.setStartPosition(p)
        case .target:
            AppLog.tap("地图点击", "设目标 \(p)")
            target = p
            targetLabel = ""
        }
    }

    private static func arrowName(_ d: TurnDirection) -> String {
        switch d {
        case .straight: return "arrow.up"
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .uturn: return "arrow.uturn.down"
        }
    }

    private static func directionText(_ d: TurnDirection) -> String {
        switch d {
        case .straight: return "直行"
        case .left: return "左转"
        case .right: return "右转"
        case .uturn: return "掉头"
        }
    }
}

// MARK: - 商品选择

/// 按 sku / 名称搜索商品，取第一个带坐标的价签位置作为导航目标。
@MainActor
private struct GoodsPickerView: View {
    let goods: [GoodsItem]
    let onPick: (GoodsItem, Point2) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Row: Identifiable {
        let id: Int
        let item: GoodsItem
        let position: Point2?
    }

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Row] = []
        for (i, g) in goods.enumerated() {
            if !q.isEmpty {
                let hit = g.sku.lowercased().contains(q)
                    || (g.itemName ?? "").lowercased().contains(q)
                    || (g.ean ?? "").lowercased().contains(q)
                if !hit { continue }
            }
            let p = g.positions.compactMap { e -> Point2? in
                guard let x = e.x, let y = e.y else { return nil }
                return Point2(x, y)
            }.first
            out.append(Row(id: i, item: g, position: p))
            if out.count >= 300 { break }
        }
        return out
    }

    var body: some View {
        List(rows) { row in
            LoggedButton(name: "选择商品", detail: row.item.sku) {
                guard let p = row.position else { return }
                onPick(row.item, p)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.item.itemName ?? row.item.sku)
                    Text(row.item.sku + (row.position == nil ? " · 无坐标" : " · \(row.item.positions.count) 个位置"))
                        .font(.caption)
                        .foregroundStyle(row.position == nil ? Color.red : Color.secondary)
                }
            }
            .disabled(row.position == nil)
        }
        .searchable(text: $query, prompt: "按 SKU 或名称搜索")
        .navigationTitle("选择商品")
    }
}

// MARK: - 指纹点选择

@MainActor
private struct FingerprintPickerView: View {
    let points: [FingerprintPoint]
    let onPick: (FingerprintPoint) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [FingerprintPoint] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return points }
        return points.filter { $0.id.lowercased().contains(q) }
    }

    var body: some View {
        List(filtered, id: \.id) { p in
            LoggedButton(name: "选择指纹点", detail: p.id) {
                onPick(p)
                dismiss()
            } label: {
                HStack {
                    Text(p.id).font(.system(.body, design: .monospaced))
                    Spacer()
                    Text("\(Int(p.x.rounded())), \(Int(p.y.rounded())) cm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $query, prompt: "按点位编号搜索")
        .navigationTitle("选择指纹点")
    }
}
