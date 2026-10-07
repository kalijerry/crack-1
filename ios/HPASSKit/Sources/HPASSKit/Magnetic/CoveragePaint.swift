import Foundation

/// 「涂色」式采集覆盖（参考 Oriient）：采集时以当前位置为圆心画一个圆，走过的地方涂上颜色，目标是把整条通道
/// 的宽度都涂满，而不是只走中心线。
///
/// 为什么要涂满宽度：靠近钢货架，横着挪半米磁场就能差好几 µT。只采中间一条线，顾客贴着一边走时读数对不上图，
/// 定位就会飘、会跳。涂满了，横向也有数据，横向位置也能分辨出来。
///
/// 网格默认 25 cm，只统计通道（地图 MapCross，按通道宽度）里的格子。每格记「走过几趟」：同一趟里连续涂到
/// 同一格只算一次（离上次涂到这格走出 3 m 以上才算新的一趟）。
public final class CoveragePaint {
    public let cellCm: Double
    public let cols: Int
    public let rows: Int
    public let crosses: [CrossSegment]
    /// 圆圈半径（cm）
    public var radiusCm = 40.0
    /// 同一格再涂一次要隔多远（cm，按路程）才算新的一趟
    public var newPassCm = 300.0

    /// 每格走过几趟（不在通道里的格子永远是 0）
    public private(set) var counts: [UInt8]
    /// 是否在通道里
    public let mask: [Bool]
    public let walkableCells: Int
    public private(set) var paintedCells = 0
    /// 每条通道包含的格子（通道宽度以内）
    private let corridorCells: [[Int32]]
    private var painted: [Int]
    /// 每格上次被涂到时的路程（cm），判断是不是新的一趟；不存盘
    private var lastPaintPath: [Float]
    private var path = 0.0
    private var lastP: Point2?

    /// 有通道的范围（格子下标，含两端），画图时只画这一块
    public let bbox: (i0: Int, j0: Int, i1: Int, j1: Int)
    /// 改过就加一，界面据此决定要不要重画
    public private(set) var revision = 0

    /// 房间（没有通道）：用可走区域的格子当涂色范围，整个房间算一条「通道」。网格与 walkable 一致。
    public init(walkable w: WalkableMap) {
        cellCm = w.cellCm
        cols = w.cols
        rows = w.rows
        crosses = []
        var mask = [Bool](repeating: false, count: cols * rows)
        var bi0 = Int.max, bj0 = Int.max, bi1 = -1, bj1 = -1
        for k in 0..<(cols * rows) where w.isWalkable(index: k) {
            mask[k] = true
            let i = k % cols, j = k / cols
            bi0 = min(bi0, i); bi1 = max(bi1, i); bj0 = min(bj0, j); bj1 = max(bj1, j)
        }
        self.mask = mask
        corridorCells = []
        walkableCells = mask.reduce(0) { $0 + ($1 ? 1 : 0) }
        counts = [UInt8](repeating: 0, count: cols * rows)
        lastPaintPath = [Float](repeating: -1e9, count: cols * rows)
        painted = []
        bbox = bi1 >= 0 ? (bi0, bj0, bi1, bj1) : (0, 0, cols - 1, rows - 1)
    }

    public init(crosses: [CrossSegment], widthCm: Double, heightCm: Double, cellCm: Double = 25) {
        self.cellCm = cellCm
        self.crosses = crosses
        cols = max(Int((widthCm / cellCm).rounded(.up)), 1)
        rows = max(Int((heightCm / cellCm).rounded(.up)), 1)
        var mask = [Bool](repeating: false, count: cols * rows)
        var lists: [[Int32]] = []
        var bi0 = Int.max, bj0 = Int.max, bi1 = -1, bj1 = -1
        for c in crosses {
            var list: [Int32] = []
            let dx = c.b.x - c.a.x, dy = c.b.y - c.a.y
            let len2 = dx * dx + dy * dy
            let half = max(c.lineWidth, 0) / 2
            if len2 > 1e-6 && half >= cellCm / 2 {
                let i0 = max(Int((min(c.a.x, c.b.x) - half) / cellCm), 0), i1 = min(Int((max(c.a.x, c.b.x) + half) / cellCm), cols - 1)
                let j0 = max(Int((min(c.a.y, c.b.y) - half) / cellCm), 0), j1 = min(Int((max(c.a.y, c.b.y) + half) / cellCm), rows - 1)
                if i0 <= i1 && j0 <= j1 {
                    for j in j0...j1 {
                        for i in i0...i1 {
                            let px = (Double(i) + 0.5) * cellCm, py = (Double(j) + 0.5) * cellCm
                            let t = min(max(((px - c.a.x) * dx + (py - c.a.y) * dy) / len2, 0), 1)
                            guard hypot(px - (c.a.x + t * dx), py - (c.a.y + t * dy)) <= half else { continue }
                            let k = j * cols + i
                            mask[k] = true
                            list.append(Int32(k))
                            bi0 = min(bi0, i); bi1 = max(bi1, i); bj0 = min(bj0, j); bj1 = max(bj1, j)
                        }
                    }
                }
            }
            lists.append(list)
        }
        self.mask = mask
        corridorCells = lists
        walkableCells = mask.reduce(0) { $0 + ($1 ? 1 : 0) }
        counts = [UInt8](repeating: 0, count: cols * rows)
        lastPaintPath = [Float](repeating: -1e9, count: cols * rows)
        painted = [Int](repeating: 0, count: crosses.count)
        bbox = bi1 >= 0 ? (bi0, bj0, bi1, bj1) : (0, 0, cols - 1, rows - 1)
    }

