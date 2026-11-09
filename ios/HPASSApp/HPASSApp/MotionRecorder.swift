import CoreMotion
import Foundation

/// 已换算成 Android 传感器约定的 IMU 样本（见 docs/data-format.md）。
struct IMUSample {
    let tMs: Int64
    let acc: (Double, Double, Double)   // m/s²，含重力，平放屏幕朝上 az ≈ +9.81
    let gyr: (Double, Double, Double)   // rad/s
    let mag: (Double, Double, Double)   // µT，iOS 校准后；参考系不用磁力计时无效（见 magValid）
    let magAccuracy: Int
    let quat: (Double, Double, Double, Double) // w, x, y, z（CoreMotion 姿态，参考系见 MotionRecorder.Frame）
    let headingDeg: Double
    /// 陀螺辅助的重力，m/s²，Android 约定（平放屏幕朝上 ≈ (0, 0, +9.81)，与 acc 同号）
    let grav: (Double, Double, Double)

    /// iOS 校准后磁场是否有效：参考系不含磁力计时 CoreMotion 给的是 accuracy = -1、全零
    var magValid: Bool {
        magAccuracy >= 0 && (mag.0 != 0 || mag.1 != 0 || mag.2 != 0)
    }

    /// imu.csv v4 的表头（见 docs/data-format.md「格式 v4」）
    static let csvHeaderV4 = "t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg,gvx,gvy,gvz"

    /// imu.csv v4 的一行。`mag` / `magAcc` 允许调用方换成自己校正过的磁场（参考系不含磁力计时）。
    func csvLineV4(mag m: (Double, Double, Double)? = nil, magAcc: Int? = nil) -> String {
        let mm = m ?? mag
        return [
            "\(tMs)",
            Fmt.f(acc.0), Fmt.f(acc.1), Fmt.f(acc.2),
            Fmt.f(gyr.0, 5), Fmt.f(gyr.1, 5), Fmt.f(gyr.2, 5),
            Fmt.f(mm.0, 3), Fmt.f(mm.1, 3), Fmt.f(mm.2, 3),
            "\(magAcc ?? magAccuracy)",
            Fmt.f(quat.0, 6), Fmt.f(quat.1, 6), Fmt.f(quat.2, 6), Fmt.f(quat.3, 6),
            Fmt.f(headingDeg, 2),
            Fmt.f(grav.0, 4), Fmt.f(grav.1, 4), Fmt.f(grav.2, 4),
        ].joined(separator: ",")
    }
}

final class MotionRecorder {
    static let g = 9.80665

    /// CoreMotion 姿态参考系。
    enum Frame: String {
        /// 定位用、本机有可信的硬铁偏置存档时：`.xArbitraryZVertical`，姿态不用磁力计。
        /// 这个参考系下 CMDeviceMotion.magneticField 无效（accuracy = -1），磁场 = 原始磁力计 − 本机偏置（MagBiasEstimator）。
        case positioning
        /// 定位用、本机还没有（或刚作废了）偏置存档时：`.xArbitraryCorrectedZVertical`，iOS 照常给校准后磁场。
        /// 定位流水线不用 CoreMotion 的姿态 / 偏航（FusionAttitude 自己积陀螺；重力、角速度和参考系无关），
        /// 所以磁力计参与姿态解算对定位没有影响；而没有偏置时不含磁力计的参考系会让地磁完全用不上（评审：阻断）。
        case positioningCalibrated
        /// 建图 / 采集用：`.xMagneticNorthZVertical`（不可用时 `.xArbitraryCorrectedZVertical`）。
        /// 建图离线流水线要 iOS 校准后磁场（imu.csv mx..mz）和系统航向，这条路不改。
        case mapping
    }

    var onSample: (@Sendable (IMUSample) -> Void)?
    /// 全 App 只用这一个实例（Apple 的要求），SensorLogger 也从这里取。
    let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "imu"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    /// 实际在用的参考系名字（写进 meta.json 的 attitude_frame）
    private(set) var frameName = ""

    func start(hz: Double = 50, frame want: Frame = .positioning) {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / hz
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame
        switch want {
        case .positioning:
            frame = .xArbitraryZVertical
            manager.showsDeviceMovementDisplay = false
        case .positioningCalibrated:
            frame = frames.contains(.xArbitraryCorrectedZVertical) ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical
            // 不弹系统的「画 8 字校准」界面（盲测 / 口袋里没法操作）
            manager.showsDeviceMovementDisplay = false
        case .mapping:
            frame = frames.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical : .xArbitraryCorrectedZVertical
            manager.showsDeviceMovementDisplay = true
        }
        frameName = Self.name(frame)
        // CMDeviceMotion.timestamp 是开机后的秒数，换算成 Unix 时间。
        let epochOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

        manager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            let g = MotionRecorder.g
            let ax = -(m.userAcceleration.x + m.gravity.x) * g
            let ay = -(m.userAcceleration.y + m.gravity.y) * g
            let az = -(m.userAcceleration.z + m.gravity.z) * g
            let r = m.rotationRate
            let f = m.magneticField
            let q = m.attitude.quaternion
            let heading: Double
            if #available(iOS 14.0, *), frame == .xMagneticNorthZVertical {
                heading = m.heading
            } else {
                heading = -1
            }
            let t = Int64(((epochOffset + m.timestamp) * 1000).rounded())
            self.onSample?(IMUSample(tMs: t,
                                     acc: (ax, ay, az),
                                     gyr: (r.x, r.y, r.z),
                                     mag: (f.field.x, f.field.y, f.field.z),
                                     magAccuracy: Int(f.accuracy.rawValue),
                                     quat: (q.w, q.x, q.y, q.z),
                                     headingDeg: heading,
                                     // CoreMotion 的重力在设备系指向地心（平放朝上为 (0,0,-1) g），取负换成 Android 约定
                                     grav: (-m.gravity.x * g, -m.gravity.y * g, -m.gravity.z * g)))
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }

    static func name(_ f: CMAttitudeReferenceFrame) -> String {
        switch f {
        case .xArbitraryZVertical: return "xArbitraryZVertical"
        case .xArbitraryCorrectedZVertical: return "xArbitraryCorrectedZVertical"
        case .xMagneticNorthZVertical: return "xMagneticNorthZVertical"
        case .xTrueNorthZVertical: return "xTrueNorthZVertical"
        default: return "unknown"
        }
    }
}
