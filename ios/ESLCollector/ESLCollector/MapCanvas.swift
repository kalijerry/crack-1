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
    var showHeading = true
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
                    LongPressGesture(minimumDuration: 0.5)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onEnded { value in
                            guard let onLongPress, !headingEditing else { return }
                            if case .second(true, let drag?) = value {
                                onLongPress(transform(extent: extent, size: geo.size).toMap(drag.location))
                            }
                        }
                )
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).onEnded { _ in onDoubleTap?() }
                )
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
                if headingEditing, let onHeadingPoint {
                    onHeadingPoint(transform(extent: extent, size: size).toMap(v.location))
                    return
                }
                if abs(v.translation.width) > 10 || abs(v.translation.height) > 10 { dragMoved = true }
                if dragMoved { dragOffset = v.translation }
            }
            .onEnded { v in
                if headingEditing {
                    dragOffset = .zero
                    dragMoved = false
                    return
                }
                if dragMoved {
                    pan.width += v.translation.width
                    pan.height += v.translation.height
                } else if let onTap {
                    let t = transform(extent: extent, size: size)
                    onTap(t.toMap(v.startLocation))
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

        // 通道：半透明粗线
        for c in m.crosses {
            var p = Path()
            p.move(to: t.toScreen(c.a))
            p.addLine(to: t.toScreen(c.b))
            let w = Swift.max(t.len(c.lineWidth), 1.5)
            ctx.stroke(p, with: .color(.blue.opacity(0.14)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round))
            ctx.stroke(p, with: .color(.blue.opacity(0.35)), lineWidth: 0.6)
        }

        // 其他元素（柱子等）：浅浅画一下
        for o in m.others {
            let path = Self.rectPath(cx: o.x, cy: o.y, w: o.width, h: o.height, rotation: o.rotation, t: t)
            ctx.fill(path, with: .color(.gray.opacity(0.18)))
        }

        // 货架：旋转矩形
        for s in m.shelves {
            let path = Self.rectPath(cx: s.x, cy: s.y, w: s.width, h: s.height, rotation: s.rotation, t: t)
            ctx.fill(path, with: .color(.gray.opacity(0.35)))
            ctx.stroke(path, with: .color(.gray.opacity(0.7)), lineWidth: 0.6)
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

        // 当前位置：不确定度圆 + 实心点 + 航向箭头
        if let pos = position {
            let c = t.toScreen(pos)
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
            ctx.fill(Path(ellipseIn: rect), with: .color(.accentColor))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
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
