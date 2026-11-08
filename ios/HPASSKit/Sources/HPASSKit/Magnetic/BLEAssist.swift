import Foundation

/// 蓝牙辅助（每秒一次）：手机实时定位和电脑回放评估共用同一套。
///
/// 1. **粗定位**：最近几秒听到的标签 → 粗位置，拉一下地磁粒子（没定到时多撒一些过去）；
/// 2. **不在采集区域**：听到的强标签大多不在指纹里 → 人在没采过的地方，禁止地磁收敛（宁可不显示也不定错）；
/// 3. **交叉检验**：已经定到，但蓝牙粗位置连续好几秒都离得很远 → 判定错了，重新找。
///
/// 实测（建图 / 测试分开）：人在没采过的区域时「自信地定错」的点少 50%～89%，正常区域精度不变。
public final class BLEAssist {
    public let map: BLEFingerprintMap
    public var crossCheckEnabled = true
    public var minKnownFraction = 0.4
    public var crossCheckSeconds = 6
    public var crossCheckCm = 1500.0
    /// 逐片标签的范围约束（见 MagneticLocalizer.applyTagRanges）；false = 老办法（只用加权平均出来的粗位置）
    public var tagRanges = BLEAssist.defaultTagRanges
    /// 评估对比用（hpass-eval --old-ble）
    nonisolated(unsafe) public static var defaultTagRanges = true
    public var tagRangeMinRssi = -90.0
    public var tagRangeMax = 8

    /// 证据一致才算定到：地磁的位置要落在大部分强标签的范围里。连续 disagreeSeconds 秒对不上 → 判定错了重新找，
    /// 之后要重新对得上（≥ agreeFraction）才允许再定。
    public var agreementGate = true
    /// 不在磁场图里：标签显示人所在的那一片（最强几片标签范围的交集附近）基本没有磁场数据 → 不许地磁宣布定到。
    /// （蓝牙底图是全场标签表，「听到的标签不在指纹里」再也判断不了人在没采过的地方；不挡的话地磁会去附近采过的
    /// 地方硬找一个像的点锁上，看起来就是先漂走、走几步再被标签拉回来）
    public var fieldCoverageGate = BLEAssist.defaultCoverageGate
    nonisolated(unsafe) public static var defaultCoverageGate = true
    /// 有标签时没磁场数据的地方的罚分（0 = 不罚）
    nonisolated(unsafe) public static var defaultMissingPenalty: Double? = 0
    public var minFieldCoverage = 0.15
    public private(set) var outsideField = false
    private var outsideFieldStreak = 0, insideFieldStreak = 0

    /// 标签显示的人所在区域里，磁场图有数据的比例
    public func fieldCoverage(_ obs: [String: Double], field: MagneticFieldMap, learned: Bool = false) -> Double? {
        let tags = BLEFingerprintMap.strongest(obs, k: 4, minRssi: -85).compactMap { o in map.tags[o.0].map { (Point2($0.x, $0.y), self.rangeCm(o.1, learned: learned)) } }
        guard tags.count >= 2 else { return nil }
        // 在最强那片的范围里取点，留下同时落在其余大部分标签范围里的
        let (c0, r0) = tags.min { $0.1 < $1.1 }!
        var inside = 0, covered = 0
        for gx in stride(from: -r0, through: r0, by: 100) {
            for gy in stride(from: -r0, through: r0, by: 100) where gx * gx + gy * gy <= r0 * r0 {
                let p = Point2(c0.x + gx, c0.y + gy)
                let ok = tags.filter { p.distance(to: $0.0) <= $0.1 }.count
                guard Double(ok) >= Double(tags.count) * 0.6 else { continue }
                inside += 1
                if field.sample(at: p) != nil { covered += 1 }
            }
        }
        return inside >= 5 ? Double(covered) / Double(inside) : nil
    }

    /// 宣布定到之前就要对上（false = 只在定到之后检查，老办法）
    public var preConvergenceGate = BLEAssist.defaultPreGate
    nonisolated(unsafe) public static var defaultPreGate = true
    public var agreeFraction = 0.5
    public var disagreeSeconds = 3
    private var disagreeStreak = 0
    private var blockedByDisagree = false
    /// 最近一次：地磁位置落在几成强标签的范围里（强标签不够 3 片时 nil）
    public private(set) var lastAgreement: Double?
    /// 贴近标签：这么强就认为手机就在这片标签旁边（标签广播功率小，正常走路很少超过 −62）
    public static let touchRssi = -55.0

    /// p 落在几成强标签（≥ −85 dBm，最多 6 片）的范围里。learned：用学到的范围（只有跟踪软约束用），否则固定表
    public func agreement(_ obs: [String: Double], at p: Point2, learned: Bool = false) -> Double? {
        let tags = BLEFingerprintMap.strongest(obs, k: 6, minRssi: -85).compactMap { o in map.tags[o.0].map { (Point2($0.x, $0.y), self.rangeCm(o.1, learned: learned)) } }
        guard tags.count >= 3 else { return nil }
        return Double(tags.filter { p.distance(to: $0.0) <= $0.1 }.count) / Double(tags.count)
    }

