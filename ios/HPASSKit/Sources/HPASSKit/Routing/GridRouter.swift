import Foundation

/// 可走栅格上的 A*：通道图缺失（房间扫描）或不连通时的兜底。
///
/// 8 邻域，不允许斜着擦过不可走格的角；找到的格子路径再做“拉直”
/// （从当前点尽量远地直连到看得见的下一点），最后得到很少的折点。
public struct GridRouter {
    public let walkable: WalkableMap
    /// 起点 / 终点不在可走格上时，最多向外找多远（cm）
    public var snapRadiusCm: Double = 400

    public init(walkable: WalkableMap) { self.walkable = walkable }

    private struct Entry { var f: Double; var g: Double; var k: Int }

    /// 返回拉直后的折线（起点、终点都已吸附到可走格）；不可达返回 nil。
    public func path(from a: Point2, to b: Point2) -> [Point2]? {
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
        guard let s = walkable.nearestWalkable(to: a, radiusCm: snapRadiusCm),
              let g = walkable.nearestWalkable(to: b, radiusCm: snapRadiusCm) else { return nil }
        let cols = walkable.cols, rows = walkable.rows, cell = walkable.cellCm
        func idx(_ p: Point2) -> Int {
            min(max(Int(p.x / cell), 0), cols - 1) + min(max(Int(p.y / cell), 0), rows - 1) * cols
        }
        func center(_ k: Int) -> Point2 { Point2((Double(k % cols) + 0.5) * cell, (Double(k / cols) + 0.5) * cell) }
        let sk = idx(s), gk = idx(g)
        if sk == gk { return [s, g] }

        let gi = gk % cols, gj = gk / cols
        func h(_ k: Int) -> Double {
            let dx = Double(abs(k % cols - gi)), dy = Double(abs(k / cols - gj))
            return (dx + dy + (2.0.squareRoot() - 2) * min(dx, dy)) * cell
        }
        var best = [Double](repeating: .infinity, count: cols * rows)
        var prev = [Int32](repeating: -1, count: cols * rows)
        var heap = RouteBinaryHeap<Entry> { l, r in l.f != r.f ? l.f < r.f : l.k < r.k }
        best[sk] = 0
        heap.push(Entry(f: h(sk), g: 0, k: sk))
        let diag = 2.0.squareRoot() * cell
        var found = false
        while let e = heap.pop() {
            if e.g > best[e.k] { continue }
            if e.k == gk { found = true; break }
            let ci = e.k % cols, cj = e.k / cols
            for dj in -1...1 {
                for di in -1...1 where di != 0 || dj != 0 {
                    let ni = ci + di, nj = cj + dj
                    guard ni >= 0, ni < cols, nj >= 0, nj < rows else { continue }
                    let nk = nj * cols + ni
                    guard walkable.isWalkable(index: nk) else { continue }
                    if di != 0 && dj != 0 {
                        guard walkable.isWalkable(index: cj * cols + ni),
                              walkable.isWalkable(index: nj * cols + ci) else { continue }
                    }
                    let ng = e.g + (di != 0 && dj != 0 ? diag : cell)
                    if ng < best[nk] - 1e-9 {
                        best[nk] = ng
                        prev[nk] = Int32(e.k)
                        heap.push(Entry(f: ng + h(nk), g: ng, k: nk))
                    }
                }
            }
        }
        guard found else { return nil }
        var cells: [Int] = []
        var k = gk
        while k != sk { cells.append(k); k = Int(prev[k]) }
        cells.append(sk)
        cells.reverse()

        // 拉直：格子中心当候选点，起点 / 终点用吸附后的位置
        var pts = cells.map(center)
        pts[0] = s
        pts[pts.count - 1] = g
        var out: [Point2] = [pts[0]]
        var i = 0
        while i < pts.count - 1 {
            var j = pts.count - 1
            while j > i + 1 && !walkable.isSegmentClear(from: pts[i], to: pts[j]) { j -= 1 }
            out.append(pts[j])
            i = j
        }
        return out
    }
}
