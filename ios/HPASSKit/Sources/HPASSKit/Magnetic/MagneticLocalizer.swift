import Foundation

// 地磁定位：粒子滤波。
//
// 运动模型：惯导（FusionEngine 的位移增量，cm）。每个粒子带一个航向偏差和一个步长比例，
//          用来吸收室内磁场对罗盘航向的扰动和步长误差。
// 观测模型：粒子位置处地图里的 (|B|, Bz, Bh) 与实测特征比较，重尾似然（Student-t，ν = 4），
//          只在累计走过一段距离之后才更新一次，避免站着不动时权重被越压越窄。
// 约束：    粒子不能出地图边界；地图里没有数据的格子会被扣分但不会被直接杀掉。

public struct MagneticConfig {
    public var particleCount = 1500
    /// 累计位移达到多少 cm 才做一次观测更新。
    public var updateDistanceCm: Double = 50
    /// 每走 1 cm 附加的位置噪声比例，外加一个固定底噪（cm）。
    public var positionNoiseFraction: Double = 0.08
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
    /// 粒子所在位置没有地图数据时的对数似然惩罚。
    public var missingDataPenalty: Double = -4
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

    private var rng: MagRNG
    private var xs: [Double] = []
    private var ys: [Double] = []
    private var bias: [Double] = []     // 航向偏差，弧度
    private var scale: [Double] = []    // 步长比例
    private var logw: [Double] = []

    private var travelledCm = 0.0
    private var featureSum = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
    private var featureCount = 0
    private var updateCount = 0
    private var lastEffectiveRatio = 1.0

    public init(field: MagneticFieldMap, config: MagneticConfig = .init(), seed: UInt64 = 1) {
        self.field = field
        self.config = config
        self.rng = MagRNG(seed: seed)
        reset(start: nil)
    }

