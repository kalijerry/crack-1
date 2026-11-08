import Foundation

/// 垂直移动方式。
public enum VerticalMode: String, Codable {
    case elevator      // 电梯：垂直速度快（≥ 0.6 m/s），几乎没有步
    case escalator     // 扶梯 / 坡道站立：垂直速度慢，几乎没有步
    case stairs        // 楼梯（或在扶梯上走）：有持续步频
}

/// 一次完成的楼层切换。
public struct FloorChange: Equatable {
    public let startMs: Int64
    public let endMs: Int64
    /// 楼层差，上楼为正。
    public let deltaFloors: Int
    /// 气压换算的高度差（m），上为正。
    public let deltaMeters: Double
    public let mode: VerticalMode
    /// 移动段内的最大垂直速度（m/s，绝对值，按 `speedWindowS` 窗口算）。
    public let peakSpeed: Double
    /// 垂直速度超过阈值那段时间内的步频（步/秒）。
    public let stepRate: Double
}

/// 气压计楼层检测：只看**相对**高度变化，不依赖绝对气压（天气一小时能变 1 hPa ≈ 8 m）。
///
/// 做法：
/// 1. 气压（或 CMAltimeter 的相对高度）→ 高度，指数低通；
/// 2. 用最近 `speedWindowS` 秒的高度差算垂直速度，|速度| 持续超过 `movingSpeed` 一段时间 → 进入「垂直移动中」；
/// 3. 速度回落并稳定 `settleS` 秒 → 移动段结束，高度差按层高量化成楼层差（不足一层但超过 `minChangeM` 记 ±1）；
/// 4. 按平均垂直速度和段内步频分类电梯 / 扶梯 / 楼梯。分类结果可以把粒子吸附到对应类型的连接体上。
///
/// 每个移动段单独算高度差，所以静止时的天气漂移不会累积成楼层变化。
/// 不是线程安全的，和其他传感器回调放在同一个串行队列上调用。
public final class FloorDetector {
    public struct Config {
        /// 典型层高（m）。商场 4.5～6，写字楼 3.5～4，车库 3～3.5。
        public var floorHeightM: Double = 4.5
        /// 小于它的高度差不算换层（夹层、坡道起伏、开门造成的气压跳动）。
        public var minChangeM: Double = 2.5
        /// 低通时间常数（s）。
        public var smoothingTauS: Double = 1.0
        /// 算垂直速度用的窗口（s）。
        public var speedWindowS: Double = 3.0
        /// 超过它算「在上下」（m/s）。楼梯约 0.15～0.3，扶梯约 0.2～0.3，电梯 ≥ 1。
        public var movingSpeed: Double = 0.1
        /// 超过阈值要持续多久才算开始（s）。
        public var startHoldS: Double = 1.5
        /// 回落后要稳定多久才算结束（s）。
        public var settleS: Double = 3.0
        /// 最大垂直速度超过它且没有步 → 电梯。
        public var elevatorSpeed: Double = 0.6
        /// 步频超过它 → 楼梯（步/秒）。
        public var stairsStepRate: Double = 0.8
        public init() {}
    }

    public let config: Config
    /// 当前楼层（相对起始楼层，或调用方设定的绝对楼层）。
    public private(set) var floor: Int
    /// 当前低通后的相对高度（m）。
    public private(set) var altitudeM: Double = 0
    /// 是否正在上下楼。
    public private(set) var isMovingVertically = false
    /// 历次切换，按时间顺序。
    public private(set) var changes: [FloorChange] = []

    private var referenceHPa: Double?
    private var lastMs: Int64?
    private var hasAltitude = false
    private var history: [(t: Int64, h: Double)] = []
    private var aboveSinceMs: Int64?
    private var belowSinceMs: Int64?
    private var segStartMs: Int64 = 0
    private var segStartAlt: Double = 0
    private var stepTimes: [Int64] = []
    private var coreStartMs: Int64 = 0
    private var coreEndMs: Int64 = 0
    private var peakSpeed: Double = 0

    public init(startFloor: Int = 0, config: Config = Config()) {
        self.floor = startFloor
        self.config = config
    }

    /// 用户或其他来源（Wi-Fi、地图、视觉）确认了楼层：直接改，不影响正在进行的检测。
    public func setFloor(_ f: Int) { floor = f }

