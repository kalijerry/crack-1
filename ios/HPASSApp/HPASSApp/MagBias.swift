import Foundation
import HPASSKit

/// 手机自带磁场（硬铁偏置）的本机存档。
///
/// 定位改用不含磁力计的姿态参考系（`.xArbitraryZVertical`）后，CoreMotion 不再给「iOS 校准后磁场」，
/// 实时定位的磁场 = 原始磁力计 − 这个偏置。偏置从哪来：
/// 1. 建图 / 采集会话（参考系含磁力计，有 iOS 校准值）结束时，用整次会话「原始 − 校准」的中位数存一份（`learned`）；
///    没有存档时的实时定位（参考系含磁力计）攒够 `liveMinSeconds` 秒，结束时也存一份（`live`），下次定位就用固定偏置；
/// 2. 没有存档时，实时定位里用原始读数做球面拟合在线估计（`sphere_fit`，要手机转过足够多的朝向）。
/// 换保护壳 / 磁吸附件后偏置会变：建图或采集一次就会刷新存档。
enum MagBiasStore {
    private static let key = "hpass.magHardIron.v1"

    struct Stored: Codable {
        var bias: [Double]
        var savedMs: Int64
        var source: String
    }

    /// 存档超过这么多天不再直接用（换壳 / 加磁吸附件后偏置会变）。占位值，待自采 iPhone 双机数据标定
    static let maxAgeDays = 30.0
    /// 实时定位学偏置：至少攒这么多秒「原始 − 校准」才存（短了中位数还在跟着 iOS 漂）
    static let liveMinSeconds = 30
    /// 这么新的存档（毫秒）核对没通过也不作废，只这次不用
    static let keepFreshMs = 86_400_000.0

    static func load() -> Stored? {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Stored.self, from: d), s.bias.count == 3 else { return nil }
        return s
    }

    /// 还能用的存档：没过期。定位开始时按它选参考系（有就不用磁力计参与姿态）
    static func loadValid(nowMs: Int64 = Fmt.nowMs()) -> Stored? {
        guard let s = load(), Double(nowMs - s.savedMs) / 86_400_000 <= maxAgeDays else { return nil }
        return s
    }

    /// 在线核对没通过（磁吸附件、磁性保护壳、钥匙和手机在同一个口袋）：作废存档，下次定位回到 iOS 校准的参考系
    static func invalidate() {
        UserDefaults.standard.removeObject(forKey: key)
        AppLog.w("地磁", "本机磁力计偏置存档作废（读数和地图磁场强度对不上，可能有磁吸附件），下次定位用 iOS 校准值")
    }

    static func save(_ b: (Double, Double, Double), source: String) {
        let s = Stored(bias: [b.0, b.1, b.2], savedMs: Fmt.nowMs(), source: source)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
        AppLog.i("地磁", "存下本机磁力计偏置（\(source)）：\(Int(b.0)), \(Int(b.1)), \(Int(b.2)) µT")
    }
}

/// 采集会话里顺带学偏置：原始磁力计（传感器线程）和 iOS 校准后磁场（IMU 线程）配对，结束时存档。线程安全。
final class MagBiasLearner: @unchecked Sendable {
    private let lock = NSLock()
    /// 整次会话的中位数（和云端建图 SurveyMapBuilder.features 同一个口径）；不够 20 秒不存
    private let tracker = RawBiasTracker(windowSeconds: 3600, minSeconds: 20)
    private var lastRaw: (t: Int64, v: (Double, Double, Double))?

    func reset() {
        lock.lock(); tracker.reset(); lastRaw = nil; lock.unlock()
    }

    func addRaw(tMs: Int64, _ v: (Double, Double, Double)) {
        lock.lock(); lastRaw = (tMs, v); lock.unlock()
    }

    func addCalibrated(_ s: IMUSample) {
        guard s.magValid, s.magAccuracy >= 1 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let r = lastRaw, abs(r.t - s.tMs) <= 30 else { return }
        tracker.add(tMs: s.tMs, raw: r.v, calibrated: s.mag)
    }

    /// 学到了就存档（会话结束时调用）。
    func persistIfReady() {
        lock.lock(); let b = tracker.bias; lock.unlock()
        if let b { MagBiasStore.save(b, source: "learned") }
    }
}

/// 实时定位里的硬铁偏置：优先本机存档；没有存档时用原始读数在线球面拟合。非线程安全（在引擎队列上用）。
final class MagBiasEstimator {
    enum Source: String { case none, learned, sphereFit = "sphere_fit", ios, rejected }

    private(set) var bias: (Double, Double, Double)?
    private(set) var source: Source = .none
    /// 球面拟合的残差（µT），只在 sphere_fit 时有
    private(set) var fitRmsUT: Double?

    // 球面拟合：按 10 µT 立方体分格保留样本，避免同一个朝向的样本占满（每格最多 3 个，先进先出）
    private var bins: [Int: [(Double, Double, Double)]] = [:]
    private var lastAddMs: Int64 = 0
    private var addedSinceFit = 0

