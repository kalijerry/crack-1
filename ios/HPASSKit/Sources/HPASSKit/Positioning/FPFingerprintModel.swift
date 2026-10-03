import Foundation

// MARK: - 输入 / 输出 / 配置

/// 一条 BLE 广播读数。
public struct BLEReading {
    /// 价签 ID（与 eslToShelf 的 key 一致）
    public var tagId: String
    /// 原始 RSSI（dBm，未做跨机型校正）
    public var rssi: Int
    /// 0 = 基础设施侧上报，1 = 手机扫描
    public var type: Int
    /// Unix 毫秒
    public var tMs: Int64

    public init(tagId: String, rssi: Int, type: Int = 1, tMs: Int64) {
        self.tagId = tagId
        self.rssi = rssi
        self.type = type
        self.tMs = tMs
    }
}

/// 定位参数。前 11 项是外部约定的字段，后面是本实现额外暴露的可调项。
public struct PositioningConfig {
    /// 一次估计所用的滑动窗口长度
    public var windowMs: Int64 = 1500
    /// 窗口内读数少于该值时，把窗口放宽到 maxWindowMs
    public var minReadings: Int = 3
    public var maxWindowMs: Int64 = 3000
    /// 校正后弱于该值的读数直接丢弃
    public var minRSSI: Int = -95
    /// WKNN 的 k
    public var k: Int = 4
    /// 跨机型线性校正 rssi' = scale*rssi + offset，作用在**原始读数**上
    public var rssiScale: Double = 1.0
    public var rssiOffset: Double = 0.0
    /// 是否在邻居图上做 HMM/Viterbi 平滑
    public var useGraphSmoothing: Bool = true
    /// 转移门控用的最大步行速度
    public var maxSpeedCmPerSec: Double = 180
    /// 由区间推出的 sigma 的下限
    public var sigmaFloorDb: Double = 3.0

    // --- 以下为本实现的额外可调项 ---

    /// 单个货架残差的 z 截断（污染高斯 / Huber 化）。单项 log-lik 下界 = -0.5*maxZ²
    public var maxZ: Double = 3.0
    /// 「证据量」上限：归一化后的平均 log-lik 乘以 min(terms, evidenceCap)。
    /// 它决定单帧似然的最大动态范围 = evidenceCap * 0.5 * maxZ²。
    public var evidenceCap: Double = 4.0
    /// 某点强烈期望、但本窗口完全没扫到的货架，每个扣多少（nat）
    public var missPenalty: Double = 2.0
    /// 扫到了、但该点指纹库里没有这个货架，每个扣多少（nat）
    public var unexpectedPenalty: Double = 1.0
    /// 只有期望 RSSI 强于该值的货架才参与缺失惩罚（弱信号货架本来就会随机丢失）
    public var missExpectThresholdDb: Double = -80
    /// 只有强于该值的观测才参与「意外货架」惩罚
    public var strongObsThresholdDb: Double = -85
    /// 「任意点跳转」的 log 概率惩罚。必须大于 evidenceCap*0.5*maxZ²，
    /// 否则单帧噪声就能把估计瞬移走；又不能太大，否则真实跳转恢复太慢。
    public var jumpLogPenalty: Double = 25.0
    /// 连续多少帧最优点的拟合都极差就重启 Viterbi
    public var restartAfterBadFrames: Int = 3
    /// 判定「拟合极差」的归一化 log-lik 阈值
    public var badFitNormThreshold: Double = -3.6
    /// candidates 里返回几个
    public var topCandidates: Int = 5

    public init() {}
}

/// 一次定位结果。
public struct PositionEstimate {
    public var tMs: Int64
    /// 厘米，门店地图坐标系
    public var position: Point2
    /// 后验最大的指纹点
    public var pointId: String?
    /// 0...1
    public var confidence: Double
    /// 约 1-sigma 半径（cm）
    public var uncertaintyCm: Double
    public var readingsUsed: Int
    /// 前几名，用于调试 / 热力图
    public var candidates: [(pointId: String, score: Double)]

