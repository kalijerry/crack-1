import SwiftUI

/// 功能开关。现在只做地磁定位，蓝牙相关的页面（蓝牙采集、蓝牙定位、指纹库 / 价签数据）先藏起来；
/// 代码都还在，改成 true 就回来。
enum Features {
    static let bluetooth = false
}

/// 两种模式：
/// - 正常模式（默认）：只用云端（GitHub Actions）融合出来的地图（带版本号），能采集（自动上传）、定位、找价签；
/// - 开发模式：全部功能——本机生成磁场图、选会话、导入各种数据、扫房间、实验功能、上传本机版本。
@MainActor
final class AppMode: ObservableObject {
    static let shared = AppMode()
    @Published var developer: Bool = UserDefaults.standard.bool(forKey: "developerMode") {
        didSet {
            UserDefaults.standard.set(developer, forKey: "developerMode")
            AppLog.i("应用", developer ? "切到开发模式" : "切到正常模式")
            if !developer { MapLibrary.shared.ensureCloudActive() }
        }
    }
}

struct ContentView: View {
    @State private var tab = Features.bluetooth ? Tab.collect : Tab.magnetic
    @ObservedObject private var mode = AppMode.shared

    enum Tab: Hashable {
        case collect, storeData, live, magnetic, scan, log
    }

    var body: some View {
        TabView(selection: $tab) {
            if Features.bluetooth {
                CollectView()
                    .tabItem { Label("采集", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(Tab.collect)
            }

            StoreDataView()
                .tabItem { Label("门店数据", systemImage: "square.and.arrow.down") }
                .tag(Tab.storeData)

            if Features.bluetooth {
                LiveLocationView()
                    .tabItem { Label("蓝牙定位", systemImage: "location.viewfinder") }
                    .tag(Tab.live)
            }

            MagneticView()
                .tabItem { Label("地磁定位", systemImage: "scope") }
                .tag(Tab.magnetic)

            if mode.developer {
                RoomScanView()
                    .tabItem { Label("房间扫描", systemImage: "cube.transparent") }
                    .tag(Tab.scan)
            }

            LogView()
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }
                .tag(Tab.log)
        }
        .onChange(of: tab) { newValue in
            AppLog.tap("切换页面", Self.name(of: newValue))
        }
        .onAppear {
            AppLog.i("应用", "启动")
            _ = MapLibrary.shared          // 第一次用：把现在的地图收进地图库
        }
        // 启动时拉一次云端：正常模式自动装上云端正式地图（含已采涂色、价签表），重装 App 后打开就有
        .task { await CloudMaps.shared.refresh() }
    }

    private static func name(of tab: Tab) -> String {
        switch tab {
        case .collect: return "采集"
        case .storeData: return "门店数据"
        case .live: return "蓝牙定位"
        case .magnetic: return "地磁定位"
        case .scan: return "房间扫描"
        case .log: return "日志"
        }
    }
}
