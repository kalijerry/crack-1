import Combine
import SwiftUI
import UIKit

/// 办公室双机测试（协议见 docs/office-carry-test.md）：
/// - 盲测机 A：被测手机，摄像头强制关，按被测携带方式带着走，录实时定位会话（purpose = blind_test）；
/// - 伴随真值机 B：同一个人竖着拿，跑 ARKit（复用建图采集的测试会话），广播配对编号，踩到地贴长按修正。
/// 两机开始和结束时叠在一起敲三下对时。离线按 pair_id 配对、按敲击对时、伴随机 ARKit 轨迹减杆臂当真值。

/// 被测携带方式（v1 支持的集合，见设计文档 decisions）
enum OfficeCarryMode: String, CaseIterable, Identifiable {
    case texting, pocketFront = "pocket_front", handSwing = "hand_swing", calling, bag, mixed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .texting: return "边走边看屏"
        case .pocketFront: return "前裤兜"
        case .handSwing: return "手握摆臂"
        case .calling: return "贴耳打电话"
        case .bag: return "包里"
        case .mixed: return "中途切换"
        }
    }
}

/// 固定路线（便于跨版本比较）
enum OfficeRoute: String, CaseIterable, Identifiable {
    case r1 = "R1", r2 = "R2", r3 = "R3", other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .r1: return "R1 走廊环线"
        case .r2: return "R2 工位到工位"
        case .r3: return "R3 混合 + 转身"
        case .other: return "其他"
        }
    }
}

// MARK: - 盲测机

@MainActor
final class BlindTestSession: ObservableObject {
    static let shared = BlindTestSession()
    static let ownerName = "盲测录制"

    @Published private(set) var running = false
    @Published var carryMode: OfficeCarryMode = .texting
    @Published private(set) var currentMode: OfficeCarryMode = .texting
    @Published var route: OfficeRoute = .r1
    @Published var manualPair = ""
    @Published private(set) var pairId: String?
    @Published private(set) var pairRssi: Int?
    @Published private(set) var pairSource = ""
    @Published private(set) var bumps: [Int64] = []
    @Published private(set) var modeSwitches: [(t: Int64, mode: String)] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastError: String?

    private let scanner = PairScanner()
    private let bump = BumpRecorder()
    private var scanTimeout: Task<Void, Never>?

    var engine: MagneticEngine { AppEngines.shared.magnetic }