    /// 气压读数（hPa）。第一条读数作为参考，之后换算成相对高度（国际标准大气公式）。
    @discardableResult
    public func addPressure(tMs: Int64, hPa: Double) -> FloorChange? {
        guard hPa > 100, hPa < 1200 else { return nil }
        if referenceHPa == nil { referenceHPa = hPa }
        let h = 44330.0 * (1 - pow(hPa / referenceHPa!, 1 / 5.255))
        return addRelativeAltitude(tMs: tMs, meters: h)
    }

    /// 相对高度（m，向上为正），例如 CMAltimeter 的 relativeAltitude。
    @discardableResult
    public func addRelativeAltitude(tMs: Int64, meters: Double) -> FloorChange? {
        guard meters.isFinite else { return nil }
        if let last = lastMs, tMs <= last { return nil }
        if hasAltitude, let last = lastMs {
            let dt = Double(tMs - last) / 1000
            let a = 1 - exp(-dt / max(config.smoothingTauS, 1e-3))
            altitudeM += a * (meters - altitudeM)
        } else {
            altitudeM = meters
            hasAltitude = true
        }
        lastMs = tMs

        history.append((t: tMs, h: altitudeM))
        let keepFrom = tMs - Int64(config.speedWindowS * 1000)
        while history.count > 2, history[1].t <= keepFrom { history.removeFirst() }
        let speed = verticalSpeed()

        if !isMovingVertically {
            if abs(speed) > config.movingSpeed {
                if aboveSinceMs == nil {
                    aboveSinceMs = tMs
                    // 移动段从「超过阈值的窗口起点」算，起点高度取窗口最早的值，不漏掉开头那一段
                    segStartMs = history.first?.t ?? tMs
                    segStartAlt = history.first?.h ?? altitudeM
                }
                peakSpeed = max(peakSpeed, abs(speed))
                if tMs - aboveSinceMs! >= Int64(config.startHoldS * 1000) {
                    isMovingVertically = true
                    belowSinceMs = nil
                    coreStartMs = aboveSinceMs!
                    coreEndMs = tMs
                }
            } else {
                aboveSinceMs = nil
                peakSpeed = 0
            }
            pruneSteps(before: tMs - 30_000)
            return nil
        }

        peakSpeed = max(peakSpeed, abs(speed))
        if abs(speed) > config.movingSpeed { coreEndMs = tMs }
        if abs(speed) < config.movingSpeed / 2 {
            if belowSinceMs == nil { belowSinceMs = tMs }
            if tMs - belowSinceMs! >= Int64(config.settleS * 1000) {
                return finishSegment(endMs: tMs)
            }
        } else {
            belowSinceMs = nil
        }
        return nil
    }

    /// 计步器的每一步（用于区分楼梯和电梯 / 扶梯）。
    public func addStep(tMs: Int64) {
        stepTimes.append(tMs)
    }

    private func verticalSpeed() -> Double {
        guard let first = history.first, let last = history.last, last.t > first.t else { return 0 }
        return (last.h - first.h) / (Double(last.t - first.t) / 1000)
    }

    private func pruneSteps(before t: Int64) {
        if let i = stepTimes.firstIndex(where: { $0 >= t }) {
            if i > 0 { stepTimes.removeFirst(i) }
        } else {
            stepTimes.removeAll()
        }
    }

    private func finishSegment(endMs: Int64) -> FloorChange? {
        isMovingVertically = false
        aboveSinceMs = nil
        belowSinceMs = nil
        let peak = peakSpeed
        peakSpeed = 0
        let delta = altitudeM - segStartAlt
        // 步频只在「垂直速度超过阈值」的那段时间里算，不把走进 / 走出电梯的几步算进去
        let coreDur = max(Double(coreEndMs - coreStartMs) / 1000, 1)
        let steps = stepTimes.filter { $0 >= coreStartMs && $0 <= coreEndMs }.count
        pruneSteps(before: endMs)
        guard abs(delta) >= config.minChangeM else { return nil }

        var floors = Int((delta / config.floorHeightM).rounded())
        if floors == 0 { floors = delta > 0 ? 1 : -1 }
        let rate = Double(steps) / coreDur
        let mode: VerticalMode
        if rate >= config.stairsStepRate {
            mode = .stairs
        } else if peak >= config.elevatorSpeed {
            mode = .elevator
        } else {
            mode = .escalator
        }
        let change = FloorChange(startMs: segStartMs, endMs: endMs, deltaFloors: floors,
                                 deltaMeters: delta, mode: mode, peakSpeed: peak, stepRate: rate)
        floor += floors
        changes.append(change)
        return change
    }
}
