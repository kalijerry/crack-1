import Foundation

/// 货架立柱上的黄色位置标签（如「082-20」= 通道 082、第 20 段，下面一条条码）：摄像头读到就知道人在哪个货架段前面。
///
/// 门店地图里每段货架是单面的矩形 Shelf-082-20（长约 2.8 m），只有一个长边朝通道。标签贴在这段两端的立柱上，
/// 所以读到标签 = 人在这段货架朝通道一侧、沿货架方向 ±半段长 + 余量 以内，离货架面 0.3～2.5 m。
/// 比价签蓝牙（2 m 左右、靠信号强弱猜）确定得多，而且不会认错。
public struct ShelfSigns {
    public struct Sign: Equatable {
        public var text: String
        public var shelfCode: String
        /// 朝通道那条长边的中点
        public var faceCenter: Point2
        /// 朝通道的单位法向
        public var normal: Point2
        /// 沿货架方向的单位向量
        public var along: Point2
        public var halfLength: Double
    }

    public var minOffsetCm = 30.0
    public var maxOffsetCm = 250.0
    /// 沿货架方向在这段两端以外还允许多远（读的是端头立柱上的标签，人可能站在相邻段前）
    public var alongMarginCm = 80.0

    private var byCode: [String: ShelfRect] = [:]
    private let walkable: WalkableMap?

    public init(map: StoreMap, walkable: WalkableMap?) {
        for s in map.shelves where s.code.hasPrefix("Shelf-") { byCode[s.code] = s }
        self.walkable = walkable
    }

    public var count: Int { byCode.count }

    /// 「082-20」「082 - 20」「O82-2O」（OCR 把 0 认成 O）→ (82, 20)
    public static func parse(_ raw: String) -> (aisle: Int, bay: Int)? {
        let s = raw.uppercased().replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: " ", with: "")
        guard let r = s.range(of: #"(?<![0-9])([0-9]{3})-([0-9]{2})(?![0-9])"#, options: .regularExpression) else { return nil }
        let parts = s[r].split(separator: "-")
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return (a, b)
    }

    /// 标签文字 → 地图上的货架段和它朝通道的那一面；地图里没有这段就 nil
    public func sign(for text: String) -> Sign? {
        guard let (a, b) = Self.parse(text) else { return nil }
        for code in [String(format: "Shelf-%03d-%02d", a, b), String(format: "Shelf-%d-%02d", a, b)] {
            if let s = byCode[code] { return face(s, text: String(format: "%03d-%02d", a, b)) }
        }
        return nil
    }

    /// 按地图货架编号（Shelf-082-20）找；EslLocation.shelfCode 用
    public func sign(forShelfCode code: String) -> Sign? {
        guard let s = byCode[code] else { return nil }
        return face(s, text: String(code.dropFirst("Shelf-".count)))
    }

    func face(_ s: ShelfRect, text: String) -> Sign {
        let r = s.rotation * .pi / 180
        // 矩形自身坐标：width 沿 (cos, sin)，height 沿 (-sin, cos)
        let u = Point2(cos(r), sin(r)), v = Point2(-sin(r), cos(r))
        let longIsW = s.width >= s.height
        let along = longIsW ? u : v
        var n = longIsW ? v : u
        let halfDepth = (longIsW ? s.height : s.width) / 2
        let halfLen = (longIsW ? s.width : s.height) / 2
        let c = Point2(s.x, s.y)
        // 哪一面朝通道：外面 80 cm 能走的那面（两面都能走 / 都不能走时取 +n）
        if let w = walkable {
            let p1 = c + n * (halfDepth + 80), p2 = c - n * (halfDepth + 80)
            if !w.isWalkable(p1) && w.isWalkable(p2) { n = n * -1 }
        }
        return Sign(text: text, shelfCode: s.code, faceCenter: c + n * halfDepth, normal: n, along: along, halfLength: halfLen)
    }

    /// 站在这段货架正中前方 offsetCm 处
    public func standPoint(_ s: Sign, offsetCm: Double = 90) -> Point2 { s.faceCenter + s.normal * offsetCm }

    /// 读到标签时人可能在的区域里离 p 最近的点（p 已经在区域里就是 p 自己）
    public func nearestValid(_ s: Sign, to p: Point2) -> Point2 {
        let d = p - s.faceCenter
        let t = min(max(d.x * s.along.x + d.y * s.along.y, -(s.halfLength + alongMarginCm)), s.halfLength + alongMarginCm)
        let o = min(max(d.x * s.normal.x + d.y * s.normal.y, minOffsetCm), maxOffsetCm)
        return s.faceCenter + s.along * t + s.normal * o
    }

    /// 区域里的一个点：u、v ∈ [0, 1)（沿货架、离货架面）
    public func randomPoint(_ s: Sign, u: Double, v: Double) -> Point2 {
        let t = (u * 2 - 1) * (s.halfLength + alongMarginCm)
        let o = minOffsetCm + v * (min(maxOffsetCm, 200) - minOffsetCm)
        return s.faceCenter + s.along * t + s.normal * o
    }

    /// p 离这个区域多远（cm，在区域里为 0）
    public func distance(_ s: Sign, from p: Point2) -> Double { p.distance(to: nearestValid(s, to: p)) }
}

/// 采集时读到的标签（signs.csv：t_ms,text,shelf_code,confidence）
public struct SignSample {
    public var tMs: Int64
    public var text: String
    public init(tMs: Int64, text: String) { self.tMs = tMs; self.text = text }

    public static func load(_ dir: URL) -> [SignSample] {
        guard let t = try? String(contentsOf: dir.appendingPathComponent("signs.csv"), encoding: .utf8) else { return [] }
        return t.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let c = line.split(separator: ",", omittingEmptySubsequences: false)
            guard c.count >= 3, let t = Int64(c[0]), !c[2].isEmpty else { return nil }
            return SignSample(tMs: t, text: String(c[1]))
        }
    }
}
