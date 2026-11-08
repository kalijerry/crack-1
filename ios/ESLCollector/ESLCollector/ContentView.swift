import SwiftUI

/// 功能开关。现在只做地磁定位，蓝牙相关的页面（蓝牙采集、蓝牙定位、指纹库 / 信标数据）先藏起来；
/// 代码都还在，改成 true 就回来（入口在「设置 → 开发者」）。
enum Features {
    static let bluetooth = false
}

/// 两种模式：
/// - 普通模式（默认）：只用云端（GitHub Actions）生成的地图（带版本号），能采集（自动上传）、定位、导航；
/// - 开发者模式：全部功能——本机生成地图、选采集记录、导入各种数据、扫房间、实验功能、上传本机版本。
@MainActor
final class AppMode: ObservableObject {
    static let shared = AppMode()
    @Published var developer: Bool = UserDefaults.standard.bool(forKey: "developerMode") {
        didSet {
            UserDefaults.standard.set(developer, forKey: "developerMode")
            AppLog.i("应用", developer ? "切到开发者模式" : "切到普通模式")
            if !developer { MapLibrary.shared.ensureCloudActive() }
        }
    }
}

/// 一级页面。顺序见 docs/uiux-redesign.md：导航 → 建图 → 地图库 → 设置（开发者区域在设置里）。
enum AppTab: String, Hashable {
    case navigate, mapping, library, settings

    var title: String {
        switch self {
        case .navigate: return "导航"
        case .mapping: return "建图"
        case .library: return "地图库"
        case .settings: return "设置"
        }
    }
}

struct ContentView: View {
    @State private var tab: AppTab = DemoMode.initialTab.flatMap(AppTab.init(rawValue:)) ?? .navigate
    @ObservedObject private var storeData = StoreDataStore.shared
    @ObservedObject private var store = MagMapStore.shared

    var body: some View {
        TabView(selection: $tab) {
            NavigateView(tab: $tab)
                .tabItem { Label(AppTab.navigate.title, systemImage: "location.north.circle.fill") }
                .tag(AppTab.navigate)

            MappingView(tab: $tab)
                .tabItem { Label(AppTab.mapping.title, systemImage: "figure.walk.motion") }
                .tag(AppTab.mapping)

            LibraryView(tab: $tab)
                .tabItem { Label(AppTab.library.title, systemImage: "map") }
                .tag(AppTab.library)

            SettingsView(tab: $tab)
                .tabItem { Label(AppTab.settings.title, systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onChange(of: tab) { newValue in
            Haptics.selection()
            AppLog.tap("切换页面", newValue.title)
        }
        .onAppear {
            AppLog.i("应用", "启动")
            _ = MapLibrary.shared          // 第一次用：把现在的地图收进地图库
            AppEngines.shared.prepareIfNeeded()
        }
        // 换地图 / 地图内容更新：所有页面共用的引擎一起刷新
        .onChange(of: storeData.mapSignature) { _ in
            Telemetry.shared.mapChanged()
            AppEngines.shared.survey.coverage.invalidate()
            AppEngines.shared.refreshForMap()
        }
        // 通道变了（装上云端新版本）：重建覆盖网格
        .onChange(of: store.crosses.count) { _ in AppEngines.shared.configureCoverage() }
        // 启动时拉一次云端：普通模式自动装上云端正式地图，重装 App 后打开就有
        .task { if !DemoMode.isOn { await CloudMaps.shared.refresh() } }
    }
}