    /// 标签范围。learned = true 且底图学过本场地的范围（BLEFingerprintMap.learnedRanges）时用学到的，否则用固定表 `rangeCm(_:)`。
    /// 学到的范围只会比固定表大（固定表是按货架标签量的，已经是最紧的；场地标签离人更远、学到的标签位置也有偏差）。
    /// 只有已知起点跟踪的软约束（`softTrackingTick`）传 true；冷启动 / 硬约束（覆盖门、对证门、挡收敛、标签范围约束）
    /// 一律用固定表，行为和没学范围之前一样。
    public func rangeCm(_ rssi: Double, learned: Bool) -> Double {
        let fixed = Self.rangeCm(rssi)
        guard learned, useLearnedRanges, let r = map.learnedRangeCm(rssi) else { return fixed }
        return max(r, fixed)
    }
    /// 用底图里学到的范围（false = 一律用固定表，跟踪也走硬约束；评估对比用）
    public var useLearnedRanges = BLEAssist.defaultLearnedRanges
    nonisolated(unsafe) public static var defaultLearnedRanges = true
    /// 这张底图能不能走跟踪软约束：学过本场地的标签范围才行。人工打点的标签位置表合成的底图（TagLocations.seededBLEMap）
    /// 没有学到的范围，只剩宽位置先验那一种软约束，公开数据上量过不稳（P90 5.8～6.4 m），这种底图跟踪时照旧用硬约束。
    public var supportsSoftTracking: Bool { useLearnedRanges && map.learnedRanges?.isEmpty == false }

    /// 跟踪软约束下，局部找回之后蓝牙还没重新对上（≥ agreeFraction + 0.1）就又持续对不上、次数到了这个数：
    /// 不再围着被否定的位置找，升级成原有的硬约束（全图找、挡收敛，直到重新定到而且蓝牙对上）。
    /// 局部找回的中心是最后一次可靠位置，也就是蓝牙刚否定的位置；起点给错 / 锁错了地方时只靠局部找回会一直往回拉。
    public var softEscalateAfter = 1
    private var softLocalRecoveries = 0
    /// 软约束升级成了硬约束（见 softEscalateAfter）
    public private(set) var softEscalated = false

    /// 信号（2.5 秒平均，dBm）→ 人离标签所在货架中心最远多少（cm）：实测 P90 + 1 m 余量（平均值比单次读数稳、表里位置是货架中心）
    public static func rangeCm(_ rssi: Double) -> Double {
        switch rssi {
        case (-75)...: return 350
        case (-80)...: return 420
        case (-85)...: return 600
        case (-90)...: return 900
        default: return 1500
        }
    }

    private var unknownStreak = 0
    private var knownStreak = 0
    private var farStreak = 0
    public private(set) var outsideSurveyed = false
    public private(set) var resets = 0
    public private(set) var lastEstimate: (position: Point2, spreadCm: Double)?
    public private(set) var lastHeard = 0

    public init(map: BLEFingerprintMap) { self.map = map }

