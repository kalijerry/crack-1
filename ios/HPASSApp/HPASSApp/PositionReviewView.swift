import HPASSKit
import SwiftUI
import UIKit

/// 视觉复核：同一部手机竖着拿，ARKit 认出房间后的相机位置当真值，实时看地磁混合定位差多少，并把逐帧误差录下来上传。
///
/// - 真值：房间扫描时存的视觉特征地图 + 「ARKit → 地图」变换（StoreData.arAlign），认出房间且位姿稳定后才算；
/// - 被测：计步 + 地磁 + 蓝牙。视觉位置不喂给定位（不当观测），货架标签不抓定位，深度不参与；
/// - 录制：会话目录里的 review.csv（5 Hz）+ meta.json 的 purpose = review、review 摘要；
///   tools/collection_eval.py（每日采集评估）按地图汇总。
/// 单机只能竖着拿，测的是「边走边看屏」；口袋、包里等携带方式用双机测试。
@MainActor
final class PositionReviewSession: ObservableObject {
    static let shared = PositionReviewSession()

    @Published private(set) var running = false
    @Published var startFromVisual = true
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastError: String?
    /// 上一次复核的结果（结束后显示）
    @Published private(set) var lastResult: PositionReviewStats?
    @Published private(set) var lastUploaded = false

    var engine: MagneticEngine { AppEngines.shared.magnetic }

    /// 不能开始的原因（nil = 可以）
    var blocker: String? {
        if !ARKitLogger.isSupported { return "这台设备不支持 ARKit，无法视觉复核" }
        if MapLibrary.shared.activeWorldMapURL == nil || StoreDataStore.shared.map?.arAlign == nil {
            return "当前地图没有视觉特征地图（房间扫描建的地图才有），没有视觉真值"
        }
        if !startFromVisual, MagMapStore.shared.field == nil { return "当前地图还没有磁场图，不能让地磁自己定位；改用「视觉起点」" }
        return nil
    }

    func start() {
        guard !running else { return }
        AppEngines.shared.prepareIfNeeded()
        if let b = blocker { lastError = b; return }
        let e = engine
        guard e.phase == .idle else {
            lastError = "定位正在运行：先在「导航」页结束定位"
            return
        }
        lastError = nil
        lastResult = nil
        e.reviewMode = true
        e.reviewStartFromVisual = startFromVisual
        e.startLive()
        guard e.phase == .live else {
            e.reviewMode = false
            lastError = e.lastError ?? "定位没有启动"
            return
        }
        // 从别的页面结束定位、或传感器被抢走时也要收尾
        e.onLiveStopped = { [weak self] in self?.finishAfterLiveStopped() }
        if !startFromVisual { e.startColdSearch() }
        running = true
        startedAt = Date()
    }

    func stop() {
        guard running else { return }
        engine.stopLive()             // 回调 finishAfterLiveStopped
    }

    private func finishAfterLiveStopped() {
        lastResult = engine.reviewStats
        lastUploaded = Telemetry.shared.enabled
        running = false
        startedAt = nil
    }
}

struct PositionReviewView: View {
    @ObservedObject private var session = PositionReviewSession.shared
    @ObservedObject private var engine = AppEngines.shared.magnetic