    /// 在 p 处涂一圈。返回有没有新涂上的格子或新的一趟。
    @discardableResult
    public func paint(at p: Point2) -> Bool {
        if let l = lastP {
            let d = p.distance(to: l)
            path += d < 300 ? d : 0                   // 跳变（修正、重新定位）不算路程
        }
        lastP = p
        let r = radiusCm, r2 = r * r
        let i0 = max(Int((p.x - r) / cellCm), 0), i1 = min(Int((p.x + r) / cellCm), cols - 1)
        let j0 = max(Int((p.y - r) / cellCm), 0), j1 = min(Int((p.y + r) / cellCm), rows - 1)
        guard i0 <= i1, j0 <= j1 else { return false }
        var changed = false
        for j in j0...j1 {
            for i in i0...i1 {
                let k = j * cols + i
                guard mask[k] else { continue }
                let cx = (Double(i) + 0.5) * cellCm - p.x, cy = (Double(j) + 0.5) * cellCm - p.y
                guard cx * cx + cy * cy <= r2 else { continue }
                let newPass = path - Double(lastPaintPath[k]) > newPassCm
                lastPaintPath[k] = Float(path)
                guard newPass, counts[k] < 255 else { continue }
                if counts[k] == 0 { paintedCells += 1 }
                counts[k] += 1
                changed = true
            }
        }
        if changed { revision += 1 }
        return changed
    }

    /// 新的一段（新会话、修正位置）：下一次涂色不和上一个点连起来算路程
    public func breakStroke() { lastP = nil }

    public var fraction: Double { walkableCells > 0 ? Double(paintedCells) / Double(walkableCells) : 0 }
    public var paintedAreaM2: Double { Double(paintedCells) * cellCm * cellCm / 10_000 }
    public var walkableAreaM2: Double { Double(walkableCells) * cellCm * cellCm / 10_000 }

    /// 第 i 条通道涂了多少（0...1）
    public func fraction(corridor i: Int) -> Double {
        guard corridorCells.indices.contains(i), !corridorCells[i].isEmpty else { return 0 }
        let n = corridorCells[i].reduce(0) { $0 + (counts[Int($1)] > 0 ? 1 : 0) }
        return Double(n) / Double(corridorCells[i].count)
    }

    /// p 所在的通道（通道宽度以内，取离中心线最近的）
    public func corridorIndex(at p: Point2) -> Int? {
        var best: (Int, Double)?
        for (i, c) in crosses.enumerated() where corridorCells.indices.contains(i) && !corridorCells[i].isEmpty {
            let d = c.b - c.a
            let l2 = d.dot(d)
            let t = min(max((p - c.a).dot(d) / l2, 0), 1)
            let dist = p.distance(to: Point2(c.a.x + d.x * t, c.a.y + d.y * t))
            guard dist <= max(c.lineWidth, 0) / 2 else { continue }
            if best == nil || dist < best!.1 { best = (i, dist) }
        }
        return best?.0
    }

    /// 离 p 最近的没涂的格子中心（只在 maxCm 以内找）
    public func nearestUnpainted(from p: Point2, maxCm: Double = 5000) -> Point2? {
        let ci = Int(p.x / cellCm), cj = Int(p.y / cellCm)
        let maxR = Int(maxCm / cellCm)
        for r in 0...maxR {
            var best: (Point2, Double)?
            for j in (cj - r)...(cj + r) where j >= 0 && j < rows {
                for i in (ci - r)...(ci + r) where i >= 0 && i < cols {
                    guard abs(i - ci) == r || abs(j - cj) == r else { continue }   // 只看这一圈
                    let k = j * cols + i
                    guard mask[k], counts[k] == 0 else { continue }
                    let q = Point2((Double(i) + 0.5) * cellCm, (Double(j) + 0.5) * cellCm)
                    let d = q.distance(to: p)
                    if best == nil || d < best!.1 { best = (q, d) }
                }
            }
            if let b = best { return b.0 }
        }
        return nil
    }

