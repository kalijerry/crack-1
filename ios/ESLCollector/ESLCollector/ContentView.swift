import SwiftUI

/// 功能开关。现在只做地磁定位，蓝牙相关的页面（蓝牙采集、蓝牙定位、指纹库 / 价签数据）先藏起来；
/// 代码都还在，改成 true 就回来。
enum Features {
    static let bluetooth = false
}

struct ContentView: View {
    @State private var tab = Features.bluetooth ? Tab.collect : Tab.magnetic

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

            RoomScanView()
                .tabItem { Label("房间扫描", systemImage: "cube.transparent") }
                .tag(Tab.scan)

            LogView()
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }
                .tag(Tab.log)
        }
        .onChange(of: tab) { newValue in
            AppLog.tap("切换页面", Self.name(of: newValue))
        }
        .onAppear {
            AppLog.i("应用", "启动")
        }
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
