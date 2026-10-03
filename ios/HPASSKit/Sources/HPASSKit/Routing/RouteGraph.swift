import Foundation

// 通道图（无向加权图）+ Dijkstra + 带转弯惩罚的 A*。
// 几何约定见 RouteGeometry.swift 顶部。

/// 空间哈希的格子键。
/// 注意：Double 不适合直接做 Hashable 相等键（计算得到的坐标会有浮点误差），
/// 因此所有“按坐标查表”的地方都先量化成整数格子，再在 3×3 邻域内按真实距离比对。
struct RouteCellKey: Hashable {
    var ix: Int64
    var iy: Int64
}

/// 有向边（无向图按两条有向边存储）。
struct RouteGraphEdge {
    var to: Int
    var weight: Double
}

/// A* 状态键：(当前节点, 前驱节点)。带上前驱才能计算转弯惩罚。
struct RouteStateKey: Hashable {
    var node: Int
    var prev: Int
}

struct RouteDijkstraEntry {
    var node: Int
    var dist: Double
}

struct RouteAStarEntry {
    var f: Double
    var turns: Int
    var node: Int
    var state: Int
}

/// 极简二叉堆（优先队列）。比较器显式传入，保证排序完全确定。
struct RouteBinaryHeap<Element> {
    private var items: [Element] = []
    private let less: (Element, Element) -> Bool

