import SwiftUI

/// 「设置」Tab：云端连接、诊断、开发者区域、关于。
///
/// 原来散在各页的调试功能都收进「开发者」，打开开发者模式后才出现。
@MainActor
struct SettingsView: View {
    @Binding var tab: AppTab

    @ObservedObject private var mode = AppMode.shared
    @ObservedObject private var tel = Telemetry.shared
    @ObservedObject private var log = AppLog.shared

    @State private var showRoomScan = false
    @State private var showBLECollect = false
    @State private var showBLELive = false

    var body: some View {
        NavigationStack {
            Form {
                cloudSection
                positioningSection
                diagnosticsSection
                developerSection
                aboutSection
            }
            .navigationTitle("设置")
        }
        .sheet(isPresented: $showRoomScan) { RoomScanView() }
        .sheet(isPresented: $showBLECollect) { CollectView() }
        .sheet(isPresented: $showBLELive) { LiveLocationView() }
    }

    // MARK: 云端

    private var cloudSection: some View {
        Section {
            NavigationLink {
                Form { TelemetrySection() }
                    .navigationTitle("云端连接")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                HStack {
                    DSRowLabel(title: "云端连接", systemImage: "icloud", tint: DS.Palette.info,
                               subtitle: tel.enabled ? tel.statusText : "未连接")
                    Spacer()
                    StatusPill(text: tel.status == .connected ? "已连接" : (tel.enabled ? "连接中" : "关闭"),
                               tone: tel.status == .connected ? .success : (tel.enabled ? .info : .neutral))
                }
            }
            Toggle(isOn: $tel.autoUpload) {
                DSRowLabel(title: "采集结束自动上传", systemImage: "arrow.up.circle", tint: DS.Palette.success)
            }
            .disabled(!tel.enabled)
        } header: {
            Text("云端")
        } footer: {
            Text("连上云端后，地图会自动下载和更新，采集记录会自动上传、由云端生成正式地图。")
        }
    }

    // MARK: 定位

    @ObservedObject private var magnetic = AppEngines.shared.magnetic
    @AppStorage("backgroundPositioning") private var backgroundPositioning = true
    @AppStorage("carryMotionEnabled") private var carryMotionEnabled = true

    private var positioningSection: some View {
        Section {
            Toggle(isOn: $backgroundPositioning) {
                DSRowLabel(title: "锁屏后继续定位", systemImage: "lock.iphone", tint: DS.Palette.success,
                           subtitle: "手机放口袋、按侧键锁屏也不中断")
            }
            Toggle(isOn: $carryMotionEnabled) {
                DSRowLabel(title: "按携带方式调整", systemImage: "figure.walk", tint: DS.Palette.info,
                           subtitle: "认出看屏 / 口袋 / 包里 / 打电话 / 甩手，分别处理（实验，下次开始定位生效）")
            }
            Toggle(isOn: $magnetic.visualEnhancement) {
                DSRowLabel(title: "视觉增强", systemImage: "camera.viewfinder", tint: DS.Palette.info,
                           subtitle: "可选：竖着拿时用摄像头认房间")
            }
        } header: {
            Text("定位")
        } footer: {
            Text("定位不需要摄像头，只靠运动传感器和地磁。拿在手里看屏最准；口袋、包里、打电话、甩手走时靠「按携带方式调整」，这些方式还在实测验证中。蓝牙标签只在 App 前台时扫描，锁屏后用不上。锁屏后继续定位要用到位置权限（只用最低精度保持 App 运行，不读取经纬度），状态栏会显示定位图标，会多耗一些电；不需要时可以关掉。视觉增强默认关，打开后只在手机竖着拿时开摄像头，认出房间时当一次位置参考，更耗电发热。")
        }
    }

    // MARK: 诊断