    public init(tMs: Int64, position: Point2, pointId: String?, confidence: Double,
                uncertaintyCm: Double, readingsUsed: Int,
                candidates: [(pointId: String, score: Double)]) {
        self.tMs = tMs
        self.position = position
        self.pointId = pointId
        self.confidence = confidence
        self.uncertaintyCm = uncertaintyCm
        self.readingsUsed = readingsUsed
        self.candidates = candidates
    }
}

// MARK: - 区间 → 分布

/// 指纹库里一个 (货架, type) 的 RSSI 区间，以及由它推出的高斯参数。
///
/// 建模假设（重要）：
/// 指纹库只存 [min,max]，没有均值/方差/样本数。我们把区间当作该点该货架 RSSI 分布的
/// **粗略摘要**，按「区间 ≈ 均值 ±2σ（约 95% 覆盖）」反推：
///   mu    = (min+max)/2
///   sigma = max(sigmaFloorDb, (max-min)/4)
/// 这是指纹定位里最常用的高斯似然模型（Gaussian likelihood / probabilistic
/// fingerprinting，见 Roos et al. 2002、Youssef & Agrawala Horus 2005）的最小假设版本。
///
/// 为什么不用「区间内平顶 + 软尾」的梯形/均匀似然：
/// 实测区间常有 10~25 dB 宽，平顶会让相邻采集点（间距 1~2 m）完全无法区分，
/// 分辨率直接丢掉。取中点高斯保留了区间内部的判别力，代价是假定区间大致对称。
/// sigma 下限（sigmaFloorDb）用来兜住「只采到一两帧、区间退化成一个点」的情况，
/// 否则 sigma→0 会让该货架的似然变成硬约束。
///
/// 另外，单项 log-lik 截断到 -0.5*maxZ²（污染高斯 / Huber 化）：
/// 真实场景里人体遮挡、货架金属反射会造成 15 dB 以上的离群读数，
/// 不截断的话一个离群货架就能否决整个点。
struct FPInterval {
    var minV: Double
    var maxV: Double

    var mu: Double { (minV + maxV) * 0.5 }

    func sigma(floor: Double) -> Double {
        max(floor, (maxV - minV) * 0.25)
    }

    /// 两个区间取并（指纹库里同一个 (货架,type) 出现多条时）
    func merged(with o: FPInterval) -> FPInterval {
        FPInterval(minV: Swift.min(minV, o.minV), maxV: Swift.max(maxV, o.maxV))
    }
}

/// 窗口内聚合后的「每 (货架, type) 一条」观测。
struct FPObservation {
    var shelfCode: String
    var type: Int
    /// 已做过跨机型校正
    var rssi: Double
}

/// 打分用的参数快照（定位和标定用不同的一套）。
struct FPScoreParams {
    var sigmaFloor: Double = 3.0
    var maxZ: Double = 3.0
    var evidenceCap: Double = 4.0
    var usePenalties: Bool = true
    var missPenalty: Double = 2.0
    var unexpectedPenalty: Double = 1.0
    var missExpectThreshold: Double = -80
    var strongObsThreshold: Double = -85
}

// MARK: - 指纹库索引

/// 把 [FingerprintPoint] 预处理成便于打分的结构，并收集数据问题。
/// 定位器和标定器共用它，避免重复实现似然。
struct FPPointIndex {

    struct PointModel {
        var id: String
        var position: Point2
        /// key = "shelfCode|type"
        var byShelfType: [String: FPInterval]
        /// key = shelfCode（跨 type 取并），当精确 type 命中不到时回退
        var byShelf: [String: FPInterval]
        var typesPresent: Set<Int>
        /// 参与缺失惩罚的货架（期望 RSSI 够强）
        var strongShelves: [String]
        /// 邻居在 models 里的下标（已剔除不存在的 id）
        var neighbours: [Int]
    }

    var models: [PointModel] = []
    var idToIndex: [String: Int] = [:]
    var eslToShelf: [String: String] = [:]

    // 建索引时顺手记下的数据问题，供 validate() 使用
    private(set) var duplicateIds: [String] = []
    private(set) var danglingNeighbours: [(point: String, neighbour: String)] = []
    private(set) var rawPoints: [FingerprintPoint] = []