    public func reset() {
        counts = [UInt8](repeating: 0, count: cols * rows)
        lastPaintPath = [Float](repeating: -1e9, count: cols * rows)
        paintedCells = 0
        lastP = nil
        revision += 1
    }

    // MARK: 存盘

    /// 头：cols、rows、通道数（各 4 字节，小端），然后每格 1 字节。
    public func serialized() -> Data {
        var d = Data()
        for v in [UInt32(cols), UInt32(rows), UInt32(crosses.count)] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: counts)
        return d
    }

    /// 读回存盘的数据；尺寸或通道数不一致（换了地图）就不读，返回 false。
    @discardableResult
    public func load(_ d: Data) -> Bool {
        guard d.count == 12 + cols * rows else { return false }
        func u32(_ o: Int) -> Int { Int(d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian) }
        guard u32(0) == cols, u32(4) == rows, u32(8) == crosses.count else { return false }
        counts = [UInt8](d.subdata(in: 12..<d.count))
        for k in counts.indices where !mask[k] { counts[k] = 0 }
        paintedCells = counts.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        revision += 1
        return true
    }

    /// 合并另一份存盘的涂色（云端融合的、别的手机采的）：每格取走过趟数多的。尺寸或通道数不一致返回 false。
    @discardableResult
    public func merge(_ d: Data) -> Bool {
        let other = CoveragePaint.counts(of: d, cols: cols, rows: rows, crosses: crosses.count)
        guard let o = other else { return false }
        for k in counts.indices where mask[k] && o[k] > counts[k] { counts[k] = o[k] }
        paintedCells = counts.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        revision += 1
        return true
    }

    /// 一份存盘涂色的每格趟数（尺寸 / 通道数和本网格一致才返回）
    public func counts(of d: Data) -> [UInt8]? { CoveragePaint.counts(of: d, cols: cols, rows: rows, crosses: crosses.count) }

    /// 两份存盘数据直接按格取大（不用建网格；头不一致就用 b）
    public static func mergeSerialized(_ a: Data?, _ b: Data) -> Data {
        guard let a, a.count == b.count, a.prefix(12) == b.prefix(12) else { return b }
        var out = Data(b.prefix(12))
        out.append(contentsOf: zip(a.dropFirst(12), b.dropFirst(12)).map { max($0, $1) })
        return out
    }

    private static func counts(of d: Data, cols: Int, rows: Int, crosses: Int) -> [UInt8]? {
        guard d.count == 12 + cols * rows else { return nil }
        func u32(_ o: Int) -> Int { Int(d.subdata(in: d.startIndex + o..<d.startIndex + o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian) }
        guard u32(0) == cols, u32(4) == rows, u32(8) == crosses else { return nil }
        return [UInt8](d.dropFirst(12))
    }
}

/// 「方向图」：每条通道每 binCm 一段，两个方向各走过没有（和手机上 SurveyCoverage 同一套规则）。
/// 云端按融合用上的轨迹算一份，打进地图包，手机重装后也能看到哪些路段只走了一个方向。
public enum DirectionCoverage {
    public struct File: Codable, Equatable {
        public var f: [[Int]]
        public var b: [[Int]]
        public init(f: [[Int]], b: [[Int]]) { self.f = f; self.b = b }
    }

    public static func build(crosses: [CrossSegment], tracks: [[(tMs: Int64, p: Point2)]], binCm: Double = 100) -> File {
        let lengths = crosses.map { $0.a.distance(to: $0.b) }
        var f = lengths.map { [Int](repeating: 0, count: max(Int(($0 / binCm).rounded(.up)), 1)) }
        var b = f
        for tr in tracks {
            for k in tr.indices where k >= 3 {
                let p = tr[k].p, q = tr[k - 3].p
                let dir = Point2(p.x - q.x, p.y - q.y)
                guard dir.x * dir.x + dir.y * dir.y > 100, dir.x * dir.x + dir.y * dir.y < 300 * 300 else { continue }
                for (i, c) in crosses.enumerated() {
                    let dx = c.b.x - c.a.x, dy = c.b.y - c.a.y
                    let len2 = dx * dx + dy * dy
                    guard len2 > 1 else { continue }
                    let t = ((p.x - c.a.x) * dx + (p.y - c.a.y) * dy) / len2
                    guard t >= -0.01, t <= 1.01 else { continue }
                    let foot = Point2(c.a.x + t * dx, c.a.y + t * dy)
                    guard p.distance(to: foot) <= max(c.lineWidth, 0) / 2 + 40 else { continue }
                    let bin = min(max(Int(t * lengths[i] / binCm), 0), f[i].count - 1)
                    if dir.x * dx + dir.y * dy >= 0 { f[i][bin] = 1 } else { b[i][bin] = 1 }
                }
            }
        }
        return File(f: f, b: b)
    }
}

