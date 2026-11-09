import CoreLocation
import Foundation

/// 锁屏 / 放进口袋后让定位继续跑。
///
/// iOS 在 App 进后台（用户按侧键锁屏、切到别的 App）几秒后就会挂起进程，CoreMotion 回调随之停止，
/// 位置就停在锁屏那一刻。办法是 Info.plist 声明 `UIBackgroundModes: location`，并在定位期间开一个
/// 「最低精度」的系统定位（3 km 级，只用基站 / Wi-Fi，不开 GPS）：进程保持活跃，CoreMotion 继续送数据。
/// 我们**不使用**它给的经纬度（室内也没意义），只是借它保活；状态栏会显示定位图标，用户随时能看到。
///
/// 耗电：3 km 精度的系统定位本身很省电；主要耗电来自 50 Hz 运动传感器 + 粒子滤波，口袋里实测待补
/// （盲测会话的 meta.json 记录了开始 / 结束电量和发热状态）。
@MainActor
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeeper()

    /// 设置里的开关「锁屏后继续定位」，默认开
    static var enabledSetting: Bool {
        get { UserDefaults.standard.object(forKey: "backgroundPositioning") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "backgroundPositioning") }
    }

    private let manager = CLLocationManager()
    private(set) var active = false
    private var owners = Set<String>()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .fitness
    }

    /// 是否声明了后台定位模式（没声明时打开 allowsBackgroundLocationUpdates 会直接崩溃）
    private static var hasBackgroundMode: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
    }

    /// `owner`：谁在用（实时定位、盲测录制），都结束了才真正停。
    func begin(_ owner: String) {
        guard Self.enabledSetting, Self.hasBackgroundMode, CLLocationManager.locationServicesEnabled() else { return }
        owners.insert(owner)
        guard !active else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()       // 授权后在回调里再开
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdates()
        default:
            AppLog.w("定位", "没有位置权限：锁屏后定位会停止（可以在系统设置里打开「使用 App 期间」）")
        }
    }

    func end(_ owner: String) {
        owners.remove(owner)
        guard owners.isEmpty, active else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        active = false
        AppLog.i("定位", "后台保活结束")
    }

    private func startUpdates() {
        guard !owners.isEmpty, !active else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        active = true
        AppLog.i("定位", "后台保活开始：锁屏 / 放口袋后继续定位（系统定位只用最低精度，不读经纬度）")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let s = self.manager.authorizationStatus
            if s == .authorizedWhenInUse || s == .authorizedAlways { self.startUpdates() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 只用来保活，不处理位置
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in AppLog.w("定位", "后台保活的系统定位出错：\(error.localizedDescription)") }
    }
}
