import Foundation

/// 步长 K 的在线标定（docs/carry-motion.md）：粒子滤波收敛、稳定跟踪时每走 `everyCm`，把粒子步长比例的加权中位数
/// 回写当前携带模式的 K（`FusionEngine.applyLearnedStepScale`），再把粒子的比例除以同一个系数（`absorbStepScale`），
/// 净位移不变。App 的实时定位、评估器的 `.pdrIMU` 回放和单元测试的流水线都用这一个类，量到的就是产品行为。
///
/// 只有 `FusionConfig.motion.enabled` 时起作用（分模式 K 只在携带模式路径里有）。参数是占位值，待自采 iPhone 双机数据标定。
public final class StepScaleCalibrator {
    /// 每稳定跟踪这么远（cm）吸收一次
    public var everyCm = 5000.0
    /// 粒子步长比例的加权标准差超过这个就不吸收（粒子还没对步长达成一致）
    public var maxSigma = 0.08
    /// 每次只吸收这么大一部分（`applyLearnedStepScale` 的 alpha）
    public var alpha = 0.5
    /// 吸收过几次（诊断）
    public private(set) var absorbed = 0
    private var walkedCm = 0.0

    public init() {}

    public func reset() { walkedCm = 0 }

    /// 每送一次运动增量调一次。返回这次吸收进 K 的系数（没吸收返回 nil）。
    @discardableResult
    public func step(deltaCm: Double, engine: FusionEngine, localizer: MagneticLocalizer) -> Double? {
        guard engine.config.motion.enabled, localizer.isConverged, !localizer.lostSuppressed,
              engine.activeCarryMode.isCarryPosture, deltaCm.isFinite else {
            walkedCm = 0
            return nil
        }
        walkedCm += max(deltaCm, 0)
        guard walkedCm >= everyCm else { return nil }
        walkedCm = 0
        let st = localizer.scaleStatistics()
        guard st.sigma <= maxSigma else { return nil }
        let f = engine.applyLearnedStepScale(st.median, for: engine.activeCarryMode, alpha: alpha)
        guard abs(f - 1) > 1e-9 else { return nil }
        localizer.absorbStepScale(f)
        absorbed += 1
        return f
    }
}