    private var diagnosticsSection: some View {
        Section("诊断") {
            NavigationLink {
                AccuracyTestView(survey: AppEngines.shared.survey, mapService: AppEngines.shared.mapService) {
                    startAccuracyTest()
                }
            } label: {
                DSRowLabel(title: "精度测试", systemImage: "scope", tint: .purple, subtitle: "走一圈测试路线，看定位准不准")
            }
            NavigationLink {
                OfficeCarryTestView { tab = .mapping }
            } label: {
                DSRowLabel(title: "双机测试", systemImage: "iphone.gen3.radiowaves.left.and.right", tint: .orange,
                           subtitle: "盲测机 + 伴随真值机，办公室携带方式测试")
            }
            NavigationLink {
                DataManagerView()
            } label: {
                DSRowLabel(title: "数据管理", systemImage: "externaldrive", tint: DS.Palette.neutral, subtitle: "采集记录、定位轨迹")
            }
            NavigationLink {
                LogView()
            } label: {
                DSRowLabel(title: "运行日志", systemImage: "list.bullet.rectangle", tint: DS.Palette.neutral,
                           subtitle: "\(log.entries.count) 条")
            }
        }
    }

    /// 精度测试：走一段不参与建图的测试路线，切到「建图」页显示进度
    private func startAccuracyTest() {
        let survey = AppEngines.shared.survey
        AppEngines.shared.accuracyTestRunning = true
        survey.isTestSession = true
        survey.evaluate = MagMapStore.shared.field != nil
        survey.start(note: "精度测试")
        if !survey.isRunning {
            AppEngines.shared.accuracyTestRunning = false
            survey.isTestSession = false
            Haptics.error()
        } else {
            tab = .mapping
        }
    }

    // MARK: 开发者

    @ViewBuilder private var developerSection: some View {
        Section {
            Toggle(isOn: $mode.developer) {
                DSRowLabel(title: "开发者模式", systemImage: "hammer", tint: DS.Palette.warning)
            }
            if mode.developer {
                NavigationLink {
                    MagneticView()
                } label: {
                    DSRowLabel(title: "高级控制台", systemImage: "slider.horizontal.below.square.and.square.filled",
                               tint: DS.Palette.mapping, subtitle: "点位、朝向、本机生成地图、3D / AR 校对、实验功能")
                }
                NavigationLink {
                    StoreDataView()
                } label: {
                    DSRowLabel(title: "场地数据与导入", systemImage: "square.and.arrow.down", tint: DS.Palette.info,
                               subtitle: "地图文件、服务器下载、蓝牙标签列表")
                }
                Button { showRoomScan = true } label: {
                    DSRowLabel(title: "房间扫描", systemImage: "cube.transparent", tint: .teal, subtitle: "激光雷达扫描生成房间地图")
                }
                .foregroundStyle(DS.Palette.textPrimary)
                if Features.bluetooth {
                    Button { showBLECollect = true } label: {
                        DSRowLabel(title: "蓝牙信号采集", systemImage: "antenna.radiowaves.left.and.right", tint: DS.Palette.info)
                    }
                    .foregroundStyle(DS.Palette.textPrimary)
                    Button { showBLELive = true } label: {
                        DSRowLabel(title: "蓝牙定位", systemImage: "location.viewfinder", tint: DS.Palette.info)
                    }
                    .foregroundStyle(DS.Palette.textPrimary)
                }
            }
        } header: {
            Text("开发者")
        } footer: {
            Text(mode.developer
                 ? "开发者模式：可以用本机生成的地图、导入数据、扫描房间和查看原始传感器数据。"
                 : "普通模式只使用云端生成的正式地图。打开开发者模式可以看到调试和实验功能。")
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text(Self.version).foregroundStyle(DS.Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("只用手机的室内定位").font(.callout.weight(.semibold))
                Text("地磁 + 惯性导航 + 视觉融合，蓝牙信标可选增强，不需要额外安装硬件。")
                    .font(.footnote).foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(.vertical, 2)
            NavigationLink {
                ScrollView {
                    PermissionExplainer(items: PermissionExplainer.positioning).padding(DS.Spacing.l)
                }
                .navigationTitle("权限说明")
            } label: {
                DSRowLabel(title: "权限说明", systemImage: "hand.raised", tint: DS.Palette.success)
            }
        } header: { Text("关于") }
    }

    private static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(v) (\(b))"
    }
}
