import Foundation

/// 货架级 RSSI 指纹定位器。
///
/// 流水线（都是教科书方法）：
///   滑动窗口聚合 → 每点截断高斯似然（含漏检惩罚）→ 邻居图上的在线 Viterbi 平滑
///   → 后验加权的 WKNN 加权质心 → 置信度 / 不确定度
///
/// 线程约定：非线程安全。约定在同一个串行队列上调用（例如 BLE 回调队列）。
public final class FingerprintPositioner {

    // MARK: 状态

    private var index: FPPointIndex
    private var buffer: [BLEReading] = []
    private var bufferSorted = true

    /// 在线 Viterbi 的每状态最优 log 概率（已逐帧减去最大值）。nil = 尚未初始化
    private var delta: [Double]?
    private var lastEstimateMs: Int64?
    private var badFrames = 0

    private var _config: PositioningConfig

    public var config: PositioningConfig {
        get { _config }
        set {
            let needRebuild = newValue.missExpectThresholdDb != _config.missExpectThresholdDb
            _config = newValue
            if needRebuild {
                // strongShelves 依赖该阈值，改了就重建索引
                index = FPPointIndex(points: index.rawPoints, eslToShelf: index.eslToShelf,
                                     missExpectThreshold: newValue.missExpectThresholdDb)
                delta = nil
            }
        }
    }

    public init(points: [FingerprintPoint], eslToShelf: [String: String], config: PositioningConfig = .init()) {
        self._config = config
        self.index = FPPointIndex(points: points, eslToShelf: eslToShelf,
                                  missExpectThreshold: config.missExpectThresholdDb)
    }

    // MARK: 输入

    public func add(_ readings: [BLEReading]) {
        guard !readings.isEmpty else { return }
        if let last = buffer.last {
            if let first = readings.first, first.tMs < last.tMs { bufferSorted = false }
        }
        for i in 1..<Swift.max(readings.count, 1) where readings[i].tMs < readings[i - 1].tMs {
            bufferSorted = false
        }
        buffer.append(contentsOf: readings)
        // 缓冲区只需要覆盖最长窗口的两倍
        if let newest = readings.map(\.tMs).max() {
            let keepFrom = newest - Swift.max(_config.maxWindowMs, _config.windowMs) * 2
            if buffer.count > 512 || buffer.first.map({ $0.tMs < keepFrom }) == true {
                buffer.removeAll { $0.tMs < keepFrom }
            }
        }
    }

    public func reset() {
        buffer.removeAll()
        bufferSorted = true
        delta = nil
        lastEstimateMs = nil
        badFrames = 0
    }

    /// 已知起点时给 Viterbi 一个先验（高斯，sigma 取 150 cm 量级）。
    public func seed(position: Point2) {
        guard index.count > 0 else { return }
        let sigma = 150.0
        var d = [Double](repeating: 0, count: index.count)
        for i in 0..<index.count {
            let z = index.models[i].position.distance(to: position) / sigma
            d[i] = -0.5 * z * z
        }
        let m = d.max() ?? 0
        for i in 0..<d.count { d[i] = Swift.max(d[i] - m, -_config.jumpLogPenalty) }
        delta = d
        badFrames = 0
    }

    // MARK: 输出

    /// 建议约 1 Hz 调用。窗口内没有可用读数时返回 nil。
    public func estimate(nowMs: Int64) -> PositionEstimate? {
        guard index.count > 0 else { return nil }
        let win = window(nowMs: nowMs)
        let agg = index.aggregate(win, scale: _config.rssiScale, offset: _config.rssiOffset,
                                  minRSSI: Double(_config.minRSSI))
        guard !agg.observations.isEmpty else { return nil }

        let p = scoreParams()
        var ll = [Double](repeating: 0, count: index.count)
        var norms = [Double](repeating: 0, count: index.count)
        var matched = [Int](repeating: 0, count: index.count)
        for i in 0..<index.count {
            let r = index.logLikelihood(agg.observations, at: i, params: p)
            ll[i] = r.scaled
            norms[i] = r.normalized
            matched[i] = r.matched
        }

        // --- 在线 Viterbi 平滑 ---
        var logPost = ll
        if _config.useGraphSmoothing {
            logPost = viterbiStep(ll: ll, norms: norms, nowMs: nowMs)
        } else {
            delta = nil
            badFrames = 0
        }
        lastEstimateMs = nowMs

        let post = Self.softmax(logPost)
        return makeEstimate(tMs: nowMs, posterior: post, norms: norms, matched: matched,
                            readingsUsed: agg.kept)
    }