    init(_ less: @escaping (Element, Element) -> Bool) {
        self.less = less
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    mutating func push(_ e: Element) {
        items.append(e)
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if less(items[i], items[parent]) {
                items.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    mutating func pop() -> Element? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1
                let r = 2 * i + 2
                var m = i
                if l < items.count && less(items[l], items[m]) { m = l }
                if r < items.count && less(items[r], items[m]) { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
        return top
    }
}

/// 通道图。值类型：规划时整体复制一份再插入起点 / 目标点，不破坏基础图。
struct RouteGraph {

    /// 节点坐标（cm）
    var nodes: [Point2] = []
    /// 邻接表
    var adj: [[RouteGraphEdge]] = []

    private var tolerance: Double
    private var cells: [RouteCellKey: [Int]] = [:]

    init(tolerance: Double) {
        self.tolerance = tolerance.isFinite && tolerance > 1e-6 ? tolerance : 1e-6
    }

    /// 无向边条数。
    var edgeCount: Int {
        var n = 0
        for list in adj { n += list.count }
        return n / 2
    }

    // MARK: 节点

    private static func cellIndex(_ v: Double) -> Int64 {
        guard v.isFinite else { return 0 }
        return Int64(min(max(v, -1e15), 1e15))
    }

    private func cellKey(_ p: Point2) -> RouteCellKey {
        RouteCellKey(ix: RouteGraph.cellIndex((p.x / tolerance).rounded(.down)),
                     iy: RouteGraph.cellIndex((p.y / tolerance).rounded(.down)))
    }

    /// 查找容差内已存在的节点（3×3 邻域 + 真实距离，避免格子边界误判）。
    func findNode(_ p: Point2) -> Int? {
        let k = cellKey(p)
        var best: Int? = nil
        var bestD = Double.greatestFiniteMagnitude
        for dx in -1...1 {
            for dy in -1...1 {
                let key = RouteCellKey(ix: k.ix &+ Int64(dx), iy: k.iy &+ Int64(dy))
                guard let list = cells[key] else { continue }
                for i in list where i < nodes.count {
                    let d = nodes[i].distance(to: p)
                    if d <= tolerance && d < bestD {
                        bestD = d
                        best = i
                    }
                }
            }
        }
        return best
    }

    /// 加节点；容差内已有则复用（junctionToleranceCm 合并）。
    @discardableResult
    mutating func addNode(_ p: Point2) -> Int {
        guard p.x.isFinite, p.y.isFinite else { return -1 }
        if let i = findNode(p) { return i }
        let idx = nodes.count
        nodes.append(p)
        adj.append([])
        cells[cellKey(p), default: []].append(idx)
        return idx
    }

    // MARK: 边

    /// 加无向边；重复边保留较小权重。
    mutating func addEdge(_ a: Int, _ b: Int) {
        guard a >= 0, b >= 0, a < nodes.count, b < nodes.count, a != b else { return }
        let w = nodes[a].distance(to: nodes[b])
        link(a, b, w)
        link(b, a, w)
    }

    private mutating func link(_ a: Int, _ b: Int, _ w: Double) {
        if let i = adj[a].firstIndex(where: { $0.to == b }) {
            if w < adj[a][i].weight { adj[a][i].weight = w }
        } else {
            adj[a].append(RouteGraphEdge(to: b, weight: w))
        }
    }

    mutating func removeEdge(_ a: Int, _ b: Int) {
        guard a >= 0, b >= 0, a < adj.count, b < adj.count else { return }
        adj[a].removeAll { $0.to == b }
        adj[b].removeAll { $0.to == a }
    }

    // MARK: 建图

    /// 由通道中心线建图。
    ///
    /// 步骤（标准做法）：
    /// 1. 每条通道先取两端点的参数 0、1；
    /// 2. 与其他每条通道求交（RouteGeometry.junctions：精确解析求交 + 共线重叠），
    ///    把交点投影回各自参数轴；
    /// 3. 参数排序去重（容差 = tolerance / 线段长度），相邻参数点之间连边，
    ///    权重为欧氏距离，双向；
    /// 4. 所有节点通过空间哈希按 tolerance 合并，于是不同通道在交点处自然连通。
    ///
    /// 平行但不共线的通道不会产生任何交点 → 不会有虚假边。
    static func build(crosses: [CrossSegment], tolerance: Double) -> RouteGraph {
        var g = RouteGraph(tolerance: tolerance)
        let n = crosses.count
        guard n > 0 else { return g }

        var params = [[Double]](repeating: [0.0, 1.0], count: n)
        if n > 1 {
            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    let pts = RouteGeometry.junctions(crosses[i].a, crosses[i].b,
                                                      crosses[j].a, crosses[j].b,
                                                      tolerance: tolerance)
                    for p in pts {
                        params[i].append(RouteGeometry.project(p, onto: crosses[i].a, crosses[i].b).t)
                        params[j].append(RouteGeometry.project(p, onto: crosses[j].a, crosses[j].b).t)
                    }
                }
            }
        }

        for i in 0..<n {
            let a = crosses[i].a
            let b = crosses[i].b
            guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { continue }
            let len = a.distance(to: b)
            if len <= 1e-9 {
                // 退化通道（单点）：只建节点，不建边
                g.addNode(a)
                continue
            }
            let tolT = max(tolerance / len, 1e-12)
            var ts: [Double] = []
            for raw in params[i].sorted() {
                let t = min(max(raw, 0.0), 1.0)
                if let last = ts.last, abs(t - last) <= tolT { continue }
                ts.append(t)
            }
            var prev = -1
            for t in ts {
                let idx = g.addNode(a + (b - a) * t)
                if prev >= 0 { g.addEdge(prev, idx) }
                prev = idx
            }
        }
        return g
    }

    // MARK: 动态插点（起点 / 目标）

    /// 把一个点插入图：
    /// - 容差内已有节点 → 复用；
    /// - 否则找最近的边，在垂足处拆边插入新节点；
    /// - 图里没有任何边时退化为最近节点。
    /// 返回节点下标，失败返回 nil。
    mutating func insertPoint(_ p: Point2, maxDistance: Double) -> Int? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        if let i = findNode(p) { return i }

        var bestA = -1
        var bestB = -1
        var bestD = Double.greatestFiniteMagnitude
        var bestPoint = p
        for a in 0..<nodes.count {
            for e in adj[a] where e.to > a {
                let pr = RouteGeometry.project(p, onto: nodes[a], nodes[e.to])
                if pr.distance < bestD - 1e-12 {
                    bestD = pr.distance
                    bestA = a
                    bestB = e.to
                    bestPoint = pr.point
                }
            }
        }

        if bestA < 0 {
            var bi = -1
            var bd = Double.greatestFiniteMagnitude
            for i in 0..<nodes.count {
                let d = nodes[i].distance(to: p)
                if d < bd { bd = d; bi = i }
            }
            return (bi >= 0 && bd <= maxDistance) ? bi : nil
        }
        guard bestD <= maxDistance else { return nil }
        if let i = findNode(bestPoint) { return i }

        let w = addNode(bestPoint)
        guard w >= 0 else { return nil }
        removeEdge(bestA, bestB)
        addEdge(bestA, w)
        addEdge(w, bestB)
        return w
    }

    // MARK: Dijkstra（用于多目标排序 / 可达性）

    /// 从 src 出发的单源最短距离（纯长度，不含转弯惩罚）。不可达为 .infinity。
    func dijkstra(from src: Int, maxIterations: Int = 2_000_000) -> [Double] {
        var dist = [Double](repeating: .infinity, count: nodes.count)
        guard src >= 0, src < nodes.count else { return dist }
        var done = [Bool](repeating: false, count: nodes.count)
        dist[src] = 0
        var heap = RouteBinaryHeap<RouteDijkstraEntry> { l, r in
            if l.dist != r.dist { return l.dist < r.dist }
            return l.node < r.node
        }
        heap.push(RouteDijkstraEntry(node: src, dist: 0))
        var iter = 0
        while let top = heap.pop() {
            iter += 1
            if iter > maxIterations { break }
            if done[top.node] { continue }
            done[top.node] = true
            for e in adj[top.node] {
                let nd = top.dist + e.weight
                if nd < dist[e.to] - 1e-12 {
                    dist[e.to] = nd
                    heap.push(RouteDijkstraEntry(node: e.to, dist: nd))
                }
            }
        }
        return dist
    }

