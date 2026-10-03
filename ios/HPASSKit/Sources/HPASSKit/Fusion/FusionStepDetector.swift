import Foundation

/// 一次检出的脚步。
struct FusionStepEvent {
    /// 检出时刻（Unix ms）。注意是「峰值下降沿」，相对真实落地滞后约 0.1 s。
    var tMs: Int64
    /// 平滑后的步长（m）。
    var lengthM: Double
    /// 本步加速度动态分量的峰谷差（m/s²），Weinberg 模型的输入。
    var accelRange: Double
}

/// 步伐检测 + 步长估计 + 运动检测。
///
/// 技术组成：
/// - **去重力加速度模长**：`a_dyn = LPF_fast(|a|) − LPF_slow(LPF_fast(|a|))`。
///   先用快低通压噪声，再减掉慢低通（等效带通），直流的 9.81 自动消掉，
///   而且用模长 |a| 而不是某个轴，所以结果与手机握持姿态无关。
/// - **峰/谷状态机 + 滞回 + 最小间隔**：一步必须「先下冲过谷阈值、再上冲过峰阈值」，
///   并且距上一步不短于 minStepIntervalMs。站立时 a_dyn 远达不到阈值，所以不会误计数。
/// - **Weinberg 步长模型**：`L = k · (a_max − a_min)^(1/4)`（Weinberg 2002），再限幅 + EMA 平滑。
/// - **运动检测**：a_dyn 在 1 s 滑窗内的方差。
///
/// 线程约定：非线程安全，由 FusionEngine 在同一串行队列上驱动。
final class FusionStepDetector {

    // MARK: - 可调常量（每个都注明取值理由）

    /// |a| 快低通时间常数（s）。0.04 s ≈ 4 Hz 截止：
    /// 完整保留 1.5–2.5 Hz 的步伐基频，压掉手抖与传感器高频噪声。
    private let fastTau: Double = 0.04
    /// 慢低通（直流/重力分量）时间常数（s）。1.0 s ≈ 0.16 Hz，远低于最低步频 1.2 Hz，
    /// 对步伐信号的泄漏不到 10%。
    private let slowTau: Double = 1.0

    /// 峰值触发阈值（m/s²）。正常步行竖向加速度峰峰值 2–6 m/s²，
    /// 手持静置的 a_dyn 幅度 < 0.3 m/s²；1.0 取在两者中间，上下都有 3 倍以上裕量。
    private let peakThresh: Double = 1.0
    /// 峰值退出阈值（m/s²）。与 peakThresh 构成 0.4 的滞回带，防止峰顶抖动重复计数。
    private let peakExitThresh: Double = 0.6
    /// 谷值「武装」阈值（m/s²）。一步必须经历一次明显下冲，才算一个完整步伐周期。
    private let valleyThresh: Double = -0.6

    /// Weinberg 系数，单位 m·(m/s²)^(−1/4)。文献常用 0.4–0.5（手持/口袋姿态）。
    /// 0.45 对应峰峰值 4 m/s² 时步长 0.64 m，符合成人常速步行。**这是最需要按人标定的常量。**
    private let weinbergK: Double = 0.45
    /// 步长下限（m）。小于 0.3 m 基本是原地挪步，不应该推动位置。
    private let minStepLenM: Double = 0.30
    /// 峰谷差下限（m/s²）。低于此值 Weinberg 的四次根不可靠，沿用上一次平滑值。
    private let minRangeForWeinberg: Double = 0.5
    /// 步长 EMA 系数。0.4：跟得上步速变化（2–3 步收敛），又不会被单步噪声带飞。
    private let lenAlpha: Double = 0.4
    /// 还没有有效观测前的默认步长（m）：成人平均步长。
    private let defaultLenM: Double = 0.65

    /// 运动判据：a_dyn 在 1 s 窗内的方差阈值（(m/s²)²）。
    /// 0.2 → σ ≈ 0.45 m/s²；手持静置通常 σ < 0.15，步行时 σ > 1.0。
    private let movingVarThresh: Double = 0.2
    /// 滑窗长度：50 样本 @50 Hz = 1 s，刚好覆盖 1–2 个步伐周期。
    private let windowSize: Int = 50

