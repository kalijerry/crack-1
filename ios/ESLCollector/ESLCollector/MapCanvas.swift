import HPASSKit
import SwiftUI

// MARK: - 坐标变换

/// 地图（厘米）↔ 屏幕（点）的仿射变换。
///
/// 地图坐标系：+x 向右、**+y 向下**（见 HPASSKit 的单位约定）。
/// SwiftUI 的屏幕坐标 y 也向下，所以这里**不做翻转**，只有缩放和平移。
struct MapTransform {
    /// 屏幕点 / 厘米
    var scale: Double
    /// 地图原点在屏幕上的位置（点）
    var origin: CGPoint

    func toScreen(_ p: Point2) -> CGPoint {
        CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
    }

    func toMap(_ pt: CGPoint) -> Point2 {
        guard scale > 0 else { return .zero }
        return Point2(Double(pt.x - origin.x) / scale, Double(pt.y - origin.y) / scale)
    }

    /// 厘米长度 → 屏幕长度
    func len(_ cm: Double) -> CGFloat { CGFloat(max(cm, 0) * scale) }
}

// MARK: - 地图视图

/// Canvas 绘制的门店地图 + 定位叠加层。支持双指缩放、拖动平移、点击取坐标。
struct MapCanvas: View {

    let map: StoreMap?
    var fingerprints: [FingerprintPoint] = []
    /// 当前匹配到的指纹点编号（高亮）
    var matchedPointId: String?
    /// 走过的轨迹（cm）
    var trail: [Point2] = []
    /// 当前显示位置（cm）
    var position: Point2?
    /// 航向（弧度，0 = 地图 +y）
    var headingRad: Double = 0
    /// 1σ 不确定度（cm）
    var uncertaintyCm: Double = 0
    /// 原始指纹定位结果（与融合结果不同时画成空心圈）
    var rawEstimate: Point2?
    var route: Route?
    var showFingerprints = true
    /// 点击地图回调，参数是地图坐标（cm）
    var onTap: ((Point2) -> Void)?

