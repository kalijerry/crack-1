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
    /// 按场景调地磁权重（见 MagneticLocalizer.magneticWeight）：磁场图稀、走得还短、磁场平、和标签对不上时，
    /// 地磁似然打折，交给标签 / 通道 / 运动去定，免得地磁把位置带偏（公开数据集上「只用地磁比纯推算还差」）
    public var adaptiveMagWeight = false
    public var magWeightFloor = 0.15
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
    /// 重采样时注入的随机粒子：航向未知时航向偏差也在整圆上均匀取值（false = 沿用 N(0, `initialHeadingBiasSigmaDeg`)）。
    /// 默认关，保持原有冷启动行为；由需要的配置档显式打开。
    public var uniformHeadingForInjection = false

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
    /// 只比「起伏」不比「绝对值」：读数和地图各减去最近一段路的平均再比。
    /// 实测两次采集同一处的磁场起伏很像（相关 0.78），但整体差 10～16 µT（手机磁力计偏置每次估得不一样），
    /// 按绝对值比就对不上。打开后整体偏移被抵消掉。
    public var offsetInvariant = false
    /// 混合模式：没定到时按「起伏」找（不怕整体偏移），定到之后估出这次的整体偏移、改回按绝对值比（更准），
    /// 偏移在定位过程中慢慢跟踪。优先于 offsetInvariant。
    public var hybridOffset = false
    /// 定到之后偏移跟踪的速度（每次更新）
    public var offsetTrackRate = 0.03
    /// 「最近一段路」有多长：按观测更新次数算的指数平均（每次约 20 cm，40 次约 8 m）
    public var offsetWindowUpdates: Double = 40
    /// 起伏模式下绝对值还占多少分量（0 = 完全不看绝对值）；绝对值那一项的标准差加上 offsetSlackUT
    public var absoluteWeight: Double = 0
    public var offsetSlackUT: Double = 12
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
    /// 整步撞墙时贴墙滑（先只走 x，再只走 y），滑得过去就不原地不动。false = 原有行为。跟踪配置档打开。
    public var wallSlide = false
    /// 贴墙滑过去的粒子的对数惩罚（比原地不动轻：方向偏了一点，但不是穿墙）。
    public var wallSlidePenalty: Double = -1
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

    // MARK: 跟踪策略（默认全是原有行为；跟踪配置档 `MagneticConfig.tracking` 打开）

    /// 已收敛后地磁似然乘的权重（adaptiveMagWeight 打开时不用这个）。1 = 原有行为。
    public var convergedMagWeight: Double = 1
    /// 已收敛时，地磁似然再乘 g = clamp((有数据粒子的权重占比 − 0.5) / 0.4, 0, 1)：
    /// 粒子大多落在没采过磁场的格子上时，这一段完全靠推算，不让少数「有数据」的粒子把权重抢走。
    public var coverageGatedMagWeight = false
    /// 估计点落在没有磁场数据的格子上时置信度归零（于是持续几次就判丢）。跟踪时关掉：没采过的地方本来就该纯推算。
    public var zeroConfidenceOffMap = true
    /// 原来的簇权重占比低于 `keepClusterMinMass` 时立刻切换——只在新簇离得近（≤ 2 × `jumpGateCm`）时这样做；
    /// 远处的簇照样要连续 `jumpConfirmUpdates` 次确认，确认期间原来的簇权重低也不算「走向丢失」
    /// （否则判丢之后估计直接取最重的簇，等于绕过了确认）。false = 原有行为（不管远近都立刻切）。
    public var keepClusterRequiresNear = false
    /// 已知起点开始的定位自己丢了（置信度持续低）：只在最后一次可靠位置（按推算一路平移）附近找回，
    /// 半径 = `localRecoveryBaseCm` + `localRecoveryPerCm` × 丢了之后走过的路（上限 `localRecoveryMaxCm`）。
    /// 这个圆只限制「注入的新粒子撒在哪」：已有的粒子不拉回圆里、也不因为在圆外扣分（公开数据集的移植上量过：
    /// 圆外扣分让 P90 变差，丢了的时候真实位置常常就在圆外的那部分粒子里），估计和重新收敛照样看全部粒子。
    /// 找回期间没有磁场数据的粒子不罚（不用 missingDataPenalty）。
    /// 外部判定定错（declareLost，例如蓝牙说离得很远）不走局部找回：最后的「可靠位置」正是被否定的那个，直接全图找。
    /// 丢了之后走了 `localRecoveryGlobalAfterCm` 还没找回，也改回全图找（起点 / 最后的可靠位置本身可能就是错的）。
    /// false = 原有行为（全图重新找）。冷启动（没有起点）不受影响。
    public var localRecovery = false
    public var localRecoveryBaseCm: Double = 300
    public var localRecoveryPerCm: Double = 0.2
    public var localRecoveryMaxCm: Double = 3000
    /// nil = 一直局部找回
    public var localRecoveryGlobalAfterCm: Double?
    /// 跟踪配置档的运动来源（nil = 不是跟踪档）。运动来源中途变了（视觉里程计没对齐 / 跟丢时计步顶上）
    /// 用 `MagneticLocalizer.setOdometry` 换成对应那一套参数。
    public var trackingOdometry: OdometrySource?
    public var trackingHeadingKnown = true

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
    /// 起伏模式：每个粒子沿自己走过的路，地图值的指数平均；读数的指数平均（NaN = 还没有）
    private var ema0: [Double] = [], ema1: [Double] = [], ema2: [Double] = []
    private var obsEma: (Double, Double, Double)?
    /// 混合模式：这次读数相对地图的整体偏移（定到之后才有）
    private var offsetEst: MagneticFeature?
    public var currentOffset: MagneticFeature? { offsetEst }

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
    /// 这次是从已知起点开始的（reset 给了 start）
    public private(set) var startedFromPrior = false
    /// 局部找回：最后一次可靠位置（丢了之后按粒子平均位移一路平移）和之后走过的路
    private var lastGoodFix: Point2?
    private var sinceGoodCm = 0.0
    /// 正在局部找回（已知起点开始、现在没把握、打开了 localRecovery）
    private var recoveringLocally: Bool { config.localRecovery && startedFromPrior && !hasConverged && lastGoodFix != nil }
    /// 局部找回的半径（cm）
    public var localRecoveryRadiusCm: Double? {
        guard recoveringLocally else { return nil }
        return min(config.localRecoveryBaseCm + config.localRecoveryPerCm * sinceGoodCm, config.localRecoveryMaxCm)
    }
    /// 局部找回的中心（只读，测试 / 调试用）
    public var localRecoveryCenter: Point2? { recoveringLocally ? lastGoodFix : nil }
    /// 局部找回没找到、改回全图找的次数
    public private(set) var globalFallbackCount = 0
    /// 正在为远处的簇做跳转确认（keepClusterRequiresNear），这次更新不算「走向丢失」
    private var holdingAgainstFar = false

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

    private func randomPosition() -> Point2 { randomPositionWithAnchor().point }

    /// 随机位置，外加一个保证可走的「锚点」（选中的有数据格子中心；没有时为 nil）。
    /// 格内偏移最多半格，可能落到通道外，调用方可以退回锚点。
    private func randomPositionWithAnchor() -> (point: Point2, anchor: Point2?) {
        // 只在有磁场数据的地方找：没采集过的地方本来就没法用地磁定位
        if !mappedCells.isEmpty {
            let c = mappedCells[min(Int(rng.uniform() * Double(mappedCells.count)), mappedCells.count - 1)]
            let h = field.cellCm / 2
            return (Point2(c.x + (rng.uniform() * 2 - 1) * h, c.y + (rng.uniform() * 2 - 1) * h), c)
        }
        if let w = walkable, let p = w.randomPoint(u1: rng.uniform(), u2: rng.uniform(), u3: rng.uniform()) {
            return (p, p)
        }
        return (Point2(rng.uniform() * field.widthCm, rng.uniform() * field.heightCm), nil)
    }

    /// 重新开始。start 为 nil 时在可走区域（没有通道信息就是整张图）均匀撒点；
    /// 否则以 start 为中心，spreadCm 为 1σ。
    ///
    /// - Parameter headingUnknown: 位置已知但朝向不知道（或冷启动）。此时粒子的航向偏差在整圆上均匀取值。
    /// - Parameter priorFraction: 朝向不知道时，有一部分粒子仍按惯导给的方向（偏差 1σ = `initialHeadingBiasSigmaDeg`），
    ///   其余在整圆上均匀。惯导方向来自罗盘 + 地图朝向时设 0.5 左右；完全没有参考时设 0。
    public func reset(start: Point2?, spreadCm: Double = 150, headingUnknown: Bool = false, priorFraction: Double = 0) {
        pathSinceResetCm = start == nil ? 0 : 3000     // 已知起点：不用等走够路
        recentTotals = []
        magneticWeight = 1
        coldStart = start == nil
        self.headingUnknown = (start == nil || headingUnknown) && config.uniformHeadingWhenUnknown
        firstUpdateDone = false
        lowStreak = 0
        let n = max(coldStart ? config.coldStartParticleCount : config.particleCount, 10)
        xs = [Double](repeating: 0, count: n)
        ys = xs
        bias = xs
        scale = [Double](repeating: 1, count: n)
        ema0 = [Double](repeating: .nan, count: n); ema1 = ema0; ema2 = ema0
        obsEma = nil
        offsetEst = nil
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
        startedFromPrior = start != nil
        lastGoodFix = start
        sinceGoodCm = 0
        switchStreak = 0
        holdingAgainstFar = false
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

    /// 外部判断「现在不在采集过的区域」（例如听到的标签大多不在指纹里）时设为 true：不允许收敛，
    /// 宁可不显示位置，也不在别处「定」一个错的。
    public var convergenceBlocked = false
    /// 有标签约束时（BLEAssist 设）：没有磁场数据的地方不罚。全场只有一小部分采过磁场，重罚会把粒子都推到
    /// 采过的地方，人在没采过的地方时就会「先漂到别处、走几步再被标签拉回来」；标签全场都有，交给标签定。
    public var missingDataPenaltyOverride: Double?
    /// 外部（BLEAssist）给的：当前位置落在几成强标签的范围里；nil = 不知道
    public var externalAgreement: Double?
    /// 当前地磁权重（0…1，adaptiveMagWeight 打开时才变），和它的各项因子（调试 / 日志用）
    public private(set) var magneticWeight = 1.0
    public private(set) var magWeightFactors: (coverage: Double, path: Double, info: Double, agree: Double) = (1, 1, 1, 1)
    private var pathSinceResetCm = 0.0
    private var recentTotals: [Double] = []
    private var weightUpdates = 0

    /// 外部判断「定错了」（例如蓝牙粗定位持续离得很远）：退回没把握的状态，重新找。
    /// 粒子不清空，靠后面的观测和外部粗定位把它们拉回去。
    /// 不做局部找回：最后一次可靠位置就是刚被否定的那个，围着它找等于往回拉。
    public func declareLost() {
        pathSinceResetCm = 0
        recentTotals = []
        hasConverged = false
        convergedStreak = 0
        committed = nil
        switchStreak = 0
        holdingAgainstFar = false
        lastGoodFix = nil
        sinceGoodCm = 0
    }

    /// 运动来源换了（视觉里程计 ↔ 计步）：跟踪配置档换成对应的参数，粒子的航向偏差 / 步长比例按新来源的初始 1σ
    /// 再撒开一些（两路的误差互不相关，之前学到的偏差不能直接沿用）。不是跟踪档（冷启动）或来源没变时什么都不做。
    public func setOdometry(_ o: OdometrySource) {
        guard let cur = config.trackingOdometry, cur != o else { return }
        config.applyTrackingOdometry(o)
        let hs = config.initialHeadingBiasSigmaDeg * Double.pi / 180
        for i in 0..<xs.count {
            bias[i] += rng.normal() * hs
            scale[i] = min(max(scale[i] + rng.normal() * config.initialScaleSigma, config.scaleRange.lowerBound),
                           config.scaleRange.upperBound)
        }
    }

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
                if k < ema0.count { ema0[k] = .nan; ema1[k] = .nan; ema2[k] = .nan }
            }
        }
        normalize()
    }

    /// 标签范围约束：每片听到的标签都要求「人在它 rangeCm 以内」（按信号强弱定，实测 P90：−75 dBm 2.5 m、
    /// −80 3.2 m、−85 5 m、−90 8 m）。磁场平缓的地方几处长得像，粒子会被拉到别处；附近没有这片标签的位置直接被压下去。
    /// 每片标签的惩罚有上限 capLog（标签表个别位置不对、反射，不至于一片就把正确的位置否掉）。
    /// 还没定到时，把一部分最差的粒子撒到最强那片标签的范围里。
    public func applyTagRanges(_ tags: [(position: Point2, rangeCm: Double)], sigmaCm: Double = 150, capLog: Double = 3,
                               weight: Double = 1, injectFraction: Double = 0) {
        guard !xs.isEmpty, !tags.isEmpty, weight > 0 else { return }
        let s2 = 2 * sigmaCm * sigmaCm
        for i in 0..<xs.count {
            var pen = 0.0
            for t in tags {
                let d = ((xs[i] - t.position.x) * (xs[i] - t.position.x) + (ys[i] - t.position.y) * (ys[i] - t.position.y)).squareRoot()
                let e = d - t.rangeCm
                if e > 0 { pen += min(e * e / s2, capLog) }
            }
            logw[i] -= weight * pen
        }
        if !hasConverged && injectFraction > 0, let best = tags.min(by: { $0.rangeCm < $1.rangeCm }) {
            let m = Int(Double(xs.count) * min(injectFraction, 0.5))
            let order = logw.indices.sorted { logw[$0] < logw[$1] }
            let floorW = logw.max() ?? 0
            for k in order.prefix(m) {
                let a = rng.uniform() * 2 * Double.pi, r = best.rangeCm * rng.uniform().squareRoot()
                var p = Point2(best.position.x + cos(a) * r, best.position.y + sin(a) * r)
                if let w = walkable, !w.isWalkable(p) { p = w.nearestWalkable(to: p, radiusCm: 300) ?? p }
                xs[k] = min(max(p.x, 0), field.widthCm)
                ys[k] = min(max(p.y, 0), field.heightCm)
                bias[k] = headingUnknown ? (rng.uniform() * 2 - 1) * Double.pi : rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
                scale[k] = 1 + rng.normal() * config.initialScaleSigma
                logw[k] = floorW - 2
                if k < ema0.count { ema0[k] = .nan; ema1[k] = .nan; ema2[k] = .nan }
            }
        }
        normalize()
    }

    /// 确定的区域观测（读到货架标签、手机贴近蓝牙标签）：区域外的粒子按离区域的距离重罚（上限 capLog），
    /// 并把一部分最差的粒子撒进区域。已经定到、但当前估计离区域超过 relocateCm：说明定错了，先退回没把握，再多撒一些。
    /// - distance: 点到区域的距离（区域内为 0）；sample: 在区域里随机取一点
    /// - Returns: 是否判定为定错并重新定位
    @discardableResult
    public func applyRegion(distance: (Point2) -> Double, sample: () -> Point2, sigmaCm: Double = 80, capLog: Double = 12,
                            injectFraction: Double = 0.3, relocateCm: Double = 300) -> Bool {
        guard !xs.isEmpty else { return false }
        var wsum = 0.0, mx = 0.0, my = 0.0
        let mw = logw.max() ?? 0
        for i in xs.indices { let w = exp(logw[i] - mw); wsum += w; mx += w * xs[i]; my += w * ys[i] }
        let mean = Point2(mx / max(wsum, 1e-12), my / max(wsum, 1e-12))
        var relocated = false
        if hasConverged && distance(mean) > relocateCm { declareLost(); relocated = true }
        let s2 = 2 * sigmaCm * sigmaCm
        for i in xs.indices {
            let d = distance(Point2(xs[i], ys[i]))
            if d > 0 { logw[i] -= min(d * d / s2, capLog) }
        }
        let frac = hasConverged ? 0 : (relocated ? max(injectFraction, 0.5) : injectFraction)
        if frac > 0 {
            let m = Int(Double(xs.count) * min(frac, 0.6))
            let order = logw.indices.sorted { logw[$0] < logw[$1] }
            let top = logw.max() ?? 0
            for k in order.prefix(m) {
                var p = sample()
                if let w = walkable, !w.isWalkable(p) { p = w.nearestWalkable(to: p, radiusCm: 200) ?? p }
                xs[k] = min(max(p.x, 0), field.widthCm)
                ys[k] = min(max(p.y, 0), field.heightCm)
                bias[k] = headingUnknown ? (rng.uniform() * 2 - 1) * Double.pi : rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
                scale[k] = 1 + rng.normal() * config.initialScaleSigma
                logw[k] = top - 1
                if k < ema0.count { ema0[k] = .nan; ema1[k] = .nan; ema2[k] = .nan }
            }
        }
        normalize()
        return relocated
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
            if config.localRecovery && startedFromPrior {
                // 有把握（且没在走向丢失）时记下可靠位置；否则让它跟着推算走，并累计走过的路
                if hasConverged && lowStreak == 0, let c = committed {
                    lastGoodFix = c
                    sinceGoodCm = 0
                } else if let g = lastGoodFix {
                    lastGoodFix = g + meanMotion
                    sinceGoodCm += dist
                    // 走了这么远还没找回：最后的可靠位置本身可能就是错的（起点给错 / 早就锁错），改回全图找
                    if !hasConverged, let lim = config.localRecoveryGlobalAfterCm, sinceGoodCm >= lim {
                        lastGoodFix = nil
                        sinceGoodCm = 0
                        globalFallbackCount += 1
                    }
                }
            }
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
        pathSinceResetCm += dist
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
                    // 贴墙滑：整步走不过去时先试只走 x、再试只走 y（人沿墙 / 店铺边走，推算的方向偏了一点）
                    let slide = config.wallSlide
                        ? [Point2(np.x, old.y), Point2(old.x, np.y)].first { $0 != old && w.isWalkable($0) && w.isSegmentClear(from: old, to: $0) }
                        : nil
                    if let sp = slide {
                        np = sp
                        logw[i] += config.wallSlidePenalty
                    } else {
                        np = old                      // 不能穿货架：原地不动并扣分
                        logw[i] += config.blockedPenalty
                    }
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
        let a = 1 / max(config.offsetWindowUpdates, 1)
        let usesEma = config.offsetInvariant || config.hybridOffset
        // 读数沿路的平均（原始读数）
        if usesEma {
            if let o = obsEma { obsEma = (o.0 + a * (f.total - o.0), o.1 + a * (f.vertical - o.1), o.2 + a * (f.horizontal - o.2)) }
            else { obsEma = (f.total, f.vertical, f.horizontal) }
        }
        // 混合模式：没定到 / 丢了 → 按起伏找；刚定到 → 偏移 = 读数平均 − 粒子沿路地图平均（按权重）；之后按绝对值比
        if config.hybridOffset {
            if !hasConverged {
                offsetEst = nil
            } else if offsetEst == nil, let o = obsEma {
                var w0 = 0.0, s0 = 0.0, s1 = 0.0, s2 = 0.0
                let mx = logw.max() ?? 0
                for i in 0..<xs.count where !ema0[i].isNaN {
                    let wi = exp(logw[i] - mx); w0 += wi; s0 += wi * ema0[i]; s1 += wi * ema1[i]; s2 += wi * ema2[i]
                }
                if w0 > 0 { offsetEst = MagneticFeature(total: o.0 - s0 / w0, vertical: o.1 - s1 / w0, horizontal: o.2 - s2 / w0) }
            }
        }
        if config.adaptiveMagWeight { updateMagWeight(f) }
        let mw = config.adaptiveMagWeight ? magneticWeight : (hasConverged ? config.convergedMagWeight : 1)
        let rel = config.hybridOffset ? offsetEst == nil : config.offsetInvariant
        let fAbs = offsetEst.map { f - $0 } ?? f
        let slack2 = config.offsetSlackUT * config.offsetSlackUT
        for i in 0..<xs.count {
            guard let m = field.sample(at: Point2(xs[i], ys[i])) else { continue }
            let v0 = m.sigma.total * m.sigma.total + floor2
            let v1 = m.sigma.vertical * m.sigma.vertical + floor2
            let v2 = m.sigma.horizontal * m.sigma.horizontal + floor2
            if usesEma {
                // 粒子沿自己的路累积地图的平均；新粒子（NaN）从当前值开始
                if ema0[i].isNaN { ema0[i] = m.mean.total; ema1[i] = m.mean.vertical; ema2[i] = m.mean.horizontal }
                else {
                    ema0[i] += a * (m.mean.total - ema0[i]); ema1[i] += a * (m.mean.vertical - ema1[i]); ema2[i] += a * (m.mean.horizontal - ema2[i])
                }
            }
            var ll: Double
            if rel, let o = obsEma {
                let r0 = (f.total - o.0) - (m.mean.total - ema0[i])
                let r1 = (f.vertical - o.1) - (m.mean.vertical - ema1[i])
                let r2 = (f.horizontal - o.2) - (m.mean.horizontal - ema2[i])
                ll = w.0 * t(r0 * r0 / v0) + w.1 * t(r1 * r1 / v1) + w.2 * t(r2 * r2 / v2)
                if config.absoluteWeight > 0 {
                    let d0 = f.total - m.mean.total, d1 = f.vertical - m.mean.vertical, d2 = f.horizontal - m.mean.horizontal
                    ll += config.absoluteWeight * (w.0 * t(d0 * d0 / (v0 + slack2)) + w.1 * t(d1 * d1 / (v1 + slack2)) + w.2 * t(d2 * d2 / (v2 + slack2)))
                }
                ll *= mw * trust / config.likelihoodTemperature
            } else {
                let d0 = fAbs.total - m.mean.total, d1 = fAbs.vertical - m.mean.vertical, d2 = fAbs.horizontal - m.mean.horizontal
                ll = mw * trust * (w.0 * t(d0 * d0 / v0) + w.1 * t(d1 * d1 / v1) + w.2 * t(d2 * d2 / v2)) / config.likelihoodTemperature
            }
            lls[i] = ll
            let pw = exp(logw[i])
            sumLL += pw * ll
            sumW += pw
        }
        var neutral = sumW > 0 ? sumLL / sumW : 0
        // 覆盖门：已收敛时按「有数据粒子的权重占比」给地磁打折，大多落在没采过的地方时完全靠推算
        var gate = 1.0
        if config.coverageGatedMagWeight && hasConverged {
            var total = 0.0
            for v in logw { total += exp(v) }
            let share = total > 0 ? sumW / total : 0
            gate = min(max((share - 0.5) / 0.4, 0), 1)
            neutral *= gate
        }
        // 局部找回时没有数据的粒子也不罚（和已收敛时一样给平均值）：找回范围本来就只在附近
        let missing = (hasConverged || recoveringLocally) ? neutral : (missingDataPenaltyOverride ?? config.missingDataPenalty)
        for i in 0..<xs.count {
            if let ll = lls[i] {
                logw[i] += ll * gate
            } else {
                logw[i] += missing
            }
        }
        normalize()
        // 混合模式：定到之后慢慢跟踪偏移（读数 − 地图在当前位置的值）
        if config.hybridOffset, let off = offsetEst, let c = committed ?? lastCenter, let m = field.sample(at: c) {
            let r = config.offsetTrackRate
            offsetEst = MagneticFeature(total: off.total + r * ((f.total - m.mean.total) - off.total),
                                        vertical: off.vertical + r * ((f.vertical - m.mean.vertical) - off.vertical),
                                        horizontal: off.horizontal + r * ((f.horizontal - m.mean.horizontal) - off.horizontal))
        }
        updateCount += 1
        let neff = effectiveCount()
        lastEffectiveRatio = neff / Double(xs.count)
        if lastEffectiveRatio < config.resampleThreshold { resample(to: xs.count) }
        decideCluster()
        checkConvergence()
    }

    /// 决定认定哪个簇：离当前认定位置近就直接跟；远的另一个簇要连续确认几次才切过去。
    private func decideCluster() {
        holdingAgainstFar = false
        let best = cluster(from: nil)
        guard hasConverged, let c = committed else { committed = best.center; switchStreak = 0; return }
        if best.center.distance(to: c) <= config.jumpGateCm {
            committed = best.center
            switchStreak = 0
            return
        }
        let mine = cluster(from: c)
        // 跟踪策略：只有新簇离得近才「立刻切」，远处的簇照样要连续确认
        let near = !config.keepClusterRequiresNear || best.center.distance(to: c) <= 2 * config.jumpGateCm
        if mine.mass < config.keepClusterMinMass && near {
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
            // 原来的簇已经很轻、远处的簇还在确认：这几次不算「走向丢失」，否则判丢后估计直接取远处的簇，绕过确认
            if config.keepClusterRequiresNear && mine.mass < config.keepClusterMinMass { holdingAgainstFar = true }
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
            && !convergenceBlocked
        if !hasConverged {
            convergedStreak = (good && consistent) ? convergedStreak + 1 : 0
            if convergedStreak >= 3 {
                hasConverged = true
                lowStreak = 0
                if coldStart && xs.count > config.particleCount { resample(to: config.particleCount) }
            }
            return
        }
        if holdingAgainstFar { return }       // 远跳确认期间：丢失计数不动（远跳要么确认、要么原来的簇恢复）
        let bad = e.confidence < config.lostConfidence || e.uncertaintyCm > config.lostUncertaintyCm
        lowStreak = bad ? lowStreak + 1 : 0
        if lowStreak >= config.lostUpdates { loseTrack() }
    }

    /// 自己判定丢了（置信度持续低）：退回没把握的状态；已知起点开始时保留最后一次可靠位置做局部找回。
    func loseTrack() {
        hasConverged = false
        convergedStreak = 0
        lowStreak = 0
        holdingAgainstFar = false
        lostCount += 1
    }

    /// 测试用：把权重最低的一部分粒子挪到 `center` 附近（航向偏差、步长比例不变），模拟远处长出一个簇。
    func moveParticlesForTesting(fraction: Double, to center: Point2, spreadCm: Double) {
        let m = Int(Double(xs.count) * min(max(fraction, 0), 1))
        let order = logw.indices.sorted { logw[$0] < logw[$1] }
        for k in order.prefix(m) {
            xs[k] = min(max(center.x + rng.normal() * spreadCm, 0), field.widthCm)
            ys[k] = min(max(center.y + rng.normal() * spreadCm, 0), field.heightCm)
        }
    }

    /// 累计丢失过几次。
    public private(set) var lostCount = 0

    /// 减去最大值再归一到 Σw = 1（对数域），防止下溢。
    /// 按场景算地磁权重（每 5 次观测更新一次）。找位置时用下面四项相乘，已经定到时基本全给（见函数末尾）：
    /// - 磁场图密度：粒子加权中心 4 m 内有数据的格子比例（< 20% 几乎不用地磁，≥ 70% 全用）；
    /// - 走过的路：冷启动后走得越长，磁场序列越有区分度（< 5 m 只给一半，20 m 后全给）；
    /// - 磁场起伏：最近约 20 次读数 |B| 的标准差（< 1 µT 很平、匹配不出东西 → 打折）；
    /// - 标签一致：当前位置落在几成强标签范围里（≤ 30% 只给三成）。
    private func updateMagWeight(_ f: MagneticFeature) {
        recentTotals.append(f.total)
        if recentTotals.count > 20 { recentTotals.removeFirst(recentTotals.count - 20) }
        weightUpdates += 1
        guard weightUpdates % 5 == 0 || magneticWeight == 1 && weightUpdates < 5 else { return }
        // 加权中心
        let mx = logw.max() ?? 0
        var sw = 0.0, cx = 0.0, cy = 0.0
        for i in xs.indices { let w = exp(logw[i] - mx); sw += w; cx += w * xs[i]; cy += w * ys[i] }
        let c = Point2(cx / max(sw, 1e-12), cy / max(sw, 1e-12))
        var n = 0, cov = 0
        for gx in stride(from: -400.0, through: 400, by: 100) {
            for gy in stride(from: -400.0, through: 400, by: 100) where gx * gx + gy * gy <= 160_000 {
                let p = Point2(c.x + gx, c.y + gy)
                if let w = walkable, !w.isWalkable(p) { continue }
                n += 1
                if field.sample(at: p) != nil { cov += 1 }
            }
        }
        let coverage = n > 0 ? Double(cov) / Double(n) : 0
        let fCov = min(max((coverage - 0.2) / 0.5, 0), 1)
        let fPath = min(1, 0.5 + pathSinceResetCm / 4000)
        var fInfo = 1.0
        if recentTotals.count >= 10 {
            let m = recentTotals.reduce(0, +) / Double(recentTotals.count)
            let sd = (recentTotals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(recentTotals.count)).squareRoot()
            fInfo = min(1, 0.4 + sd / 2.5)
        }
        let fAgree = externalAgreement.map { min(max(($0 - 0.3) / 0.4, 0), 1) * 0.7 + 0.3 } ?? 1
        magWeightFactors = (fCov, fPath, fInfo, fAgree)
        if hasConverged {
            // 已经定到（跟踪）：地磁跟踪很准（实测 0.7～1.1 m），全权给地磁；只有和标签明显对不上才打折
            magneticWeight = max(0.5, fAgree)
        } else {
            // 找位置（冷启动 / 丢了）：地磁容易被长得像的地方带偏，按场景打折，让标签 / 通道 / 运动先把范围定下来
            magneticWeight = max(config.magWeightFloor, fCov * fPath * fInfo * fAgree)
        }
    }

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
        var e0 = [Double](repeating: .nan, count: m), e1 = e0, e2 = e0
        var src = [Int](repeating: 0, count: m)  // 每个新粒子的重采样来源下标；注入粒子为 -1
        var anchor = [Point2?](repeating: nil, count: m)  // 注入粒子的可走锚点
        var j = 0
        for i in 0..<m {
            while j < n - 1 && cum[j] < u { j += 1 }
            nx[i] = xs[j] + rng.normal() * config.roughenCm
            ny[i] = ys[j] + rng.normal() * config.roughenCm
            nb[i] = bias[j]
            ns[i] = scale[j]
            if j < ema0.count { e0[i] = ema0[j]; e1[i] = ema1[j]; e2[i] = ema2[j] }
            src[i] = j
            u += step
        }
        let inject = Int(Double(m) * (hasConverged ? config.randomInjectionConverged : config.randomInjection))
        // 局部找回：注入粒子只撒在最后一次可靠位置附近的圆里，不在全图找
        let localCenter = localRecoveryCenter, localR = localRecoveryRadiusCm ?? 0
        for k in 0..<inject {
            let i = m - 1 - k
            let pa: (point: Point2, anchor: Point2?)
            if let c = localCenter {
                let ang = rng.uniform() * 2 * Double.pi, r = localR * rng.uniform().squareRoot()
                let q = Point2(c.x + cos(ang) * r, c.y + sin(ang) * r)
                // 锚点只在落到不可走区域时才用：最近的可走点，找不到就退回中心
                let off = walkable.map { !$0.isWalkable(q) } ?? false
                pa = (q, off ? (walkable?.nearestWalkable(to: q, radiusCm: 300) ?? c) : c)
            } else {
                pa = randomPositionWithAnchor()
            }
            let p = pa.point, a = pa.anchor
            nx[i] = p.x
            ny[i] = p.y
            src[i] = -1
            anchor[i] = a
            nb[i] = headingUnknown && config.uniformHeadingForInjection ? (rng.uniform() * 2 - 1) * Double.pi : rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
            ns[i] = 1 + rng.normal() * config.initialScaleSigma
            e0[i] = .nan; e1[i] = .nan; e2[i] = .nan
        }
        for i in 0..<m {
            var p = Point2(min(max(nx[i], 0), field.widthCm), min(max(ny[i], 0), field.heightCm))
            if let w = walkable, !w.isWalkable(p) {
                if src[i] >= 0 {
                    // 抖动后落到不可走区域：退回它的重采样来源粒子的位置（不是旧数组里同下标的无关粒子）
                    p = Point2(xs[src[i]], ys[src[i]])
                } else {
                    // 注入粒子的格内偏移落到通道外：退回选中的格子中心（或最近的可走点），
                    // 绝不退回重采样来源，否则会被拉进已收敛（可能锁错）的簇里
                    p = anchor[i] ?? w.nearestWalkable(to: p, radiusCm: 300) ?? p
                }
            }
            nx[i] = p.x
            ny[i] = p.y
        }
        xs = nx; ys = ny; bias = nb; scale = ns
        ema0 = e0; ema1 = e1; ema2 = e2
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
        // （跟踪配置档关掉：没采过的地方本来就该纯推算，不算丢）
        if config.zeroConfidenceOffMap && field.sample(at: c.center) == nil { conf = 0 }
        return MagneticEstimate(position: c.center, uncertaintyCm: c.unc, confidence: conf,
                                effectiveRatio: lastEffectiveRatio, updates: updateCount, converged: hasConverged)
    }
}