    func start() {
        guard !running else { return }
        let e = engine
        guard e.phase == .idle else {
            lastError = "定位正在运行：先在「导航」页结束定位"
            return
        }
        lastError = nil
        bumps = []
        modeSwitches = []
        pairId = nil
        pairRssi = nil
        pairSource = ""
        if let m = PairCode.normalize(manualPair) { pairId = m; pairSource = "manual" }
        currentMode = carryMode
        // 摄像头强制关：被测的就是「不用摄像头」的定位
        e.forceCameraOff = true
        e.liveExtraMeta = { [weak self] in self?.meta() ?? [:] }
        e.startLive()
        guard e.phase == .live else {
            e.forceCameraOff = false
            e.liveExtraMeta = nil
            lastError = e.lastError ?? "定位没有启动"
            return
        }
        // 从「导航」页、地磁页结束定位，或传感器被别的页面抢走时，引擎结束后回调这里收尾（评审：之前只有本页的「结束」会收尾，
        // 之后的普通定位会一直带着盲测 meta、摄像头被强制关、近距离传感器和后台保活一直开着）
        e.onLiveStopped = { [weak self] in self?.finishAfterLiveStopped() }
        e.setCarryModeLabel(currentMode.rawValue)
        // 有磁场图就开始自动找（只靠地磁不报位置，等外部先验或在「导航」页长按起点）
        if MagMapStore.shared.field != nil && MagMapStore.shared.usesStoreMap { e.startColdSearch() }
        if let d = e.liveSessionDir { bump.start(dir: d) }
        bump.onBump = { [weak self] t in self?.bumps.append(t); Haptics.tap() }
        // 口袋 / 贴耳时自动熄屏但 App 保持前台；锁屏后靠后台定位保活
        UIDevice.current.isProximityMonitoringEnabled = true
        BackgroundKeeper.shared.begin(Self.ownerName)
        if pairId == nil {
            scanner.onFound = { [weak self] id, rssi in
                Task { @MainActor in self?.foundPair(id, rssi: rssi) }
            }
            scanner.start()
            scanTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                self?.scanner.stop()
            }
        }
        running = true
        startedAt = Date()
        AppLog.i("双机测试", "盲测机开始：携带方式 \(currentMode.rawValue)，路线 \(route.rawValue)，摄像头关")
    }

    private func foundPair(_ id: String, rssi: Int) {
        guard running, pairId == nil || pairSource == "ble" else { return }
        if pairId != id || (pairRssi ?? -200) < rssi {
            if pairId == nil { Haptics.success(); AppLog.i("双机测试", "扫到伴随机配对编号 \(id)（\(rssi) dBm）") }
            pairId = id
            pairRssi = rssi
            pairSource = "ble"
        }
    }

    func switchMode(_ m: OfficeCarryMode) {
        guard running, m != currentMode else { return }
        currentMode = m
        modeSwitches.append((Fmt.nowMs(), m.rawValue))
        engine.setCarryModeLabel(m.rawValue)
        AppLog.i("双机测试", "携带方式切换为 \(m.rawValue)")
    }

    func stop() {
        guard running else { return }
        bump.stop()
        engine.stopLive()           // 结束时再写一次 meta（含敲击、切换、配对）；引擎随后回调 finishAfterLiveStopped
        finishAfterLiveStopped()    // 定位已经不在跑（引擎没回调）时也收尾
    }

    /// 收尾（可重复调用）：敲击记录、配对扫描、近距离传感器、后台保活
    private func finishAfterLiveStopped() {
        guard running else { return }
        scanTimeout?.cancel()
        scanner.stop()
        bump.stop()
        if engine.onLiveStopped != nil { engine.onLiveStopped = nil }
        engine.forceCameraOff = false
        engine.liveExtraMeta = nil
        UIDevice.current.isProximityMonitoringEnabled = false
        BackgroundKeeper.shared.end(Self.ownerName)
        running = false
        AppLog.i("双机测试", "盲测机结束：敲击 \(bumps.count) 次，切换 \(modeSwitches.count) 次，配对 \(pairId ?? "无")")
    }

    private func meta() -> [String: Any] {
        [
            "purpose": "blind_test",
            "protocol": "office-carry-v1",
            "camera": false,
            "carry_mode": carryMode.rawValue,
            "route": route.rawValue,
            "pair_id": pairId ?? "",
            "pair_source": pairSource,
            "pair_rssi": pairRssi ?? 0,
            "bumps_ms": bumps,
            "bump_threshold_g": BumpRecorder.thresholdG,
            "mode_switches": modeSwitches.map { ["t_ms": $0.t, "mode": $0.mode] },
            "proximity_monitoring": true,
            "map_version": MapLibrary.shared.active?.cloudVersion ?? 0,
        ]
    }
}

// MARK: - 伴随真值机

@MainActor
final class CompanionSession: ObservableObject {
    static let shared = CompanionSession()

    @Published private(set) var running = false
    @Published private(set) var pairId = ""
    @Published private(set) var advertState = ""
    @Published private(set) var bumps: [Int64] = []
    @Published private(set) var switches: [Int64] = []
    @Published private(set) var lastError: String?
    @Published var leverArmCm: Double = UserDefaults.standard.object(forKey: "companionLeverArmCm") as? Double ?? 25 {
        didSet { UserDefaults.standard.set(leverArmCm, forKey: "companionLeverArmCm") }
    }

    private let advertiser = PairAdvertiser()
    private let bump = BumpRecorder()
    private var stageSub: AnyCancellable?

    var survey: SurveyEngine { AppEngines.shared.survey }