    // 地磁页用到的附加层和手势
    /// 手动定的点位
    var markPoints: [MarkPoint] = []
    var targetId: String?
    var highlightId: String?
    /// 画 1 m 方格（没有货架的小测试区用）
    var gridCm: Double?
    /// 建图采集进度：每条通道每 `crossBinCm` 一段（数量须与 map.crosses 一致）。
    /// 采过的段都带一条半透明绿带：中间是绿色实线 = 还是孤立的一段；黑色虚线 = 已经和别的路段关联起来。
    var crossStates: [[CoverageState]] = []
    var crossBinCm: Double = 100
    /// 涂色图层（有它时画涂色，通道只画淡淡的底）
    var paintLayer: PaintLayer?
    /// 当前位置画一个涂色圆圈（cm）；nil 不画
    var paintRadiusCm: Double?
    /// 最近没涂的地方：橙色圈 + 从我这里指过去的虚线
    var nextTarget: Point2?
    /// 宽通道的建议走线（虚线）
    var laneGuides: [(Point2, Point2)] = []
    /// 本次采集区域的通道段（紫色高亮）：两端、通道宽（cm）
    var zoneSegments: [(Point2, Point2, Double)] = []
    /// 进区入口（紫色圈）：从这里进，先沿已采路段走一段
    var zoneEntry: Point2?
    /// 路线规划的下一段（橙色粗线 + 箭头，从 .0 走到 .1）
    var nextLane: (Point2, Point2)?
    /// 可能变了的地方（1 m 的橙色方块）
    var alertSpots: [Point2] = []
    /// 寻找模式：高亮这个货架（红框）
    var highlightShelf: String?
    var showHeading = true
    /// 位置已冻结（定位丢失）：画成灰色
    var positionStale = false
    /// 设朝向中：箭头画长、橙色；拖动 / 点击不再平移，而是把方向交给 onHeadingPoint
    var headingEditing = false
    var onLongPress: ((Point2) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onHeadingPoint: ((Point2) -> Void)?

    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var dragMoved = false
    // 长按 / 双击都在同一个拖动手势里判断，不另外加手势，免得挡住双指缩放
    @State private var touchStart: Date?
    @State private var lastTapTime: Date?
    @State private var lastTapLoc: CGPoint = .zero

    /// 画布留白（点）
    private let padding: CGFloat = 12
    /// 原始结果与融合结果相差多少厘米才单独画出来
    private let rawMarkerThresholdCm: Double = 50

    var body: some View {
        GeometryReader { geo in
            let extent = Self.extent(map: map, fingerprints: fingerprints)
            ZStack(alignment: .topTrailing) {
                Canvas { ctx, size in
                    let t = transform(extent: extent, size: size)
                    draw(ctx: ctx, t: t)
                }
                .background(Color(.secondarySystemBackground))
                .contentShape(Rectangle())
                .gesture(dragGesture(extent: extent, size: geo.size))
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { v in pinch = v }
                        .onEnded { v in
                            zoom = min(max(zoom * v, 0.5), 20)
                            pinch = 1
                        }
                )

                if map == nil {
                    Text("未导入地图")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }

                if !isIdentity {
                    LoggedButton("回到全图") {
                        withAnimation(.easeOut(duration: 0.2)) {
                            zoom = 1
                            pinch = 1
                            pan = .zero
                            dragOffset = .zero
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .padding(8)
                }
            }
        }
    }

    private var isIdentity: Bool {
        abs(zoom - 1) < 0.001 && abs(pan.width) < 0.5 && abs(pan.height) < 0.5
    }

    // MARK: 手势

    /// 用一个 minimumDistance = 0 的拖动手势同时实现「平移」和「点击」，
    /// 避免 TapGesture 与 DragGesture 互相抢占。移动不超过 10 点视为点击。
    private func dragGesture(extent: CGRect, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if touchStart == nil { touchStart = Date() }
                if headingEditing, let onHeadingPoint {
                    onHeadingPoint(transform(extent: extent, size: size).toMap(v.location))
                    return
                }
                if abs(v.translation.width) > 10 || abs(v.translation.height) > 10 { dragMoved = true }
                if dragMoved { dragOffset = v.translation }
            }
            .onEnded { v in
                let held = touchStart.map { Date().timeIntervalSince($0) } ?? 0
                touchStart = nil
                if headingEditing {
                    // 设朝向中：拖动 / 点击只用来指方向；但「再双击」要能被识别，用来确定
                    let moved = hypot(v.translation.width, v.translation.height) > 12
                    let now = Date()
                    if !moved, let onDoubleTap, let last = lastTapTime,
                       now.timeIntervalSince(last) < 0.5,
                       hypot(v.startLocation.x - lastTapLoc.x, v.startLocation.y - lastTapLoc.y) < 40 {
                        lastTapTime = nil
                        onDoubleTap()
                    } else {
                        lastTapTime = moved ? nil : now
                        lastTapLoc = v.startLocation
                    }
                    dragOffset = .zero
                    dragMoved = false
                    return
                }
                if dragMoved {
                    pan.width += v.translation.width
                    pan.height += v.translation.height
                } else {
                    let t = transform(extent: extent, size: size)
                    let now = Date()
                    if held >= 0.5, let onLongPress {
                        // 长按：按住不动 0.5 s 以上，松手时生效
                        onLongPress(t.toMap(v.startLocation))
                        lastTapTime = nil
                    } else if let onDoubleTap, let last = lastTapTime,
                              now.timeIntervalSince(last) < 0.4,
                              hypot(v.startLocation.x - lastTapLoc.x, v.startLocation.y - lastTapLoc.y) < 30 {
                        lastTapTime = nil
                        onDoubleTap()
                    } else {
                        lastTapTime = now
                        lastTapLoc = v.startLocation
                        onTap?(t.toMap(v.startLocation))
                    }
                }
                dragOffset = .zero
                dragMoved = false
            }
    }

    // MARK: 变换

    /// 地图内容的外接矩形（cm）。地图为空或退化时给一个 1×1 的兜底，避免除零。
    static func extent(map: StoreMap?, fingerprints: [FingerprintPoint]) -> CGRect {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        func include(_ x: Double, _ y: Double) {
            guard x.isFinite, y.isFinite else { return }
            minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
            minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
        }

        if let m = map {
            if m.width > 0 && m.height > 0 {
                include(0, 0)
                include(m.width, m.height)
            }
            for s in m.shelves {
                let r = Swift.max(s.width, s.height) * 0.5
                include(s.x - r, s.y - r)
                include(s.x + r, s.y + r)
            }
            for c in m.crosses {
                let half = Swift.max(c.lineWidth, 0) * 0.5
                include(Swift.min(c.a.x, c.b.x) - half, Swift.min(c.a.y, c.b.y) - half)
                include(Swift.max(c.a.x, c.b.x) + half, Swift.max(c.a.y, c.b.y) + half)
            }
            for o in m.others {
                let r = Swift.max(o.width, o.height) * 0.5
                include(o.x - r, o.y - r)
                include(o.x + r, o.y + r)
            }
        }
        for p in fingerprints { include(p.x, p.y) }

        guard minX <= maxX, minY <= maxY else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let w = Swift.max(maxX - minX, 1)
        let h = Swift.max(maxY - minY, 1)
        return CGRect(x: minX, y: minY, width: w, height: h)
    }

    private func transform(extent: CGRect, size: CGSize) -> MapTransform {
        let availW = Swift.max(Double(size.width) - Double(padding) * 2, 1)
        let availH = Swift.max(Double(size.height) - Double(padding) * 2, 1)
        let ew = Swift.max(Double(extent.width), 1)
        let eh = Swift.max(Double(extent.height), 1)
        let base = Swift.min(availW / ew, availH / eh)
        let z = Swift.max(Double(zoom * pinch), 0.01)
        let scale = Swift.max(base * z, 1e-6)

        // 先按 aspect fit 居中，再叠加用户平移
        let cx = Double(size.width) * 0.5 - (Double(extent.midX) * scale)
        let cy = Double(size.height) * 0.5 - (Double(extent.midY) * scale)
        let dx = Double(pan.width + dragOffset.width)
        let dy = Double(pan.height + dragOffset.height)
        return MapTransform(scale: scale, origin: CGPoint(x: cx + dx, y: cy + dy))
    }

    // MARK: 绘制

    private func draw(ctx: GraphicsContext, t: MapTransform) {
        guard let m = map else { return }

        if let g = gridCm, g > 0, m.width > 0, m.height > 0 {
            var grid = Path()
            var x = 0.0
            while x <= m.width + 0.5 {
                grid.move(to: t.toScreen(Point2(x, 0)))
                grid.addLine(to: t.toScreen(Point2(x, m.height)))
                x += g
            }
            var y = 0.0
            while y <= m.height + 0.5 {
                grid.move(to: t.toScreen(Point2(0, y)))
                grid.addLine(to: t.toScreen(Point2(m.width, y)))
                y += g
            }
            ctx.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.8)
        }

        // 房间地面
        if !m.floor.isEmpty {
            var fp = Path()
            for poly in m.floor where poly.count >= 3 {
                fp.move(to: t.toScreen(poly[0]))
                for q in poly.dropFirst() { fp.addLine(to: t.toScreen(q)) }
                fp.closeSubpath()
            }
            ctx.fill(fp, with: .color(Color.blue.opacity(0.06)))
        }

        // 本次采集区域：紫色底
        if !zoneSegments.isEmpty {
            for (a, b, w) in zoneSegments {
                var zp = Path(); zp.move(to: t.toScreen(a)); zp.addLine(to: t.toScreen(b))
                ctx.stroke(zp, with: .color(Color.purple.opacity(0.22)), style: StrokeStyle(lineWidth: Swift.max(t.len(w + 60), 4), lineCap: .butt))
            }
        }
        // 涂色图层：每格一个像素，按地图范围缩放，不插值
        if let pl = paintLayer {
            let o = t.toScreen(Point2(Double(pl.rect.minX), Double(pl.rect.minY)))
            let r = CGRect(x: o.x, y: o.y, width: t.len(Double(pl.rect.width)), height: t.len(Double(pl.rect.height)))
            ctx.draw(Image(decorative: pl.image, scale: 1).interpolation(.none), in: r)
        }

        // 通道：半透明粗线
        let coloring = crossStates.count == m.crosses.count && !crossStates.isEmpty
        for (i, c) in m.crosses.enumerated() {
            if coloring {
                drawCoverage(ctx: ctx, t: t, cross: c, states: crossStates[i])
                continue
            }
            var p = Path()
            p.move(to: t.toScreen(c.a))
            p.addLine(to: t.toScreen(c.b))
            let w = Swift.max(t.len(c.lineWidth), 1.5)
            if paintLayer == nil {          // 有涂色时通道宽度已经由涂色图层表示
                ctx.stroke(p, with: .color(Color.blue.opacity(0.14)),
                           style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
            ctx.stroke(p, with: .color(Color.blue.opacity(0.35)), lineWidth: 0.6)
        }

        // 其他元素和货架：几千个矩形预先合成三条路径（地图坐标，缓存），每帧只做一次缩放平移再画，
        // 不再逐个画几千次（拖动大图时这是主要开销）
        let cached = ShelfPathCache.shared.paths(for: m)
        var mc = ctx
        mc.concatenate(CGAffineTransform(a: CGFloat(t.scale), b: 0, c: 0, d: CGFloat(t.scale), tx: t.origin.x, ty: t.origin.y))
        let px = 1 / CGFloat(Swift.max(t.scale, 1e-6))          // 1 屏幕点对应的地图长度
        mc.fill(cached.others, with: .color(.gray.opacity(0.18)))
        mc.fill(cached.standard, with: .color(.gray.opacity(0.35)))
        mc.stroke(cached.standard, with: .color(.gray.opacity(0.7)), lineWidth: 0.6 * px)
        mc.stroke(cached.nonStandard, with: .color(.gray.opacity(0.25)), lineWidth: 0.4 * px)

        // 房间扫描的墙 / 门 / 窗：墙深色、门棕色、窗浅蓝（门店地图没有这些类型）
        for o in m.others {
            let color: Color
            switch o.shapeType {
            case "MapWall": color = Color.primary.opacity(0.75)
            case "MapDoor": color = Color.brown
            case "MapWindow": color = Color.cyan
            case "MapOpening": color = Color.green.opacity(0.6)
            default: continue
            }
            let p = MapCanvas.rectPath(cx: o.x, cy: o.y, w: o.width, h: Swift.max(o.height, 8), rotation: o.rotation, t: t)
            ctx.fill(p, with: .color(color))
        }
        // 房间家具的名字（Room-bed-1 → 床）
        for s in m.shelves where s.code.hasPrefix("Room-") {
            let parts = s.code.split(separator: "-")
            guard parts.count >= 2 else { continue }
            ctx.draw(Text(RoomCategory.label(String(parts[1]))).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary),
                     at: t.toScreen(Point2(s.x, s.y)), anchor: .center)
        }

        // 指纹点
        if showFingerprints {
            for p in fingerprints {
                let c = t.toScreen(p.position)
                let hit = matchedPointId != nil && p.id == matchedPointId
                let r: CGFloat = hit ? 5 : 2
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect),
                         with: .color(hit ? Color.orange : Color.secondary.opacity(0.45)))
            }
        }

