import Foundation

// 地磁定位：粒子滤波。
//
// 运动模型：惯导（FusionEngine 的位移增量，cm）。每个粒子带一个航向偏差和一个步长比例，
//          用来吸收惯导的航向漂移和步长误差。
// 观测模型：粒子位置处地图里的 (|B|, Bz, Bh) 与实测特征比较，重尾似然（Student-t，ν = 4），
//          只在累计走过一段距离之后才更新一次，避免站着不动时权重被越压越窄。
// 通道约束：（可选）粒子必须在通道里走，不能穿货架；单一走向的通道里，行走方向应沿通道轴线。
// 冷启动：  没有起点时在可走区域均匀撒粒子，收敛后缩到较少的粒子数。

public struct MagneticConfig {
    /// 已知起点或收敛之后用的粒子数。
    public var particleCount = 1500
    /// 冷启动（没有起点）时用的粒子数，收敛后自动缩到 `particleCount`。
    public var coldStartParticleCount = 6000
    /// 收敛判据：簇内不确定度小于该值（cm）、置信度大于 `convergedConfidence`，连续 3 次更新。
    public var convergedUncertaintyCm: Double = 200
    public var convergedConfidence: Double = 0.6
    /// 丢失判据：已经收敛之后，置信度低于 `lostConfidence`、或不确定度超过 `lostUncertaintyCm`，
    /// 连续 `lostUpdates` 次更新，就认为丢了（`converged` 变回 false），要重新收敛才恢复。
    public var lostConfidence: Double = 0.2
    public var lostUncertaintyCm: Double = 600
    public var lostUpdates: Int = 4
    /// 不知道朝向（冷启动，或只知道位置不知道朝向）时，每个粒子的航向偏差在整圆上均匀取值，
    /// 靠通道走向和磁场匹配把它挑出来；不依赖罗盘或「地图朝向」。
    public var uniformHeadingWhenUnknown = true

    /// 累计位移达到多少 cm 才做一次观测更新。
    public var updateDistanceCm: Double = 50
    /// 每走 1 cm 附加的位置噪声比例，外加一个固定底噪（cm）。
    public var positionNoiseFraction: Double = 0.08
    /// 收敛之后用的位置噪声比例（nil = 同上）。运动模型很准（视觉里程计）时调小，粒子不会沿通道「滑」到别处。
    public var convergedPositionNoiseFraction: Double?
    public var positionNoiseFloorCm: Double = 2
    /// 冷启动时每个粒子的航向偏差 1σ（度）；以及每走 1 m 的随机游走（度）。
    public var initialHeadingBiasSigmaDeg: Double = 12
    public var headingBiasWalkDegPerM: Double = 2
    /// 步长比例的初始 1σ 与每走 1 m 的随机游走。
    public var initialScaleSigma: Double = 0.06
    public var scaleWalkPerM: Double = 0.005

    /// 观测噪声下限（µT），与地图格子的标准差合成。
    public var observationSigmaFloorUT: Double = 1.5
    /// 总强度、垂直分量、水平分量的权重（Bh 与前两者相关，权重低一些）。
    public var featureWeights: (Double, Double, Double) = (1.0, 1.0, 0.5)
    /// 对数似然除以这个温度，抵消特征之间的相关性造成的过度自信。
    public var likelihoodTemperature: Double = 1.5
    /// 粒子所在位置没有地图数据时的对数似然惩罚。要比「在对的地方但读数有点对不上」重得多，
    /// 否则粒子会跑到没采集过的地方去（实测：−4 时估计会跳到一百多米外）。
    public var missingDataPenalty: Double = -20
    /// 步长比例的上下限。计步在手机竖拿时可能少算三成，所以给足范围。
    public var scaleRange: ClosedRange<Double> = 0.6...1.7

    /// 通道约束：新位置不在可走区域、或中途穿过货架时的对数惩罚。
    public var blockedPenalty: Double = -4
    /// 通道走向先验的标准差（度）。行走方向偏离通道轴线越多，扣分越多。
    public var corridorHeadingSigmaDeg: Double = 22
    /// 走向先验的整体强度，0 关闭。
    public var corridorHeadingWeight: Double = 1.0

