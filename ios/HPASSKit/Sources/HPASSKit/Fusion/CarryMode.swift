import Foundation

/// 手机是怎么带着的（携带模式）。驱动分模式步长 K、航向噪声、地磁特征权重和粒子滤波的航向重撒。
///
/// 和 `HoldPosture`（给界面看的持握姿态）的关系：`HoldClassifier` 现在只是 `CarryModeClassifier` 的映射壳。
public enum CarryMode: String, CaseIterable, Codable {
    /// 窗口还没填满 / 没有数据。
    case unknown
    /// 站着不动（手机相对身体的姿态没变，上一个携带姿态仍然有效，见 `CarryModeClassifier.activeMode`）。
    case still
    /// 边走边看屏幕（平端或斜着拿）：前向轴 +y 就是行走方向，夹角 δ ≈ 0。
    case texting
    /// 竖直拿着、屏幕对着自己（AR / 测绘姿势）：前向轴 −z 就是行走方向，δ ≈ 0。
    case upright
    /// 贴耳通话：前向轴 −z 指向侧面，δ ≈ ±90°（哪只耳朵未知），头部转动再带 ±30～60° 抖动。
    case calling
    /// 手握、手臂自然摆动：夹角未知，且随摆动周期性抖动。
    case swinging
    /// 裤兜：夹角未知（屏幕朝腿 / 朝外、口袋开口方向），大腿摆动带周期性俯仰。
    case pocket
    /// 包里：夹角未知，姿态随包晃动慢变。
    case bag

    public var title: String {
        switch self {
        case .unknown: return "未知"
        case .still: return "静止"
        case .texting: return "看屏"
        case .upright: return "竖持"
        case .calling: return "通话"
        case .swinging: return "摆臂"
        case .pocket: return "口袋"
        case .bag: return "包里"
        }
    }

    /// 是「携带姿态」（still / unknown 不是：它们不改变手机相对身体的姿态）。
    public var isCarryPosture: Bool { self != .unknown && self != .still }

    /// 手机-行走夹角 δ 在几何上已知（前向轴就是行走方向）：texting、upright。
    public var hasGeometricHeading: Bool { self == .texting || self == .upright }
}

/// 一个携带模式的运动 / 观测参数。**全部是占位值：待自采 iPhone 双机数据标定**
/// （RIDI / NILoc 派生的数字因许可证作废，这里没有任何一个数值来自它们）。
public struct CarryMotionParameters {
    /// 进入该模式时粒子航向偏差的 1σ（度）。nil = 在整圆上均匀（夹角完全未知）。
    public var headingSpreadDeg: Double?
    /// 航向偏差先验的中心（度，可以多个 = 多峰，例如通话 ±90°）。`headingSpreadDeg` 为 nil 时不用。
    public var headingCentersDeg: [Double]
    /// 粒子航向偏差每走 1 m 的随机游走（度）。
    public var headingBiasWalkDegPerM: Double
    /// 进入该模式时粒子步长比例再撒开的 1σ。
    public var initialScaleSigma: Double
    /// Weinberg 步长系数 K。
    public var stepLengthK: Double
    /// 单步内的航向误差 1σ（度，EKF 步进噪声）。
    public var stepHeadingSigmaDeg: Double
    /// 地磁特征权重 (|B|, Bz, Bh)。
    public var featureWeights: (Double, Double, Double)
    /// 地磁观测噪声下限（µT）。
    public var observationSigmaFloorUT: Double
    /// 航向按一个步幅周期做滑动圆平均再推步（摆臂 / 口袋的周期性抖动）。
    public var strideAverageHeading: Bool
    /// 切到该模式重撒之后走这么远（cm）不判丢（航向整圆撒开后置信度必然先掉）。
    public var lostSuppressCm: Double

    public init(headingSpreadDeg: Double?, headingCentersDeg: [Double] = [0], headingBiasWalkDegPerM: Double,
                initialScaleSigma: Double, stepLengthK: Double, stepHeadingSigmaDeg: Double,
                featureWeights: (Double, Double, Double), observationSigmaFloorUT: Double,
                strideAverageHeading: Bool, lostSuppressCm: Double) {
        self.headingSpreadDeg = headingSpreadDeg
        self.headingCentersDeg = headingCentersDeg.isEmpty ? [0] : headingCentersDeg
        self.headingBiasWalkDegPerM = headingBiasWalkDegPerM
        self.initialScaleSigma = initialScaleSigma
        self.stepLengthK = stepLengthK
        self.stepHeadingSigmaDeg = stepHeadingSigmaDeg
        self.featureWeights = featureWeights
        self.observationSigmaFloorUT = observationSigmaFloorUT
        self.strideAverageHeading = strideAverageHeading
        self.lostSuppressCm = lostSuppressCm
    }
}