    init(points: [FingerprintPoint], eslToShelf: [String: String], missExpectThreshold: Double) {
        self.eslToShelf = eslToShelf
        self.rawPoints = points

        // 1) 去重：同一个 id 只保留第一条（后面的记入 duplicateIds）
        var kept: [FingerprintPoint] = []
        var seen = Set<String>()
        var dup = Set<String>()
        for p in points {
            if seen.contains(p.id) {
                dup.insert(p.id)
                continue
            }
            seen.insert(p.id)
            kept.append(p)
        }
        duplicateIds = dup.sorted()

        // 2) id → 下标
        for (i, p) in kept.enumerated() { idToIndex[p.id] = i }

        // 3) 区间表
        var built: [PointModel] = []
        built.reserveCapacity(kept.count)
        for p in kept {
            var byShelfType: [String: FPInterval] = [:]
            var byShelf: [String: FPInterval] = [:]
            var types = Set<Int>()
            for r in p.ranges {
                guard !r.shelfCode.isEmpty else { continue }
                // 容错：库里偶尔 min/max 写反
                let lo = Double(Swift.min(r.minRSSI, r.maxRSSI))
                let hi = Double(Swift.max(r.minRSSI, r.maxRSSI))
                let iv = FPInterval(minV: lo, maxV: hi)
                let key = "\(r.shelfCode)|\(r.type)"
                byShelfType[key] = byShelfType[key]?.merged(with: iv) ?? iv
                byShelf[r.shelfCode] = byShelf[r.shelfCode]?.merged(with: iv) ?? iv
                types.insert(r.type)
            }
            let strong = byShelf.filter { $0.value.mu >= missExpectThreshold }.map { $0.key }.sorted()
            built.append(PointModel(id: p.id, position: p.position,
                                    byShelfType: byShelfType, byShelf: byShelf,
                                    typesPresent: types, strongShelves: strong,
                                    neighbours: []))
        }

        // 4) 邻居下标
        var dangling: [(String, String)] = []
        for (i, p) in kept.enumerated() {
            var nb: [Int] = []
            for n in p.neighbours {
                if n == p.id { continue }
                if let j = idToIndex[n] {
                    if !nb.contains(j) { nb.append(j) }
                } else {
                    dangling.append((p.id, n))
                }
            }
            built[i].neighbours = nb
        }
        danglingNeighbours = dangling.map { (point: $0.0, neighbour: $0.1) }
        models = built
    }

    var count: Int { models.count }

    // MARK: 聚合

    /// 窗口内读数 → 每 (货架, type) 一条观测。
    ///
    /// 聚合策略（两级）：
    /// 1. 同一个价签的多条读数取**均值** —— 压掉毫秒级的快衰落（Rayleigh fading）；
    /// 2. 同一个货架上的多个价签取**最大值** —— 一个货架往往挂几十个价签，
    ///    最强的那个代表「离该货架最近、遮挡最少」的路径，和「货架级指纹」的物理含义一致；
    ///    取均值会被货架另一端的远价签拉低，而且结果强依赖该货架在本窗口被扫到几个价签，
    ///    不同机型/不同扫描占空比下不稳定。
    ///    代价：max 对噪声有正偏（约 +0.5~1 dB），由 sigma 下限吸收。
    ///
    /// - Parameter minRSSI: 校正**后**的下限。标定时传一个很松的值，否则 offset 会改变参与的读数集合、
    ///   让目标函数不连续。
    func aggregate(_ readings: [BLEReading], scale: Double, offset: Double, minRSSI: Double)
        -> (observations: [FPObservation], types: Set<Int>, kept: Int) {

        var sum: [String: Double] = [:]      // key = "tag|shelf|type"
        var cnt: [String: Double] = [:]
        var meta: [String: (shelf: String, type: Int)] = [:]
        var kept = 0

        for r in readings {
            // iOS 上 127 表示 RSSI 不可用；顺手挡掉明显非法值
            if r.rssi >= 0 || r.rssi < -127 { continue }
            guard let shelf = eslToShelf[r.tagId], !shelf.isEmpty else { continue }  // 未知价签直接忽略
            let corrected = scale * Double(r.rssi) + offset
            if corrected < minRSSI { continue }
            let key = "\(r.tagId)|\(shelf)|\(r.type)"
            sum[key] = (sum[key] ?? 0) + corrected
            cnt[key] = (cnt[key] ?? 0) + 1
            meta[key] = (shelf, r.type)
            kept += 1
        }

        var best: [String: Double] = [:]     // key = "shelf|type"
        var types = Set<Int>()
        for (key, s) in sum {
            guard let c = cnt[key], c > 0, let m = meta[key] else { continue }
            let mean = s / c
            let k2 = "\(m.shelf)|\(m.type)"
            if let b = best[k2] { best[k2] = Swift.max(b, mean) } else { best[k2] = mean }
            types.insert(m.type)
        }

        var obs: [FPObservation] = []
        obs.reserveCapacity(best.count)
        for (k2, v) in best {
            let parts = k2.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let t = Int(parts[1]) else { continue }
            obs.append(FPObservation(shelfCode: String(parts[0]), type: t, rssi: v))
        }
        // 固定顺序，保证结果可复现
        obs.sort { $0.shelfCode == $1.shelfCode ? $0.type < $1.type : $0.shelfCode < $1.shelfCode }
        return (obs, types, kept)
    }

