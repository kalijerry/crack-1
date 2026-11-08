import Foundation

/// 运动（里程计）来源：决定跟踪时粒子要撒多开、地磁该占多少分量。
public enum OdometrySource: String, CaseIterable {
    /// 视觉里程计（ARKit 等）：位移和航向都很准，一路漂移不到 1%
    case vio
    /// 计步（PDR）：步长、航向误差都大得多
    case pdr
}

/// 「已知起点」跟踪用的配置档。实时定位页（MagneticEngine.makeLocalizer，有起点时）和评估的已知起点分支
/// （SessionEvaluator.evaluate，oracleStart）用同一份，基准量到的就是产品的行为。
///
/// 跟踪和冷启动是两回事：冷启动要在全图找，跟踪时位置本来就知道，地磁只该做小修正。所以跟踪档：
/// - 定到之后不在全图注入随机粒子（`randomInjectionConverged = 0`），远处长得像的地方没有机会「接管」。
///   代价：只用地磁时，起点给错 / 锁到了长得像的地方，地磁自己纠不回来，要靠外部（蓝牙 declareLost、
///   区域观测、用户重新指起点）。公开数据集的移植上量过：留千分之一的全图注入，计步 P90 5.9 → 9.5 m，
///   视觉里程计 4.8 → 5.7 m；而起点错 15 m 的合成走廊里走 300 m 也只有 2/8 次找回，不值；
/// - 原来的簇快没了也不立刻切到远处的簇（`keepClusterRequiresNear`），远跳一律要连续确认 15 次，确认期间不判丢；
/// - 估计点落在没采过磁场的格子上不算「丢了」（`zeroConfidenceOffMap = false`）：那里本来就该纯推算；
/// - 自己丢了（置信度持续低）先在最后一次可靠位置附近找回（`localRecovery`）：半径随丢了之后走过的路变大，
///   新粒子只撒在圆里，不罚没数据的粒子；走了 `localRecoveryGlobalAfterCm` 还没找回就改回全图找。
///   外部判定定错（区域观测 declareLost）直接全图找，不围着被否定的位置找；
/// - 运动来源中途变了（视觉里程计没对齐 / 跟丢时计步顶上），调用方用 `MagneticLocalizer.setOdometry` 换参数；
/// - 整步撞墙时贴墙滑（`wallSlide`）：推算方向偏一点就顶到墙 / 店铺边的粒子不原地卡住；
/// - 定到之后地磁只占一部分（`convergedMagWeight`），并按粒子落在有数据格子上的权重比例再打折
///   （`coverageGatedMagWeight`）：一段没采过的路上完全靠推算；
/// - 地磁似然按实测残差标定（`TrackingProfile.observationSigmaFloorUT` / `magneticCorrelationCm`），
///   整体偏移不用单次读数估，攒够一段再取中位数（`offsetWarmupUpdates`）；
/// - 蓝牙只做软约束（`bleSoftTracking`）：底图学过本场地标签范围时用有上限的软范围约束，没学过用宽的位置先验；
///   不挡收敛，持续对不上只触发局部找回，不全图找。
///
/// 数值在公开数据集的 Python 移植上挑的（见 PR 描述），不按单条测试轨迹调。
public enum TrackingProfile {
    /// 已知起点时粒子撒开的 1σ（cm）。
    public static let startSpreadCm: Double = 50
    /// 自己丢了之后走了这么远（cm）还没在附近找回，就改回全图找
    public static let localRecoveryGlobalAfterCm: Double = 6000

    // 地磁似然标定。数值来自公开数据集的实测残差（hpass-eval --residuals：测试会话每 50 cm 的读数和
    // 「全局解偏移的融合图」在参考位置的值比，扣掉每条会话的整体偏移），不是按定位结果调的：
    // - 残差按 Student-t（ν = 4）拟合的尺度三个分量都是 5 µT 左右，而地图格子自己的标准差中位才 1 µT，
    //   原来的 1.5 µT 下限让 1/3 的读数落在 3σ 以外（t 分布应该是 5%）；
    // - 残差沿路的积分相关长度约 12～17 次更新（6～8 m）：地图误差、偏移误差都是成片的，每 50 cm 一次的更新远不是独立的；
    // - 用开头一次读数估整体偏移，误差中位 5～7 µT、P90 11～25 µT；攒 20 次（10 m）取中位数，降到中位 2.5～4.5 µT。
    /// 观测噪声下限（µT），和地图格子的标准差合成
    public static let observationSigmaFloorUT: Double = 5
    /// 地磁残差的相关长度（cm）：走这么远才算一次独立的地磁观测
    public static let magneticCorrelationCm: Double = 600
    /// 定到之后攒这么多次更新的残差再估整体偏移（中位数），之后用最近 `offsetMedianWindow` 次的中位数慢慢跟
    public static let offsetWarmupUpdates = 20
    public static let offsetMedianWindow = 60
}

