import HPASSKit
import SwiftUI

/// 「地图库」Tab：当前地图、本机地图、云端地图。
@MainActor
struct LibraryView: View {
    @Binding var tab: AppTab

    @ObservedObject private var lib = MapLibrary.shared
    @ObservedObject private var cloud = CloudMaps.shared
    @ObservedObject private var tel = Telemetry.shared
    @ObservedObject private var store = MagMapStore.shared
    @ObservedObject private var storeData = StoreDataStore.shared
    @ObservedObject private var mode = AppMode.shared

    @State private var renaming: MapLibrary.Entry?
    @State private var newName = ""
    @State private var switchError: String?
    @State private var confirmDelete: MapLibrary.Entry?

    private var demo: Bool { DemoMode.isOn }
    private var busy: Bool { AppEngines.shared.magnetic.phase != .idle || AppEngines.shared.survey.isRunning }

    var body: some View {
        NavigationStack {
            List {
                activeSection
                localSection
                cloudSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("地图库")
            .refreshable { await cloud.refresh() }
            .alert("重命名地图", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("名字", text: $newName)
                Button("保存") { if let r = renaming { lib.rename(r.id, to: newName) }; renaming = nil }
                Button("取消", role: .cancel) { renaming = nil }
            }
            .alert("没能切换地图", isPresented: Binding(get: { switchError != nil }, set: { if !$0 { switchError = nil } })) {
                Button("好") { switchError = nil }
            } message: { Text(switchError ?? "") }
            .mapDeleteConfirmation($confirmDelete)
        }
        .onAppear { Task { await cloud.refresh() } }
    }

    // MARK: 当前地图

    @ViewBuilder private var activeSection: some View {
        if demo || lib.active != nil {
            Section {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    MapCanvas(map: demo ? DemoMode.map : AppEngines.shared.canvasMap, fingerprints: [],
                              showFingerprints: false, productStyle: true, showsResetButton: false,
                              accessibilitySummary: "当前地图预览")
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                        .allowsHitTesting(false)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(demo ? "示例场地" : (lib.active?.name ?? "")).font(DS.Typography.title)
                            Text(demo ? "云端生成 · 11-08 09:30" : lib.active.map(MapLibrarySection.versionText) ?? "")
                                .font(.footnote).foregroundStyle(DS.Palette.textSecondary)
                        }
                        Spacer()
                        StatusPill(text: "在用", systemImage: "checkmark", tone: .success)
                    }
                    HStack {
                        MetricTile(value: Fmt.f((demo ? DemoMode.map.width : store.widthCm) / 100, 0) + "×"
                                   + Fmt.f((demo ? DemoMode.map.height : store.heightCm) / 100, 0),
                                   unit: "m", label: "范围")
                        MetricTile(value: demo || store.field != nil ? "可以" : "还不能",
                                   label: "自动定位",
                                   tint: demo || store.field != nil ? DS.Palette.success : DS.Palette.warning)
                        MetricTile(value: lib.active?.bleEnabled == false ? "关" : "开", label: "无线信号辅助")
                    }
                    if !demo && store.field == nil {
                        Text("这张地图还没有定位数据：到「建图」走一遍，或等云端生成后自动更新。")
                            .font(.footnote).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                .padding(.vertical, DS.Spacing.s)
            } header: { Text("当前地图") }
        }
    }

    // MARK: 本机

