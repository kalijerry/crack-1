import CoreBluetooth
import Foundation

struct BLEReading {
    let tMs: Int64
    let eslId: String?
    let rssi: Int
    let src: String
    let mfgHex: String
}

enum ESLParser {
    /// 价签广播使用的公司 ID（Handy+ 中 getManufacturerSpecificData(13)）。
    static let companyId: UInt16 = 0x000D

    /// 与 Android 端规则一致：去掉 2 字节公司 ID 后 payload 长度 4..7，取前 4 字节转大写十六进制，用 "-" 连接。
    /// 注意 iOS 的 kCBAdvDataManufacturerData 含公司 ID 前缀，Android 的 getManufacturerSpecificData 不含。
    static func eslId(from data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let cid = UInt16(b[0]) | (UInt16(b[1]) << 8)
        guard cid == companyId else { return nil }
        let payload = b.dropFirst(2)
        guard payload.count >= 4, payload.count < 8 else { return nil }
        return payload.prefix(4).map { String(format: "%02X", $0) }.joined(separator: "-")
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

final class BLEScanner: NSObject, CBCentralManagerDelegate {
    var onReading: (@Sendable (BLEReading) -> Void)?
    var onState: (@Sendable (CBManagerState) -> Void)?
    /// 只记录价签广播；关闭时记录所有带厂商数据的广播。
    var onlyESL = true

    private var central: CBCentralManager!
    private let queue = DispatchQueue(label: "ble.scan", qos: .userInitiated)
    private var wantScan = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func start() {
        queue.async {
            self.wantScan = true
            if self.central.state == .poweredOn { self.scan() }
        }
    }

    func stop() {
        queue.async {
            self.wantScan = false
            if self.central.state == .poweredOn { self.central.stopScan() }
        }
    }

    private func scan() {
        // AllowDuplicates：前台下每次收到广播都回调，才能得到连续 RSSI。
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onState?(central.state)
        if central.state == .poweredOn, wantScan { scan() }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        if rssi >= 127 || rssi == 0 { return } // 127 = 不可用
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        let id = ESLParser.eslId(from: mfg)
        if onlyESL, id == nil { return }
        onReading?(BLEReading(tMs: Fmt.nowMs(),
                              eslId: id,
                              rssi: rssi,
                              src: peripheral.identifier.uuidString,
                              mfgHex: ESLParser.hex(mfg)))
    }
}
