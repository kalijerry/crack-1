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
/// - 不在全图注入随机粒子（`randomInjectionConverged = 0`），远处长得像的地方没有机会「接管」；
/// - 原来的簇快没了也不立刻切到远处的簇（`keepClusterRequiresNear`），远跳一律要连续确认；
/// - 估计点落在没采过磁场的格子上不算「丢了」（`zeroConfidenceOffMap = false`）：那里本来就该纯推算；
/// - 真丢了（置信度持续低、或外部判定定错）只在最后一次可靠位置附近找回（`localRecovery`），
///   半径随丢了之后走过的路变大，不罚没数据的粒子，不在全图重新找；
/// - 定到之后地磁只占一部分（`convergedMagWeight`），并按粒子落在有数据格子上的权重比例再打折
///   （`coverageGatedMagWeight`）：一段没采过的路上完全靠推算。
///
/// 数值在公开数据集的 Python 移植上挑的（见 PR 描述），不按单条测试轨迹调。
public enum TrackingProfile {
    /// 已知起点时粒子撒开的 1σ（cm）。
    public static let startSpreadCm: Double = 50
}

public extension MagneticConfig {
    /// 已知起点的跟踪配置档。
    /// - Parameters:
    ///   - odometry: 运动来源。
    ///   - headingKnown: 起始朝向是否知道（用户在屏幕上指过 / 面朝下一个点位）。不知道时调用方 reset 时要传 headingUnknown。
    static func tracking(odometry: OdometrySource, headingKnown: Bool = true) -> MagneticConfig {
        var c = MagneticConfig()
        // 混合偏移：没定到按起伏找，定到后估出整体偏移再按绝对值比（每次读数的整体水平会差 10～16 µT）
        c.hybridOffset = true
        // 以垂直分量 Bz 为主：人掉头时手机偏置的估计误差会让 Bh 和 |B| 的误差反过来，Bz 不受影响
        c.featureWeights = (0.5, 1.0, 0.25)
        // 远跳要连续确认 15 次（约 7.5 m）；收敛后粒子噪声小，不会沿「长得像」的通道滑走
        c.jumpConfirmUpdates = 15
        c.convergedPositionNoiseFraction = 0.03
        switch odometry {
        case .vio:
            // 视觉里程计的位移和航向都比计步准得多，粒子不用撒那么开；丢跟踪退回计步时仍留有余量
            c.initialHeadingBiasSigmaDeg = 5
            c.headingBiasWalkDegPerM = 1
            c.positionNoiseFraction = 0.04
            c.initialScaleSigma = 0.03
            c.scaleWalkPerM = 0.003
            // 推算本身已经很准（公开数据集：中位 0.3 m），地磁只做很小的修正
            c.convergedMagWeight = 0.1
        case .pdr:
            // 起始朝向来自「面朝下一个点位」/ 在屏幕上指，比视觉里程计粗：8～10°
            c.initialHeadingBiasSigmaDeg = headingKnown ? 10 : 30
            c.convergedMagWeight = 0.2
        }
        // 跟踪策略
        c.randomInjectionConverged = 0
        c.keepClusterRequiresNear = true
        c.zeroConfidenceOffMap = false
        c.localRecovery = true
        c.coverageGatedMagWeight = true
        return c
    }
}
