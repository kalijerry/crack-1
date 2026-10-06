import Foundation

/// 把通道中心线（`MapCross`，带宽度）栅格化成「能走的地方」，并记录每格的通道走向。
///
/// 定位用它做两件事：
/// 1. 粒子不能穿货架：新位置不在通道里、或一步走过去中途穿过货架，就扣分；
/// 2. 通道走向先验：在单一走向的通道里，行走方向应该沿通道轴线（门店货架几乎全是 0°/90°）。
///    路口、岔口的格子有多个走向，不施加走向约束。
public struct WalkableMap {
    public let widthCm: Double
    public let heightCm: Double
    public let cellCm: Double
    public let cols: Int
    public let rows: Int

    /// 每格的状态：0 不可走；1 可走，走向未定（路口）；2 可走，走向见 `axis`。
    private var state: [UInt8]
    /// 通道走向，弧度，范围 [0, π)。只在 state == 2 时有意义。
    private var axis: [Float]
    private var walkableIndices: [Int] = []

    /// - Parameters:
    ///   - marginCm: 在通道宽度之外再放宽多少，容忍地图中心线与真实通道的偏差。
    public init(crosses: [CrossSegment], widthCm: Double, heightCm: Double,
                cellCm: Double = 25, marginCm: Double = 20) {
        precondition(widthCm > 0 && heightCm > 0 && cellCm > 0)
        self.widthCm = widthCm
        self.heightCm = heightCm
        self.cellCm = cellCm
        cols = Int((widthCm / cellCm).rounded(.up))
        rows = Int((heightCm / cellCm).rounded(.up))
        state = [UInt8](repeating: 0, count: cols * rows)
        axis = [Float](repeating: 0, count: cols * rows)

        for c in crosses {
            let dx = c.b.x - c.a.x, dy = c.b.y - c.a.y
            let len2 = dx * dx + dy * dy
            guard len2 > 1e-6 else { continue }
            var ang = atan2(dy, dx)
            if ang < 0 { ang += Double.pi }
            if ang >= Double.pi { ang -= Double.pi }
            let half = max(c.lineWidth, 0) / 2 + marginCm
            let minX = min(c.a.x, c.b.x) - half, maxX = max(c.a.x, c.b.x) + half
            let minY = min(c.a.y, c.b.y) - half, maxY = max(c.a.y, c.b.y) + half
            let i0 = max(Int(minX / cellCm), 0), i1 = min(Int(maxX / cellCm), cols - 1)
            let j0 = max(Int(minY / cellCm), 0), j1 = min(Int(maxY / cellCm), rows - 1)
            guard i0 <= i1, j0 <= j1 else { continue }
            for j in j0...j1 {
                for i in i0...i1 {
                    let px = (Double(i) + 0.5) * cellCm, py = (Double(j) + 0.5) * cellCm
                    let t = min(max(((px - c.a.x) * dx + (py - c.a.y) * dy) / len2, 0), 1)
                    let qx = c.a.x + t * dx, qy = c.a.y + t * dy
                    guard hypot(px - qx, py - qy) <= half else { continue }
                    let k = j * cols + i
                    if state[k] == 0 {
                        state[k] = 2
                        axis[k] = Float(ang)
                    } else if state[k] == 2 {
                        // 与已有走向差超过 20° 就是路口
                        var d = abs(Double(axis[k]) - ang)
                        d = min(d, Double.pi - d)
                        if d > 20 * Double.pi / 180 { state[k] = 1 }
                    }
                }
            }
        }
        for k in 0..<state.count where state[k] != 0 { walkableIndices.append(k) }
    }

    public var walkableCellCount: Int { walkableIndices.count }
    /// 可走面积（m²）。
    public var walkableAreaM2: Double { Double(walkableIndices.count) * cellCm * cellCm / 10_000 }

    private func index(_ p: Point2) -> Int? {
        guard p.x >= 0, p.y >= 0 else { return nil }
        let i = Int(p.x / cellCm), j = Int(p.y / cellCm)
        guard i < cols, j < rows else { return nil }
        return j * cols + i
    }

    public func isWalkable(_ p: Point2) -> Bool {
        guard let k = index(p) else { return false }
        return state[k] != 0
    }

    /// p 所在格的通道走向（弧度，[0, π)）。不可走或路口返回 nil。
    public func axisAngle(at p: Point2) -> Double? {
        guard let k = index(p), state[k] == 2 else { return nil }
        return Double(axis[k])
    }

    /// 从 a 到 b 的直线是否一路都在可走区域里（每半格检查一次）。
    public func isSegmentClear(from a: Point2, to b: Point2) -> Bool {
        let d = a.distance(to: b)
        let n = max(Int(d / (cellCm * 0.5)), 1)
        for s in 1...n {
            let t = Double(s) / Double(n)
            if !isWalkable(Point2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)) { return false }
        }
        return true
    }

    /// 可走区域内均匀随机取一点。没有可走格时返回 nil。
    func randomPoint(u1: Double, u2: Double, u3: Double) -> Point2? {
        guard !walkableIndices.isEmpty else { return nil }
        let k = walkableIndices[min(Int(u1 * Double(walkableIndices.count)), walkableIndices.count - 1)]
        let i = k % cols, j = k / cols
        return Point2((Double(i) + u2) * cellCm, (Double(j) + u3) * cellCm)
    }

    /// 离 p 最近的可走格中心，在 radiusCm 内找；找不到返回 nil。
    public func nearestWalkable(to p: Point2, radiusCm: Double) -> Point2? {
        if isWalkable(p) { return p }
        let r = Int((radiusCm / cellCm).rounded(.up))
        guard let k0 = index(Point2(min(max(p.x, 0), widthCm - 1), min(max(p.y, 0), heightCm - 1))) else { return nil }
        let i0 = k0 % cols, j0 = k0 / cols
        var best: Point2?
        var bd = radiusCm
        for dj in -r...r {
            for di in -r...r {
                let i = i0 + di, j = j0 + dj
                guard i >= 0, i < cols, j >= 0, j < rows, state[j * cols + i] != 0 else { continue }
                let c = Point2((Double(i) + 0.5) * cellCm, (Double(j) + 0.5) * cellCm)
                let d = c.distance(to: p)
                if d < bd { bd = d; best = c }
            }
        }
        return best
    }
}
