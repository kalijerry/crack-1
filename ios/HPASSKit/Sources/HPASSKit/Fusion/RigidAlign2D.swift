import Foundation

/// 两次扫描之间的几何对齐（2D 刚体：旋转 + 平移，尺度由激光雷达保证）。
///
/// 用在「认不出已扫区域」（视觉重定位失败、或 iOS 16 没有自定义 ARSession）的扫描段：新段在自己的坐标系里扫完，
/// 再用墙和门把它对到已有地图上。`RoomMapBuilder` 已经把每段按墙的主方向转正，两段之间的旋转只剩
/// {0°, 90°, 180°, 270°} 加小残差，所以：
///
/// - `auto`：4 个旋转候选 × 门—门配对给出的平移 → 点到线 ICP 精修（平移 + ≤ 3° 旋转）→ 打分。
///   打分 = 重合墙长 − 3 × 冲突墙长（一边的墙落进另一边房间内部、附近又没有墙），防止沿走廊错位一个房间；
///   精修后出发的那对门必须仍然对得上（≤ 40 cm），否则是别处的墙把它吸走了（两个一样大的房间、长走廊）。
///   要求重合 ≥ 3 m、且有门对上或两组不平行的墙对上；次优解得分 ≥ 最优 85% 时标「有歧义」。没有门或对不上返回 nil，
///   界面进入手动两点对齐。新一段必须把门口 / 走廊这类已扫过的地方再扫一小段，否则几何对齐无解。
/// - `twoPoints`：手动两点（只解旋转 + 平移，报告尺度比，偏离 1 超过 5% 多半是点错了）；
/// - `snapToAxes`：吸附到 90° 整数倍，然后可以再 `refine` 一轮。
///
/// 变换用 `MapARTransform` 表示：「AR 一侧」= 新段坐标，「地图一侧」= 目标地图坐标。
public enum RigidAlign2D {
    public struct Features {
        public var walls: [MapGeometry.Segment]
        /// 门和开口（中心 + 方向 + 宽度）
        public var doors: [MapGeometry.Segment]
        /// 单元多边形（判断冲突用）
        public var units: [[Point2]]

        public init(walls: [MapGeometry.Segment], doors: [MapGeometry.Segment], units: [[Point2]] = []) {
            self.walls = walls; self.doors = doors; self.units = units
        }

        public init(mapJSON: Data) throws {
            let r = try MapGeometry.root(mapJSON)
            walls = MapGeometry.segments(r, types: ["MapWall"])
            doors = MapGeometry.segments(r, types: ["MapDoor", "MapOpening"])
            units = MapGeometry.units(r).map(\.polygon)
        }

        func transformed(by t: MapARTransform) -> Features {
            Features(walls: walls.map { $0.transformed(by: t) }, doors: doors.map { $0.transformed(by: t) },
                     units: units.map { $0.map(t.toMap) })
        }
    }

    public struct Config {
        public var sampleStepCm = 20.0
        /// ICP 找对应墙的最远距离
        public var icpMaxDistCm = 60.0
        public var icpAngleDeg = 10.0
        public var icpIterations = 20
        /// ICP 最多改多少旋转（度）
        public var maxRefineRotDeg = 3.0
        /// 打分：离对应墙这么近算重合
        public var inlierCm = 15.0
        /// 冲突：落在对方房间里、离对方的墙超过这么远
        public var conflictCm = 40.0
        public var conflictWeight = 3.0
        public var minOverlapCm = 300.0
        public var doorMatchCm = 40.0
        public var ambiguousRatio = 0.85
        public init() {}
    }

    public struct Result {
        public var transform: MapARTransform
        public var overlapCm: Double
        public var residualCm: Double
        public var conflictCm: Double
        public var score: Double
        public var doorsMatched: Int
        public var ambiguous: Bool
        /// 次优（和最优不是同一个解）的得分
        public var secondScore: Double?
        public var quality: ScanRegistry.Quality {
            .init(overlapCm: overlapCm.rounded(), residualCm: (residualCm * 10).rounded() / 10, ambiguous: ambiguous)
        }
    }

    // MARK: 自动