    /// 横向距离（深度相机量到的左右货架距离）观测的权重，0 = 不用。需要设置 `raycaster`。
    public var lateralWeight: Double = 0
    /// 横向距离观测的 1σ（cm），再加上距离的 15%。
    public var lateralSigmaCm: Double = 35
    /// 超过这个距离的墙不参与比较（深度相机量程之外）。
    public var lateralMaxCm: Double = 450

    /// 已收敛后，估计位置想跳到 `jumpGateCm` 以外的另一个簇，要连续 `jumpConfirmUpdates` 次更新都指向那里才切换；
    /// 期间继续跟着原来的簇走。防止一两次读数异常（比如系统重新校准磁力计）就把位置甩到别处。
    public var jumpGateCm: Double = 300
    public var jumpConfirmUpdates: Int = 6
    /// 原来的簇权重占比低于这个值，就不再坚持，立刻切换。
    public var keepClusterMinMass: Double = 0.12
    /// 已收敛时注入随机粒子的比例（没收敛时用 `randomInjection`）。
    public var randomInjectionConverged: Double = 0.003

    /// 有效粒子数低于 N × 该比例时重采样。
    public var resampleThreshold: Double = 0.5
    /// 重采样后的位置抖动（cm），以及注入的随机粒子比例（用于跟丢后重新找回）。
    public var roughenCm: Double = 6
    public var randomInjection: Double = 0.02
    /// 估计位置取「最重粒子周围这个半径内」的加权平均，避免多峰时平均到两个峰中间。
    public var clusterRadiusCm: Double = 250
    /// 置信度的参考尺度：不确定度达到该值时置信度归零（cm）。
    public var confidenceScaleCm: Double = 400

    public init() {}
}

public struct MagneticEstimate {
    /// 位置，cm，地图系。
    public var position: Point2
    /// 最重粒子簇的 1σ 位置不确定度（cm）。
    public var uncertaintyCm: Double
    /// 0...1。簇内权重占比 × (1 − 不确定度 / 参考尺度)。
    public var confidence: Double
    /// 有效粒子数 / 总粒子数。
    public var effectiveRatio: Double
    /// 已经做过几次观测更新。
    public var updates: Int
    /// 是否已经收敛（冷启动时从 false 变 true）。
    public var converged: Bool
}

/// 可复现的随机数（测试要求结果稳定）。
struct MagRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func normal() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

/// 非线程安全，与其他 HPASSKit 对象一样要在同一串行队列上使用。
public final class MagneticLocalizer {
    public var config: MagneticConfig
    public let field: MagneticFieldMap
    /// 可走区域。nil 表示整张地图都能走（10×10 m 测试区）。
    public let walkable: WalkableMap?
    /// 货架射线投射，用于横向距离观测。
    public var raycaster: ShelfRaycaster?

    private var rng: MagRNG
    private var xs: [Double] = []
    private var ys: [Double] = []
    private var bias: [Double] = []     // 航向偏差，弧度
    private var scale: [Double] = []    // 步长比例
    private var logw: [Double] = []

    private var travelledCm = 0.0
    private var featureSum = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
    private var featureCount = 0
    private var trustSum = 0.0
    private var latLeftSum = 0.0, latLeftN = 0
    private var latRightSum = 0.0, latRightN = 0
    private var latHeadingSin = 0.0, latHeadingCos = 0.0, latN = 0
    private var updateCount = 0
    private var lastEffectiveRatio = 1.0
    private var coldStart = false
    private var convergedStreak = 0
    private var hasConverged = false
    private var lowStreak = 0
    private var firstUpdateDone = false
    private var headingUnknown = false
    /// 有磁场数据（并且能走）的格子中心，冷启动撒点和跟丢后注入粒子都只在这里面。
    private var mappedCells: [Point2] = []
    /// 当前认定的位置（簇中心）。跳到远处另一个簇需要连续确认。
    private var committed: Point2?
    private var switchStreak = 0
    /// 收敛判定要求「簇的移动和实际走的一致」：上次更新时的簇中心，以及之后累计的平均位移。
    private var lastCenter: Point2?
    private var motionSinceUpdate = Point2.zero

    public init(field: MagneticFieldMap, walkable: WalkableMap? = nil,
                config: MagneticConfig = .init(), seed: UInt64 = 1) {
        self.field = field
        self.walkable = walkable
        self.config = config
        self.rng = MagRNG(seed: seed)
        for j in 0..<field.rows {
            for i in 0..<field.cols {
                let c = Point2((Double(i) + 0.5) * field.cellCm, (Double(j) + 0.5) * field.cellCm)
                guard field.sample(at: c) != nil else { continue }
                if let w = walkable, !w.isWalkable(c) { continue }
                mappedCells.append(c)
            }
        }
        reset(start: nil)
    }

