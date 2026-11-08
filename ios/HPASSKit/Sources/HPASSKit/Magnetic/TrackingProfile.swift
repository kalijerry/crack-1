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
///   外部判定定错（蓝牙 / 区域观测 declareLost）直接全图找，不围着被否定的位置找；
/// - 运动来源中途变了（视觉里程计没对齐 / 跟丢时计步顶上），调用方用 `MagneticLocalizer.setOdometry` 换参数；
/// - 定到之后地磁只占一部分（`convergedMagWeight`），并按粒子落在有数据格子上的权重比例再打折
///   （`coverageGatedMagWeight`）：一段没采过的路上完全靠推算。
///
/// 数值在公开数据集的 Python 移植上挑的（见 PR 描述），不按单条测试轨迹调。
public enum TrackingProfile {
    /// 已知起点时粒子撒开的 1σ（cm）。
    public static let startSpreadCm: Double = 50
    /// 自己丢了之后走了这么远（cm）还没在附近找回，就改回全图找
    public static let localRecoveryGlobalAfterCm: Double = 6000
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

/// Wi-Fi 冷启动（只有 Android 能扫 Wi-Fi；评估 `--wifi`，场景 public/pdr/cold-wifi）：
/// 第一次 Wi-Fi 指纹定位当起点，粒子按 N(定位, `seedSpreadCm`) 撒开、朝向整圆均匀；之后每次扫描给一个重尾（Student-t）
/// 的位置观测；粒子的位置散布小于 `reportSpreadCm`、航向散布小于 `reportHeadingSpreadDeg` 才报位置
/// （宁可不报，也不报一个没把握的），报了之后散布涨到 `holdSpreadCm` 以上才停（不在门限附近来回闪）。
///
/// 地磁：滤波器以跟踪档为底（只在局部，不在全图找），但地磁权重 `magneticWeight` 目前是 0。
/// 公开数据集上量过：定到之后再按 0.02～1 的权重用地磁（混合偏移 / 只比起伏两种都试过），中位、P90、错定都变差——
/// 单次 Wi-Fi 定位的误差在一段路上是成片偏的（同一段路连续十几次偏同一个方向），地磁跟踪从偏了几米的位置出发
/// 会锁到旁边长得像的地方。所以现在是「Wi-Fi + 计步」，地磁这一路留着接口（权重调成正数就用上）。
public enum WiFiColdStartProfile {
    /// kNN 的 k
    public static let neighbours = 5
    /// 起点撒开的 1σ（cm）：单次 Wi-Fi 定位中位误差约 4.5 m、P90 约 9 m
    public static let seedSpreadCm: Double = 800
    /// 每次扫描的位置观测 σ（cm）和 Student-t 的自由度
    public static let priorSigmaCm: Double = 500
    public static let priorNu: Double = 3
    /// 粒子位置散布（cm）小于这个、航向散布（度）小于这个才开始报位置
    public static let reportSpreadCm: Double = 300
    public static let reportHeadingSpreadDeg: Double = 20
    /// 已经在报位置时，位置散布涨到这个（cm）以上才停
    public static let holdSpreadCm: Double = 350
    /// 定到之后地磁的权重（MagneticConfig.convergedMagWeight）。0 = 不用地磁，原因见上
    public static let magneticWeight: Double = 0
}

public extension MagneticConfig {
    /// Wi-Fi 冷启动配置档：跟踪档（不知道朝向）为底，Wi-Fi 一直在给全局位置，所以
    /// - 自己不判丢（不做局部找回 / 全图找）：报不报位置只看粒子散布，Wi-Fi 会把跑偏的粒子拉回来；
    /// - 重采样注入的粒子朝向也在整圆上均匀（位姿坐标系和地图的夹角完全不知道）；
    /// - 地磁权重见 `WiFiColdStartProfile.magneticWeight`。
    static func wifiColdStart(odometry: OdometrySource) -> MagneticConfig {
        var c = MagneticConfig.tracking(odometry: odometry, headingKnown: false)
        c.lostUpdates = Int.max
        c.localRecovery = false
        c.uniformHeadingForInjection = true
        c.convergedMagWeight = WiFiColdStartProfile.magneticWeight
        return c
    }
}
