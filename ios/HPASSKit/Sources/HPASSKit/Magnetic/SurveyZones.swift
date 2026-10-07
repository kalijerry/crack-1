import Foundation

/// 采集分区：把整店的通道切成一块块「一次采得完」的区域（默认每块走线约 1.2 km ≈ 25 分钟），
/// 每次进采集模式自动分到一块；融合后按涂色算各区域进度，告诉下次该去哪块。
///
/// - 通道先切成 ≤ pieceCm 的小段（贯穿全店的主通道会被分到沿途的几个区域里）；
/// - 按小段中心递归二分（沿分布更散的那个方向、按走线长度对半分），直到每块 ≤ targetLaneCm，
///   得到空间上紧凑的区域；区域按位置从上到下、从左到右编号；
/// - 下一个区域：先把开了头的（≥ startedFraction）采完；否则选离已采部分最近的（有重叠才能对齐磁场整体偏差）；
///   全店都没采过就选离我最近的；
/// - 进区入口：区域里还没怎么采时，给出离它最近的已采过的地方：从那里进，先沿已采路段走 10～20 m。
public struct SurveyZones {
    public struct Piece: Codable, Equatable {
        public var corridor: String
        public var t0: Double
        public var t1: Double
        public var a: Point2
        public var b: Point2
        public var widthCm: Double
    }

    public struct Zone: Codable {
        public var id: Int
        public var name: String
        public var pieces: [Piece]
        public var laneCm: Double
        public var center: Point2
        public var corridors: Set<String> { Set(pieces.map(\.corridor)) }
    }

    public struct Status: Codable {
        public var id: Int
        public var name: String
        public var fraction: Double
        public var remainingCm: Double
        public var totalCm: Double
        public var done: Bool
    }

    public let zones: [Zone]
    public let planner: SurveyPlanner
    public var doneFraction = 0.85
    public var startedFraction = 0.15

    public init(crosses: [CrossSegment], radiusCm: Double = 40, targetLaneCm: Double = 120_000, pieceCm: Double = 1500) {
        planner = SurveyPlanner(crosses: crosses, radiusCm: radiusCm)
        var lanesPer: [String: Int] = [:]
        for l in planner.lanes { lanesPer[l.corridor, default: 0] += 1 }
        var items: [(piece: Piece, w: Double, c: Point2)] = []
        for c in crosses {
            guard let nl = lanesPer[c.code] else { continue }
            let len = c.a.distance(to: c.b)
            let n = max(Int((len / pieceCm).rounded(.up)), 1)
            for k in 0..<n {
                let t0 = Double(k) / Double(n), t1 = Double(k + 1) / Double(n)
                let a = c.a + (c.b - c.a) * t0, b = c.a + (c.b - c.a) * t1
                items.append((Piece(corridor: c.code, t0: t0, t1: t1, a: a, b: b, widthCm: c.lineWidth),
                              len / Double(n) * Double(nl), Point2((a.x + b.x) / 2, (a.y + b.y) / 2)))
            }
        }
        var groups: [[Int]] = []
        func split(_ idx: [Int]) {
            let total = idx.reduce(0) { $0 + items[$1].w }
            guard total > targetLaneCm * 1.15, idx.count > 1 else { groups.append(idx); return }
            let xs = idx.map { items[$0].c.x }, ys = idx.map { items[$0].c.y }
            let byX = (xs.max()! - xs.min()!) >= (ys.max()! - ys.min()!)
            let sorted = idx.sorted { byX ? items[$0].c.x < items[$1].c.x : items[$0].c.y < items[$1].c.y }
            let parts = Int((total / targetLaneCm).rounded(.up))
            let leftShare = Double(parts / 2) / Double(parts)
            var acc = 0.0, cut = 1
            for (i, k) in sorted.enumerated() {
                acc += items[k].w
                if acc >= total * leftShare { cut = max(1, min(i + 1, sorted.count - 1)); break }
            }
            split(Array(sorted[..<cut])); split(Array(sorted[cut...]))
        }
        if !items.isEmpty { split(Array(items.indices)) }
        var zs: [Zone] = groups.map { g in
            let w = g.reduce(0) { $0 + items[$1].w }
            let cx = g.reduce(0) { $0 + items[$1].c.x * items[$1].w } / max(w, 1)
            let cy = g.reduce(0) { $0 + items[$1].c.y * items[$1].w } / max(w, 1)
            return Zone(id: 0, name: "", pieces: g.map { items[$0].piece }, laneCm: w, center: Point2(cx, cy))
        }
        // 编号：按 10 m 一行从上到下、行内从左到右
        zs.sort { (Int($0.center.y / 1000), $0.center.x) < (Int($1.center.y / 1000), $1.center.x) }
        for i in zs.indices { zs[i].id = i + 1; zs[i].name = "区域 \(i + 1)" }
        zones = zs
    }