    /// 有磁场数据的面积（m²），冷启动只在这里面找。
    public var mappedAreaM2: Double { Double(mappedCells.count) * field.cellCm * field.cellCm / 10_000 }

    private func randomPosition() -> Point2 {
        // 只在有磁场数据的地方找：没采集过的地方本来就没法用地磁定位
        if !mappedCells.isEmpty {
            let c = mappedCells[min(Int(rng.uniform() * Double(mappedCells.count)), mappedCells.count - 1)]
            let h = field.cellCm / 2
            return Point2(c.x + (rng.uniform() * 2 - 1) * h, c.y + (rng.uniform() * 2 - 1) * h)
        }
        if let w = walkable, let p = w.randomPoint(u1: rng.uniform(), u2: rng.uniform(), u3: rng.uniform()) {
            return p
        }
        return Point2(rng.uniform() * field.widthCm, rng.uniform() * field.heightCm)
    }

    /// 重新开始。start 为 nil 时在可走区域（没有通道信息就是整张图）均匀撒点；
    /// 否则以 start 为中心，spreadCm 为 1σ。
    ///
    /// - Parameter headingUnknown: 位置已知但朝向不知道（或冷启动）。此时粒子的航向偏差在整圆上均匀取值。
    /// - Parameter priorFraction: 朝向不知道时，有一部分粒子仍按惯导给的方向（偏差 1σ = `initialHeadingBiasSigmaDeg`），
    ///   其余在整圆上均匀。惯导方向来自罗盘 + 地图朝向时设 0.5 左右；完全没有参考时设 0。
    public func reset(start: Point2?, spreadCm: Double = 150, headingUnknown: Bool = false, priorFraction: Double = 0) {
        coldStart = start == nil
        self.headingUnknown = (start == nil || headingUnknown) && config.uniformHeadingWhenUnknown
        firstUpdateDone = false
        lowStreak = 0
        let n = max(coldStart ? config.coldStartParticleCount : config.particleCount, 10)
        xs = [Double](repeating: 0, count: n)
        ys = xs
        bias = xs
        scale = [Double](repeating: 1, count: n)
        logw = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var p: Point2
            if let s = start {
                p = Point2(s.x + rng.normal() * spreadCm, s.y + rng.normal() * spreadCm)
                if let w = walkable, !w.isWalkable(p) { p = w.nearestWalkable(to: p, radiusCm: 300) ?? s }
            } else {
                p = randomPosition()
            }
            xs[i] = min(max(p.x, 0), field.widthCm)
            ys[i] = min(max(p.y, 0), field.heightCm)
            let usePrior = !self.headingUnknown || Double(i) < Double(n) * min(max(priorFraction, 0), 1)
            bias[i] = usePrior ? rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
                               : (rng.uniform() * 2 - 1) * Double.pi
            scale[i] = 1 + rng.normal() * config.initialScaleSigma
        }
        travelledCm = 0
        featureSum = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
        featureCount = 0
        trustSum = 0
        committed = start
        switchStreak = 0
        lastCenter = nil
        motionSinceUpdate = .zero
        clearLateral()
        updateCount = 0
        lastEffectiveRatio = 1
        convergedStreak = 0
        hasConverged = !coldStart
    }

    /// 是否已经收敛（有把握）
    public var isConverged: Bool { hasConverged }

    /// 外部给的「粗位置」（蓝牙指纹）：每个粒子按离 `center` 的距离加权（高斯，σ = sigmaCm）。
    /// 还没收敛时再把权重最低的一部分粒子换成撒在 `center` 附近的新粒子（朝向全方向），冷启动几秒就能圈到对的区域。
    /// - Parameter weight: 0...1，收敛后应该给小一点（只当约束，不抢地磁的主导）。
    public func applyPositionPrior(_ center: Point2, sigmaCm: Double, weight: Double, injectFraction: Double = 0) {
        guard !xs.isEmpty, sigmaCm > 0, weight > 0 else { return }
        let s2 = 2 * sigmaCm * sigmaCm
        for i in 0..<xs.count {
            let dx = xs[i] - center.x, dy = ys[i] - center.y
            logw[i] += weight * -(dx * dx + dy * dy) / s2
        }
        if !hasConverged && injectFraction > 0 {
            let m = Int(Double(xs.count) * min(injectFraction, 0.5))
            let order = logw.indices.sorted { logw[$0] < logw[$1] }
            let floorW = logw.max() ?? 0
            for k in order.prefix(m) {
                var p = Point2(center.x + rng.normal() * sigmaCm, center.y + rng.normal() * sigmaCm)
                if let w = walkable, !w.isWalkable(p) { p = w.nearestWalkable(to: p, radiusCm: 300) ?? p }
                xs[k] = min(max(p.x, 0), field.widthCm)
                ys[k] = min(max(p.y, 0), field.heightCm)
                bias[k] = headingUnknown ? (rng.uniform() * 2 - 1) * Double.pi : rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
                scale[k] = 1 + rng.normal() * config.initialScaleSigma
                logw[k] = floorW - 2          // 新粒子先给一个中等偏低的权重，靠后面的地磁观测说话
            }
        }
        normalize()
    }

    /// 送入一次惯导位移增量（cm，地图系）和这段时间内最新的磁场特征，返回当前估计。
    ///
    /// - Parameter trust: 这一刻磁场读数可信度 0...1（见 `MagneticTrustMonitor`）。
    ///   可信度低时观测更新的权重按比例缩小，为 0 时这段读数完全不参与；位置预测不受影响。
    @discardableResult
    public func step(delta: Point2, feature: MagneticFeature?, trust: Double = 1,
                     lateral: LateralObservation? = nil) -> MagneticEstimate {
        let dist = delta.length
        if let l = lateral {
            if let v = l.leftCm { latLeftSum += v; latLeftN += 1 }
            if let v = l.rightCm { latRightSum += v; latRightN += 1 }
            latHeadingSin += sin(l.headingRad); latHeadingCos += cos(l.headingRad); latN += 1
        }
        if dist > 0 {
            predict(delta: delta, dist: dist)
            // 认定的位置跟着粒子的平均位移走
            if let c = committed { committed = c + meanMotion }
            motionSinceUpdate = motionSinceUpdate + meanMotion
        }

        travelledCm += dist
        if let f = feature {
            let t = min(max(trust, 0), 1)
            featureSum = featureSum + f * t
            trustSum += t
            featureCount += 1
        }
        // 冷启动时站着不动也要先做一次观测更新：把「全图任何地方」缩小到「磁场长这样的地方」，走起来才有的放矢
        let firstDue = coldStart && !firstUpdateDone && featureCount >= 3
        let due = travelledCm >= config.updateDistanceCm || firstDue
        if due, config.lateralWeight > 0, raycaster != nil, latN > 0 {
            updateLateral()
        }
        if due, featureCount > 0 {
            if firstDue { firstUpdateDone = true }
            // 特征按可信度加权平均；整体似然再乘以平均可信度
            if trustSum > 1e-6 {
                update(feature: featureSum * (1 / trustSum), trust: trustSum / Double(featureCount))
            }
            travelledCm = 0
            featureSum = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
            featureCount = 0
            trustSum = 0
        }
        if due { clearLateral() }
        return estimate()
    }

    private func clearLateral() {
        latLeftSum = 0; latLeftN = 0; latRightSum = 0; latRightN = 0
        latHeadingSin = 0; latHeadingCos = 0; latN = 0
    }

    /// 横向距离观测：每个粒子在自己位置、自己的行进方向上射线投射，与实测的左右距离比较。
    private func updateLateral() {
        guard let rc = raycaster else { return }
        let left = latLeftN > 0 ? latLeftSum / Double(latLeftN) : nil
        let right = latRightN > 0 ? latRightSum / Double(latRightN) : nil
        guard left != nil || right != nil else { return }
        let heading = atan2(latHeadingSin, latHeadingCos)
        let maxCm = config.lateralMaxCm
        let nu = 4.0
        func t(_ d2: Double) -> Double { -(nu + 1) / 2 * log(1 + d2 / nu) }
        func side(_ measured: Double?, _ predicted: Double?) -> Double {
            switch (measured, predicted) {
            case let (m?, p?):
                let sigma = config.lateralSigmaCm + 0.15 * p
                let d = (m - p) / sigma
                return t(d * d)
            case (_?, nil): return -2           // 实测有墙，模型里这个位置前方没墙
            case (nil, let p?): return p < maxCm * 0.7 ? -1 : 0   // 模型里该有墙，实测没看到（可能被视野挡了，轻罚）
            default: return 0
            }
        }
        for i in 0..<xs.count {
            let h = heading + bias[i]
            let (pl, pr) = rc.lateral(from: Point2(xs[i], ys[i]), headingRad: h, maxCm: maxCm)
            logw[i] += config.lateralWeight * (side(left, pl) + side(right, pr)) / config.likelihoodTemperature
        }
        normalize()
        let neff = effectiveCount()
        lastEffectiveRatio = neff / Double(xs.count)
        if lastEffectiveRatio < config.resampleThreshold { resample(to: xs.count) }
    }

    // MARK: 预测

    private var meanMotion = Point2.zero

    private func predict(delta: Point2, dist: Double) {
        var mx = 0.0, my = 0.0, mw = 0.0
        let distM = dist / 100
        let frac = hasConverged ? (config.convergedPositionNoiseFraction ?? config.positionNoiseFraction) : config.positionNoiseFraction
        let posSigma = frac * dist + config.positionNoiseFloorCm
        let biasWalk = config.headingBiasWalkDegPerM * Double.pi / 180 * distM.squareRoot()
        let scaleWalk = config.scaleWalkPerM * distM.squareRoot()
        let hs = config.corridorHeadingSigmaDeg * Double.pi / 180
        let useHeading = config.corridorHeadingWeight > 0 && dist >= 10
        for i in 0..<xs.count {
            bias[i] += rng.normal() * biasWalk
            scale[i] = min(max(scale[i] + rng.normal() * scaleWalk, config.scaleRange.lowerBound), config.scaleRange.upperBound)
            let c = cos(bias[i]), s = sin(bias[i])
            let dx = (delta.x * c - delta.y * s) * scale[i]
            let dy = (delta.x * s + delta.y * c) * scale[i]
            let old = Point2(xs[i], ys[i])
            var nx = old.x + dx + rng.normal() * posSigma
            var ny = old.y + dy + rng.normal() * posSigma
            if nx < 0 || nx > field.widthCm || ny < 0 || ny > field.heightCm {
                nx = min(max(nx, 0), field.widthCm)
                ny = min(max(ny, 0), field.heightCm)
                logw[i] -= 2           // 撞墙：扣分
            }
            var np = Point2(nx, ny)
            if let w = walkable {
                if !w.isWalkable(np) || !w.isSegmentClear(from: old, to: np) {
                    np = old                          // 不能穿货架：原地不动并扣分
                    logw[i] += config.blockedPenalty
                } else if useHeading, let ax = w.axisAngle(at: np) {
                    // 行走方向相对通道轴线的夹角（模 π：沿轴线正反两个方向都可以）
                    let walk = atan2(dy, dx)
                    var d = abs(walk - ax).truncatingRemainder(dividingBy: Double.pi)
                    d = min(d, Double.pi - d)
                    logw[i] -= config.corridorHeadingWeight * 0.5 * (d / hs) * (d / hs)
                }
            }
            let w = exp(logw[i])
            mx += (np.x - old.x) * w; my += (np.y - old.y) * w; mw += w
            xs[i] = np.x
            ys[i] = np.y
        }
        meanMotion = mw > 0 ? Point2(mx / mw, my / mw) : delta
    }

    // MARK: 观测更新

    private func update(feature f: MagneticFeature, trust: Double = 1) {
        let nu = 4.0
        let w = config.featureWeights
        let floor2 = config.observationSigmaFloorUT * config.observationSigmaFloorUT
        func t(_ d2: Double) -> Double { -(nu + 1) / 2 * log(1 + d2 / nu) }

        // 没有地图数据的粒子：
        // - 还没收敛（冷启动）时重罚，免得定到没采集过的地方；
        // - 已经收敛后不奖不罚（给有数据粒子的平均似然），否则路上一个数据空洞就会把整团粒子「赶」回别处有数据的地方
        var lls = [Double?](repeating: nil, count: xs.count)
        var sumLL = 0.0, sumW = 0.0
        for i in 0..<xs.count {
            guard let m = field.sample(at: Point2(xs[i], ys[i])) else { continue }
            let d0 = f.total - m.mean.total, d1 = f.vertical - m.mean.vertical, d2 = f.horizontal - m.mean.horizontal
            let v0 = m.sigma.total * m.sigma.total + floor2
            let v1 = m.sigma.vertical * m.sigma.vertical + floor2
            let v2 = m.sigma.horizontal * m.sigma.horizontal + floor2
            let ll = trust * (w.0 * t(d0 * d0 / v0) + w.1 * t(d1 * d1 / v1) + w.2 * t(d2 * d2 / v2)) / config.likelihoodTemperature
            lls[i] = ll
            let pw = exp(logw[i])
            sumLL += pw * ll
            sumW += pw
        }
        let neutral = sumW > 0 ? sumLL / sumW : 0
        for i in 0..<xs.count {
            if let ll = lls[i] {
                logw[i] += ll
            } else {
                logw[i] += hasConverged ? neutral : config.missingDataPenalty
            }
        }
        normalize()
        updateCount += 1
        let neff = effectiveCount()
        lastEffectiveRatio = neff / Double(xs.count)
        if lastEffectiveRatio < config.resampleThreshold { resample(to: xs.count) }
        decideCluster()
        checkConvergence()
    }

    /// 决定认定哪个簇：离当前认定位置近就直接跟；远的另一个簇要连续确认几次才切过去。
    private func decideCluster() {
        let best = cluster(from: nil)
        guard hasConverged, let c = committed else { committed = best.center; switchStreak = 0; return }
        if best.center.distance(to: c) <= config.jumpGateCm {
            committed = best.center
            switchStreak = 0
            return
        }
        let mine = cluster(from: c)
        if mine.mass < config.keepClusterMinMass {
            committed = best.center                 // 原来的簇已经快没了，不再坚持
            switchStreak = 0
            return
        }
        switchStreak += 1
        if switchStreak >= config.jumpConfirmUpdates {
            committed = best.center
            switchStreak = 0
        } else {
            committed = mine.center
        }
    }

    /// 收敛与丢失：
    /// - 没收敛：连续几次更新都落在一个小簇里就算收敛，冷启动时同时把粒子数缩到 `particleCount`；
    /// - 已收敛：置信度持续很低（走进没采过的地方、磁场对不上）就算丢失，`converged` 变回 false。
    private func checkConvergence() {
        let e = estimate()
        // 簇中心应当按实际走的方向和距离移动；凑巧在别处匹配上的「簇」会忽东忽西，不算
        let consistent = lastCenter.map { ($0 + motionSinceUpdate).distance(to: e.position) <= 100 } ?? false
        lastCenter = e.position
        motionSinceUpdate = .zero
        let good = e.uncertaintyCm <= config.convergedUncertaintyCm && e.confidence >= config.convergedConfidence
        if !hasConverged {
            convergedStreak = (good && consistent) ? convergedStreak + 1 : 0
            if convergedStreak >= 3 {
                hasConverged = true
                lowStreak = 0
                if coldStart && xs.count > config.particleCount { resample(to: config.particleCount) }
            }
            return
        }
        let bad = e.confidence < config.lostConfidence || e.uncertaintyCm > config.lostUncertaintyCm
        lowStreak = bad ? lowStreak + 1 : 0
        if lowStreak >= config.lostUpdates {
            hasConverged = false
            convergedStreak = 0
            lowStreak = 0
            lostCount += 1
        }
    }

    /// 累计丢失过几次。
    public private(set) var lostCount = 0

    /// 减去最大值再归一到 Σw = 1（对数域），防止下溢。
    private func normalize() {
        guard let mx = logw.max(), mx.isFinite else {
            logw = [Double](repeating: 0, count: logw.count)
            return
        }
        var sum = 0.0
        for v in logw { sum += exp(v - mx) }
        let shift = mx + log(sum)
        for i in 0..<logw.count { logw[i] -= shift }
    }

    private func effectiveCount() -> Double {
        var s2 = 0.0
        for v in logw { let w = exp(v); s2 += w * w }
        return s2 > 0 ? 1 / s2 : 0
    }

    /// 系统重采样到 m 个粒子 + 位置抖动 + 少量随机粒子（跟丢后能重新找回）。
    private func resample(to m: Int) {
        let n = xs.count
        var cum = [Double](repeating: 0, count: n)
        var acc = 0.0
        for i in 0..<n { acc += exp(logw[i]); cum[i] = acc }
        let step = acc / Double(m)
        var u = rng.uniform() * step
        var nx = [Double](repeating: 0, count: m), ny = nx, nb = nx, ns = nx
        var j = 0
        for i in 0..<m {
            while j < n - 1 && cum[j] < u { j += 1 }
            nx[i] = xs[j] + rng.normal() * config.roughenCm
            ny[i] = ys[j] + rng.normal() * config.roughenCm
            nb[i] = bias[j]
            ns[i] = scale[j]
            u += step
        }
        let inject = Int(Double(m) * (hasConverged ? config.randomInjectionConverged : config.randomInjection))
        for k in 0..<inject {
            let i = m - 1 - k
            let p = randomPosition()
            nx[i] = p.x
            ny[i] = p.y
            nb[i] = rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
            ns[i] = 1 + rng.normal() * config.initialScaleSigma
        }
        for i in 0..<m {
            var p = Point2(min(max(nx[i], 0), field.widthCm), min(max(ny[i], 0), field.heightCm))
            if let w = walkable, !w.isWalkable(p) { p = Point2(xs[min(i, n - 1)], ys[min(i, n - 1)]) }
            nx[i] = p.x
            ny[i] = p.y
        }
        xs = nx; ys = ny; bias = nb; scale = ns
        logw = [Double](repeating: -log(Double(m)), count: m)
    }

    // MARK: 估计

    /// 从 `seed` 开始（nil = 从权重总和最大的 2 m 方块开始）做均值漂移，返回簇中心、权重占比、1σ 不确定度。
    private func cluster(from seed: Point2?) -> (center: Point2, mass: Double, unc: Double) {
        let n = xs.count
        let mx = logw.max() ?? 0
        var w = [Double](repeating: 0, count: n)
        var total = 0.0
        for i in 0..<n { w[i] = exp(logw[i] - mx); total += w[i] }
        guard total > 0 else { return (Point2(field.widthCm / 2, field.heightCm / 2), 0, field.widthCm) }
        var cx: Double, cy: Double
        if let s = seed {
            cx = s.x; cy = s.y
        } else {
            // 不从「单个最重粒子」开始：权重很平的时候，单个最重粒子可能是刚注入的随机粒子，估计会满图跳
            var mass: [Int: Double] = [:], sumX: [Int: Double] = [:], sumY: [Int: Double] = [:]
            let bin = 200.0
            for i in 0..<n {
                let k = Int(ys[i] / bin) * 100_000 + Int(xs[i] / bin)
                mass[k, default: 0] += w[i]
                sumX[k, default: 0] += w[i] * xs[i]
                sumY[k, default: 0] += w[i] * ys[i]
            }
            let top = mass.max(by: { $0.value < $1.value })!
            cx = sumX[top.key]! / top.value
            cy = sumY[top.key]! / top.value
        }
        let r2 = config.clusterRadiusCm * config.clusterRadiusCm
        var m = 0.0
        for _ in 0..<3 {
            var sw = 0.0, sx = 0.0, sy = 0.0
            for i in 0..<n {
                let dx = xs[i] - cx, dy = ys[i] - cy
                if dx * dx + dy * dy <= r2 { sw += w[i]; sx += w[i] * xs[i]; sy += w[i] * ys[i] }
            }
            if sw > 0 { cx = sx / sw; cy = sy / sw }
            m = sw / total
        }
        var sw = 0.0, vx = 0.0, vy = 0.0
        for i in 0..<n {
            let dx = xs[i] - cx, dy = ys[i] - cy
            if dx * dx + dy * dy <= r2 { sw += w[i]; vx += w[i] * dx * dx; vy += w[i] * dy * dy }
        }
        let unc = sw > 0 ? ((vx + vy) / sw).squareRoot() : config.clusterRadiusCm
        return (Point2(cx, cy), m, unc)
    }

    public func estimate() -> MagneticEstimate {
        let c = cluster(from: hasConverged ? committed : nil)
        var conf = max(0, min(1, c.mass * (1 - c.unc / config.confidenceScaleCm)))
        // 估计点本身落在没有磁场数据的地方：地磁说了不算，置信度归零
        if field.sample(at: c.center) == nil { conf = 0 }
        return MagneticEstimate(position: c.center, uncertaintyCm: c.unc, confidence: conf,
                                effectiveRatio: lastEffectiveRatio, updates: updateCount, converged: hasConverged)
    }
}