    // 在线核对（磁污染）：开始后 validationWindowMs 内 |原始 − 偏置| 的中位数要落在地图 |B| 的范围（± validationSlackUT）里。
    // 占位值，待自采 iPhone 双机数据标定
    static let validationWindowMs: Int64 = 15_000
    static let validationMinSamples = 40
    static let validationSlackUT = 15.0
    /// 地图磁场强度 |B| 的 P5～P95（µT），定位开始时由引擎给；nil = 不核对
    var expectedTotalUT: ClosedRange<Double>?
    /// 核对没通过：偏置作废，这次只用计步 + 地图
    private(set) var polluted = false
    private var validationStartMs: Int64?
    private var validationTotals: [Double] = []
    private var validated = false

    func reset(useStored: Bool = true) {
        bins = [:]
        lastAddMs = 0
        addedSinceFit = 0
        fitRmsUT = nil
        polluted = false
        validationStartMs = nil
        validationTotals = []
        validated = false
        if useStored, let s = MagBiasStore.loadValid() {
            bias = (s.bias[0], s.bias[1], s.bias[2])
            source = .learned
        } else {
            bias = nil
            source = .none
        }
    }

    func corrected(_ raw: (Double, Double, Double)) -> (Double, Double, Double)? {
        guard let b = bias else { return nil }
        return (raw.0 - b.0, raw.1 - b.1, raw.2 - b.2)
    }

    /// 送入原始读数（µT）。有存档时只记不拟合。
    func addRaw(tMs: Int64, _ v: (Double, Double, Double)) {
        validate(tMs: tMs, v)
        guard source == .none || source == .sphereFit else { return }
        guard tMs - lastAddMs >= 200 else { return }        // 5 Hz 就够
        lastAddMs = tMs
        let key = Int((v.0 / 10).rounded()) &* 73856093 ^ Int((v.1 / 10).rounded()) &* 19349663 ^ Int((v.2 / 10).rounded()) &* 83492791
        var b = bins[key] ?? []
        b.append(v)
        if b.count > 3 { b.removeFirst() }
        bins[key] = b
        addedSinceFit += 1
        if addedSinceFit >= 25 {
            addedSinceFit = 0
            fit()
        }
    }

    /// 存档 / 拟合出来的偏置用之前先核对一段：|原始 − 偏置| 的中位数要像这张地图的磁场强度
    private func validate(tMs: Int64, _ v: (Double, Double, Double)) {
        guard !validated, !polluted, let b = bias, let band = expectedTotalUT else { return }
        if validationStartMs == nil { validationStartMs = tMs }
        let c = (v.0 - b.0, v.1 - b.1, v.2 - b.2)
        validationTotals.append((c.0 * c.0 + c.1 * c.1 + c.2 * c.2).squareRoot())
        guard tMs - (validationStartMs ?? tMs) >= Self.validationWindowMs || validationTotals.count >= 4 * Self.validationMinSamples,
              validationTotals.count >= Self.validationMinSamples else { return }
        let sorted = validationTotals.sorted()
        let med = sorted[sorted.count / 2]
        validated = true
        if med < band.lowerBound - Self.validationSlackUT || med > band.upperBound + Self.validationSlackUT {
            AppLog.w("地磁", "磁力计偏置核对没通过：|B| 中位 \(Int(med)) µT，地图 \(Int(band.lowerBound))～\(Int(band.upperBound)) µT；这次只用计步 + 地图")
            // 一天内刚学的偏置不作废：采集时 iOS 校准值对过它，对不上多半是地图过期（比如当初带着磁吸配件采的），
            // 作废了下次只会退回更漂的 iOS 校准值
            if source == .learned {
                if let st = MagBiasStore.load(), Double(Fmt.nowMs() - st.savedMs) < MagBiasStore.keepFreshMs {
                    AppLog.w("地磁", "本机偏置是 \(Int(Double(Fmt.nowMs() - st.savedMs) / 3_600_000)) 小时内学的，先不作废：更可能是地图磁场过期，建议重采这张图")
                } else {
                    MagBiasStore.invalidate()
                }
            }
            bias = nil
            source = .rejected
            polluted = true
        }
    }

    private func fit() {
        let pts = bins.values.flatMap { $0 }
        guard pts.count >= 60 else { return }
        guard let r = HardIronFit.sphere(pts) else { return }
        // 朝向覆盖不够时球心不可信：每个轴向上的跨度都要明显大于噪声
        let span = { (k: KeyPath<(Double, Double, Double), Double>) -> Double in
            let v = pts.map { $0[keyPath: k] }
            return (v.max() ?? 0) - (v.min() ?? 0)
        }
        guard span(\.0) >= 40, span(\.1) >= 40, span(\.2) >= 40 else { return }
        guard r.radius >= 15, r.radius <= 150, r.rms <= 10 else { return }
        bias = r.center
        source = .sphereFit
        fitRmsUT = r.rms
    }
}
