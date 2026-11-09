import Foundation

/// App 实时定位页（MagneticEngine.makeFusion）和离线评估（SessionEvaluator 的 `.pdrIMU`、hpass-replay）共用的
/// 惯导引擎配置：两边改的是同一份代码，评估量到的就是 App 的计步推算。
public extension FusionConfig {
    /// - Parameters:
    ///   - hasCorridors: 场地有通道时惯导位置被限制在通道里（与蓝牙定位页一致）
    ///   - compass: 用磁罗盘持续修正航向。App 默认关（页面开关 `useCompassHeading`），只有冷启动且地图设了朝向时开；
    ///     室内磁干扰大，评估也按关来跑
    ///   - stepLengthScale: 步长整体缩放（App 用计步器距离校正后的值；评估用 1）
    ///   - declinationDeg: 地图 +y 相对磁北的方位角（只有罗盘开着时有用）
    static func live(hasCorridors: Bool, compass: Bool, stepLengthScale: Double = 1,
                     declinationDeg: Double? = nil) -> FusionConfig {
        var cfg = FusionConfig()
        cfg.useCorridorConstraint = hasCorridors
        cfg.useMagneticHeading = compass
        cfg.stepLengthScale = stepLengthScale
        if let d = declinationDeg { cfg.magneticDeclinationDeg = d }
        return cfg
    }
}

public extension FusionEngine {
    /// 按 App 实时定位页的配置建一个惯导引擎，并设好起点（cm）和航向（弧度，0 = 地图 +y；nil = 由罗盘自行初始化）。
    static func live(corridors: [CrossSegment], start: Point2, headingRad: Double?, compass: Bool,
                     stepLengthScale: Double = 1, declinationDeg: Double? = nil) -> FusionEngine {
        let cfg = FusionConfig.live(hasCorridors: !corridors.isEmpty, compass: compass,
                                    stepLengthScale: stepLengthScale, declinationDeg: declinationDeg)
        let f = FusionEngine(corridors: corridors, config: cfg)
        f.setInitialPosition(start, headingRad: headingRad)
        return f
    }
}
