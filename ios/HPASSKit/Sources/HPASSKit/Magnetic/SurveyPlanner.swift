import Foundation

/// 采集路线规划：把每条通道按宽度拆成「走线」（宽通道两边各一条、很宽的再加中线，窄通道一条），
/// 按涂色算每条走线完成了多少，给出「下一段该走哪条」和剩余工作量。
///
/// 下一段 = 离我最近的、还没涂完的走线（取它离我近的那一端当入口，朝另一端走）。贪心，不是全局最短，
/// 但每走完一段重算一次，实际走起来很顺，也不怕中途改路线。
public struct SurveyPlanner {
    public struct Lane {
        public var corridor: String
        public var a: Point2
        public var b: Point2
        /// 在通道里的位置：-1 左 / 0 中 / 1 右（相对 a→b 方向）
        public var side: Int
        public var length: Double { a.distance(to: b) }
    }

    public struct Next {
        public var lane: Lane
        /// 从哪头进、往哪头走
        public var from: Point2
        public var to: Point2
        /// 这条走线还没涂的长度（cm）
        public var remainingCm: Double
    }

    public let lanes: [Lane]
    /// 比这个宽的通道分两边走（圆圈直径 80 cm，走中间一趟涂不满）
    public static let wideCm = 100.0

    public init(crosses: [CrossSegment], radiusCm: Double) {
        var out: [Lane] = []
        for c in crosses {
            let d = c.b - c.a
            let len = d.length
            guard len > 150, c.lineWidth >= 50 else { continue }
            let n = Point2(-d.y / len, d.x / len)
            let half = c.lineWidth / 2
            var offs: [(Double, Int)] = []
            if c.lineWidth > Self.wideCm {
                offs = [(half - radiusCm, 1), (-(half - radiusCm), -1)]
                if c.lineWidth > 4 * radiusCm { offs.append((0, 0)) }
            } else {
                offs = [(0, 0)]
            }
            for (o, side) in offs { out.append(Lane(corridor: c.code, a: c.a + n * o, b: c.b + n * o, side: side)) }
        }
        lanes = out
    }

    init(lanes: [Lane]) { self.lanes = lanes }

    /// 只规划这些通道（采集区域）
    public func restricted(to corridors: Set<String>) -> SurveyPlanner {
        SurveyPlanner(lanes: lanes.filter { corridors.contains($0.corridor) })
    }

    /// 一条走线还没涂的长度（cm）
    public func remainingCm(_ l: Lane, _ p: CoveragePaint) -> Double { unpainted(l, p).0 }

    /// 走线上每 50 cm 一个点，看涂没涂：返回 (没涂的长度, 没涂的点)
    private func unpainted(_ l: Lane, _ p: CoveragePaint) -> (Double, [Point2]) {
        let n = max(Int(l.length / 50), 1)
        var pts: [Point2] = []
        for k in 0...n {
            let t = Double(k) / Double(n)
            let q = Point2(l.a.x + (l.b.x - l.a.x) * t, l.a.y + (l.b.y - l.a.y) * t)
            let i = Int(q.x / p.cellCm), j = Int(q.y / p.cellCm)
            guard i >= 0, j >= 0, i < p.cols, j < p.rows else { continue }
            let idx = j * p.cols + i
            if p.mask[idx] && p.counts[idx] == 0 { pts.append(q) }
        }
        return (Double(pts.count) * l.length / Double(n + 1), pts)
    }

    /// 所有走线还没涂的总长度（cm）
    public func remainingCm(_ p: CoveragePaint) -> Double {
        lanes.reduce(0) { $0 + unpainted($1, p).0 }
    }

    /// 下一段：离 pos 最近、还有 ≥ 1 m 没涂的走线
    public func next(from pos: Point2, paint p: CoveragePaint) -> Next? {
        var best: (Next, Double)?
        for l in lanes {
            let (rem, pts) = unpainted(l, p)
            guard rem >= 100, let first = pts.first, let last = pts.last else { continue }
            // 从没涂部分离我近的那头进
            let dFirst = first.distance(to: pos), dLast = last.distance(to: pos)
            let (from, to) = dFirst <= dLast ? (first, last) : (last, first)
            let d = min(dFirst, dLast)
            if best == nil || d < best!.1 { best = (Next(lane: l, from: from, to: to, remainingCm: rem), d) }
        }
        return best?.0
    }
}