public extension MagneticConfig {
    /// 已知起点的跟踪配置档。
    /// - Parameters:
    ///   - odometry: 运动来源。
    ///   - headingKnown: 起始朝向是否知道（用户在屏幕上指过 / 面朝下一个点位）。不知道时调用方 reset 时要传 headingUnknown。
    static func tracking(odometry: OdometrySource, headingKnown: Bool = true) -> MagneticConfig {
        var c = MagneticConfig()
        c.trackingHeadingKnown = headingKnown
        // 混合偏移：没定到按起伏找，定到后估出整体偏移再按绝对值比（每次读数的整体水平会差 10～16 µT）
        c.hybridOffset = true
        // 以垂直分量 Bz 为主：人掉头时手机偏置的估计误差会让 Bh 和 |B| 的误差反过来，Bz 不受影响
        c.featureWeights = (0.5, 1.0, 0.25)
        // 远跳要连续确认 15 次（约 7.5 m）；收敛后粒子噪声小，不会沿「长得像」的通道滑走
        c.jumpConfirmUpdates = 15
        c.convergedPositionNoiseFraction = 0.03
        c.trackingOdometry = odometry
        c.setOdometryParameters(odometry)
        // 跟踪策略
        c.randomInjectionConverged = 0
        c.keepClusterRequiresNear = true
        c.zeroConfidenceOffMap = false
        c.localRecovery = true
        c.localRecoveryGlobalAfterCm = TrackingProfile.localRecoveryGlobalAfterCm
        c.coverageGatedMagWeight = true
        // 推算方向偏一点就会顶到墙 / 店铺边：贴墙滑过去，不原地卡住（只影响有可走区域的地图）
        c.wallSlide = true
        // 似然标定（只在跟踪档里；冷启动和全局默认值不变）
        c.observationSigmaFloorUT = TrackingProfile.observationSigmaFloorUT
        c.magneticCorrelationCm = TrackingProfile.magneticCorrelationCm
        c.offsetWarmupUpdates = TrackingProfile.offsetWarmupUpdates
        c.offsetMedianWindow = TrackingProfile.offsetMedianWindow
        c.bleSoftTracking = true
        return c
    }

    /// 跟踪档换运动来源（只改和运动来源有关的那几项）。不是跟踪档时什么都不做。
    mutating func applyTrackingOdometry(_ odometry: OdometrySource) {
        guard trackingOdometry != nil else { return }
        trackingOdometry = odometry
        setOdometryParameters(odometry)
    }

    private mutating func setOdometryParameters(_ odometry: OdometrySource) {
        let d = MagneticConfig()
        switch odometry {
        case .vio:
            // 视觉里程计的位移和航向都比计步准得多，粒子不用撒那么开
            initialHeadingBiasSigmaDeg = 5
            headingBiasWalkDegPerM = 1
            positionNoiseFraction = 0.04
            initialScaleSigma = 0.03
            scaleWalkPerM = 0.003
            // 推算本身已经很准（公开数据集：中位 0.3 m），地磁只做很小的修正
            convergedMagWeight = 0.1
        case .pdr:
            // 起始朝向来自「面朝下一个点位」/ 在屏幕上指，比视觉里程计粗：8～10°
            initialHeadingBiasSigmaDeg = trackingHeadingKnown ? 10 : 30
            headingBiasWalkDegPerM = d.headingBiasWalkDegPerM
            positionNoiseFraction = d.positionNoiseFraction
            initialScaleSigma = d.initialScaleSigma
            scaleWalkPerM = d.scaleWalkPerM
            convergedMagWeight = 0.2
        }
    }
}