    public func zone(_ id: Int?) -> Zone? { zones.first { $0.id == id } }

    /// 这个区域的走线（按小段裁好的）
    public func lanes(_ z: Zone) -> [SurveyPlanner.Lane] {
        var out: [SurveyPlanner.Lane] = []
        let byCorridor = Dictionary(grouping: planner.lanes, by: \.corridor)
        for p in z.pieces {
            for l in byCorridor[p.corridor] ?? [] {
                out.append(.init(corridor: l.corridor, a: l.a + (l.b - l.a) * p.t0, b: l.a + (l.b - l.a) * p.t1, side: l.side))
            }
        }
        return out
    }

    /// 只在这个区域里规划下一段
    public func planner(for z: Zone) -> SurveyPlanner { SurveyPlanner(lanes: lanes(z)) }

    public func status(_ paint: CoveragePaint) -> [Status] {
        zones.map { z in
            let ls = lanes(z)
            let total = ls.reduce(0) { $0 + $1.length }
            let rem = ls.reduce(0) { $0 + planner.remainingCm($1, paint) }
            let f = total > 0 ? 1 - rem / total : 1
            return Status(id: z.id, name: z.name, fraction: f, remainingCm: rem, totalCm: total, done: f >= doneFraction)
        }
    }

    /// 离区域最近的已采过的地方（区域里还没怎么采时给进区入口）；全店都没采过返回 nil
    public func entry(_ z: Zone, paint: CoveragePaint, stride: Int = 2) -> Point2? {
        var best: (Point2, Double)?
        for j in Swift.stride(from: 0, to: paint.rows, by: stride) {
            for i in Swift.stride(from: 0, to: paint.cols, by: stride) {
                let k = j * paint.cols + i
                guard paint.counts[k] > 0 else { continue }
                let q = Point2((Double(i) + 0.5) * paint.cellCm, (Double(j) + 0.5) * paint.cellCm)
                let d = z.pieces.map { Self.segDist(q, $0.a, $0.b) }.min() ?? .infinity
                if best == nil || d < best!.1 { best = (q, d) }
            }
        }
        return best?.0
    }

    /// 下一个该采的区域
    public func next(_ paint: CoveragePaint, from pos: Point2? = nil) -> Int? {
        let st = status(paint)
        let todo = st.filter { !$0.done }
        guard !todo.isEmpty else { return nil }
        if let s = todo.filter({ $0.fraction >= startedFraction }).max(by: { $0.fraction < $1.fraction }) { return s.id }
        if paint.paintedCells > 0 {
            var best: (Int, Double)?
            for s in todo {
                guard let z = zone(s.id), let e = entry(z, paint: paint, stride: 4) else { continue }
                let d = z.pieces.map { Self.segDist(e, $0.a, $0.b) }.min() ?? .infinity
                if best == nil || d < best!.1 { best = (s.id, d) }
            }
            if let b = best { return b.0 }
        }
        if let p = pos {
            return todo.min { a, b in
                (zone(a.id)?.center.distance(to: p) ?? .infinity) < (zone(b.id)?.center.distance(to: p) ?? .infinity)
            }?.id
        }
        return todo.first?.id
    }

    public static func segDist(_ p: Point2, _ a: Point2, _ b: Point2) -> Double {
        let d = b - a, l2 = d.x * d.x + d.y * d.y
        guard l2 > 1e-6 else { return p.distance(to: a) }
        let t = min(max(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l2, 0), 1)
        return p.distance(to: a + d * t)
    }
}
