import HPASSKit
import SwiftUI

/// 接着扫 / 重扫的一段等着合并：候选的对齐、和已有墙体的核对、建议的合成方式。
///
/// 任何路径（视觉认出、自动几何对齐、手动两点）都要经过合并预览、由用户确认，不会默默把对不上的几何写进去。
struct PendingMerge {
    var mapId: String
    var mapName: String
    var scanId: String
    var scanName: String?
    var scanJSON: Data
    var existingJSON: Data
    var createdMs: Int64
    var osMajor: Int?
    var roomCount: Int?
    /// 扫描时视觉认出了已扫区域（和地图基准同一个 AR 坐标系）
    var relocalized: Bool
    /// 扫描时载入的特征地图的生成时间（视觉认出时才有）
    var relocSourceMs: Int64?
    var toMap: MapARTransform = .identity
    var alignment: ScanRegistry.Alignment = .geometry
    var quality: ScanRegistry.Quality?
    var mode: ScanRegistry.Mode = .append
    /// 自动对不上，必须手动对齐后才能合并
    var needsManual = false
    /// 给用户看的说明
    var notes: [String] = []
    /// 要用户留意（偏差大、没有重合、有歧义）
    var warn = false

    /// 合并进注册表的记录。只有视觉认出的段才算在基准坐标系里（它的特征地图可以顶替在用的那份）
    var record: ScanRegistry.ScanRecord {
        ScanRegistry.ScanRecord(id: scanId, name: scanName, createdMs: createdMs, osMajor: osMajor, roomCount: roomCount,
                                inBaseFrame: alignment == .worldmap, toMap: toMap, alignment: alignment,
                                quality: quality, mode: mode)
    }

    static func prepare(mapId: String, mapName: String, scanId: String, scanName: String?, scanJSON: Data, existingJSON: Data,
                        frameAlign: MapARTransform?, relocalized: Bool, osMajor: Int?, roomCount: Int?,
                        relocSourceMs: Int64? = nil) -> PendingMerge {
        var m = PendingMerge(mapId: mapId, mapName: mapName, scanId: scanId, scanName: scanName, scanJSON: scanJSON,
                             existingJSON: existingJSON, createdMs: Fmt.nowMs(), osMajor: osMajor, roomCount: roomCount,
                             relocalized: relocalized, relocSourceMs: relocalized ? relocSourceMs : nil)
        if relocalized, let fa = frameAlign, let sa = (try? StoreDataLoader.loadMap(scanJSON))?.arAlign {
            m.useWorldMap(scanAlign: sa, frameAlign: fa)
        } else {
            m.autoAlign()
        }
        return m
    }

    /// 视觉认出：这一段和地图同一个 AR 坐标系，变换直接算出来；再核对一次墙体（ARKit 可能认错位置）
    mutating func useWorldMap(scanAlign: MapARTransform, frameAlign: MapARTransform) {
        toMap = ScanRegistry.ScanRecord.toMapInBaseFrame(scanAlign: scanAlign, frameAlign: frameAlign)
        alignment = .worldmap
        needsManual = false
        quality = try? MapComposer.consistency(new: scanJSON, toMap: toMap, existing: existingJSON)
        notes = []
        warn = false
        if let q = quality, q.overlapCm >= 100 {
            notes.append("视觉认出了已扫区域：和已有的墙重合 \(Fmt.f(q.overlapCm / 100, 1)) m，平均偏差 \(Fmt.f(q.residualCm, 0)) cm。")
            if q.residualCm > 30 {
                warn = true
                notes.append("偏差偏大，可能认错了位置。看一下预览：不对就点「改用墙和门自动对齐」或「手动对齐」。")
            }
        } else {
            warn = true
            notes.append("视觉认出了已扫区域，但新扫的墙和已有的墙几乎没有重合"
                         + (quality.map { "（\(Fmt.f($0.overlapCm / 100, 1)) m）" } ?? "")
                         + "。全是新房间时这是正常的；如果预览里位置不对，点「改用墙和门自动对齐」或「手动对齐」。")
        }
        suggestMode()
    }