    var body: some View {
        Form {
            if session.running { runningSections } else { setupSections }
        }
        .navigationTitle("视觉复核")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 开始前

    @ViewBuilder private var setupSections: some View {
        Section {
            Picker("起点", selection: $session.startFromVisual) {
                Text("视觉给起点").tag(true)
                Text("地磁自己定位").tag(false)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("设置")
        } footer: {
            Text(session.startFromVisual
                 ? "认出房间后用视觉位置和朝向当起点（相当于长按定点），之后视觉只当裁判。测的是走动中的跟踪精度。"
                 : "地磁像平时一样自己冷启动找位置，视觉从头到尾只当裁判。连「多久能定到、起步定没定错」一起测。")
        }
        Section {
            Button {
                Haptics.tap()
                session.start()
            } label: { Label("开始复核", systemImage: "checkmark.seal") }
            .buttonStyle(.dsPrimary)
            .disabled(session.blocker != nil)
            if let b = session.blocker { Text(b).font(.footnote).foregroundStyle(.orange) }
            if let e = session.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
        } footer: {
            Text("手机竖着拿、摄像头对着房间，像平时看屏一样走。摄像头全程开着，但视觉位置不参与定位，只用来算误差。只能测「边走边看屏」这种拿法；口袋、包里请用双机测试。")
        }
        if let r = session.lastResult {
            Section("上次复核结果") {
                metrics(r)
                if r.count == 0 {
                    Text("没有拿到有效样本：视觉一直没认出房间，或者定位没开始。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text(session.lastUploaded
                     ? "这次的 review.csv 和完整会话已上传后台（purpose = review），每日采集评估会按地图汇总。"
                     : "云端连接没打开，记录只存在本机（数据管理里能导出）。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 复核中

    @ViewBuilder private var runningSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(statusText).font(DS.Typography.caption).foregroundStyle(statusColor)
                HStack(alignment: .firstTextBaseline) {
                    Text(currentErrorText).font(DS.Typography.hero).monospacedDigit().foregroundStyle(errorColor)
                    Text("当前误差").font(DS.Typography.caption).foregroundStyle(.secondary)
                }
            }
            ReviewTrailChart(truth: engine.reviewTruthTrail, estimate: engine.reviewEstTrail,
                             truthNow: engine.reviewTruth, estimateNow: engine.reviewEstimate)
                .frame(height: 240)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            HStack(spacing: 14) {
                legend(.blue, "视觉真值")
                legend(.orange, "地磁混合")
            }
            .font(DS.Typography.caption)
        }
        Section("累计") {
            metrics(engine.reviewStats)
            if let t = session.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    row("时长", Self.duration(ctx.date.timeIntervalSince(t)))
                }
            }
            row("步数", "\(engine.stepCount)")
        }
        Section {
            Button(role: .destructive) {
                Haptics.tap()
                session.stop()
            } label: { Label("结束复核", systemImage: "stop.circle") }
        }
    }

    @ViewBuilder private func metrics(_ s: PositionReviewStats) -> some View {
        row("误差中位数", Self.m(s.medianCm))
        row("误差 P90", Self.m(s.p90Cm))
        row("1 米内 / 2 米内", "\(Self.pct(s.withinShare(100))) / \(Self.pct(s.withinShare(200)))")
        row("有把握时的中位数", Self.m(s.convergedMedianCm))
        row("最大误差", Self.m(s.maxCm))
        if let st = s.secondsToSettle { row("稳定进 2 米用时", "\(Fmt.f(st, 1)) 秒") }
        row("样本", "\(s.count)（有真值 \(s.truthSamples)）")
    }

    private var statusText: String {
        if engine.vioTracking != 2 { return "摄像头跟踪不正常：竖着拿，对着有纹理的地方，别挡镜头" }
        if !engine.reviewHasTruth { return "等视觉认出房间（对着扫描过的地方慢慢转一圈）" }
        switch engine.locState {
        case .tracking: return "视觉真值就绪 · 定位中"
        case .searching: return "视觉真值就绪 · 地磁还在找位置"
        case .lost: return "视觉真值就绪 · 地磁定位丢失"
        case .idle: return "视觉真值就绪 · 等起点"
        }
    }

    private var statusColor: Color {
        engine.vioTracking != 2 || !engine.reviewHasTruth ? DS.Palette.warning : DS.Palette.textSecondary
    }

    private var currentErrorText: String {
        guard engine.reviewTruth != nil, engine.reviewEstimate != nil, let e = engine.reviewStats.lastErrorCm else { return "—" }
        return Self.m(e)
    }

    private var errorColor: Color {
        guard let e = engine.reviewStats.lastErrorCm, engine.reviewEstimate != nil else { return DS.Palette.textSecondary }
        return e <= 100 ? DS.Palette.success : (e <= 200 ? DS.Palette.warning : DS.Palette.danger)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(t).foregroundStyle(.secondary)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundStyle(.secondary).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }

    private static func m(_ cm: Double?) -> String { cm.map { "\(Fmt.f($0 / 100, 2)) m" } ?? "—" }
    private static func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
    private static func duration(_ s: TimeInterval) -> String {
        let n = max(0, Int(s))
        return String(format: "%d:%02d", n / 60, n % 60)
    }
}

/// 两条轨迹（地图坐标 cm，y 向下）自动缩放画在一起，当前时刻的真值和估计之间连一条线。
private struct ReviewTrailChart: View {
    var truth: [Point2]
    var estimate: [Point2]
    var truthNow: Point2?
    var estimateNow: Point2?

    var body: some View {
        Canvas { ctx, size in
            let pts = truth + estimate + [truthNow, estimateNow].compactMap { $0 }
            guard let first = pts.first else {
                ctx.draw(Text("还没有数据").font(.footnote).foregroundColor(.secondary),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            // 至少 4 m 见方，四周留 8%
            let span = max(maxX - minX, maxY - minY, 400) * 1.16
            let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
            let scale = Double(min(size.width, size.height)) / span
            func pt(_ p: Point2) -> CGPoint {
                CGPoint(x: Double(size.width) / 2 + (p.x - cx) * scale, y: Double(size.height) / 2 + (p.y - cy) * scale)
            }
            // 1 m 网格
            var grid = Path()
            let x0 = (cx - Double(size.width) / 2 / scale / 100).rounded(.down) * 100
            let y0 = (cy - Double(size.height) / 2 / scale / 100).rounded(.down) * 100
            var x = x0
            while pt(Point2(x, 0)).x <= size.width { let px = pt(Point2(x, 0)).x; grid.move(to: CGPoint(x: px, y: 0)); grid.addLine(to: CGPoint(x: px, y: size.height)); x += 100 }
            var y = y0
            while pt(Point2(0, y)).y <= size.height { let py = pt(Point2(0, y)).y; grid.move(to: CGPoint(x: 0, y: py)); grid.addLine(to: CGPoint(x: size.width, y: py)); y += 100 }
            ctx.stroke(grid, with: .color(DS.Palette.mapGrid), lineWidth: 0.5)

            func line(_ ps: [Point2]) -> Path {
                var p = Path()
                for (i, q) in ps.enumerated() { if i == 0 { p.move(to: pt(q)) } else { p.addLine(to: pt(q)) } }
                return p
            }
            ctx.stroke(line(truth), with: .color(.blue.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            ctx.stroke(line(estimate), with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let t = truthNow, let e = estimateNow {
                var d = Path(); d.move(to: pt(t)); d.addLine(to: pt(e))
                ctx.stroke(d, with: .color(.red.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            for (p, c) in [(truthNow, Color.blue), (estimateNow, Color.orange)] {
                guard let p else { continue }
                let r = CGRect(x: pt(p).x - 6, y: pt(p).y - 6, width: 12, height: 12)
                ctx.fill(Path(ellipseIn: r), with: .color(c))
                ctx.stroke(Path(ellipseIn: r), with: .color(.white), lineWidth: 2)
            }
        }
        .background(DS.Palette.mapFloor, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
