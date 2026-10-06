import Foundation

/// 估计「手机自带磁场」这个固定偏置：原始磁力计 − iOS 校准后磁场，按秒取平均，再取中位数。
///
/// iOS 的校准后磁场会跟着它自己的偏置估计漂（实测一分钟内 3～4 µT，偶尔还会跳一下）。
/// 改用「原始 − 这个中位数」，同一个地方在不同时刻读出来就一致了。建图（tools/magmap.py）用的是整次会话的中位数，
/// 实时这边用开始以来（最多最近 `windowSeconds` 秒）的中位数，两边是同一个量。
/// 非线程安全。
public final class RawBiasTracker {
    public var windowSeconds = 180
    /// 至少有这么多秒的数据才算准备好。
    public var minSeconds = 5

    private var currentSecond: Int64?
    private var acc = (0.0, 0.0, 0.0)
    private var n = 0
    private var perSecond: [(Double, Double, Double)] = []
    public private(set) var bias: (Double, Double, Double)?

    public init() {}

    public func reset() {
        currentSecond = nil
        acc = (0, 0, 0)
        n = 0
        perSecond = []
        bias = nil
    }

    public var isReady: Bool { bias != nil }

    /// 送入同一时刻附近的原始读数和校准读数。
    public func add(tMs: Int64, raw: (Double, Double, Double), calibrated: (Double, Double, Double)) {
        let sec = tMs / 1000
        if let c = currentSecond, c != sec, n > 0 {
            perSecond.append((acc.0 / Double(n), acc.1 / Double(n), acc.2 / Double(n)))
            if perSecond.count > windowSeconds { perSecond.removeFirst(perSecond.count - windowSeconds) }
            acc = (0, 0, 0)
            n = 0
            if perSecond.count >= minSeconds {
                func med(_ k: KeyPath<(Double, Double, Double), Double>) -> Double {
                    let v = perSecond.map { $0[keyPath: k] }.sorted()
                    return v[v.count / 2]
                }
                bias = (med(\.0), med(\.1), med(\.2))
            }
        }
        currentSecond = sec
        acc.0 += raw.0 - calibrated.0
        acc.1 += raw.1 - calibrated.1
        acc.2 += raw.2 - calibrated.2
        n += 1
    }

    /// 原始读数减偏置；还没准备好时返回 nil。
    public func corrected(_ raw: (Double, Double, Double)) -> (Double, Double, Double)? {
        guard let b = bias else { return nil }
        return (raw.0 - b.0, raw.1 - b.1, raw.2 - b.2)
    }
}