    /// 几何自动对齐（墙 / 门）；对不上就要求手动
    mutating func autoAlign() {
        notes = []
        warn = false
        guard let tf = try? RigidAlign2D.Features(mapJSON: existingJSON), let sf = try? RigidAlign2D.Features(mapJSON: scanJSON),
              let r = RigidAlign2D.auto(target: tf, source: sf) else {
            needsManual = true
            alignment = .manual
            quality = nil
            toMap = sideBySide()
            warn = true
            notes.append("没能按墙和门自动对上：新扫的部分和已有地图重合太少，或者没有同一扇门。"
                         + "请点「手动对齐」，在旧图和新扫的图上各点两个对应的点（同一扇门的两边、同一个墙角）。")
            return
        }
        toMap = r.transform
        alignment = .geometry
        quality = r.quality
        needsManual = false
        notes.append("按墙和门自动对齐：重合 \(Fmt.f(r.overlapCm / 100, 1)) m，平均偏差 \(Fmt.f(r.residualCm, 0)) cm"
                     + (r.doorsMatched > 0 ? "，对上了 \(r.doorsMatched) 扇门" : "") + "。")
        if r.ambiguous {
            warn = true
            notes.append("有几种差不多的放法（比如几个一样大的房间、长走廊），请仔细看预览；不对就点「手动对齐」。")
        }
        suggestMode()
    }

    /// 手动两点对齐的结果
    mutating func useManual(_ t: MapARTransform) {
        toMap = t
        alignment = .manual
        needsManual = false
        notes = []
        warn = false
        if let tf = try? RigidAlign2D.Features(mapJSON: existingJSON), let sf = try? RigidAlign2D.Features(mapJSON: scanJSON) {
            let r = RigidAlign2D.evaluate(t, target: tf, source: sf)
            quality = r.quality
            notes.append("手动对齐：和已有的墙重合 \(Fmt.f(r.overlapCm / 100, 1)) m，平均偏差 \(Fmt.f(r.residualCm, 0)) cm。")
            if r.overlapCm < 100 { warn = true; notes.append("重合很少，确认一下预览里的位置。") }
        }
        suggestMode()
    }

    /// 新段大部分落在已有房间里 → 默认「替换这块」（重扫精细化），否则「追加」（接着扫）
    mutating func suggestMode() {
        mode = (try? MapComposer.suggestedMode(new: scanJSON, toMap: toMap, existing: existingJSON)) ?? .append
    }

    /// 自动对不上时预览里先把新段放在旧图右边
    private func sideBySide() -> MapARTransform {
        let w = (try? StoreDataLoader.loadMap(existingJSON))?.width ?? 0
        return MapARTransform(pRef: Point2(w + 100, 0), aRef: .zero, phi: 0)
    }
}

// MARK: - 平面图（墙、门、房间）画布

/// 只画墙、门窗、房间的简单平面图：合并预览（旧图灰、新段彩色）和手动对齐点点用。
struct ScanPlanCanvas: View {
    struct Layer {
        var walls: [MapGeometry.Segment] = []
        var doors: [MapGeometry.Segment] = []
        var units: [[Point2]] = []
        var color: Color

        init(json: Data?, transform t: MapARTransform = .identity, color: Color) {
            self.color = color
            guard let d = json, let root = try? MapGeometry.root(d) else { return }
            walls = MapGeometry.segments(root, types: ["MapWall"]).map { $0.transformed(by: t) }
            doors = MapGeometry.segments(root, types: ["MapDoor", "MapOpening", "MapWindow"]).map { $0.transformed(by: t) }
            units = MapGeometry.units(root).map { $0.polygon.map(t.toMap) }
        }

        var points: [Point2] { walls.flatMap { [$0.a, $0.b] } + doors.flatMap { [$0.a, $0.b] } + units.flatMap { $0 } }
    }

    var layers: [Layer]
    /// 点过的点（依次标 A、B）
    var markers: [Point2] = []
    var markerColor: Color = .orange
    var onTap: ((Point2) -> Void)?

    private struct Fit {
        var minX = 0.0, minY = 0.0, scale = 1.0, ox = 0.0, oy = 0.0
        init(points: [Point2], size: CGSize) {
            guard let f = points.first else { return }
            var lo = f, hi = f
            for p in points { lo = Point2(min(lo.x, p.x), min(lo.y, p.y)); hi = Point2(max(hi.x, p.x), max(hi.y, p.y)) }
            let w = max(hi.x - lo.x, 100), h = max(hi.y - lo.y, 100)
            scale = min(Double(size.width) / w, Double(size.height) / h) * 0.9
            minX = lo.x; minY = lo.y
            ox = (Double(size.width) - w * scale) / 2
            oy = (Double(size.height) - h * scale) / 2
        }
        func view(_ p: Point2) -> CGPoint { CGPoint(x: ox + (p.x - minX) * scale, y: oy + (p.y - minY) * scale) }
        func map(_ v: CGPoint) -> Point2 { Point2((Double(v.x) - ox) / scale + minX, (Double(v.y) - oy) / scale + minY) }
    }

