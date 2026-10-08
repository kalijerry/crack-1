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
    /// 逐片价签的范围约束（见 MagneticLocalizer.applyTagRanges）；false = 老办法（只用加权平均出来的粗位置）
    public var tagRanges = BLEAssist.defaultTagRanges
    /// 评估对比用（hpass-eval --old-ble）
    nonisolated(unsafe) public static var defaultTagRanges = true
    public var tagRangeMinRssi = -90.0
    public var tagRangeMax = 8

    /// 证据一致才算定到：地磁的位置要落在大部分强价签的范围里。连续 disagreeSeconds 秒对不上 → 判定错了重新找，
    /// 之后要重新对得上（≥ agreeFraction）才允许再定。
    public var agreementGate = true
    /// 不在磁场图里：价签显示人所在的那一片（最强几片价签范围的交集附近）基本没有磁场数据 → 不许地磁宣布定到。
    /// （蓝牙底图是全店价签表，「听到的价签不在指纹里」再也判断不了人在没采过的地方；不挡的话地磁会去附近采过的
    /// 地方硬找一个像的点锁上，看起来就是先漂走、走几步再被价签拉回来）
    public var fieldCoverageGate = BLEAssist.defaultCoverageGate
    nonisolated(unsafe) public static var defaultCoverageGate = true
    /// 有价签时没磁场数据的地方的罚分（0 = 不罚）
    nonisolated(unsafe) public static var defaultMissingPenalty: Double? = 0
    public var minFieldCoverage = 0.15
    public private(set) var outsideField = false
    private var outsideFieldStreak = 0, insideFieldStreak = 0

    /// 价签显示的人所在区域里，磁场图有数据的比例
    public func fieldCoverage(_ obs: [String: Double], field: MagneticFieldMap) -> Double? {
        let tags = BLEFingerprintMap.strongest(obs, k: 4, minRssi: -85).compactMap { o in map.tags[o.0].map { (Point2($0.x, $0.y), Self.rangeCm(o.1)) } }
        guard tags.count >= 2 else { return nil }
        // 在最强那片的范围里取点，留下同时落在其余大部分价签范围里的
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
    /// 最近一次：地磁位置落在几成强价签的范围里（强价签不够 3 片时 nil）
    public private(set) var lastAgreement: Double?
    /// 贴近价签：这么强就认为手机就在这片价签旁边（价签广播功率小，正常走路很少超过 −62）
    public static let touchRssi = -55.0

    /// p 落在几成强价签（≥ −85 dBm，最多 6 片）的范围里
    public func agreement(_ obs: [String: Double], at p: Point2) -> Double? {
        let tags = BLEFingerprintMap.strongest(obs, k: 6, minRssi: -85).compactMap { o in map.tags[o.0].map { (Point2($0.x, $0.y), Self.rangeCm(o.1)) } }
        guard tags.count >= 3 else { return nil }
        return Double(tags.filter { p.distance(to: $0.0) <= $0.1 }.count) / Double(tags.count)
    }

    /// 信号（2.5 秒平均，dBm）→ 人离价签所在货架中心最远多少（cm）：实测 P90 + 1 m 余量（平均值比单次读数稳、表里位置是货架中心）
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
    ///   - obs: 最近 2.5 秒每个价签的平均信号
    ///   - current: 地磁当前估计的位置（已收敛时用来交叉检验）
    /// - candidate: 地磁当前的位置（没把握时也给），用来判断「对上了没有」
    public func tick(obs: [String: Double], localizer: MagneticLocalizer, current: Point2?, candidate: Point2? = nil) {
        lastHeard = obs.count
        if tagRanges { localizer.missingDataPenaltyOverride = Self.defaultMissingPenalty }
        if agreementGate, let c = current ?? candidate {
            lastAgreement = agreement(obs, at: c)
            localizer.externalAgreement = lastAgreement
            if let a = lastAgreement {
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
        if fieldCoverageGate, let cov = fieldCoverage(obs, field: localizer.field) {
            if cov < minFieldCoverage { outsideFieldStreak += 1; insideFieldStreak = 0 } else { insideFieldStreak += 1; outsideFieldStreak = 0 }
            if !outsideField && outsideFieldStreak >= 2 {
                outsideField = true
                if localizer.isConverged { localizer.declareLost(); resets += 1 }
            } else if outsideField && insideFieldStreak >= 2 {
                outsideField = false
            }
        }
        // 定到之前先对证据：候选位置不在大部分强价签范围里，就不许宣布定到（不先亮一个错的位置再拉回来）
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
                .compactMap { o in map.tags[o.0].map { (position: Point2($0.x, $0.y), rangeCm: Self.rangeCm(o.1)) } }
            if tags.count >= 2 {
                localizer.applyTagRanges(tags, weight: conv ? 0.5 : 1, injectFraction: conv ? 0 : 0.2)
                return
            }
        }
        localizer.applyPositionPrior(e.position, sigmaCm: max(e.spreadCm, conv ? 500 : 400),
                                     weight: conv ? 0.3 : 1, injectFraction: conv ? 0 : 0.2)
    }
}
