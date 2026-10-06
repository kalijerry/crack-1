import Foundation

/// 判断「此刻的磁场读数还能不能信」，输出 0...1 的可信度。
///
/// 三个来源：
/// 1. iOS 给的磁场精度（−1 未校准、0 低、1 中、2 高）；
/// 2. 原始磁力计与校准后磁场之差 = 系统当前估计的硬磁偏置。它在 1 秒内突然变了，说明系统重新校准了，
///    之后几秒的读数和地图（校准前录的）对不上；
/// 3. 总强度明显不合理。
///
/// 非线程安全，与其他 HPASSKit 对象一样要在同一串行队列上使用。
public final class MagneticTrustMonitor {
    public struct Config {
        /// 偏置在 `windowMs` 内变化超过这个值（µT）算一次重新校准。
        public var jumpUT: Double = 2.0
        /// 重新校准之后完全不信任的时长，之后线性恢复。
        public var cooldownMs: Int64 = 3000
        public var rampMs: Int64 = 1500
        public var minNormUT: Double = 10
        public var maxNormUT: Double = 150
        /// 用于比较偏置的两个窗口长度；两个窗口之间隔 `gapMs`。
        public var windowMs: Int64 = 500
        public var gapMs: Int64 = 500
        public init() {}
    }

    public var config: Config
    public private(set) var jumpCount = 0
    public private(set) var lastJumpMs: Int64?

    private var history: [(t: Int64, b: (Double, Double, Double))] = []

    public init(config: Config = .init()) { self.config = config }

    public func reset() {
        history.removeAll()
        lastJumpMs = nil
        jumpCount = 0
    }

    /// - Parameters:
    ///   - calibrated: 校准后的磁场（µT）
    ///   - raw: 同一时刻附近的原始磁力计读数；没有就传 nil，跳变检测会跳过
    ///   - accuracy: iOS 的磁场精度（−1...2）
    public func update(tMs: Int64, calibrated: (Double, Double, Double),
                       raw: (Double, Double, Double)?, accuracy: Int) -> Double {
        let norm = (calibrated.0 * calibrated.0 + calibrated.1 * calibrated.1 + calibrated.2 * calibrated.2).squareRoot()
        guard norm.isFinite, norm >= config.minNormUT, norm <= config.maxNormUT else { return 0 }

        var trust: Double
        switch accuracy {
        case ..<0: trust = 0
        case 0: trust = 0.25
        case 1: trust = 0.6
        default: trust = 1
        }

        if let r = raw {
            history.append((tMs, (r.0 - calibrated.0, r.1 - calibrated.1, r.2 - calibrated.2)))
            let horizon = config.windowMs * 2 + config.gapMs
            history.removeAll { tMs - $0.t > horizon }
            if let jump = detectJump(now: tMs) {
                lastJumpMs = jump
                jumpCount += 1
                history.removeAll()                                   // 重新开始，免得同一次跳变连着报警
                history.append((tMs, (r.0 - calibrated.0, r.1 - calibrated.1, r.2 - calibrated.2)))
            }
        }
        if let j = lastJumpMs {
            let since = tMs - j
            if since < config.cooldownMs {
                trust = 0
            } else if since < config.cooldownMs + config.rampMs {
                trust *= Double(since - config.cooldownMs) / Double(config.rampMs)
            }
        }
        return trust
    }

    /// 最近 windowMs 的偏置平均 与 更早一个窗口的平均 比较。
    private func detectJump(now: Int64) -> Int64? {
        let recent = history.filter { now - $0.t <= config.windowMs }
        let older = history.filter {
            let age = now - $0.t
            return age >= config.windowMs + config.gapMs && age <= config.windowMs * 2 + config.gapMs
        }
        guard recent.count >= 5, older.count >= 5 else { return nil }
        func mean(_ a: [(t: Int64, b: (Double, Double, Double))]) -> (Double, Double, Double) {
            let n = Double(a.count)
            return (a.reduce(0) { $0 + $1.b.0 } / n, a.reduce(0) { $0 + $1.b.1 } / n, a.reduce(0) { $0 + $1.b.2 } / n)
        }
        let m1 = mean(recent), m0 = mean(older)
        let d = ((m1.0 - m0.0) * (m1.0 - m0.0) + (m1.1 - m0.1) * (m1.1 - m0.1) + (m1.2 - m0.2) * (m1.2 - m0.2)).squareRoot()
        return d > config.jumpUT ? now : nil
    }
}
