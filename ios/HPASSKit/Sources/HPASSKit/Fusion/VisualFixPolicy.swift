import Foundation

/// 终端用户定位里摄像头的角色：只是可选增强，不接管定位。
///
/// - 默认不开摄像头（设置里「视觉增强」默认关），任何携带方式（口袋、摆臂、看屏、打电话、包里）都只靠计步 + 地磁 + 地图；
/// - 开了「视觉增强」，也只在手机竖持 / 斜着看屏、ARKit 跟踪正常时，把一次视觉重定位当成 σ≈50 cm 的位置观测交给粒子滤波；
///   计步永远在推粒子，视觉不再「认出房间就直接用视觉位置、地磁不参与」；
/// - ARKit 会话本身也按姿态启停：放进口袋 / 垂手摆臂时摄像头关掉（省电、不发热，口袋里也认不出房间）。
///
/// 姿态目前来自 HoldClassifier（upright / reading 当「竖持 / 看屏」）；携带模式分类器接管后换成 CarryMode。
public enum VisualFixPolicy {
    /// 视觉重定位当位置观测的标准差（cm）
    public static let sigmaCm = 50.0
    /// 没收敛（还在找）时，视觉观测附近注入的粒子比例
    public static let searchInjectFraction = 0.2
    /// 姿态满足条件持续这么久才打开 ARKit（秒）
    public static let startAfterSec = 3.0
    /// 姿态不满足（或跟踪一直不正常）持续这么久就关掉 ARKit（秒）
    public static let stopAfterSec = 6.0

    /// 摄像头能看到前方的持握姿态
    public static func postureAllowsCamera(_ p: HoldPosture) -> Bool {
        p == .upright || p == .reading
    }

    /// 这一次视觉重定位能不能当观测用。
    public static func acceptsFix(enhancementEnabled: Bool, posture: HoldPosture, arTrackingNormal: Bool) -> Bool {
        enhancementEnabled && arTrackingNormal && postureAllowsCamera(posture)
    }

    /// ARKit 会话该不该开着（带滞回：调用方按 `startAfterSec` / `stopAfterSec` 计时）。
    public static func wantsARSession(enhancementEnabled: Bool, posture: HoldPosture) -> Bool {
        enhancementEnabled && postureAllowsCamera(posture)
    }
}
