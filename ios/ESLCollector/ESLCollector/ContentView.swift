import SwiftUI

struct ContentView: View {
    @State private var tab = Tab.collect

    enum Tab: Hashable {
        case collect, storeData, live, magnetic, log
    }

    var body: some View {
        TabView(selection: $tab) {
            CollectView()
                .tabItem { Label("采集", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.collect)

            StoreDataView()
                .tabItem { Label("门店数据", systemImage: "square.and.arrow.down") }
                .tag(Tab.storeData)

            LiveLocationView()
                .tabItem { Label("蓝牙定位", systemImage: "location.viewfinder") }
                .tag(Tab.live)

            MagneticView()
                .tabItem { Label("地磁定位", systemImage: "scope") }
                .tag(Tab.magnetic)

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
        case .log: return "日志"
        }
    }
}