    /// - Parameters:
    ///   - obs: 最近 2.5 秒每个标签的平均信号
    ///   - current: 地磁当前估计的位置（已收敛时用来交叉检验）
    /// - candidate: 地磁当前的位置（没把握时也给），用来判断「对上了没有」
    public func tick(obs: [String: Double], localizer: MagneticLocalizer, current: Point2?, candidate: Point2? = nil) {
        let soft = localizer.config.bleSoftTracking && localizer.startedFromPrior && supportsSoftTracking
        if soft && !softEscalated {
            softTrackingTick(obs: obs, localizer: localizer, current: current, candidate: candidate)
            return
        }
        lastHeard = obs.count
        if tagRanges { localizer.missingDataPenaltyOverride = Self.defaultMissingPenalty }
        if agreementGate, let c = current ?? candidate {
            lastAgreement = agreement(obs, at: c)
            localizer.externalAgreement = lastAgreement
            if let a = lastAgreement {
                // 升级成硬约束之后：重新定到、蓝牙也对上了，回到软约束
                if softEscalated && localizer.isConverged && a >= agreeFraction + 0.1 { softEscalated = false; softLocalRecoveries = 0 }
                if localizer.isConverged && a < agreeFraction {
                    disagreeStreak += 1
                    if disagreeStreak >= disagreeSeconds {
                        localizer.declareLost(); resets += 1; disagreeStreak = 0; blockedByDisagree = true
                    }
                } else { disagreeStreak = 0 }
                if blockedByDisagree && a >= agreeFraction + 0.1 { blockedByDisagree = false }
            }
        } else { lastAgreement = nil }
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
            }
        }
        if fieldCoverageGate, let cov = fieldCoverage(obs, field: localizer.field, learned: false) {
            if cov < minFieldCoverage { outsideFieldStreak += 1; insideFieldStreak = 0 } else { insideFieldStreak += 1; outsideFieldStreak = 0 }
            if !outsideField && outsideFieldStreak >= 2 {
                outsideField = true
                if localizer.isConverged { localizer.declareLost(); resets += 1 }
            } else if outsideField && insideFieldStreak >= 2 {
                outsideField = false
            }
        }
        // 定到之前先对证据：候选位置不在大部分强标签范围里，就不许宣布定到（不先亮一个错的位置再拉回来）
        let preBlocked = agreementGate && preConvergenceGate && !localizer.isConverged && (lastAgreement.map { $0 < agreeFraction } ?? false)
        localizer.convergenceBlocked = outsideSurveyed || outsideField || blockedByDisagree || preBlocked
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
        if tagRanges {
            let tags = BLEFingerprintMap.strongest(obs, k: tagRangeMax, minRssi: tagRangeMinRssi)
                .compactMap { o in map.tags[o.0].map { (position: Point2($0.x, $0.y), rangeCm: self.rangeCm(o.1, learned: false)) } }
            if tags.count >= 2 {
                localizer.applyTagRanges(tags, weight: conv ? 0.5 : 1, injectFraction: conv ? 0 : 0.2)
                return
            }
        }
        localizer.applyPositionPrior(e.position, sigmaCm: max(e.spreadCm, conv ? 500 : 400),
                                     weight: conv ? 0.3 : 1, injectFraction: conv ? 0 : 0.2)
    }

    /// 已知起点的跟踪（跟踪配置档 bleSoftTracking，底图学过本场地的标签范围）：蓝牙只做软约束，范围用学到的。
    /// - 不挡收敛、不因为「不在采集区域 / 标签范围里没有磁场数据」判丢（跟踪档自己按覆盖给地磁打折）；
    /// - 当前位置连续 disagreeSeconds 秒落不进大部分强标签的范围，或连续 crossCheckSeconds 秒离蓝牙粗位置很远：
    ///   先只触发局部找回（declareLost(local: true)），不全图找；找回之后蓝牙还没对上就又对不上（softEscalateAfter），
    ///   升级成硬约束（全图找、挡收敛）；
    /// - 底图学过本场地的标签范围（learnedRanges）：每片强标签一个有上限的软范围约束
    ///   （超出学到的 P90 范围才罚，σ bleSoftRangeSigmaCm、每片每秒最多罚 bleSoftRangeCapLog、权重 bleSoftRangeWeight）；
    /// - 没学过（固定表 / 标签位置表）：每秒一个宽的位置先验（σ ≥ bleSoftPriorSigmaCm、低权重），不用逐片标签的硬范围约束。
    private func softTrackingTick(obs: [String: Double], localizer: MagneticLocalizer, current: Point2?, candidate: Point2?) {
        lastHeard = obs.count
        localizer.convergenceBlocked = false
        if tagRanges { localizer.missingDataPenaltyOverride = Self.defaultMissingPenalty }
        outsideSurveyed = false; outsideField = false; blockedByDisagree = false
        var lose = false
        if agreementGate, let c = current ?? candidate {
            lastAgreement = agreement(obs, at: c, learned: true)
            localizer.externalAgreement = lastAgreement
            if let a = lastAgreement, a >= agreeFraction + 0.1 { softLocalRecoveries = 0 }
            if let a = lastAgreement, localizer.isConverged, a < agreeFraction {
                disagreeStreak += 1
                if disagreeStreak >= disagreeSeconds { lose = true }
            } else { disagreeStreak = 0 }
        } else { lastAgreement = nil }
        let e = map.estimateByTags(obs)
        lastEstimate = e
        if crossCheckEnabled, localizer.isConverged, let cur = current, let e {
            if cur.distance(to: e.position) > max(crossCheckCm, 3 * e.spreadCm) { farStreak += 1 } else { farStreak = 0 }
            if farStreak >= crossCheckSeconds { lose = true }
        }
        if lose && localizer.isConverged && localizer.config.bleSoftLocalRecovery {
            if softLocalRecoveries >= softEscalateAfter {
                // 局部找回过了、蓝牙还是不认：不再围着被否定的位置找
                localizer.declareLost()
                blockedByDisagree = true
                localizer.convergenceBlocked = true
                softEscalated = true
                softLocalRecoveries = 0
            } else {
                localizer.declareLost(local: true)
                softLocalRecoveries += 1
            }
            resets += 1; disagreeStreak = 0; farStreak = 0
        }
        let cfg = localizer.config
        if useLearnedRanges, map.learnedRanges?.isEmpty == false, cfg.bleSoftRangeWeight > 0 {
            let tags = BLEFingerprintMap.strongest(obs, k: tagRangeMax, minRssi: tagRangeMinRssi)
                .compactMap { o in map.tags[o.0].map { (position: Point2($0.x, $0.y), rangeCm: self.rangeCm(o.1, learned: true)) } }
            if tags.count >= 2 {
                localizer.applyTagRanges(tags, sigmaCm: cfg.bleSoftRangeSigmaCm, capLog: cfg.bleSoftRangeCapLog,
                                         weight: cfg.bleSoftRangeWeight)
            }
            return
        }
        guard let e else { return }
        localizer.applyPositionPrior(e.position, sigmaCm: max(e.spreadCm, cfg.bleSoftPriorSigmaCm), weight: cfg.bleSoftPriorWeight)
    }
}
