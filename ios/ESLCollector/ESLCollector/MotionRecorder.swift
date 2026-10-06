import CoreMotion
import Foundation

/// 已换算成 Android 传感器约定的 IMU 样本（见 docs/data-format.md）。
struct IMUSample {
    let tMs: Int64
    let acc: (Double, Double, Double)   // m/s²，含重力，平放屏幕朝上 az ≈ +9.81
    let gyr: (Double, Double, Double)   // rad/s
    let mag: (Double, Double, Double)   // µT，已校准
    let magAccuracy: Int
    let quat: (Double, Double, Double, Double) // w, x, y, z
    let headingDeg: Double
}

final class MotionRecorder {
    static let g = 9.80665

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

    func start(hz: Double = 50) {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / hz
        manager.showsDeviceMovementDisplay = true
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame = frames.contains(.xMagneticNorthZVertical)
            ? .xMagneticNorthZVertical : .xArbitraryCorrectedZVertical
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
                                     headingDeg: heading))
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }
}