    @ViewBuilder private var localSection: some View {
        Section {
            if lib.visibleEntries.isEmpty && !demo {
                EmptyStateView(systemImage: "map",
                               title: "还没有地图",
                               message: tel.enabled ? "从下面的云端地图下载一张，或者到「建图」扫描生成。"
                                                    : "到「建图」用激光雷达扫描生成；或者在「设置 → 云端连接」里连上云端下载。",
                               actionTitle: tel.enabled ? nil : "打开设置",
                               action: tel.enabled ? nil : { tab = .settings })
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            ForEach(lib.visibleEntries) { e in
                entryRow(e)
            }
            if let err = lib.lastError { ErrorBanner(message: err) }
        } header: {
            Text("本机地图")
        } footer: {
            Text("每张地图有自己的定位数据和建图进度，切换不会互相覆盖。点一张地图看详情、接着扫、管理扫描段。左滑可以重命名、删除（在用的也能删，会先换到别的地图）或开关无线信号辅助。")
        }
    }

    private func entryRow(_ e: MapLibrary.Entry) -> some View {
        NavigationLink {
            MapDetailView(mapId: e.id)
        } label: {
            entryLabel(e)
        }
        .swipeActions {
            Button("删除", role: .destructive) { confirmDelete = e }
            Button("重命名") { renaming = e; newName = e.name }.tint(DS.Palette.info)
            Button(e.bleEnabled ? "关信号" : "开信号") { lib.setBLE(e.id, !e.bleEnabled) }.tint(DS.Palette.warning)
        }
    }

    private func entryLabel(_ e: MapLibrary.Entry) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: e.isRoom ? "cube.transparent" : "building.2")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(e.id == lib.activeId ? DS.Palette.accent : DS.Palette.textSecondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.name).font(.body.weight(e.id == lib.activeId ? .semibold : .regular))
                    Text(MapLibrarySection.originText(e))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background((e.isCloudFused ? DS.Palette.info : DS.Palette.mapping).opacity(0.15), in: Capsule())
                        .foregroundStyle(e.isCloudFused ? DS.Palette.info : DS.Palette.mapping)
                }
                Text((e.isRoom ? "房间" : "场地") + " · " + MapLibrarySection.versionText(e) + (e.bleEnabled ? "" : " · 不用无线信号"))
                    .font(.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            if e.id == lib.activeId {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.success)
                    .accessibilityLabel("在用")
            } else {
                Button("使用") {
                    do { try lib.activate(e.id); Haptics.success() } catch { switchError = error.localizedDescription }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: 云端

    @ViewBuilder private var cloudSection: some View {
        Section {
            if !tel.enabled {
                HStack(spacing: DS.Spacing.m) {
                    Image(systemName: "icloud.slash").font(.title3).foregroundStyle(DS.Palette.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未连接云端")
                        Text("连上后可以下载和自动更新地图").font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                    Spacer()
                    Button("设置") { tab = .settings }.buttonStyle(.bordered)
                }
            } else {
                if cloud.busy && cloud.list.isEmpty {
                    LoadingStateView(title: "正在读取云端地图").frame(maxWidth: .infinity)
                }
                ForEach(cloud.list) { c in
                    cloudRow(c)
                }
                if !cloud.busy && cloud.list.isEmpty {
                    Text("云端还没有地图。").foregroundStyle(DS.Palette.textSecondary)
                }
                if mode.developer {
                    Button { Task { await cloud.uploadActive() } } label: {
                        Label("上传本机生成的地图（临时版本）", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(cloud.busy || lib.activeId == nil || busy)
                }
                if let m = cloud.message {
                    Text(m).font(.footnote).foregroundStyle(DS.Palette.textSecondary)
                }
            }
        } header: {
            HStack {
                Text("云端地图")
                Spacer()
                if cloud.busy { ProgressView().controlSize(.small) }
            }
        } footer: {
            Text("正式地图由云端把所有采集记录合在一起生成；手机上已有的地图在云端更新后会自动更新。在这台手机上删掉的不会再自动下载，需要时点「重新下载」。下拉可刷新。")
        }
    }

    private func cloudRow(_ c: Telemetry.CloudMap) -> some View {
        let st = cloud.status(c)
        return HStack(spacing: DS.Spacing.m) {
            Image(systemName: c.kind == "room" ? "cube.transparent" : "building.2")
                .font(.title3).symbolRenderingMode(.hierarchical).foregroundStyle(DS.Palette.info)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name.isEmpty ? c.id : c.name)
                Text((c.isCloudFused ? "云端生成 " : "手机上传 ") + CloudMapsSection.date(c.version)
                     + (c.sessions.map { $0 > 0 ? " · \($0) 次采集" : "" } ?? "")
                     + " · \(max(c.size / 1024, 1)) KB")
                    .font(.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            if let a = st.action {
                VStack(alignment: .trailing, spacing: 2) {
                    Button(a) {
                        Haptics.tap()
                        Task { await cloud.download(c) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cloud.busy || busy)
                    if case .deleted = st {
                        Text(st.text).font(.caption2).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
            } else {
                Text(st.text).font(.caption.weight(.semibold))
                    .foregroundStyle(st == .latest ? DS.Palette.success : DS.Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