    /// pointId → 归一化后验（热力图用）。不推进 Viterbi 状态。
    public func scores(nowMs: Int64) -> [String: Double] {
        guard index.count > 0 else { return [:] }
        let win = window(nowMs: nowMs)
        let agg = index.aggregate(win, scale: _config.rssiScale, offset: _config.rssiOffset,
                                  minRSSI: Double(_config.minRSSI))
        guard !agg.observations.isEmpty else { return [:] }
        let p = scoreParams()
        var ll = [Double](repeating: 0, count: index.count)
        for i in 0..<index.count {
            ll[i] = index.logLikelihood(agg.observations, at: i, params: p).scaled
        }
        if _config.useGraphSmoothing, let d = delta {
            // 只做一次「先验 + 似然」，不写回 delta
            let prior = transitionPrior(from: d, dtSec: dtSeconds(nowMs: nowMs))
            for i in 0..<ll.count { ll[i] += prior[i] }
        }
        let post = Self.softmax(ll)
        var out: [String: Double] = [:]
        out.reserveCapacity(post.count)
        for i in 0..<post.count { out[index.models[i].id] = post[i] }
        return out
    }

    // MARK: 数据体检

    /// 返回人读的数据问题列表，空 = 没发现问题。
    public func validate() -> [String] {
        var msgs: [String] = []
        let models = index.models

        if models.isEmpty {
            msgs.append("指纹库为空：没有任何指纹点")
            return msgs
        }
        if models.count < 2 {
            msgs.append("指纹点少于 2 个，无法做图平滑")
        }
        for id in index.duplicateIds {
            msgs.append("重复的指纹点 id：\(id)（只保留了第一条）")
        }
        if index.eslToShelf.isEmpty {
            msgs.append("价签→货架映射为空，所有读数都会被当成未知价签丢弃")
        }

        // 区间本身的问题（用原始数据，才能看到被 merge 掉的异常）
        var dbShelves = Set<String>()
        for p in index.rawPoints {
            if p.ranges.isEmpty {
                msgs.append("指纹点 \(p.id) 没有任何 RSSI 区间（无区间，永远不会被匹配）")
            }
            for r in p.ranges {
                if r.shelfCode.isEmpty {
                    msgs.append("指纹点 \(p.id) 有一条区间的 shelfCode 为空")
                    continue
                }
                dbShelves.insert(r.shelfCode)
                if r.minRSSI > r.maxRSSI {
                    msgs.append("指纹点 \(p.id) 货架 \(r.shelfCode)(type=\(r.type)) 的 minRSSI(\(r.minRSSI)) > maxRSSI(\(r.maxRSSI))")
                }
                let lo = Swift.min(r.minRSSI, r.maxRSSI), hi = Swift.max(r.minRSSI, r.maxRSSI)
                if lo < -110 || hi > -10 {
                    msgs.append("指纹点 \(p.id) 货架 \(r.shelfCode)(type=\(r.type)) 的 RSSI 越界：[\(lo), \(hi)]")
                }
                if hi - lo > 40 {
                    msgs.append("指纹点 \(p.id) 货架 \(r.shelfCode)(type=\(r.type)) 的区间过宽：\(hi - lo) dB，判别力很弱")
                }
            }
        }

        // 邻居图
        for (pid, nid) in index.danglingNeighbours {
            msgs.append("指纹点 \(pid) 的邻居 \(nid) 不存在")
        }
        for m in models where m.neighbours.isEmpty {
            msgs.append("指纹点 \(m.id) 没有邻居（孤立点，图平滑会把它锁死）")
        }
        for m in models {
            for j in m.neighbours where !index.models[j].neighbours.contains(where: { index.models[$0].id == m.id }) {
                msgs.append("邻居关系不对称：\(m.id) → \(models[j].id)，但反向没有")
            }
        }

        // 坐标
        for i in 0..<models.count {
            for j in (i + 1)..<models.count where models[i].position.distance(to: models[j].position) < 1.0 {
                msgs.append("指纹点 \(models[i].id) 与 \(models[j].id) 坐标重合：\(models[i].position)")
            }
        }

        // 覆盖率
        let mappedShelves = Set(index.eslToShelf.values)
        let unmapped = dbShelves.subtracting(mappedShelves).sorted()
        if !unmapped.isEmpty {
            let shown = unmapped.prefix(8).joined(separator: ", ")
            msgs.append("指纹库中的 \(unmapped.count) 个货架在价签映射中不存在（永远扫不到）：\(shown)")
        }
        let unused = mappedShelves.subtracting(dbShelves).sorted()
        if !unused.isEmpty {
            let shown = unused.prefix(8).joined(separator: ", ")
            msgs.append("价签映射中的 \(unused.count) 个货架在指纹库里没有区间（读数会被当成意外货架）：\(shown)")
        }
        return msgs
    }