/// 分模式参数表。配置里各持一份拷贝，可以整表替换或逐项改。
public struct CarryMotionTable {
    private var rows: [CarryMode: CarryMotionParameters]

    public init(rows: [CarryMode: CarryMotionParameters]) { self.rows = rows }

    /// still / unknown 没有自己的行：用 `fallback`（原有行为的数值）。
    public subscript(mode: CarryMode) -> CarryMotionParameters {
        get { rows[mode] ?? CarryMotionTable.fallback }
        set { rows[mode] = newValue }
    }

    public var modes: [CarryMode] { CarryMode.allCases.filter { rows[$0] != nil } }

    /// 原有行为对应的一行（计步跟踪档：航向 1σ 10°、随机游走 2°/√m、K 0.45、步内航向噪声 3°、权重 (0.5,1,0.25)、4 µT）。
    public static let fallback = CarryMotionParameters(
        headingSpreadDeg: 10, headingBiasWalkDegPerM: 2, initialScaleSigma: 0.06, stepLengthK: 0.45,
        stepHeadingSigmaDeg: 3, featureWeights: (0.5, 1.0, 0.25), observationSigmaFloorUT: 4,
        strideAverageHeading: false, lostSuppressCm: 0)

    /// 占位表。每个数值都**待自采 iPhone 双机数据标定**（office 协议，见 docs/office-test.md）：
    /// - K 一律沿用现有 0.45：文献区间 0.4～0.5，分模式的差异只能由自采数据给出；
    /// - texting / upright 的 δ 在几何上已知，航向只撒 15°（含用户把手机指偏的习惯），步长比例 σ 放到 0.10；
    /// - calling：手机接近竖直（长轴离竖直 < 30°）时前向轴是 −z、指向侧面，δ ≈ ±90°（哪只耳朵未知）；后仰超过 30°
    ///   时前向轴切回 +y、指向后方，δ ≈ 180°。所以先验是 ±90° / 180° 三峰各撒 30°，由粒子滤波挑；步内航向噪声 10°（头部转动）；
    /// - pocket / bag / swinging：δ 完全未知，整圆均匀；
    /// - 特征权重：摆臂时手的位置相对身体前后摆、Bz 对「向上」最敏感，所以基本只信 |B|；包里 Bz 受包内姿态慢变影响，也压低。
    public static let placeholder = CarryMotionTable(rows: [
        .texting: CarryMotionParameters(
            headingSpreadDeg: 15, headingBiasWalkDegPerM: 2, initialScaleSigma: 0.10, stepLengthK: 0.45,
            stepHeadingSigmaDeg: 3, featureWeights: (0.5, 1.0, 0.25), observationSigmaFloorUT: 4,
            strideAverageHeading: false, lostSuppressCm: 800),
        .upright: CarryMotionParameters(
            headingSpreadDeg: 15, headingBiasWalkDegPerM: 2, initialScaleSigma: 0.10, stepLengthK: 0.45,
            stepHeadingSigmaDeg: 3, featureWeights: (0.5, 1.0, 0.25), observationSigmaFloorUT: 4,
            strideAverageHeading: false, lostSuppressCm: 800),
        .calling: CarryMotionParameters(
            headingSpreadDeg: 30, headingCentersDeg: [90, -90, 180], headingBiasWalkDegPerM: 3, initialScaleSigma: 0.10,
            stepLengthK: 0.45, stepHeadingSigmaDeg: 10, featureWeights: (0.5, 1.0, 0.25), observationSigmaFloorUT: 4,
            strideAverageHeading: false, lostSuppressCm: 1500),
        .pocket: CarryMotionParameters(
            headingSpreadDeg: nil, headingBiasWalkDegPerM: 4, initialScaleSigma: 0.12, stepLengthK: 0.45,
            stepHeadingSigmaDeg: 6, featureWeights: (0.6, 0.8, 0.2), observationSigmaFloorUT: 5,
            strideAverageHeading: true, lostSuppressCm: 1500),
        .bag: CarryMotionParameters(
            headingSpreadDeg: nil, headingBiasWalkDegPerM: 5, initialScaleSigma: 0.15, stepLengthK: 0.45,
            stepHeadingSigmaDeg: 8, featureWeights: (0.8, 0.5, 0.2), observationSigmaFloorUT: 6,
            strideAverageHeading: false, lostSuppressCm: 1500),
        .swinging: CarryMotionParameters(
            headingSpreadDeg: nil, headingBiasWalkDegPerM: 5, initialScaleSigma: 0.15, stepLengthK: 0.45,
            stepHeadingSigmaDeg: 10, featureWeights: (1.0, 0.3, 0.1), observationSigmaFloorUT: 6,
            strideAverageHeading: true, lostSuppressCm: 1500),
    ])
}