    /// 开始：建图采集的测试会话（ARKit 真值，不参与建图）+ 广播配对编号 + 记敲击。
    func start() {
        guard !running else { return }
        let s = survey
        guard s.stage == .idle else {
            lastError = "建图采集正在进行：先在「建图」页结束"
            return
        }
        guard AppEngines.shared.magnetic.phase == .idle else {
            lastError = "这台手机正在定位：伴随真值机不要同时跑定位"
            return
        }
        lastError = nil
        bumps = []
        switches = []
        pairId = PairCode.random()
        s.isTestSession = true
        s.evaluate = false
        s.start(note: "双机测试 · 伴随真值")
        guard s.stage != .idle, let dir = s.lastSessionDir else {
            s.isTestSession = false
            lastError = s.lastError ?? "测试会话没有启动"
            return
        }
        advertiser.onState = { [weak self] st in Task { @MainActor in self?.advertState = st } }
        advertiser.start(id: pairId)
        bump.onBump = { [weak self] t in
            guard let self else { return }
            self.bumps.append(t)
            self.updateMeta()
            Haptics.tap()
        }
        bump.start(dir: dir)
        running = true
        updateMeta()
        // 在「建图」页直接点了结束：这边跟着收尾
        stageSub = s.$stage.sink { [weak self] st in
            if st == .idle { Task { @MainActor in self?.finishAfterSurveyStopped() } }
        }
        AppLog.i("双机测试", "伴随真值机开始：配对编号 \(pairId)，杆臂 \(Int(leverArmCm)) cm")
    }

    /// 记一次携带方式切换时刻（盲测机在口袋里点不了，由伴随机记）
    func markSwitch() {
        guard running else { return }
        switches.append(Fmt.nowMs())
        updateMeta()
        Haptics.heavy()
    }

    func stop() {
        guard running else { return }
        bump.stop()
        updateMeta()
        survey.stop()              // 写 meta（extraMeta 已含配对、敲击、杆臂）、按设置自动上传
        finishAfterSurveyStopped()
    }

    private func finishAfterSurveyStopped() {
        guard running else { return }
        stageSub = nil
        bump.stop()
        advertiser.stop()
        survey.isTestSession = false
        running = false
        AppLog.i("双机测试", "伴随真值机结束：敲击 \(bumps.count) 次，切换 \(switches.count) 次")
    }

    private func updateMeta() {
        let r = survey.recorder
        r.extraMeta["role"] = "gt_companion"
        r.extraMeta["protocol"] = "office-carry-v1"
        r.extraMeta["pair_id"] = pairId
        r.extraMeta["lever_arm_cm"] = leverArmCm
        r.extraMeta["bumps_ms"] = bumps
        r.extraMeta["bump_threshold_g"] = BumpRecorder.thresholdG
        r.extraMeta["mode_switch_marks_ms"] = switches
        r.extraMeta["truth_note"] = "anchors.csv reanchor = floor mark taps; arkit_pose.csv tracking column = ARKit state"
    }
}

// MARK: - 页面

@MainActor
struct OfficeCarryTestView: View {
    /// 伴随机开始后切到「建图」页（地贴长按修正在那里）
    var openMapping: () -> Void

    enum Role: String, CaseIterable, Identifiable {
        case blind, companion
        var id: String { rawValue }
        var title: String { self == .blind ? "盲测机 A" : "伴随真值机 B" }
    }

    @State private var role: Role = .blind
    @ObservedObject private var blind = BlindTestSession.shared
    @ObservedObject private var comp = CompanionSession.shared
    @ObservedObject private var survey = AppEngines.shared.survey
    @ObservedObject private var engine = AppEngines.shared.magnetic

