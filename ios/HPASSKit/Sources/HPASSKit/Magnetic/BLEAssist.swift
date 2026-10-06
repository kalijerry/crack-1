import Foundation

/// 蓝牙辅助（每秒一次）：手机实时定位和电脑回放评估共用同一套。
///
/// 1. **粗定位**：最近几秒听到的价签 → 粗位置，拉一下地磁粒子（没定到时多撒一些过去）；
/// 2. **不在采集区域**：听到的强价签大多不在指纹里 → 人在没采过的地方，禁止地磁收敛（宁可不显示也不定错）；
/// 3. **交叉检验**：已经定到，但蓝牙粗位置连续好几秒都离得很远 → 判定错了，重新找。
///
/// 实测（建图 / 测试分开）：人在没采过的区域时「自信地定错」的点少 50%～89%，正常区域精度不变。
public final class BLEAssist {
    public let map: BLEFingerprintMap
    public var crossCheckEnabled = true
    public var minKnownFraction = 0.4
    public var crossCheckSeconds = 6
    public var crossCheckCm = 1500.0

    private var unknownStreak = 0
    private var knownStreak = 0
    private var farStreak = 0
    public private(set) var outsideSurveyed = false
    public private(set) var resets = 0
    public private(set) var lastEstimate: (position: Point2, spreadCm: Double)?
    public private(set) var lastHeard = 0

    public init(map: BLEFingerprintMap) { self.map = map }

    /// - Parameters:
    ///   - obs: 最近 2.5 秒每个价签的平均信号
    ///   - current: 地磁当前估计的位置（已收敛时用来交叉检验）
    public func tick(obs: [String: Double], localizer: MagneticLocalizer, current: Point2?) {
        lastHeard = obs.count
        if crossCheckEnabled {
            let strong = BLEFingerprintMap.strongest(obs, k: 8, minRssi: -85)
            if strong.count >= 4 {
                let known = Double(strong.filter { map.tags[$0.0] != nil }.count) / Double(strong.count)
                if known < minKnownFraction { unknownStreak += 1; knownStreak = 0 } else { knownStreak += 1; unknownStreak = 0 }
                if !outsideSurveyed && unknownStreak >= 3 {
                    outsideSurveyed = true
                    if localizer.isConverged { localizer.declareLost(); resets += 1 }
                } else if outsideSurveyed && knownStreak >= 3 {
                    outsideSurveyed = false
                }
                localizer.convergenceBlocked = outsideSurveyed
            }
        }
        guard let e = map.estimateByTags(obs) else { lastEstimate = nil; return }
        lastEstimate = e
        if crossCheckEnabled, localizer.isConverged, let cur = current {
            if cur.distance(to: e.position) > max(crossCheckCm, 3 * e.spreadCm) { farStreak += 1 } else { farStreak = 0 }
            if farStreak >= crossCheckSeconds {
                localizer.declareLost()
                farStreak = 0
                resets += 1
            }
        }
        let conv = localizer.isConverged
        localizer.applyPositionPrior(e.position, sigmaCm: max(e.spreadCm, conv ? 500 : 400),
                                     weight: conv ? 0.3 : 1, injectFraction: conv ? 0 : 0.2)
    }
}
