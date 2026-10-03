import Foundation

/// 跨机型 RSSI 线性校正的拟合结果。`rssi_db ≈ scale * rssi_device + offset`
public struct RSSICalibration {
    public var scale: Double
    public var offset: Double
    /// 最优参数下的一致性得分（越大越好；这里是平均单货架 log 似然，≤0）
    public var score: Double
    /// 未校正（scale=1, offset=0）时的同一指标，用来判断校正到底有没有用
    public var scoreBefore: Double
    /// 参与拟合的时间窗个数
    public var samples: Int
    /// 最优 scale 下的 offset-得分曲线，可直接画图看是否有明确极值
    public var curve: [(offset: Double, score: Double)]

    public init(scale: Double, offset: Double, score: Double, scoreBefore: Double,
                samples: Int, curve: [(offset: Double, score: Double)]) {
        self.scale = scale
        self.offset = offset
        self.score = score
        self.scoreBefore = scoreBefore
        self.samples = samples
        self.curve = curve
    }
}

/// 不重采指纹库的前提下，用新机型录的数据拟合 (scale, offset)。
///
/// 方法：网格搜索最大化「校正后读数与指纹库区间的平均一致性」。
/// 一致性用的是和定位同一套的截断高斯 log 似然，但**关掉漏检/意外惩罚** ——
/// 那些惩罚与 offset 无关（货架是否被扫到不取决于线性变换），只会给目标函数加常数，
/// 还会把曲线整体压低、不便于判断极值是否显著。
/// z 截断也放宽到 6σ，否则大偏差区段会饱和成平台、梯度消失。
///
/// 实现上有一个关键简化：聚合（同价签取均值 → 同货架取最大）对正仿射变换是可交换的，
/// 所以只需在 (1,0) 下聚合一次，之后对聚合值做 scale/offset 变换即可，和逐次重聚合完全等价。
public enum RSSICalibrator {

    // 搜索网格
    private static let offsetMin = -25.0
    private static let offsetMax = 25.0
    private static let offsetStep = 0.25
    private static let scaleMin = 0.85
    private static let scaleMax = 1.15
    private static let scaleStep = 0.01

    private static var params: FPScoreParams {
        FPScoreParams(sigmaFloor: 3.0, maxZ: 6.0, evidenceCap: 1.0, usePenalties: false)
    }

    /// 一个参与拟合的单元：一个时间窗的聚合观测 + 可选的已知点位。
    private struct Unit {
        var obs: [FPObservation]
        /// 已知点位在索引里的下标；nil 表示未知（盲标定）
        var truth: Int?
    }

    // MARK: 已知点位

    /// 在已知指纹点上静止录制的数据（pointId → 读数）。
    public static func fit(readingsByPoint: [String: [BLEReading]], points: [FingerprintPoint],
                           eslToShelf: [String: String], fitScale: Bool = false) -> RSSICalibration {
        let index = FPPointIndex(points: points, eslToShelf: eslToShelf, missExpectThreshold: -80)
        var units: [Unit] = []
        for pid in readingsByPoint.keys.sorted() {
            guard let i = index.idToIndex[pid], let rs = readingsByPoint[pid] else { continue }
            for w in splitWindows(rs, windowMs: 1500) {
                let agg = index.aggregate(w, scale: 1.0, offset: 0.0, minRSSI: -115)
                if agg.observations.isEmpty { continue }
                units.append(Unit(obs: agg.observations, truth: i))
            }
        }
        return search(units: units, index: index, fitScale: fitScale)
    }

    // MARK: 盲标定

    /// 边走边录、位置未知：每个时间窗取「最佳匹配点」的一致性，再对窗求平均。
    /// 这是 profile likelihood（把未知位置当作每窗的 nuisance 参数取极大）的做法，
    /// 前提是走过的区域确实被指纹库覆盖。
    public static func fitBlind(readings: [BLEReading], points: [FingerprintPoint],
                                eslToShelf: [String: String], windowMs: Int64 = 1500) -> RSSICalibration {
        let index = FPPointIndex(points: points, eslToShelf: eslToShelf, missExpectThreshold: -80)
        var units: [Unit] = []
        for w in splitWindows(readings, windowMs: Swift.max(windowMs, 200)) {
            let agg = index.aggregate(w, scale: 1.0, offset: 0.0, minRSSI: -115)
            if agg.observations.isEmpty { continue }
            units.append(Unit(obs: agg.observations, truth: nil))
        }
        return search(units: units, index: index, fitScale: false)
    }

    // MARK: - 内部

    private static func splitWindows(_ readings: [BLEReading], windowMs: Int64) -> [[BLEReading]] {
        guard !readings.isEmpty else { return [] }
        let sorted = readings.sorted { $0.tMs < $1.tMs }
        guard let t0 = sorted.first?.tMs else { return [] }
        var out: [[BLEReading]] = []
        var cur: [BLEReading] = []
        var bucket: Int64 = 0
        for r in sorted {
            let b = (r.tMs - t0) / windowMs
            if b != bucket && !cur.isEmpty {
                out.append(cur)
                cur = []
            }
            bucket = b
            cur.append(r)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 给定 (scale, offset)，算所有单元的平均一致性。
    private static func evaluate(_ units: [Unit], _ index: FPPointIndex,
                                 scale: Double, offset: Double) -> Double {
        guard !units.isEmpty, index.count > 0 else { return 0 }
        let p = params
        let worst = -0.5 * p.maxZ * p.maxZ
        var total = 0.0
        for u in units {
            var obs = u.obs
            for i in 0..<obs.count { obs[i].rssi = scale * obs[i].rssi + offset }
            if let t = u.truth {
                let r = index.logLikelihood(obs, at: t, params: p)
                total += r.matched > 0 ? r.normalized : worst
            } else {
                var best = worst
                for j in 0..<index.count {
                    let r = index.logLikelihood(obs, at: j, params: p)
                    if r.matched > 0 && r.normalized > best { best = r.normalized }
                }
                total += best
            }
        }
        return total / Double(units.count)
    }

    private static func search(units: [Unit], index: FPPointIndex, fitScale: Bool) -> RSSICalibration {
        guard !units.isEmpty else {
            return RSSICalibration(scale: 1, offset: 0, score: 0, scoreBefore: 0, samples: 0, curve: [])
        }
        let before = evaluate(units, index, scale: 1.0, offset: 0.0)

        var scales: [Double] = [1.0]
        if fitScale {
            scales = []
            var s = scaleMin
            while s <= scaleMax + 1e-9 {
                scales.append((s * 1000).rounded() / 1000)
                s += scaleStep
            }
        }
        var offsets: [Double] = []
        var o = offsetMin
        while o <= offsetMax + 1e-9 {
            offsets.append((o * 100).rounded() / 100)
            o += offsetStep
        }

        var bestScale = 1.0
        var bestOffset = 0.0
        var bestScore = -Double.greatestFiniteMagnitude
        for s in scales {
            for off in offsets {
                let v = evaluate(units, index, scale: s, offset: off)
                if v > bestScore {
                    bestScore = v
                    bestScale = s
                    bestOffset = off
                }
            }
        }

        // 只画最优 scale 下的切片曲线
        var curve: [(offset: Double, score: Double)] = []
        curve.reserveCapacity(offsets.count)
        for off in offsets {
            curve.append((offset: off, score: evaluate(units, index, scale: bestScale, offset: off)))
        }

        return RSSICalibration(scale: bestScale, offset: bestOffset,
                               score: bestScore == -Double.greatestFiniteMagnitude ? before : bestScore,
                               scoreBefore: before, samples: units.count, curve: curve)
    }
}
