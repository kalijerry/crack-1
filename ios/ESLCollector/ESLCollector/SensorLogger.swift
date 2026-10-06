import CoreLocation
import CoreMotion
import Foundation
import UIKit

/// 地磁可行性实验用的附加传感器记录（格式见 docs/data-format.md 的 v2 部分）：
/// 原始磁力计、气压、罗盘航向、计步器、设备状态。
/// DeviceMotion 与蓝牙仍由 MotionRecorder / BLEScanner 负责。
@MainActor
final class SensorLogger: NSObject, CLLocationManagerDelegate {
    /// 原始磁力计顺带转出去（建图时的地磁定位用）
    var tap: SensorTap?
    private let motionManager: CMMotionManager
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private let location = CLLocationManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "sensors"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private var magWriter: CSVWriter?
    private var baroWriter: CSVWriter?
    private var headingWriter: CSVWriter?
    private var pedoWriter: CSVWriter?
    private var deviceWriter: CSVWriter?
    private var deviceTimer: Timer?
    private let counter = MagCounter()

    /// 本次实际可用的传感器，写入 meta.json。
    private(set) var available: [String: Bool] = [:]

    var magRawRows: Int { magWriter?.rowCount ?? 0 }

    init(motionManager: CMMotionManager) {
        self.motionManager = motionManager
        super.init()
        location.delegate = self
    }

    func start(dir: URL, magHz: Double = 100) throws {
        magWriter = try CSVWriter(url: dir.appendingPathComponent("mag_raw.csv"),
                                  header: "t_ms,mx,my,mz")
        baroWriter = try CSVWriter(url: dir.appendingPathComponent("baro.csv"),
                                   header: "t_ms,rel_alt_m,pressure_kpa")
        headingWriter = try CSVWriter(url: dir.appendingPathComponent("heading.csv"),
                                      header: "t_ms,magnetic_deg,true_deg,accuracy_deg,x,y,z")
        pedoWriter = try CSVWriter(url: dir.appendingPathComponent("pedometer.csv"),
                                   header: "t_ms,steps,distance_m,cadence_hz,pace_s_per_m")
        deviceWriter = try CSVWriter(url: dir.appendingPathComponent("device.csv"),
                                     header: "t_ms,battery,battery_state,thermal,low_power,brightness")
        counter.reset()

        // CMMotionManager 的时间戳是开机后秒数，换算成 Unix 毫秒。
        let epochOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

        available["magnetometer_raw"] = motionManager.isMagnetometerAvailable
        if motionManager.isMagnetometerAvailable, !motionManager.isMagnetometerActive,
           let w = magWriter {
            motionManager.magnetometerUpdateInterval = 1.0 / magHz
            let counter = self.counter
            let tap = self.tap
            motionManager.startMagnetometerUpdates(to: queue) { d, _ in
                guard let d else { return }
                let t = Int64(((epochOffset + d.timestamp) * 1000).rounded())
                tap?.raw?(t, (d.magneticField.x, d.magneticField.y, d.magneticField.z))
                w.append("\(t),\(Fmt.f(d.magneticField.x, 3)),\(Fmt.f(d.magneticField.y, 3)),\(Fmt.f(d.magneticField.z, 3))")
                counter.add()
            }
        }

        available["barometer"] = CMAltimeter.isRelativeAltitudeAvailable()
        if CMAltimeter.isRelativeAltitudeAvailable(), let w = baroWriter {
            altimeter.startRelativeAltitudeUpdates(to: queue) { d, _ in
                guard let d else { return }
                let t = Int64(((epochOffset + d.timestamp) * 1000).rounded())
                w.append("\(t),\(Fmt.f(d.relativeAltitude.doubleValue, 3)),\(Fmt.f(d.pressure.doubleValue, 4))")
            }
        }

        available["pedometer"] = CMPedometer.isStepCountingAvailable()
        if CMPedometer.isStepCountingAvailable(), let w = pedoWriter {
            pedometer.startUpdates(from: Date()) { d, _ in
                guard let d else { return }
                let t = Int64((d.endDate.timeIntervalSince1970 * 1000).rounded())
                let dist = d.distance.map { Fmt.f($0.doubleValue, 2) } ?? ""
                let cad = d.currentCadence.map { Fmt.f($0.doubleValue, 3) } ?? ""
                let pace = d.currentPace.map { Fmt.f($0.doubleValue, 3) } ?? ""
                w.append("\(t),\(d.numberOfSteps.intValue),\(dist),\(cad),\(pace)")
            }
        }

        available["compass_heading"] = CLLocationManager.headingAvailable()
        if CLLocationManager.headingAvailable() {
            location.requestWhenInUseAuthorization()
            location.headingFilter = kCLHeadingFilterNone
            location.startUpdatingHeading()
        }

        UIDevice.current.isBatteryMonitoringEnabled = true
        sampleDevice()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleDevice() }
        }
    }

    func stop() {
        deviceTimer?.invalidate()
        deviceTimer = nil
        if motionManager.isMagnetometerActive { motionManager.stopMagnetometerUpdates() }
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        location.stopUpdatingHeading()
        UIDevice.current.isBatteryMonitoringEnabled = false
        for w in [magWriter, baroWriter, headingWriter, pedoWriter, deviceWriter] { w?.close() }
        magWriter = nil
        baroWriter = nil
        headingWriter = nil
        pedoWriter = nil
        deviceWriter = nil
    }

    func flush() {
        for w in [magWriter, baroWriter, headingWriter, pedoWriter, deviceWriter] { w?.flush() }
    }

    /// 自上次调用以来的原始磁力计样本数。
    func takeMagCount() -> Int { counter.take() }

    private func sampleDevice() {
        let d = UIDevice.current
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0
        let brightness = Fmt.f(Double(UIScreen.main.brightness), 2)
        deviceWriter?.append("\(Fmt.nowMs()),\(Fmt.f(Double(d.batteryLevel), 2)),\(d.batteryState.rawValue),\(thermal),\(low),\(brightness)")
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading h: CLHeading) {
        let t = Int64((h.timestamp.timeIntervalSince1970 * 1000).rounded())
        let line = "\(t),\(Fmt.f(h.magneticHeading, 2)),\(Fmt.f(h.trueHeading, 2)),\(Fmt.f(h.headingAccuracy, 1)),\(Fmt.f(h.x, 3)),\(Fmt.f(h.y, 3)),\(Fmt.f(h.z, 3))"
        Task { @MainActor in self.headingWriter?.append(line) }
    }

    /// 不弹系统的罗盘校准界面，避免打断走线。
    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false
    }
}

/// 磁力计回调线程写、UI 定时器读。
private final class MagCounter {
    private let lock = NSLock()
    private var n = 0

    func add() { lock.lock(); n += 1; lock.unlock() }
    func take() -> Int { lock.lock(); defer { lock.unlock() }; let v = n; n = 0; return v }
    func reset() { lock.lock(); n = 0; lock.unlock() }
}