    /// 重新开始。start 为 nil 时在整张地图上均匀撒点；否则以 start 为中心，spreadCm 为 1σ。
    public func reset(start: Point2?, spreadCm: Double = 150) {
        let n = max(config.particleCount, 10)
        xs = [Double](repeating: 0, count: n)
        ys = xs
        bias = xs
        scale = [Double](repeating: 1, count: n)
        logw = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if let s = start {
                xs[i] = min(max(s.x + rng.normal() * spreadCm, 0), field.widthCm)
                ys[i] = min(max(s.y + rng.normal() * spreadCm, 0), field.heightCm)
            } else {
                xs[i] = rng.uniform() * field.widthCm
                ys[i] = rng.uniform() * field.heightCm
            }
            bias[i] = rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
            scale[i] = 1 + rng.normal() * config.initialScaleSigma
        }
        travelledCm = 0
        featureSum = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
        featureCount = 0
        updateCount = 0
        lastEffectiveRatio = 1
    }

    /// 送入一次惯导位移增量（cm，地图系）和这段时间内最新的磁场特征，返回当前估计。
    @discardableResult
    public func step(delta: Point2, feature: MagneticFeature?) -> MagneticEstimate {
        let dist = delta.length
        if dist > 0 { predict(delta: delta, dist: dist) }

        travelledCm += dist
        if let f = feature {
            featureSum = featureSum + f
            featureCount += 1
        }
        if travelledCm >= config.updateDistanceCm, featureCount > 0 {
            update(feature: featureSum * (1 / Double(featureCount)))
            travelledCm = 0
            featureSum = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
            featureCount = 0
        }
        return estimate()
    }

    // MARK: 预测

    private func predict(delta: Point2, dist: Double) {
        let distM = dist / 100
        let posSigma = config.positionNoiseFraction * dist + config.positionNoiseFloorCm
        let biasWalk = config.headingBiasWalkDegPerM * Double.pi / 180 * distM.squareRoot()
        let scaleWalk = config.scaleWalkPerM * distM.squareRoot()
        for i in 0..<xs.count {
            bias[i] += rng.normal() * biasWalk
            scale[i] = min(max(scale[i] + rng.normal() * scaleWalk, 0.6), 1.5)
            let c = cos(bias[i]), s = sin(bias[i])
            let dx = (delta.x * c - delta.y * s) * scale[i]
            let dy = (delta.x * s + delta.y * c) * scale[i]
            var nx = xs[i] + dx + rng.normal() * posSigma
            var ny = ys[i] + dy + rng.normal() * posSigma
            if nx < 0 || nx > field.widthCm || ny < 0 || ny > field.heightCm {
                nx = min(max(nx, 0), field.widthCm)
                ny = min(max(ny, 0), field.heightCm)
                logw[i] -= 2           // 撞墙：扣分
            }
            xs[i] = nx
            ys[i] = ny
        }
    }

    // MARK: 观测更新

    private func update(feature f: MagneticFeature) {
        let nu = 4.0
        let w = config.featureWeights
        let floor2 = config.observationSigmaFloorUT * config.observationSigmaFloorUT
        func t(_ d2: Double) -> Double { -(nu + 1) / 2 * log(1 + d2 / nu) }

        for i in 0..<xs.count {
            guard let m = field.sample(at: Point2(xs[i], ys[i])) else {
                logw[i] += config.missingDataPenalty
                continue
            }
            let d0 = f.total - m.mean.total, d1 = f.vertical - m.mean.vertical, d2 = f.horizontal - m.mean.horizontal
            let v0 = m.sigma.total * m.sigma.total + floor2
            let v1 = m.sigma.vertical * m.sigma.vertical + floor2
            let v2 = m.sigma.horizontal * m.sigma.horizontal + floor2
            let ll = w.0 * t(d0 * d0 / v0) + w.1 * t(d1 * d1 / v1) + w.2 * t(d2 * d2 / v2)
            logw[i] += ll / config.likelihoodTemperature
        }
        normalize()
        updateCount += 1
        let neff = effectiveCount()
        lastEffectiveRatio = neff / Double(xs.count)
        if lastEffectiveRatio < config.resampleThreshold { resample() }
    }

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

    /// 系统重采样 + 位置抖动 + 少量随机粒子（跟丢后能重新找回）。
    private func resample() {
        let n = xs.count
        var cum = [Double](repeating: 0, count: n)
        var acc = 0.0
        for i in 0..<n { acc += exp(logw[i]); cum[i] = acc }
        let step = acc / Double(n)
        var u = rng.uniform() * step
        var nx = xs, ny = ys, nb = bias, ns = scale
        var j = 0
        for i in 0..<n {
            while j < n - 1 && cum[j] < u { j += 1 }
            nx[i] = xs[j] + rng.normal() * config.roughenCm
            ny[i] = ys[j] + rng.normal() * config.roughenCm
            nb[i] = bias[j]
            ns[i] = scale[j]
            u += step
        }
        let inject = Int(Double(n) * config.randomInjection)
        for k in 0..<inject {
            let i = n - 1 - k
            nx[i] = rng.uniform() * field.widthCm
            ny[i] = rng.uniform() * field.heightCm
            nb[i] = rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
            ns[i] = 1 + rng.normal() * config.initialScaleSigma
        }
        for i in 0..<n {
            xs[i] = min(max(nx[i], 0), field.widthCm)
            ys[i] = min(max(ny[i], 0), field.heightCm)
        }
        bias = nb
        scale = ns
        logw = [Double](repeating: -log(Double(n)), count: n)
    }

    // MARK: 估计

    public func estimate() -> MagneticEstimate {
        let n = xs.count
        // 权重（线性域）。没做过更新时所有 logw 相同，等价于均匀。
        var w = [Double](repeating: 0, count: n)
        var best = 0
        var total = 0.0
        for i in 0..<n {
            w[i] = exp(logw[i] - (logw.max() ?? 0))
            total += w[i]
            if w[i] > w[best] { best = i }
        }
        guard total > 0 else {
            return MagneticEstimate(position: Point2(field.widthCm / 2, field.heightCm / 2),
                                    uncertaintyCm: field.widthCm, confidence: 0,
                                    effectiveRatio: 0, updates: updateCount)
        }
        // 以最重粒子为中心取一个簇，做两轮均值漂移。
        var cx = xs[best], cy = ys[best]
        let r2 = config.clusterRadiusCm * config.clusterRadiusCm
        var mass = 0.0, vx = 0.0, vy = 0.0
        for _ in 0..<2 {
            var sw = 0.0, sx = 0.0, sy = 0.0
            for i in 0..<n {
                let dx = xs[i] - cx, dy = ys[i] - cy
                if dx * dx + dy * dy <= r2 { sw += w[i]; sx += w[i] * xs[i]; sy += w[i] * ys[i] }
            }
            if sw > 0 { cx = sx / sw; cy = sy / sw; mass = sw / total }
        }
        var sw = 0.0
        for i in 0..<n {
            let dx = xs[i] - cx, dy = ys[i] - cy
            if dx * dx + dy * dy <= r2 { sw += w[i]; vx += w[i] * dx * dx; vy += w[i] * dy * dy }
        }
        let unc = sw > 0 ? ((vx + vy) / sw).squareRoot() : config.clusterRadiusCm
        let conf = max(0, min(1, mass * (1 - unc / config.confidenceScaleCm)))
        return MagneticEstimate(position: Point2(cx, cy), uncertaintyCm: unc, confidence: conf,
                                effectiveRatio: lastEffectiveRatio, updates: updateCount)
    }
}