        // 规划路线
        if let route, route.nodes.count >= 2 {
            var p = Path()
            p.move(to: t.toScreen(route.nodes[0].point))
            for n in route.nodes.dropFirst() { p.addLine(to: t.toScreen(n.point)) }
            ctx.stroke(p, with: .color(.green),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            for n in route.nodes where n.isTarget {
                let c = t.toScreen(n.point)
                let rect = CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)
                ctx.fill(Path(rect), with: .color(.green))
                ctx.stroke(Path(rect), with: .color(.white), lineWidth: 1)
            }
        }

        // 走过的轨迹
        if trail.count >= 2 {
            var p = Path()
            p.move(to: t.toScreen(trail[0]))
            for q in trail.dropFirst() { p.addLine(to: t.toScreen(q)) }
            ctx.stroke(p, with: .color(.purple.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }

        // 手动定的点位
        if !markPoints.isEmpty {
            if markPoints.count > 1 {
                var line = Path()
                for (i, p) in markPoints.enumerated() {
                    i == 0 ? line.move(to: t.toScreen(p.position)) : line.addLine(to: t.toScreen(p.position))
                }
                ctx.stroke(line, with: .color(.secondary.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
            for p in markPoints {
                let c = t.toScreen(p.position)
                if p.id == targetId || p.id == highlightId {
                    let ring = CGRect(x: c.x - 15, y: c.y - 15, width: 30, height: 30)
                    ctx.stroke(Path(ellipseIn: ring), with: .color(p.id == targetId ? .green : .blue), lineWidth: 3)
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)), with: .color(.orange))
                ctx.draw(Text(p.id).font(.system(size: 10, weight: .semibold)).foregroundColor(.black),
                         at: c, anchor: .center)
            }
        }

        // 原始指纹结果（与显示位置明显不同时画空心圈）
        if let raw = rawEstimate,
           position == nil || raw.distance(to: position ?? raw) > rawMarkerThresholdCm {
            let c = t.toScreen(raw)
            let rect = CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)
            ctx.stroke(Path(ellipseIn: rect), with: .color(.orange), lineWidth: 2)
        }

        // 宽通道建议走线
        if !laneGuides.isEmpty {
            var lp = Path()
            for (a, b) in laneGuides { lp.move(to: t.toScreen(a)); lp.addLine(to: t.toScreen(b)) }
            ctx.stroke(lp, with: .color(Color.green.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
        }
        // 寻找模式：目标货架红框 + 中心红点
        if let code = highlightShelf, let s = m.shelves.first(where: { $0.code == code }) {
            let p = MapCanvas.rectPath(cx: s.x, cy: s.y, w: s.width, h: s.height, rotation: s.rotation, t: t)
            ctx.fill(p, with: .color(Color.red.opacity(0.25)))
            ctx.stroke(p, with: .color(.red), lineWidth: 2.5)
            let c = t.toScreen(Point2(s.x, s.y))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24)), with: .color(.red), lineWidth: 2)
        }
        // 可能变了的地方
        for sp in alertSpots {
            let c = t.toScreen(sp), r = Swift.max(t.len(50), 3)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(rect), with: .color(Color.orange.opacity(0.35)))
            ctx.stroke(Path(rect), with: .color(.orange), lineWidth: 1.2)
        }
        // 进区入口
        if let e = zoneEntry {
            let c = t.toScreen(e)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)), with: .color(.purple), lineWidth: 3)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.purple))
        }
        // 路线规划：下一段
        if case let (a, b)? = nextLane {
            let sa = t.toScreen(a), sb = t.toScreen(b)
            var lp = Path(); lp.move(to: sa); lp.addLine(to: sb)
            ctx.stroke(lp, with: .color(Color.orange.opacity(0.85)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            let ang = atan2(sb.y - sa.y, sb.x - sa.x)
            var head = Path()
            head.move(to: sb)
            head.addLine(to: CGPoint(x: sb.x - 12 * cos(ang - 0.45), y: sb.y - 12 * sin(ang - 0.45)))
            head.move(to: sb)
            head.addLine(to: CGPoint(x: sb.x - 12 * cos(ang + 0.45), y: sb.y - 12 * sin(ang + 0.45)))
            ctx.stroke(head, with: .color(.orange), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        // 最近没涂的地方
        if let tg = nextTarget, nextLane == nil {
            let c = t.toScreen(tg)
            if let pos = position {
                var lp = Path()
                lp.move(to: t.toScreen(pos)); lp.addLine(to: c)
                ctx.stroke(lp, with: .color(Color.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
            }
            let rect = CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)
            ctx.stroke(Path(ellipseIn: rect), with: .color(.orange), lineWidth: 2.5)
        }

        // 当前位置：不确定度圆 + 实心点 + 航向箭头
        if let pos = position {
            let c = t.toScreen(pos)
            if let pr = paintRadiusCm {
                // 涂色圆圈：走过的地方按这个圈涂
                let r = Swift.max(t.len(pr), 3)
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(Color.green.opacity(0.18)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(Color.green), lineWidth: 1.5)
            }
            if uncertaintyCm > 0 {
                let r = Swift.max(t.len(uncertaintyCm), 4)
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(.accentColor.opacity(0.15)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(.accentColor.opacity(0.4)), lineWidth: 0.8)
            }
            // 航向：dx = L·sinθ，dy = L·cosθ（地图系，y 向下）
            if headingRad.isFinite && showHeading {
                let L: CGFloat = headingEditing ? 70 : 26
                let arrowColor: Color = headingEditing ? .orange : .accentColor
                let tip = CGPoint(x: c.x + L * CGFloat(sin(headingRad)),
                                  y: c.y + L * CGFloat(cos(headingRad)))
                var arrow = Path()
                arrow.move(to: c)
                arrow.addLine(to: tip)
                ctx.stroke(arrow, with: .color(arrowColor),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                // 箭头两翼
                let back = headingRad + .pi
                for side in [0.45, -0.45] {
                    let a = back + side
                    var wing = Path()
                    wing.move(to: tip)
                    wing.addLine(to: CGPoint(x: tip.x + 8 * CGFloat(sin(a)),
                                             y: tip.y + 8 * CGFloat(cos(a))))
                    ctx.stroke(wing, with: .color(arrowColor),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }
            let rect = CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)
            ctx.fill(Path(ellipseIn: rect), with: .color(positionStale ? .gray : .accentColor))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
        }
    }

    /// 一条通道的采集进度。采过的段带一条半透明绿带；带中间的线：
    /// 绿色实线 = 孤立的一段，黑色虚线 = 已经和别的路段关联起来。没采完的段只画一条淡淡的细线。
    private func drawCoverage(ctx: GraphicsContext, t: MapTransform, cross c: CrossSegment, states: [CoverageState]) {
        let len = c.a.distance(to: c.b)
        guard len > 1, !states.isEmpty else { return }
        func point(_ s: Double) -> CGPoint {
            let f = Swift.min(Swift.max(s / len, 0), 1)
            return t.toScreen(Point2(c.a.x + (c.b.x - c.a.x) * f, c.a.y + (c.b.y - c.a.y) * f))
        }
        let band = Swift.max(t.len(c.lineWidth), 3)
        var k = 0
        while k < states.count {
            let state = states[k]
            var e = k
            while e + 1 < states.count && states[e + 1] == state { e += 1 }
            var p = Path()
            p.move(to: point(Double(k) * crossBinCm))
            p.addLine(to: point(Swift.min(Double(e + 1) * crossBinCm, len)))
            switch state {
            case .none:
                ctx.stroke(p, with: .color(Color.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 0.8, lineCap: .butt))
            case .partial:
                // 只走了一个方向：橙色，提醒反方向再走一遍
                ctx.stroke(p, with: .color(Color.orange.opacity(0.30)), style: StrokeStyle(lineWidth: band, lineCap: .butt))
                ctx.stroke(p, with: .color(Color.orange), style: StrokeStyle(lineWidth: 1.8, lineCap: .butt))
            case .isolated:
                ctx.stroke(p, with: .color(Color.green.opacity(0.28)), style: StrokeStyle(lineWidth: band, lineCap: .butt))
                ctx.stroke(p, with: .color(Color.green), style: StrokeStyle(lineWidth: 1.8, lineCap: .butt))
            case .linked:
                ctx.stroke(p, with: .color(Color.green.opacity(0.28)), style: StrokeStyle(lineWidth: band, lineCap: .butt))
                ctx.stroke(p, with: .color(Color.primary.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .butt, dash: [5, 4]))
            }
            k = e + 1
        }
    }

    /// 旋转矩形的四角路径。约定与 HPASSKit 的 `RouteGeometry.rectAxes` 一致：
    /// u =(cos,sin) 对应 width 方向，v =(−sin,cos) 对应 height 方向。
    static func rectPath(cx: Double, cy: Double, w: Double, h: Double,
                         rotation: Double, t: MapTransform) -> Path {
        let r = rotation * Double.pi / 180.0
        let co = cos(r)
        let si = sin(r)
        let ux = co, uy = si
        let vx = -si, vy = co
        let hw = w * 0.5
        let hh = h * 0.5
        let corners: [Point2] = [
            Point2(cx - ux * hw - vx * hh, cy - uy * hw - vy * hh),
            Point2(cx + ux * hw - vx * hh, cy + uy * hw - vy * hh),
            Point2(cx + ux * hw + vx * hh, cy + uy * hw + vy * hh),
            Point2(cx - ux * hw + vx * hh, cy - uy * hw + vy * hh),
        ]
        var path = Path()
        path.move(to: t.toScreen(corners[0]))
        for c in corners.dropFirst() { path.addLine(to: t.toScreen(c)) }
        path.closeSubpath()
        return path
    }
}


/// 把地图里几千个矩形合成三条路径（地图坐标，cm），按地图缓存。
final class ShelfPathCache {
    static let shared = ShelfPathCache()
    private var key = ""
    private var cached = (standard: Path(), nonStandard: Path(), others: Path())

    func paths(for m: StoreMap) -> (standard: Path, nonStandard: Path, others: Path) {
        let k = "\(Int(m.width))x\(Int(m.height))/\(m.shelves.count)/\(m.others.count)/\(m.shelves.first?.x ?? 0),\(m.shelves.first?.y ?? 0)"
        if k == key { return cached }
        let id = MapTransform(scale: 1, origin: .zero)
        var std = Path(), non = Path(), oth = Path()
        for s in m.shelves {
            let p = MapCanvas.rectPath(cx: s.x, cy: s.y, w: s.width, h: s.height, rotation: s.rotation, t: id)
            if s.kind == .standard { std.addPath(p) } else { non.addPath(p) }
        }
        for o in m.others {
            oth.addPath(MapCanvas.rectPath(cx: o.x, cy: o.y, w: o.width, h: o.height, rotation: o.rotation, t: id))
        }
        cached = (std, non, oth)
        key = k
        return cached
    }
}