    public static func auto(target: Features, source: Features, config c: Config = Config()) -> Result? {
        guard !target.walls.isEmpty, !source.walls.isEmpty else { return nil }
        let base = dominantDeg(target.walls) - dominantDeg(source.walls)
        var sols: [Result] = []
        for k in 0..<4 {
            let phi = (base + Double(k) * 90) * Double.pi / 180
            let rot = MapARTransform(pRef: .zero, aRef: .zero, phi: phi)
            for td in target.doors {
                for sd in source.doors {
                    let sr = sd.transformed(by: rot)
                    guard MapGeometry.lineAngleDiffDeg(sr.rotationDeg, td.rotationDeg) <= 15,
                          max(td.length, sd.length) <= 1.5 * max(min(td.length, sd.length), 1) else { continue }
                    let t0 = MapARTransform(pRef: td.center, aRef: sd.center, phi: phi)
                    let t = refine(t0, target: target, source: source, config: c)
                    // ICP 把它拉离了出发的那对门：说明是别处（重复的房间、长走廊）把它吸过去的，不要
                    guard t.toMap(sd.center).distance(to: td.center) <= c.doorMatchCm else { continue }
                    if sols.contains(where: { $0.transform.isClose(to: t, tolCm: 30, extentCm: 500) }) { continue }
                    sols.append(evaluate(t, target: target, source: source, config: c))
                }
            }
        }
        let valid = sols.filter { r in
            r.overlapCm >= c.minOverlapCm && r.score >= c.minOverlapCm
                && (r.doorsMatched > 0 || twoDirections(r.transform, target: target, source: source, config: c))
        }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.residualCm < $1.residualCm }
        guard var best = valid.first else { return nil }
        let second = sols.filter { !$0.transform.isClose(to: best.transform, tolCm: 30, extentCm: 500) }.map(\.score).max()
        best.secondScore = second
        best.ambiguous = (second ?? -.infinity) >= c.ambiguousRatio * best.score
        return best
    }

    /// 墙方向按长度加权的主方向（度，模 90°）
    public static func dominantDeg(_ walls: [MapGeometry.Segment]) -> Double {
        var s4 = 0.0, c4 = 0.0
        for w in walls { let r = w.rotationDeg * Double.pi / 180; s4 += w.length * sin(4 * r); c4 += w.length * cos(4 * r) }
        return (s4 == 0 && c4 == 0) ? 0 : atan2(s4, c4) / 4 * 180 / Double.pi
    }

    // MARK: 对应

    struct Match { var p: Point2; var n: Point2; var r: Double; var w: Double; var dirDeg: Double }

    /// 源的墙采样点（已变换）对到目标最近的墙：法向、有符号残差
    static func matches(_ t: MapARTransform, target: Features, source: Features, maxDist: Double, config c: Config) -> [Match] {
        var out: [Match] = []
        for s0 in source.walls {
            let s = s0.transformed(by: t)
            let pts = s.samples(step: c.sampleStepCm)
            let h = s.length / Double(max(pts.count, 1))
            for p in pts {
                var best: Match?
                for d in target.walls where MapGeometry.lineAngleDiffDeg(d.rotationDeg, s.rotationDeg) <= c.icpAngleDeg {
                    let u = d.param(of: p)
                    guard u >= -c.sampleStepCm, u <= d.length + c.sampleStepCm else { continue }
                    let dir = d.direction, n = Point2(-dir.y, dir.x)
                    let r = (p - d.a).dot(n)
                    if abs(r) <= maxDist && abs(r) < abs(best?.r ?? .infinity) { best = Match(p: p, n: n, r: r, w: h, dirDeg: d.rotationDeg) }
                }
                if let b = best { out.append(b) }
            }
        }
        return out
    }

    /// 点到线 ICP：精修平移和小旋转（总旋转改动不超过 maxRefineRotDeg）
    public static func refine(_ t0: MapARTransform, target: Features, source: Features, config c: Config = Config()) -> MapARTransform {
        var t = t0
        for _ in 0..<c.icpIterations {
            let ms = matches(t, target: target, source: source, maxDist: c.icpMaxDistCm, config: c)
            guard ms.count >= 3 else { break }
            let wsum = ms.reduce(0) { $0 + $1.w }
            let ctr = ms.reduce(Point2.zero) { $0 + $1.p * $1.w } * (1 / wsum)
            // J = [n·perp(p − c), n.x, n.y]，最小化 Σ w (r + J δ)²
            var A = [[Double]](repeating: [0, 0, 0], count: 3), b = [0.0, 0, 0]
            for m in ms {
                let q = m.p - ctr
                let j = [m.n.x * -q.y + m.n.y * q.x, m.n.x, m.n.y]
                for i in 0..<3 { for k in 0..<3 { A[i][k] += m.w * j[i] * j[k] }; b[i] -= m.w * j[i] * m.r }
            }
            let lam = 1e-3 * wsum
            A[0][0] += lam * 100; A[1][1] += lam; A[2][2] += lam
            guard let d = solve3(A, b) else { break }
            var dphi = d[0]
            let maxR = c.maxRefineRotDeg * Double.pi / 180
            let total = t.phi + dphi - t0.phi
            if abs(total) > maxR { dphi = (total > 0 ? maxR : -maxR) - (t.phi - t0.phi) }
            let delta = MapARTransform(pRef: ctr + Point2(d[1], d[2]), aRef: ctr, phi: dphi)
            t = t.compose(delta)
            if hypot(d[1], d[2]) < 0.05 && abs(dphi) < 1e-5 { break }
        }
        return t
    }

    static func solve3(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det(A)
        guard abs(d) > 1e-12 else { return nil }
        return (0..<3).map { col in
            var m = A
            for r in 0..<3 { m[r][col] = b[r] }
            return det(m) / d
        }
    }

    // MARK: 打分

    public static func evaluate(_ t: MapARTransform, target: Features, source: Features, config c: Config = Config()) -> Result {
        let ms = matches(t, target: target, source: source, maxDist: c.inlierCm, config: c)
        let overlap = ms.reduce(0) { $0 + $1.w }
        let resid = overlap > 0 ? ms.reduce(0) { $0 + abs($1.r) * $1.w } / overlap : 0
        let src = source.transformed(by: t)
        let conflict = conflictLength(walls: src.walls, into: target, config: c) + conflictLength(walls: target.walls, into: src, config: c)
        var doors = 0
        for d in src.doors where target.doors.contains(where: {
            $0.center.distance(to: d.center) <= c.doorMatchCm && MapGeometry.lineAngleDiffDeg($0.rotationDeg, d.rotationDeg) <= 15
        }) { doors += 1 }
        return Result(transform: t, overlapCm: overlap, residualCm: resid, conflictCm: conflict,
                      score: overlap - c.conflictWeight * conflict, doorsMatched: doors, ambiguous: false, secondScore: nil)
    }

    /// `walls` 落进 `other` 的房间内部、附近又没有 `other` 的墙的长度
    static func conflictLength(walls: [MapGeometry.Segment], into other: Features, config c: Config) -> Double {
        guard !other.units.isEmpty else { return 0 }
        var len = 0.0
        for w in walls {
            let pts = w.samples(step: c.sampleStepCm)
            let h = w.length / Double(max(pts.count, 1))
            for p in pts where other.units.contains(where: { pointInPolygon(p, $0) && MapGeometry.distanceToBoundary(p, $0) > c.conflictCm }) {
                if !other.walls.contains(where: { MapGeometry.distanceToSegment(p, $0.a, $0.b) <= c.conflictCm }) { len += h }
            }
        }
        return len
    }

    /// 重合的墙里有两组不平行的方向（各至少 1 m）：平移两个方向都被约束住
    static func twoDirections(_ t: MapARTransform, target: Features, source: Features, config c: Config) -> Bool {
        let ms = matches(t, target: target, source: source, maxDist: c.inlierCm, config: c)
        guard let first = ms.max(by: { $0.w < $1.w }) else { return false }
        var a = 0.0, b = 0.0
        for m in ms { if MapGeometry.lineAngleDiffDeg(m.dirDeg, first.dirDeg) <= 30 { a += m.w } else { b += m.w } }
        return a >= 100 && b >= 100
    }

    // MARK: 手动

    /// 手动两点对齐：目标地图上的 A、B 对应新段上的 A、B。只解旋转 + 平移；scaleRatio = 目标距离 / 新段距离。
    /// 两点太近（< 10 cm）返回 nil。
    public static func twoPoints(targetA: Point2, targetB: Point2, sourceA: Point2, sourceB: Point2) -> (transform: MapARTransform, scaleRatio: Double)? {
        let dt = targetB - targetA, ds = sourceB - sourceA
        guard ds.length >= 10, dt.length >= 10 else { return nil }
        let phi = atan2(dt.y, dt.x) - atan2(ds.y, ds.x)
        let t = MapARTransform(pRef: (targetA + targetB) * 0.5, aRef: (sourceA + sourceB) * 0.5, phi: phi)
        return (t, dt.length / ds.length)
    }

    /// 旋转离 90° 的整数倍不超过 withinDeg 时吸附过去（绕 pivot 转，pivot 默认 aRef，位置不变）
    public static func snapToAxes(_ t: MapARTransform, withinDeg: Double = 3, pivot: Point2? = nil) -> MapARTransform {
        let deg = t.phi * 180 / Double.pi
        let k = (deg / 90).rounded()
        guard abs(deg - k * 90) <= withinDeg else { return t }
        let p = pivot ?? t.aRef
        return MapARTransform(pRef: t.toMap(p), aRef: p, phi: k * Double.pi / 2)
    }
}
