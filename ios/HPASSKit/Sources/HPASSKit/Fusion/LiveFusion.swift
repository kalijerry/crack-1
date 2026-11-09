import Foundation

/// App 实时定位页（MagneticEngine.makeFusion）和离线评估（SessionEvaluator 的 `.pdrIMU`、hpass-replay）共用的
/// 惯导引擎配置：两边改的是同一份代码，评估量到的就是 App 的计步推算。
public extension FusionConfig {
    /// - Parameters:
    ///   - hasCorridors: 场地有通道时惯导位置被限制在通道里（与蓝牙定位页一致）。**惯导输出只当增量送粒子滤波时不要打开**：
    ///     冷启动 / 起步朝向未知时惯导的绝对位置和航向是随便给的，按它投影到通道会把增量剪掉或冻住（粒子滤波自己有墙）
    ///   - compass: 用磁罗盘持续修正航向。App 默认关（页面开关 `useCompassHeading`），只有冷启动且地图设了朝向时开；
    ///     室内磁干扰大，评估也按关来跑
    ///   - stepLengthScale: 步长整体缩放（App 用计步器距离校正后的值；评估用 1）
    ///   - declinationDeg: 地图 +y 相对磁北的方位角（只有罗盘开着时有用）
    ///   - carryMotion: 携带无关的运动模型（携带模式分类、分模式 K / 航向噪声、摆臂 / 口袋步幅平均、自适应计步，
    ///     见 docs/carry-motion.md）。粒子滤波那边要同时打开 `MagneticConfig.carryModeAdaptive` 并把 `onCarryEvent` 接到
    ///     `MagneticLocalizer.apply`
    static func live(hasCorridors: Bool, compass: Bool, stepLengthScale: Double = 1,
                     declinationDeg: Double? = nil, carryMotion: Bool = false) -> FusionConfig {
        var cfg = FusionConfig()
        cfg.useCorridorConstraint = hasCorridors
        cfg.useMagneticHeading = compass
        cfg.stepLengthScale = stepLengthScale
        if let d = declinationDeg { cfg.magneticDeclinationDeg = d }
        cfg.motion.enabled = carryMotion
        return cfg
    }
}

public extension FusionEngine {
    /// 按 App 实时定位页的配置建一个惯导引擎，并设好起点（cm）和航向（弧度，0 = 地图 +y；nil = 由罗盘自行初始化）。
    /// 输出只当增量用（送粒子滤波）时 `corridors` 传空（见 `FusionConfig.live` 的 hasCorridors）。
    static func live(corridors: [CrossSegment], start: Point2, headingRad: Double?, compass: Bool,
                     stepLengthScale: Double = 1, declinationDeg: Double? = nil, carryMotion: Bool = false) -> FusionEngine {
        let cfg = FusionConfig.live(hasCorridors: !corridors.isEmpty, compass: compass,
                                    stepLengthScale: stepLengthScale, declinationDeg: declinationDeg, carryMotion: carryMotion)
        let f = FusionEngine(corridors: corridors, config: cfg)
        f.setInitialPosition(start, headingRad: headingRad)
        return f
    }
}