    // MARK: 似然

    private func lookup(_ m: PointModel, _ shelf: String, _ type: Int) -> FPInterval? {
        // 优先同 type；库里只采了另一个 type 时回退到跨 type 的并集。
        if let iv = m.byShelfType["\(shelf)|\(type)"] { return iv }
        return m.byShelf[shelf]
    }

    /// 某个点的 log 似然。
    ///
    /// - 匹配上的货架：截断高斯 -0.5*min(z,maxZ)²
    /// - 该点强烈期望、却没扫到的货架：-missPenalty（**漏检证据**，不能忽略：
    ///   「站在 A 货架前却收不到 A 的价签」本身就是强烈的反对证据。
    ///   -2 nat ≈ 漏检概率 0.135，和实测里「强信号价签在 1.5 s 窗口内被漏掉」的量级相当；
    ///   用固定小惩罚而不是真正的漏检似然，是因为库里没有样本数/检测率可估。）
    /// - 扫到了、该点库里却没有的强货架：-unexpectedPenalty（更轻，因为库的覆盖本身可能不全）
    ///
    /// 归一化：先对参与项数取平均（= 各项似然的几何平均），再乘以
    /// min(项数, evidenceCap)。这样
    ///   (a) 覆盖货架多的点不会因为乘了更多项而被系统性压低；
    ///   (b) 单帧似然的动态范围被 evidenceCap 钉死，HMM 的跳转惩罚才有确定的安全边界。
    func logLikelihood(_ obs: [FPObservation], at i: Int, params p: FPScoreParams)
        -> (normalized: Double, scaled: Double, matched: Int, terms: Int) {

        guard i >= 0 && i < models.count else { return (-0.5 * p.maxZ * p.maxZ, 0, 0, 0) }
        let m = models[i]
        var sum = 0.0
        var terms = 0
        var matched = 0
        var seen = Set<String>()

        for o in obs {
            if let iv = lookup(m, o.shelfCode, o.type) {
                let sg = Swift.max(iv.sigma(floor: p.sigmaFloor), 0.5)
                let z = Swift.min(abs(o.rssi - iv.mu) / sg, p.maxZ)
                sum += -0.5 * z * z
                terms += 1
                matched += 1
                seen.insert(o.shelfCode)
            } else if p.usePenalties && o.rssi >= p.strongObsThreshold {
                sum -= p.unexpectedPenalty
                terms += 1
            }
        }

        if p.usePenalties {
            for s in m.strongShelves where !seen.contains(s) {
                sum -= p.missPenalty
                terms += 1
            }
        }

        guard terms > 0 else {
            // 完全没有可比项：给最差分，避免「空区间的点」凭空夺冠
            let worst = -0.5 * p.maxZ * p.maxZ
            return (worst, worst * p.evidenceCap, 0, 0)
        }
        let norm = sum / Double(terms)
        let evidence = Swift.min(Double(terms), p.evidenceCap)
        return (norm, norm * evidence, matched, terms)
    }
}