    var body: some View {
        GeometryReader { geo in
            let fit = Fit(points: layers.flatMap(\.points), size: geo.size)
            Canvas { ctx, _ in
                for l in layers {
                    for u in l.units where u.count >= 3 {
                        var path = Path()
                        path.addLines(u.map(fit.view))
                        path.closeSubpath()
                        ctx.fill(path, with: .color(l.color.opacity(0.12)))
                    }
                    for w in l.walls {
                        var path = Path()
                        path.move(to: fit.view(w.a)); path.addLine(to: fit.view(w.b))
                        ctx.stroke(path, with: .color(l.color), lineWidth: 2.5)
                    }
                    for d in l.doors {
                        var path = Path()
                        path.move(to: fit.view(d.a)); path.addLine(to: fit.view(d.b))
                        ctx.stroke(path, with: .color(l.color.opacity(0.55)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    }
                }
                for (i, p) in markers.enumerated() {
                    let c = fit.view(p)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(markerColor))
                    ctx.draw(Text(i == 0 ? "A" : "B").font(.caption.bold()).foregroundColor(.white), at: c)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in onTap?(fit.map(v.location)) }, including: onTap == nil ? .none : .all)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 合并预览

struct ScanMergeView: View {
    @ObservedObject var model: RoomScanModel
    @State private var showManual = false
    @State private var newMapName = ""
    @State private var askNewMapName = false

    var body: some View {
        if let m = model.pendingMerge {
            content(m)
        } else {
            ProgressView()
        }
    }

    private func content(_ m: PendingMerge) -> some View {
        List {
            Section {
                ScanPlanCanvas(layers: [ScanPlanCanvas.Layer(json: m.existingJSON, color: .gray),
                                        ScanPlanCanvas.Layer(json: m.scanJSON, transform: m.toMap, color: .accentColor)])
                    .frame(height: 320)
                    .listRowInsets(EdgeInsets())
                HStack(spacing: 12) {
                    Label("已有的", systemImage: "square.fill").foregroundStyle(.gray)
                    Label("这次扫的", systemImage: "square.fill").foregroundStyle(Color.accentColor)
                }
                .font(.caption)
                ForEach(m.notes, id: \.self) { n in
                    Label(n, systemImage: m.warn ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(m.warn ? Color.orange : Color.primary)
                }
            } header: {
                Text("合并到「\(m.mapName)」")
            } footer: {
                Text("灰色是地图里已有的，彩色是这次扫的、按下面的对齐放上去的样子。位置不对就别合并：改用自动对齐或手动对齐。")
            }

            Section {
                Picker("合并方式", selection: Binding(get: { model.pendingMerge?.mode ?? .append },
                                                   set: { model.pendingMerge?.mode = $0 })) {
                    Text("追加补充").tag(ScanRegistry.Mode.append)
                    Text("替换这块").tag(ScanRegistry.Mode.replace)
                }
                .pickerStyle(.segmented)
                Text(m.mode == .append
                     ? "追加补充：旧的都保留，重复的墙、门窗、家具自动去重，只补新扫到的地方。接着扫新房间用这个。"
                     : "替换这块：先删掉这次扫到的范围（房间外扩 30 cm）里的旧墙、门窗、家具和房间，再放新扫的；房间的编号、类别、名字自动继承。重扫精细化用这个。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    model.confirmMerge()
                } label: {
                    Label("确认合并", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.needsManual)
                if m.needsManual {
                    Text("先手动对齐，才能合并。").font(.footnote).foregroundStyle(.orange)
                }
                if let e = model.mergeError { Text(e).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("合并后这一段会出现在地图详情的「扫描段」里；不满意随时可以关掉这一段（等于撤销这次扫描，被替换的旧内容会回来）。")
            }

            Section {
                if m.alignment == .worldmap {
                    Button { model.pendingMerge?.autoAlign() } label: {
                        Label("改用墙和门自动对齐", systemImage: "wand.and.stars")
                    }
                } else if m.relocalized, let fa = model.targetFrameAlign,
                          let sa = (try? StoreDataLoader.loadMap(m.scanJSON))?.arAlign {
                    Button { model.pendingMerge?.useWorldMap(scanAlign: sa, frameAlign: fa) } label: {
                        Label("改回视觉认出的位置", systemImage: "eye")
                    }
                }
                if m.alignment != .geometry && !m.relocalized && !m.needsManual {
                    Button { model.pendingMerge?.autoAlign() } label: {
                        Label("重新自动对齐", systemImage: "wand.and.stars")
                    }
                }
                Button { showManual = true } label: {
                    Label("手动对齐（在两张图上各点两个对应点）", systemImage: "hand.point.up.left")
                }
                Button {
                    newMapName = m.scanName ?? "\(m.mapName) 的一段"
                    askNewMapName = true
                } label: {
                    Label("不合并，另存为一张新地图", systemImage: "doc.badge.plus")
                }
                Button("放弃这次扫描", role: .destructive) { model.discardMerge() }
            } header: { Text("对不上？") }
        }
        .navigationTitle("合并预览")
        .sheet(isPresented: $showManual) {
            NavigationStack {
                ManualAlignView(existing: m.existingJSON, scan: m.scanJSON) { t in
                    model.pendingMerge?.useManual(t)
                    showManual = false
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showManual = false } } }
            }
        }
        .alert("另存为新地图", isPresented: $askNewMapName) {
            TextField("地图名", text: $newMapName)
            Button("取消", role: .cancel) {}
            Button("保存") { model.saveMergeAsNewMap(name: newMapName) }
        } message: {
            Text("这一段单独成为一张地图。以后可以在它的基础上接着扫。")
        }
    }
}

// MARK: - 手动两点对齐

/// 旧图、新扫的图上各点两个对应的点（同一扇门的两边、同一个墙角和柱子），只解旋转 + 平移；
/// 显示尺度比（激光雷达的尺度是准的，两对点距离差 5% 以上多半点错了），然后吸附到横平竖直、再按墙精修一轮。
struct ManualAlignView: View {
    let existing: Data
    let scan: Data
    var onDone: (MapARTransform) -> Void

    @State private var target: [Point2] = []
    @State private var source: [Point2] = []

    private var solved: (transform: MapARTransform, scaleRatio: Double)? {
        guard target.count == 2, source.count == 2 else { return nil }
        return RigidAlign2D.twoPoints(targetA: target[0], targetB: target[1], sourceA: source[0], sourceB: source[1])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("在上面的旧地图上依次点 A、B 两个点，再在下面这次扫的图上点同样的 A、B（同一扇门的两边、同一个墙角……两点隔远一点更准）。点错了再点一下会重新开始。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("旧地图（\(target.count) / 2）").font(.caption.weight(.semibold))
            ScanPlanCanvas(layers: [ScanPlanCanvas.Layer(json: existing, color: .gray)], markers: target) { p in
                target = target.count >= 2 ? [p] : target + [p]
            }
            Text("这次扫的（\(source.count) / 2）").font(.caption.weight(.semibold))
            ScanPlanCanvas(layers: [ScanPlanCanvas.Layer(json: scan, color: .accentColor)], markers: source) { p in
                source = source.count >= 2 ? [p] : source + [p]
            }
            if let s = solved {
                let off = abs(s.scaleRatio - 1) * 100
                Text("两对点的距离比 \(Fmt.f(s.scaleRatio, 3))" + (off > 5 ? "：差了 \(Fmt.f(off, 0))%，多半点错了，再点一次" : "，可以用"))
                    .font(.footnote).foregroundStyle(off > 5 ? Color.orange : Color.secondary)
            }
            Button {
                guard let s = solved else { return }
                onDone(refine(s.transform))
            } label: {
                Label("用这两对点对齐", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(solved == nil)
        }
        .padding()
        .navigationTitle("手动对齐")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 吸附到 90° 的整数倍（两段扫描都已转正），再按墙精修一轮
    private func refine(_ t: MapARTransform) -> MapARTransform {
        let snapped = RigidAlign2D.snapToAxes(t, withinDeg: 5)
        guard let tf = try? RigidAlign2D.Features(mapJSON: existing), let sf = try? RigidAlign2D.Features(mapJSON: scan) else { return snapped }
        return RigidAlign2D.refine(snapped, target: tf, source: sf)
    }
}