    // MARK: A*（欧氏启发式 + 转弯惩罚）

    struct AStarResult {
        var path: [Int]
        var cost: Double
        var turns: Int
    }

    /// A* 搜索。
    ///
    /// 代价 = 边长之和 + turnPenalty × 转弯次数（折点 |转角| > turnAngleDeg 记一次）。
    /// 状态为 (节点, 前驱节点)，因此搜索空间是“边”而不是“点”。
    ///
    /// **启发式可采纳性**：h = 到终点的直线距离。由于转弯惩罚只会让真实剩余代价
    /// 变大（惩罚非负），h ≤ 真实剩余代价仍然成立，且 h 满足一致性
    /// （h(n) - h(n') ≤ 欧氏步长 ≤ 边代价），所以首次弹出终点状态即最优。
    /// **代价取舍**：最优性是针对“长度 + 转弯惩罚”这个合成代价而言的；
    /// 返回的路线在纯长度上可能略长于几何最短路——这正是为了避免锯齿路线。
    ///
    /// 同代价时按（转弯次数 → 节点下标 → 状态下标）排序，输出完全确定。
    func aStar(from src: Int, to goal: Int,
               turnPenalty: Double, turnAngleDeg: Double,
               maxIterations: Int = 400_000) -> AStarResult? {
        guard src >= 0, src < nodes.count, goal >= 0, goal < nodes.count else { return nil }
        if src == goal { return AStarResult(path: [src], cost: 0, turns: 0) }

        let penalty = turnPenalty.isFinite && turnPenalty > 0 ? turnPenalty : 0
        let goalPoint = nodes[goal]

        var stateIndex: [RouteStateKey: Int] = [:]
        var sNode: [Int] = []
        var sPrev: [Int] = []
        var sG: [Double] = []
        var sTurns: [Int] = []
        var sFrom: [Int] = []
        var sClosed: [Bool] = []

        func stateId(node: Int, prev: Int) -> Int {
            let key = RouteStateKey(node: node, prev: prev)
            if let i = stateIndex[key] { return i }
            let i = sNode.count
            stateIndex[key] = i
            sNode.append(node)
            sPrev.append(prev)
            sG.append(.infinity)
            sTurns.append(0)
            sFrom.append(-1)
            sClosed.append(false)
            return i
        }

        let start = stateId(node: src, prev: -1)
        sG[start] = 0
        var heap = RouteBinaryHeap<RouteAStarEntry> { l, r in
            if l.f != r.f { return l.f < r.f }
            if l.turns != r.turns { return l.turns < r.turns }
            if l.node != r.node { return l.node < r.node }
            return l.state < r.state
        }
        heap.push(RouteAStarEntry(f: nodes[src].distance(to: goalPoint), turns: 0, node: src, state: start))

        var iter = 0
        var goalState = -1
        while let top = heap.pop() {
            iter += 1
            if iter > maxIterations { break }
            let s = top.state
            guard s < sClosed.count, !sClosed[s] else { continue }
            sClosed[s] = true
            if sNode[s] == goal { goalState = s; break }

            let cur = sNode[s]
            let prev = sPrev[s]
            let g0 = sG[s]
            let t0 = sTurns[s]
            for e in adj[cur] {
                var isTurn = false
                if prev >= 0 {
                    let ang = abs(RouteGeometry.signedTurnDeg(nodes[cur] - nodes[prev],
                                                              nodes[e.to] - nodes[cur]))
                    isTurn = ang > turnAngleDeg
                }
                let ng = g0 + e.weight + (isTurn ? penalty : 0)
                let nTurns = t0 + (isTurn ? 1 : 0)
                let ns = stateId(node: e.to, prev: cur)
                if sClosed[ns] { continue }
                let better = ng < sG[ns] - 1e-9
                    || (abs(ng - sG[ns]) <= 1e-9 && nTurns < sTurns[ns])
                if better {
                    sG[ns] = ng
                    sTurns[ns] = nTurns
                    sFrom[ns] = s
                    heap.push(RouteAStarEntry(f: ng + nodes[e.to].distance(to: goalPoint),
                                              turns: nTurns, node: e.to, state: ns))
                }
            }
        }

        guard goalState >= 0 else { return nil }
        var path: [Int] = []
        var s = goalState
        var guardCount = 0
        while s >= 0 && guardCount <= sNode.count {
            path.append(sNode[s])
            s = sFrom[s]
            guardCount += 1
        }
        path.reverse()
        return AStarResult(path: path, cost: sG[goalState], turns: sTurns[goalState])
    }
}
