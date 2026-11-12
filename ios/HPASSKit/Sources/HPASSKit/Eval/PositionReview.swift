import Foundation

/// 视觉复核：以视觉定位为真值，统计地磁混合定位的误差。
///
/// 真值来自同一部手机的 ARKit：带视觉特征地图启动、认出房间并且位姿稳定之后，相机位置经房间扫描时存的
/// 「ARKit → 地图」变换就是地图上的绝对位置（厘米级）。复核时视觉位置**不喂给**定位，只当裁判。
/// 采样由调用方节流（App 里 5 Hz）；这里只做累计和统计，和 tools/collection_eval.py 的 review 汇总同一口径。
public struct PositionReviewStats: Equatable {
    /// 每个有真值、也有定位估计的样本的误差（cm）
    public private(set) var errorsCm: [Double] = []
    /// 其中定位自认有把握（converged）时的误差
    public private(set) var convergedErrorsCm: [Double] = []
    /// 有真值的样本数（含定位还没有估计的）
    public private(set) var truthSamples = 0
    public private(set) var firstTruthMs: Int64?
    public private(set) var lastTruthMs: Int64?
    /// 误差第一次连续 `settleMs` 都在 2 m 内的开始时刻
    public private(set) var settledAtMs: Int64?
    /// 最后一个样本的误差（没有估计时为 nil）
    public private(set) var lastErrorCm: Double?
    private var within2Since: Int64?

    public static let settleCm = 200.0
    public static let settleMs: Int64 = 3000

    public init() {}

    /// 加一个样本，返回这一刻的误差（没有估计时 nil）。
    @discardableResult
    public mutating func add(tMs: Int64, truth: Point2, estimate: Point2?, converged: Bool) -> Double? {
        truthSamples += 1
        if firstTruthMs == nil { firstTruthMs = tMs }
        lastTruthMs = tMs
        guard let e = estimate else {
            lastErrorCm = nil
            within2Since = nil
            return nil
        }
        let err = truth.distance(to: e)
        errorsCm.append(err)
        if converged { convergedErrorsCm.append(err) }
        lastErrorCm = err
        if err <= Self.settleCm {
            let since = within2Since ?? tMs
            within2Since = since
            if settledAtMs == nil, tMs - since >= Self.settleMs { settledAtMs = since }
        } else {
            within2Since = nil
        }
        return err
    }

    public var count: Int { errorsCm.count }
    public var medianCm: Double? { Self.percentile(errorsCm, 0.5) }
    public var p90Cm: Double? { Self.percentile(errorsCm, 0.9) }
    public var maxCm: Double? { errorsCm.max() }
    public var convergedMedianCm: Double? { Self.percentile(convergedErrorsCm, 0.5) }
    /// 有真值的时刻里，定位有估计的比例
    public var estimateShare: Double? { truthSamples > 0 ? Double(errorsCm.count) / Double(truthSamples) : nil }
    public func withinShare(_ cm: Double) -> Double? {
        errorsCm.isEmpty ? nil : Double(errorsCm.filter { $0 <= cm }.count) / Double(errorsCm.count)
    }
    /// 从第一次有真值到误差稳定在 2 m 内用了几秒（还没稳定过为 nil）
    public var secondsToSettle: Double? {
        guard let a = firstTruthMs, let b = settledAtMs else { return nil }
        return Double(b - a) / 1000
    }

    /// 写进 meta.json 的摘要（单位米 / 比例），键名和 collection_eval.py 的 review_* 字段一致
    public func summary() -> [String: Any] {
        var d: [String: Any] = ["samples": count, "truth_samples": truthSamples]
        func m(_ v: Double?) -> Double? { v.map { ($0 / 100 * 100).rounded() / 100 } }
        func r(_ v: Double?) -> Double? { v.map { ($0 * 100).rounded() / 100 } }
        if let v = m(medianCm) { d["err_median_m"] = v }
        if let v = m(p90Cm) { d["err_p90_m"] = v }
        if let v = m(maxCm) { d["err_max_m"] = v }
        if let v = m(convergedMedianCm) { d["err_converged_median_m"] = v }
        if let v = r(withinShare(100)) { d["within_1m"] = v }
        if let v = r(withinShare(200)) { d["within_2m"] = v }
        if let v = r(estimateShare) { d["estimate_share"] = v }
        if let v = secondsToSettle { d["settle_s"] = (v * 10).rounded() / 10 }
        return d
    }

    /// 线性插值百分位（和 collection_eval.py 的 pct、numpy 默认一致）
    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let k = Double(s.count - 1) * min(max(p, 0), 1)
        let lo = Int(k.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (k - Double(lo))
    }
}
