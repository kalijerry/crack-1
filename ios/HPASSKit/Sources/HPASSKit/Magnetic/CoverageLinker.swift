import Foundation

/// 采集进度里每一小段（默认 1 m）的状态。
public enum CoverageState: UInt8 {
    /// 还没采完。
    case none
    /// 只走了一个方向：还要反方向再走一遍（`CoverageLinker` 本身不产生它，由调用方按单向记录叠加）。
    case partial
    /// 已采完，但还是孤立的一段：没有和别的已采路段通过交叉口连起来。
    case isolated
    /// 已采完，并且已经和别的已采路段关联起来（共用一个交叉口 / T 形口，两边在路口附近都采过）。
    case linked
}

/// 判断已采集的通道段之间有没有「关联」起来。
///
/// 做法：
/// 1. 每条通道上连续采完的小段合成一个「段」；
/// 2. 找出通道之间的路口（线段相交、或一条通道的端点落在另一条通道上，容差 `junctionTolCm`）；
/// 3. 路口两边各自在 `reachCm` 范围内都有已采完的段，就把这两个段并成一组；
/// 4. 一组里有两个及以上的段就是「已关联」，只有一个就是「孤立」。
///
/// 全场采完、全部连通之后，所有已采的段都会变成 `linked`。
public enum CoverageLinker {

    public static func link(crosses: [CrossSegment], done: [[Bool]], binCm: Double,
                            junctionTolCm: Double = 80, reachCm: Double = 150) -> [[CoverageState]] {
        precondition(crosses.count == done.count, "done 的条数必须与通道数一致")
        // 1. 段
        var runOfBin: [[Int]] = done.map { [Int](repeating: -1, count: $0.count) }
        var runs: [(corridor: Int, from: Int, to: Int)] = []
        for (i, bins) in done.enumerated() {
            var k = 0
            while k < bins.count {
                guard bins[k] else { k += 1; continue }
                var e = k
                while e + 1 < bins.count && bins[e + 1] { e += 1 }
                for b in k...e { runOfBin[i][b] = runs.count }
                runs.append((i, k, e))
                k = e + 1
            }
        }
        // 并查集
        var parent = Array(0..<runs.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
            return r
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }

        /// 通道 i 上，离沿线位置 s（cm）reachCm 以内的已采段。
        func runsNear(_ i: Int, _ s: Double) -> Set<Int> {
            let bins = done[i]
            guard !bins.isEmpty else { return [] }
            let lo = max(Int(((s - reachCm) / binCm).rounded(.down)), 0)
            let hi = min(Int(((s + reachCm) / binCm).rounded(.down)), bins.count - 1)
            guard lo <= hi else { return [] }
            var out = Set<Int>()
            for b in lo...hi where runOfBin[i][b] >= 0 { out.insert(runOfBin[i][b]) }
            return out
        }

        // 2~3. 路口
        for i in 0..<crosses.count {
            for j in (i + 1)..<crosses.count {
                guard let (si, sj) = junction(crosses[i], crosses[j], tol: junctionTolCm) else { continue }
                let a = runsNear(i, si), b = runsNear(j, sj)
                for x in a { for y in b { union(x, y) } }
            }
        }

        // 4. 每组的段数
        var groupSize: [Int: Int] = [:]
        for r in 0..<runs.count { groupSize[find(r), default: 0] += 1 }
        return done.enumerated().map { i, bins in
            bins.indices.map { b -> CoverageState in
                let r = runOfBin[i][b]
                guard r >= 0 else { return .none }
                return (groupSize[find(r)] ?? 1) >= 2 ? .linked : .isolated
            }
        }
    }

    /// 两条通道的路口：返回路口分别在两条通道上的沿线位置（cm）。两线段最近距离大于容差时返回 nil。
    static func junction(_ a: CrossSegment, _ b: CrossSegment, tol: Double) -> (Double, Double)? {
        let d1 = Point2(a.b.x - a.a.x, a.b.y - a.a.y), d2 = Point2(b.b.x - b.a.x, b.b.y - b.a.y)
        let l1 = d1.length, l2 = d2.length
        guard l1 > 1, l2 > 1 else { return nil }
        // 平行（或几乎平行）的通道不算相交
        let cross = d1.cross(d2) / (l1 * l2)
        if abs(cross) < 0.05 { return nil }
        // 两条无限直线的交点参数
        let r = Point2(b.a.x - a.a.x, b.a.y - a.a.y)
        let denom = d1.cross(d2)
        let t = r.cross(d2) / denom          // a.a + t·d1
        let u = r.cross(d1) / denom          // b.a + u·d2
        // 参数夹到线段内，再看夹完之后两点够不够近（容差内的 T 形口、端点相接都算）
        let tc = min(max(t, 0), 1), uc = min(max(u, 0), 1)
        let pa = Point2(a.a.x + d1.x * tc, a.a.y + d1.y * tc)
        let pb = Point2(b.a.x + d2.x * uc, b.a.y + d2.y * uc)
        guard pa.distance(to: pb) <= tol else { return nil }
        return (tc * l1, uc * l2)
    }
}
