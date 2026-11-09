import Foundation
import HPASSKit

/// 手机自带磁场（硬铁偏置）的本机存档。
///
/// 定位改用不含磁力计的姿态参考系（`.xArbitraryZVertical`）后，CoreMotion 不再给「iOS 校准后磁场」，
/// 实时定位的磁场 = 原始磁力计 − 这个偏置。偏置从哪来：
/// 1. 建图 / 采集会话（参考系含磁力计，有 iOS 校准值）结束时，用「原始 − 校准」的中位数存一份（`learned`）；
/// 2. 没有存档时，实时定位里用原始读数做球面拟合在线估计（`sphere_fit`，要手机转过足够多的朝向）。
/// 换保护壳 / 磁吸附件后偏置会变：建图或采集一次就会刷新存档。
enum MagBiasStore {
    private static let key = "hpass.magHardIron.v1"

    struct Stored: Codable {
        var bias: [Double]
        var savedMs: Int64
        var source: String
    }

    static func load() -> Stored? {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Stored.self, from: d), s.bias.count == 3 else { return nil }
        return s
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
    private let tracker = RawBiasTracker()
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
    enum Source: String { case none, learned, sphereFit = "sphere_fit", ios }

    private(set) var bias: (Double, Double, Double)?
    private(set) var source: Source = .none
    /// 球面拟合的残差（µT），只在 sphere_fit 时有
    private(set) var fitRmsUT: Double?

    // 球面拟合：按 10 µT 立方体分格保留样本，避免同一个朝向的样本占满（每格最多 3 个，先进先出）
    private var bins: [Int: [(Double, Double, Double)]] = [:]
    private var lastAddMs: Int64 = 0
    private var addedSinceFit = 0

    func reset(useStored: Bool = true) {
        bins = [:]
        lastAddMs = 0
        addedSinceFit = 0
        fitRmsUT = nil
        if useStored, let s = MagBiasStore.load() {
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