    var body: some View {
        Form {
            Section {
                Picker("这台手机是", selection: $role) {
                    ForEach(Role.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(blind.running || comp.running)
            } footer: {
                Text("两台 iPhone 同一个人带：A 按被测方式带着（摄像头关），B 竖着拿跑 ARKit 当真值。开始和结束时两机叠在一起在桌面敲三下。完整步骤见 docs/office-carry-test.md。")
            }
            if role == .blind { blindSections } else { companionSections }
        }
        .navigationTitle("双机测试")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 盲测机

    @ViewBuilder private var blindSections: some View {
        if !blind.running {
            Section("设置") {
                Picker("携带方式", selection: $blind.carryMode) {
                    ForEach(OfficeCarryMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("路线", selection: $blind.route) {
                    ForEach(OfficeRoute.allCases) { Text($0.title).tag($0) }
                }
                TextField("配对编号（可空，会自动扫伴随机）", text: $blind.manualPair)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            Section {
                Button {
                    Haptics.tap()
                    blind.start()
                } label: { Label("开始盲测录制", systemImage: "record.circle") }
                .buttonStyle(.dsPrimary)
                if let e = blind.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("开始后摄像头强制关闭。先和 B 叠在一起敲三下，再把手机放进被测的携带位置。口袋 / 贴耳时屏幕会自动熄灭但定位继续；按侧键锁屏也会继续（需要允许位置权限）。")
            }
        } else {
            Section("录制中") {
                row("携带方式", blind.currentMode.title)
                row("配对编号", blind.pairId.map { "\($0)（\(blind.pairSource == "ble" ? "蓝牙扫到" : "手动")）" } ?? "扫描中…")
                row("检测到敲击", "\(blind.bumps.count) 次")
                row("定位状态", locText)
                if let t = blind.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        row("时长", Self.duration(ctx.date.timeIntervalSince(t)))
                    }
                }
            }
            Section {
                Picker("切换携带方式", selection: Binding(get: { blind.currentMode }, set: { blind.switchMode($0) })) {
                    ForEach(OfficeCarryMode.allCases.filter { $0 != .mixed }) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("中途切换（mixed）：能拿到手机时在这里选新的方式；拿不到时在 B 上点「记一次切换」。")
            }
            Section {
                Button(role: .destructive) {
                    Haptics.tap()
                    blind.stop()
                } label: { Label("结束（先敲三下）", systemImage: "stop.circle") }
            }
        }
    }

    private var locText: String {
        switch engine.locState {
        case .tracking: return "定位中"
        case .searching: return "找位置中（不报位置）"
        case .lost: return "丢失"
        case .idle: return "未开始"
        }
    }

    // MARK: 伴随机

    @ViewBuilder private var companionSections: some View {
        if !comp.running {
            Section {
                HStack {
                    Text("杆臂（两机水平距离）")
                    Spacer()
                    TextField("cm", value: $comp.leverArmCm, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("cm").foregroundStyle(.secondary)
                }
            } footer: {
                Text("B 竖着拿在胸前、A 在被测位置时两者的大致水平距离，写进 meta，事后可以改。")
            }
            Section {
                Button {
                    Haptics.tap()
                    comp.start()
                    if comp.running { openMapping() }
                } label: { Label("开始伴随真值", systemImage: "arkit") }
                .buttonStyle(.dsPrimary)
                if let e = comp.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("开始后会切到「建图」页：先长按起点、设朝向；之后每踩到一个地贴就在地图上长按那个地贴（不用停步）。这段只当测试真值，不参与建图。")
            }
        } else {
            Section("进行中") {
                row("配对编号", comp.pairId)
                row("蓝牙广播", comp.advertState.isEmpty ? "启动中…" : comp.advertState)
                row("检测到敲击", "\(comp.bumps.count) 次")
                row("地贴修正", "\(survey.anchorCount) 次")
                row("ARKit 跟踪", survey.trackingState == 2 ? "正常" : (survey.trackingState == 1 ? "受限" : "不可用"))
                row("携带方式切换记号", "\(comp.switches.count) 次")
            }
            Section {
                Button { comp.markSwitch() } label: { Label("记一次切换（A 换携带方式时点）", systemImage: "arrow.triangle.swap") }
                Button { openMapping() } label: { Label("去「建图」页记地贴", systemImage: "map") }
                Button(role: .destructive) {
                    Haptics.tap()
                    comp.stop()
                } label: { Label("结束（先敲三下）", systemImage: "stop.circle") }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private static func duration(_ s: TimeInterval) -> String {
        let n = max(0, Int(s))
        return String(format: "%d:%02d", n / 60, n % 60)
    }
}
