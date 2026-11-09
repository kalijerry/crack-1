import Foundation

/// 静止冻结的判定（办公室：坐在工位上、站着开会）：静止连续够久且在房间里 → 冻结；之后一旦不静止 → 解冻。
///
/// 「静止」由调用方给（计步器 / 姿态里的静止判定，例如加速度模长贴近 g、陀螺很小）。这里只管计时和滞回，
/// 冻结 / 解冻本身见 `MagneticLocalizer.freezeStationary` / `releaseStationaryFreeze`（受 `MagneticConfig.stationaryFreeze` 开关）。
///
/// 时长门限是占位参数（待自采 iPhone 双机数据标定），可配置。
public struct StationaryFreezeDetector {
    public enum Event: Equatable {
        case freeze
        case release
    }

    /// 静止持续多久（秒）才冻结。占位值（待自采 iPhone 双机数据标定）
    public var freezeAfterS: Double = 20
    /// 不静止持续多久（秒）才解冻：一下抖动（伸手拿杯子）不算起身。占位值（待自采 iPhone 双机数据标定）
    public var releaseAfterS: Double = 0.5

    public private(set) var frozen = false
    private var stillSinceMs: Int64?
    private var movingSinceMs: Int64?

    public init(freezeAfterS: Double = 20, releaseAfterS: Double = 0.5) {
        self.freezeAfterS = freezeAfterS
        self.releaseAfterS = releaseAfterS
    }

    /// 送一个时刻的静止判定。inRoom = 当前估计在房间里（不在房间里、在走廊 / 门口站着不冻结）。
    /// 返回这一刻要做的事（没有就 nil）。
    public mutating func update(tMs: Int64, still: Bool, inRoom: @autoclosure () -> Bool = true) -> Event? {
        if still {
            movingSinceMs = nil
            if stillSinceMs == nil { stillSinceMs = tMs }
            if !frozen, let s = stillSinceMs, Double(tMs - s) / 1000 >= freezeAfterS, inRoom() {
                frozen = true
                return .freeze
            }
            return nil
        }
        stillSinceMs = nil
        guard frozen else { return nil }
        if movingSinceMs == nil { movingSinceMs = tMs }
        if let m = movingSinceMs, Double(tMs - m) / 1000 >= releaseAfterS {
            frozen = false
            movingSinceMs = nil
            return .release
        }
        return nil
    }

    public mutating func reset() {
        frozen = false
        stillSinceMs = nil
        movingSinceMs = nil
    }
}

extension MagneticLocalizer {
    /// 把静止判定接到定位上：判定器说冻结就 `freezeStationary`（没冻成——没收敛 / 不在房间 / 开关没开——判定器也退回未冻结），
    /// 说解冻就 `releaseStationaryFreeze`。返回这一刻实际发生的事。
    @discardableResult
    public func feedStationary(_ det: inout StationaryFreezeDetector, tMs: Int64, still: Bool) -> StationaryFreezeDetector.Event? {
        // 房间判断只在到了冻结时长时才做（估计要遍历粒子，静止判定是逐帧送的）
        func inRoom() -> Bool {
            guard let g = walkable?.rooms else { return true }
            return g.roomIndex(at: estimate().position) != nil
        }
        switch det.update(tMs: tMs, still: still, inRoom: inRoom()) {
        case .freeze?:
            if freezeStationary() { return .freeze }
            det.reset()
            return nil
        case .release?:
            releaseStationaryFreeze()
            return .release
        case nil:
            return nil
        }
    }
}
