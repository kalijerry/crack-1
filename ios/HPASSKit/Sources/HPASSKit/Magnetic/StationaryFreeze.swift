import Foundation

/// 静止冻结的判定（办公室：坐在工位上、站着开会）：静止连续够久且在房间里 → 冻结；之后**真的在走**才解冻。
///
/// 「静止」由调用方给（计步器 / 姿态里的静止判定，例如惯导引擎的 `isMoving`）。解冻看的是步子，不是「不静止」：
/// 坐着时口袋里的伪步正是挪动椅子、换坐姿、伸手拿东西这些「不静止」带出来的，按「不静止 0.5 s 就解冻」会在最该冻住的时候解冻。
/// 现在要连续检出 `releaseSteps` 步、相邻间隔像走路（`stepMinIntervalS`～`stepMaxIntervalS`）才解冻，
/// 并告诉定位这串步从哪一刻开始（`releaseWalkStartMs`），定位把冻结期间那之后的位移补推一次，起身后的头几步不丢。
/// 调用方没有步数时退回「不静止持续 `releaseAfterS`」。
///
/// 冻结 / 解冻本身见 `MagneticLocalizer.freezeStationary` / `releaseStationaryFreeze`（受 `MagneticConfig.stationaryFreeze` 开关）。
/// 全部门限是占位参数（待自采 iPhone 双机数据标定），可配置。
public struct StationaryFreezeDetector {
    public enum Event: Equatable {
        case freeze
        case release
    }

    /// 静止持续多久（秒）才冻结。占位值（待自采 iPhone 双机数据标定）
    public var freezeAfterS: Double = 20
    /// 连续这么多步（间隔像走路）才算起身走了。占位值（待自采 iPhone 双机数据标定）
    public var releaseSteps = 3
    public var stepMinIntervalS = 0.3
    public var stepMaxIntervalS = 1.2
    /// 没有步数时：不静止持续多久（秒）才解冻。占位值（待自采 iPhone 双机数据标定）
    public var releaseAfterS: Double = 4

    public private(set) var frozen = false
    /// 最近一次解冻对应的那串步的第一步时刻（按步数解冻时才有）：定位从这一刻起补推冻结期间的位移
    public private(set) var releaseWalkStartMs: Int64?
    private var stillSinceMs: Int64?
    private var movingSinceMs: Int64?
    private var lastStepCount: Int?
    private var lastStepMs: Int64?
    private var streak = 0
    private var streakStartMs: Int64?

    public init(freezeAfterS: Double = 20, releaseSteps: Int = 3, releaseAfterS: Double = 4) {
        self.freezeAfterS = freezeAfterS
        self.releaseSteps = releaseSteps
        self.releaseAfterS = releaseAfterS
    }

    /// 送一个时刻的静止判定。`stepCount`：惯导引擎的累计步数（没有就 nil，退回按时长解冻）。
    /// inRoom = 当前估计在房间里（不在房间里、在走廊 / 门口站着不冻结）。返回这一刻要做的事（没有就 nil）。
    public mutating func update(tMs: Int64, still: Bool, stepCount: Int? = nil,
                                inRoom: @autoclosure () -> Bool = true) -> Event? {
        // 步子：间隔像走路就接上，否则从这一步重新数
        if let n = stepCount {
            if let l = lastStepCount, n > l {
                if streak > 0, let ls = lastStepMs, Double(tMs - ls) / 1000 >= stepMinIntervalS / Double(n - l),
                   Double(tMs - ls) / 1000 <= stepMaxIntervalS {
                    streak += n - l
                } else {
                    streak = n - l
                    streakStartMs = tMs
                }
                lastStepMs = tMs
            } else if let ls = lastStepMs, Double(tMs - ls) / 1000 > stepMaxIntervalS {
                streak = 0
                streakStartMs = nil
            }
            lastStepCount = n
        }
        if still {
            movingSinceMs = nil
            if stillSinceMs == nil { stillSinceMs = tMs }
            if !frozen, let s = stillSinceMs, Double(tMs - s) / 1000 >= freezeAfterS, inRoom() {
                frozen = true
                streak = 0
                streakStartMs = nil
                return .freeze
            }
            return nil
        }
        stillSinceMs = nil
        guard frozen else { return nil }
        if stepCount != nil {
            if streak >= releaseSteps {
                frozen = false
                releaseWalkStartMs = streakStartMs
                movingSinceMs = nil
                return .release
            }
            return nil
        }
        if movingSinceMs == nil { movingSinceMs = tMs }
        if let m = movingSinceMs, Double(tMs - m) / 1000 >= releaseAfterS {
            frozen = false
            movingSinceMs = nil
            releaseWalkStartMs = nil
            return .release
        }
        return nil
    }

    public mutating func reset() {
        frozen = false
        stillSinceMs = nil
        movingSinceMs = nil
        lastStepCount = nil
        lastStepMs = nil
        streak = 0
        streakStartMs = nil
        releaseWalkStartMs = nil
    }
}

extension MagneticLocalizer {
    /// 把静止判定接到定位上：判定器说冻结就 `freezeStationary`（没冻成——没收敛 / 房间不确定 / 开关没开——判定器也退回未冻结），
    /// 说解冻就 `releaseStationaryFreeze`（按步数解冻时补推那串步的位移）。要在同一时刻的 `step` **之前**调，
    /// 冻结期间的位移才能按时刻缓冲。返回这一刻实际发生的事。
    @discardableResult
    public func feedStationary(_ det: inout StationaryFreezeDetector, tMs: Int64, still: Bool,
                               stepCount: Int? = nil) -> StationaryFreezeDetector.Event? {
        noteStationaryTime(tMs)
        // 房间判断只在到了冻结时长时才做（要遍历粒子，静止判定是逐帧送的）
        func inRoom() -> Bool {
            guard let g = walkable?.rooms else { return true }
            return (roomMasses(in: g).max() ?? 0) > 0
        }
        switch det.update(tMs: tMs, still: still, stepCount: stepCount, inRoom: inRoom()) {
        case .freeze?:
            if freezeStationary() { return .freeze }
            det.reset()
            return nil
        case .release?:
            releaseStationaryFreeze(replaySinceMs: det.releaseWalkStartMs)
            return .release
        case nil:
            return nil
        }
    }
}
