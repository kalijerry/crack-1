import Foundation

/// 在门店地图的货架矩形上做射线投射：从某个位置沿某个方向，多远会撞到货架。
///
/// 用来预测 LiDAR / 深度相机应该在通道左右两侧测到多远的货架，与实测对比，
/// 得到「通道里横向在哪」这条很强的观测。货架用 `StoreMap.shelves`（中心 + 旋转，
/// 已由 `StoreDataLoader` 把左上角锚点换算好）。
/// 非线程安全；构造之后是只读的，可在多个线程同时查询。
public final class ShelfRaycaster {
    private struct Box {
        var cx, cy, hw, hh, c, s: Double       // u = (c, s) 沿 width，v = (−s, c) 沿 height
    }

    private let boxes: [Box]
    private let cell: Double
    private let cols: Int, rows: Int
    private let grid: [[Int32]]

    /// - Parameter excludingCodePrefixes: 编码以这些前缀开头的货架不参与（例如不是实物的虚拟货架）。
    public init(shelves: [ShelfRect], widthCm: Double, heightCm: Double,
                excludingCodePrefixes: [String] = [], cellCm: Double = 200) {
        cell = cellCm
        cols = max(Int((widthCm / cellCm).rounded(.up)), 1)
        rows = max(Int((heightCm / cellCm).rounded(.up)), 1)
        var bx: [Box] = []
        var g = [[Int32]](repeating: [], count: cols * rows)
        for s in shelves where !excludingCodePrefixes.contains(where: { s.code.hasPrefix($0) }) {
            let r = s.rotation * Double.pi / 180
            let b = Box(cx: s.x, cy: s.y, hw: s.width / 2, hh: s.height / 2, c: cos(r), s: sin(r))
            let ex = abs(b.c) * b.hw + abs(b.s) * b.hh, ey = abs(b.s) * b.hw + abs(b.c) * b.hh
            let i0 = max(Int((b.cx - ex) / cellCm), 0), i1 = min(Int((b.cx + ex) / cellCm), cols - 1)
            let j0 = max(Int((b.cy - ey) / cellCm), 0), j1 = min(Int((b.cy + ey) / cellCm), rows - 1)
            guard i0 <= i1, j0 <= j1 else { continue }
            let idx = Int32(bx.count)
            bx.append(b)
            for j in j0...j1 { for i in i0...i1 { g[j * cols + i].append(idx) } }
        }
        boxes = bx
        grid = g
    }

    public var shelfCount: Int { boxes.count }

    /// 从 p 沿 `angleRad`（地图系，0 = +y，dx = sin，dy = cos）射出去，到最近货架的距离（cm）。
    /// `maxCm` 内没有撞到返回 nil；起点就在货架里返回 0。
    public func distance(from p: Point2, angleRad: Double, maxCm: Double) -> Double? {
        let dx = sin(angleRad), dy = cos(angleRad)
        var best: Double?
        var seen = Set<Int32>()
        let step = cell / 2
        var t = 0.0
        while t <= maxCm + step {
            let x = p.x + dx * t, y = p.y + dy * t
            if x >= 0, y >= 0 {
                let i = Int(x / cell), j = Int(y / cell)
                if i < cols, j < rows {
                    for idx in grid[j * cols + i] where seen.insert(idx).inserted {
                        if let h = hit(boxes[Int(idx)], p, dx, dy), h <= maxCm, h < (best ?? .infinity) { best = h }
                    }
                }
            }
            if let b = best, b <= t { break }          // 已经找到比当前采样点更近的命中，后面的格子不可能更近
            t += step
        }
        return best
    }

    /// 以 `headingRad` 面朝的方向行走时，左右两侧最近的货架距离。
    /// 地图 y 向下，θ 增大 = 向左转，所以左手边方向是 θ + 90°。
    public func lateral(from p: Point2, headingRad: Double, maxCm: Double = 500) -> (left: Double?, right: Double?) {
        (distance(from: p, angleRad: headingRad + Double.pi / 2, maxCm: maxCm),
         distance(from: p, angleRad: headingRad - Double.pi / 2, maxCm: maxCm))
    }

    private func hit(_ b: Box, _ p: Point2, _ dx: Double, _ dy: Double) -> Double? {
        let ox = p.x - b.cx, oy = p.y - b.cy
        let lox = ox * b.c + oy * b.s, loy = -ox * b.s + oy * b.c
        let ldx = dx * b.c + dy * b.s, ldy = -dx * b.s + dy * b.c
        var tmin = -Double.infinity, tmax = Double.infinity
        for (o, d, h) in [(lox, ldx, b.hw), (loy, ldy, b.hh)] {
            if abs(d) < 1e-12 {
                if abs(o) > h { return nil }
            } else {
                var t1 = (-h - o) / d, t2 = (h - o) / d
                if t1 > t2 { swap(&t1, &t2) }
                tmin = max(tmin, t1)
                tmax = min(tmax, t2)
                if tmin > tmax { return nil }
            }
        }
        if tmax < 0 { return nil }
        return max(tmin, 0)
    }
}

/// 一次横向距离观测：用深度相机量到的左右两侧货架距离。
public struct LateralObservation {
    public var leftCm: Double?
    public var rightCm: Double?
    /// 测量时的行进方向（地图系，0 = +y）。
    public var headingRad: Double

    public init(leftCm: Double?, rightCm: Double?, headingRad: Double) {
        self.leftCm = leftCm
        self.rightCm = rightCm
        self.headingRad = headingRad
    }
}