    // MARK: - 内部

    private func scoreParams() -> FPScoreParams {
        FPScoreParams(sigmaFloor: Swift.max(_config.sigmaFloorDb, 0.5),
                      maxZ: Swift.max(_config.maxZ, 0.5),
                      evidenceCap: Swift.max(_config.evidenceCap, 1.0),
                      usePenalties: true,
                      missPenalty: _config.missPenalty,
                      unexpectedPenalty: _config.unexpectedPenalty,
                      missExpectThreshold: _config.missExpectThresholdDb,
                      strongObsThreshold: _config.strongObsThresholdDb)
    }

    /// 取窗口；读数不够时放宽到 maxWindowMs（仍然不够也照常输出，只是置信度低）。
    private func window(nowMs: Int64) -> [BLEReading] {
        if !bufferSorted {
            buffer.sort { $0.tMs < $1.tMs }
            bufferSorted = true
        }
        let w1 = Swift.max(_config.windowMs, 1)
        var sel = buffer.filter { $0.tMs <= nowMs && $0.tMs > nowMs - w1 }
        if sel.count < _config.minReadings {
            let w2 = Swift.max(_config.maxWindowMs, w1)
            if w2 > w1 {
                sel = buffer.filter { $0.tMs <= nowMs && $0.tMs > nowMs - w2 }
            }
        }
        return sel
    }

    private func dtSeconds(nowMs: Int64) -> Double {
        guard let last = lastEstimateMs else { return 1.0 }
        let dt = Double(nowMs - last) / 1000.0
        return Swift.min(Swift.max(dt, 0.2), 5.0)
    }

    /// 转移先验：max over {自身 ∪ 邻居}（按速度门控惩罚），并给所有状态一个
    /// 「从全局最优跳过来」的下界 —— 这就是 HMM 里的小概率任意跳转，保证真跳转时能恢复。
    private func transitionPrior(from d: [Double], dtSec: Double) -> [Double] {
        let n = index.count
        var prior = [Double](repeating: -Double.greatestFiniteMagnitude, count: n)
        guard d.count == n, n > 0 else { return [Double](repeating: 0, count: n) }
        let best = d.max() ?? 0
        let jumpFloor = best - Swift.max(_config.jumpLogPenalty, 1.0)
        // 速度门控的 sigma：一个采样间隔内「正常」能走多远
        let sigmaMove = Swift.max(_config.maxSpeedCmPerSec * dtSec, 10.0)
        for j in 0..<n {
            var b = d[j]                                  // 自转移，无惩罚
            for i in index.models[j].neighbours {
                let dist = index.models[i].position.distance(to: index.models[j].position)
                let z = dist / sigmaMove
                let cand = d[i] - 0.5 * z * z
                if cand > b { b = cand }
            }
            prior[j] = Swift.max(b, jumpFloor)
        }
        return prior
    }

    /// 在线 Viterbi：每状态只保留最优 log 概率，不存路径（无界存储）。
    private func viterbiStep(ll: [Double], norms: [Double], nowMs: Int64) -> [Double] {
        let n = index.count
        // 持续拟合极差 → 认为处在未知区域，重启
        let bestNorm = norms.max() ?? 0
        if bestNorm < _config.badFitNormThreshold {
            badFrames += 1
            if badFrames >= Swift.max(_config.restartAfterBadFrames, 1) {
                delta = nil
                badFrames = 0
            }
        } else {
            badFrames = 0
        }

        guard let d = delta, d.count == n else {
            var nd = ll
            Self.normalizeInPlace(&nd, lowerBound: -(_config.jumpLogPenalty + 40))
            delta = nd
            return nd
        }
        let prior = transitionPrior(from: d, dtSec: dtSeconds(nowMs: nowMs))
        var nd = [Double](repeating: 0, count: n)
        for i in 0..<n { nd[i] = prior[i] + ll[i] }
        Self.normalizeInPlace(&nd, lowerBound: -(_config.jumpLogPenalty + 40))
        delta = nd
        return nd
    }

