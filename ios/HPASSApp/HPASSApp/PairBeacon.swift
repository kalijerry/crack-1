import CoreBluetooth
import CoreMotion
import Foundation

/// 双机测试的配对：伴随真值机广播一个随机配对编号，盲测机扫到后写进自己的 meta.json，离线按它把两段录制配成一对。
///
/// iOS 前台广播只能带 local name 和 service UUID（后台连 local name 都没有），所以配对编号直接编码进
/// service UUID：`<8 位十六进制编号>-7A11-4E5B-9C3D-0B11D7E57A1B`，后缀固定，扫描端按后缀认。
/// 盲测机在开始录制时（手机还在手上、前台）扫，扫到即停；扫不到也可以手动输入编号。
enum PairCode {
    static let suffix = "-7A11-4E5B-9C3D-0B11D7E57A1B"

    static func random() -> String {
        String(format: "%08X", UInt32.random(in: 0x1000_0000...0xFFFF_FFFE))
    }

    static func uuid(for id: String) -> CBUUID? {
        guard id.count == 8, UInt32(id, radix: 16) != nil else { return nil }
        return CBUUID(string: id.uppercased() + suffix)
    }

    static func id(from u: CBUUID) -> String? {
        let s = u.uuidString.uppercased()
        guard s.hasSuffix(suffix), s.count == 36 else { return nil }
        return String(s.prefix(8))
    }

    /// 手动输入的编号规范化（去空格、转大写、必须是 8 位十六进制）
    static func normalize(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return uuid(for: t) != nil ? t : nil
    }
}

/// 伴随真值机：前台广播配对编号。
final class PairAdvertiser: NSObject, CBPeripheralManagerDelegate {
    private var pm: CBPeripheralManager?
    private var id: String?
    var onState: ((String) -> Void)?

    func start(id: String) {
        self.id = id
        if pm == nil { pm = CBPeripheralManager(delegate: self, queue: nil) } else { advertise() }
    }

    func stop() {
        pm?.stopAdvertising()
        id = nil
    }

    private func advertise() {
        guard let pm, pm.state == .poweredOn, let id, let u = PairCode.uuid(for: id) else { return }
        pm.stopAdvertising()
        pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [u], CBAdvertisementDataLocalNameKey: "HP-\(id)"])
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn: advertise(); onState?("广播中")
        case .unauthorized: onState?("没有蓝牙权限")
        case .poweredOff: onState?("蓝牙已关闭")
        default: onState?("蓝牙不可用")
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { onState?("广播失败：\(error.localizedDescription)") }
    }
}

/// 盲测机：扫描伴随机的配对编号（取信号最强的那个）。
final class PairScanner: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var want = false
    /// 扫到：编号、信号强度
    var onFound: ((String, Int) -> Void)?

    func start() {
        want = true
        if central == nil { central = CBCentralManager(delegate: self, queue: nil) } else { scan() }
    }

    func stop() {
        want = false
        if central?.state == .poweredOn { central?.stopScan() }
    }

    private func scan() {
        guard want, let c = central, c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { scan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        var uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        uuids += advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        for u in uuids {
            if let id = PairCode.id(from: u) { onFound?(id, RSSI.intValue) }
        }
    }
}

/// 对时敲击：两台手机叠在一起在桌面敲三下（间隔约 0.5 s），开始和结束各一组。
///
/// 50 Hz 的 deviceMotion 经过 Apple 低通，敲击尖峰常被削平，所以这里另开 100 Hz 原始加速度计，
/// 写 `acc_raw.csv`（t_ms,ax,ay,az，m/s²，Android 约定），离线用它做互相关对时；在线只做粗检测
/// （|a| 超过 2.5 g 的峰，相隔 ≥ 150 ms 算一次），检测到的时刻写进 meta 的 bumps_ms 方便核对。
/// 两机贴紧一起转 2～3 秒（陀螺互相关）更稳，见 docs/office-carry-test.md。
final class BumpRecorder {
    private let manager = CMMotionManager()     // 只开加速度计，和定位用的 deviceMotion 互不影响
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "bump"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var writer: CSVWriter?
    private var lastPeakMs: Int64 = 0
    /// 检测到一次敲击（主线程回调）
    var onBump: ((Int64) -> Void)?
    static let thresholdG = 2.5

    func start(dir: URL) {
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        writer = try? CSVWriter(url: dir.appendingPathComponent("acc_raw.csv"), header: "t_ms,ax,ay,az")
        let w = writer
        manager.accelerometerUpdateInterval = 0.01
        let epochOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        lastPeakMs = 0
        manager.startAccelerometerUpdates(to: queue) { [weak self] d, _ in
            guard let self, let d else { return }
            let t = Int64(((epochOffset + d.timestamp) * 1000).rounded())
            let g = MotionRecorder.g
            let a = d.acceleration
            w?.append("\(t),\(Fmt.f(-a.x * g, 3)),\(Fmt.f(-a.y * g, 3)),\(Fmt.f(-a.z * g, 3))")
            let n = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            if n >= Self.thresholdG, t - self.lastPeakMs >= 150 {
                self.lastPeakMs = t
                DispatchQueue.main.async { self.onBump?(t) }
            }
        }
    }

    func stop() {
        if manager.isAccelerometerActive { manager.stopAccelerometerUpdates() }
        writer?.close()
        writer = nil
    }
}