    // MARK: - 状态

    private var fast: Double = 0
    private var slow: Double = 0
    private var started = false

    private var inPeak = false
    private var armed = false
    private var curMax: Double = 0
    private var curMin: Double = 0

    private var lastStepTMs: Int64 = 0
    private var hasStep = false
    private var smoothedLen: Double = 0.65

    /// 长度等于 windowSize（50）。
    private var window = [Double](repeating: 0, count: 50)
    private var windowIdx = 0
    private var windowFilled = 0

    /// 最近一次的 a_dyn（调试用）。
    private(set) var lastDyn: Double = 0

    init() {
        smoothedLen = defaultLenM
    }

    func reset() {
        fast = 0; slow = 0; started = false
        inPeak = false; armed = false
        curMax = 0; curMin = 0
        lastStepTMs = 0; hasStep = false
        smoothedLen = defaultLenM
        window = [Double](repeating: 0, count: windowSize)
        windowIdx = 0; windowFilled = 0
        lastDyn = 0
    }

    /// 1 s 窗内 a_dyn 方差是否超过阈值。窗未半满时保守返回 false。
    var isMoving: Bool {
        guard windowFilled >= windowSize / 2 else { return false }
        let n = Double(windowFilled)
        var mean = 0.0
        for i in 0..<windowFilled { mean += window[i] }
        mean /= n
        var v = 0.0
        for i in 0..<windowFilled {
            let d = window[i] - mean
            v += d * d
        }
        v /= n
        return v > movingVarThresh
    }

    /// 推进一个样本；检出脚步时返回事件，否则 nil。
    func update(sample s: IMUSample, dt: Double, minStepIntervalMs: Int64, maxStepLengthM: Double) -> FusionStepEvent? {
        let aNorm = (s.ax * s.ax + s.ay * s.ay + s.az * s.az).squareRoot()
        guard aNorm.isFinite else { return nil }

        if !started {
            fast = aNorm
            slow = aNorm
            started = true
        }
        fast += (aNorm - fast) * FusionMath.lpfAlpha(dt: dt, tau: fastTau)
        slow += (fast - slow) * FusionMath.lpfAlpha(dt: dt, tau: slowTau)
        let dyn = fast - slow
        lastDyn = dyn

        // 运动检测滑窗
        if windowIdx >= 0 && windowIdx < window.count {
            window[windowIdx] = dyn
        }
        windowIdx = (windowIdx + 1) % windowSize
        if windowFilled < windowSize { windowFilled += 1 }

        // 谷值跟踪 / 武装
        if dyn < curMin { curMin = dyn }
        if dyn <= valleyThresh { armed = true }

        var event: FusionStepEvent?

        if inPeak {
            if dyn > curMax { curMax = dyn }
            if dyn < peakExitThresh {
                // 峰值下降沿：此时 curMax / curMin 已经是本周期的完整峰谷。
                inPeak = false
                let intervalOK = !hasStep || (s.tMs - lastStepTMs) >= max(minStepIntervalMs, 0)
                if armed && intervalOK {
                    let range = max(curMax - curMin, 0.0)
                    let raw = range > minRangeForWeinberg ? weinbergK * pow(range, 0.25) : smoothedLen
                    let upper = max(maxStepLengthM, minStepLenM)
                    let clamped = FusionMath.clamp(raw, minStepLenM, upper)
                    smoothedLen = hasStep ? smoothedLen + (clamped - smoothedLen) * lenAlpha : clamped
                    event = FusionStepEvent(tMs: s.tMs, lengthM: smoothedLen, accelRange: range)
                    lastStepTMs = s.tMs
                    hasStep = true
                }
                armed = false
                curMin = dyn
                curMax = dyn
            }
        } else if dyn > peakThresh {
            inPeak = true
            curMax = dyn
        }

        return event
    }
}