    /// 减去最大值并裁掉下界，防止数值漂移。
    private static func normalizeInPlace(_ v: inout [Double], lowerBound: Double) {
        guard let m = v.max() else { return }
        for i in 0..<v.count { v[i] = Swift.max(v[i] - m, lowerBound) }
    }

    private static func softmax(_ logv: [Double]) -> [Double] {
        guard let m = logv.max() else { return [] }
        var e = logv.map { exp(Swift.max($0 - m, -60.0)) }
        let s = e.reduce(0, +)
        if s > 0 { for i in 0..<e.count { e[i] /= s } }
        else { for i in 0..<e.count { e[i] = 1.0 / Double(e.count) } }
        return e
    }

    /// WKNN 加权质心 + 置信度 / 不确定度
    private func makeEstimate(tMs: Int64, posterior: [Double], norms: [Double], matched: [Int],
                              readingsUsed: Int) -> PositionEstimate {
        let n = posterior.count
        var order = Array(0..<n)
        order.sort { a, b in
            posterior[a] == posterior[b] ? index.models[a].id < index.models[b].id : posterior[a] > posterior[b]
        }
        guard let bestIdx = order.first else {
            return PositionEstimate(tMs: tMs, position: .zero, pointId: nil, confidence: 0,
                                    uncertaintyCm: 1e4, readingsUsed: readingsUsed, candidates: [])
        }

        // --- WKNN 加权质心：取后验最大的 k 个点，按后验归一化加权 ---
        let k = Swift.min(Swift.max(_config.k, 1), n)
        let top = Array(order.prefix(k))
        var wsum = 0.0
        var cx = 0.0, cy = 0.0
        for i in top {
            let w = posterior[i]
            wsum += w
            cx += index.models[i].position.x * w
            cy += index.models[i].position.y * w
        }
        if wsum <= 1e-12 {
            // 后验全是 0（数值退化）：退化成等权质心
            wsum = Double(top.count)
            cx = 0; cy = 0
            for i in top { cx += index.models[i].position.x; cy += index.models[i].position.y }
        }
        let centroid = Point2(cx / wsum, cy / wsum)

        // --- 后验尖锐度：top-m 归一化熵 ---
        let m = Swift.min(8, n)
        let headRaw = order.prefix(m).map { posterior[$0] }
        let headSum = headRaw.reduce(0, +)
        var sharp = 1.0
        if m > 1 && headSum > 1e-12 {
            var h = 0.0
            for v in headRaw {
                let pv = v / headSum
                if pv > 1e-12 { h -= pv * log(pv) }
            }
            sharp = Swift.max(0.0, Swift.min(1.0, 1.0 - h / log(Double(m))))
        }

        // --- top-k 的空间散布（加权标准差）---
        var varSum = 0.0
        if wsum > 1e-12 {
            for i in top {
                let dd = index.models[i].position.distance(to: centroid)
                varSum += posterior[i] * dd * dd
            }
            varSum /= wsum
        }
        let spread = sqrt(Swift.max(varSum, 0))
        let spreadTerm = 1.0 / (1.0 + spread / 150.0)

        // --- 拟合质量：最优点的平均单货架 log-lik（≤0），exp 回到 0..1 ---
        let fitTerm = exp(Swift.max(Swift.min(norms[bestIdx], 0.0), -8.0))
        // --- 证据量：匹配上的货架数 ---
        let evidenceTerm = Swift.min(1.0, Double(matched[bestIdx]) / 3.0)

        let confidence = Swift.max(0.0, Swift.min(1.0,
            (0.5 * sharp + 0.3 * spreadTerm + 0.2 * fitTerm) * evidenceTerm))
        // 置信度越低，1-sigma 半径越大；下限 30 cm（采集点本身的定位精度量级）
        let uncertaintyCm = Swift.max(spread, 30.0) * (1.0 + 1.5 * (1.0 - confidence))

        let cands: [(pointId: String, score: Double)] = order
            .prefix(Swift.min(Swift.max(_config.topCandidates, 1), n))
            .map { (pointId: index.models[$0].id, score: posterior[$0]) }

        return PositionEstimate(tMs: tMs, position: centroid, pointId: index.models[bestIdx].id,
                                confidence: confidence, uncertaintyCm: uncertaintyCm,
                                readingsUsed: readingsUsed, candidates: cands)
    }
}
