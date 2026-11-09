import Foundation
import HPASSKit

/// 步长 K 在线标定学到的分携带方式比例（HPASSKit StepScaleCalibrator → FusionEngine.onStepScaleLearned），本机存，
/// 下次定位开始时用 FusionEngine.setLearnedStepScales 恢复。线程安全（UserDefaults）。
enum StepScaleStore {
    private static let key = "hpass.stepScales.v1"

    static func load() -> [CarryMode: Double] {
        guard let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] else { return [:] }
        var out: [CarryMode: Double] = [:]
        for (k, v) in d { if let m = CarryMode(rawValue: k) { out[m] = v } }
        return out
    }

    static func save(mode: CarryMode, scale: Double) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        d[mode.rawValue] = scale
        UserDefaults.standard.set(d, forKey: key)
    }
}
