import HPASSKit
import SwiftUI

/// 一张地图的详情：预览、使用、接着扫 / 重扫、扫描段（启用 / 关掉 / 删除 / 改名）、房间类别和名称、导出、改名、删除。
/// 两种模式都能用。
struct MapDetailView: View {
    let mapId: String

    @ObservedObject private var lib = MapLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var map: StoreMap?
    @State private var unitCount = 0
    @State private var registry: ScanRegistry?
    @State private var error: String?
    @State private var scanTarget: ScanTarget?
    @State private var renaming = false
    @State private var newName = ""
    @State private var renamingScan: ScanRegistry.ScanRecord?
    @State private var scanName = ""
    @State private var confirmDelete: MapLibrary.Entry?
    @State private var confirmScanDelete: ScanRegistry.ScanRecord?

    private var entry: MapLibrary.Entry? { lib.entries.first { $0.id == mapId } }
    private var busy: Bool { AppEngines.shared.magnetic.phase != .idle || AppEngines.shared.survey.isRunning }

    var body: some View {
        Group {
            if let e = entry {
                list(e)
            } else {
                EmptyStateView(systemImage: "trash", title: "这张地图已经删除", message: "回到地图库看其他地图。")
            }
        }
        .navigationTitle(entry?.name ?? "地图")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: lib.geometryRevision) { _ in load() }
        .sheet(item: $scanTarget, onDismiss: load) { t in RoomScanView(target: t) }
        .alert("重命名地图", isPresented: $renaming) {
            TextField("名字", text: $newName)
            Button("保存") { lib.rename(mapId, to: newName) }
            Button("取消", role: .cancel) {}
        }
        .alert("扫描段改名", isPresented: Binding(get: { renamingScan != nil }, set: { if !$0 { renamingScan = nil } })) {
            TextField("名字", text: $scanName)
            Button("保存") {
                if let s = renamingScan { run { try lib.renameScan(mapId, s.id, scanName) } }
                renamingScan = nil
            }
            Button("取消", role: .cancel) { renamingScan = nil }
        }
        .confirmationDialog("删除这一段扫描？", isPresented: Binding(get: { confirmScanDelete != nil },
                                                             set: { if !$0 { confirmScanDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除这一段", role: .destructive) {
                if let s = confirmScanDelete { run { try lib.removeScan(mapId, s.id) } }
                confirmScanDelete = nil
            }
        } message: {
            Text("这一段扫到的墙、门窗、家具、房间从地图里去掉（被它替换掉的旧内容会回来），原始扫描文件也删掉，不能恢复。只是暂时不要的话，用开关关掉就行。")
        }
        .mapDeleteConfirmation($confirmDelete) { dismiss() }
    }

    private func load() {
        let json = try? Data(contentsOf: lib.mapURL(mapId))
        map = json.flatMap { try? StoreDataLoader.loadMap($0) }
        unitCount = json.map { RoomMapBuilder.units($0).count } ?? 0
        // 房间地图第一次打开详情：老地图在这里生成注册表（当前地图记为基准段）
        if entry?.isRoom == true || lib.storedRegistry(mapId) != nil {
            registry = try? lib.registry(mapId)
        } else {
            registry = nil
        }
    }

    private func run(_ f: () throws -> Void) {
        do {
            try f()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        load()
    }

    @ViewBuilder private func list(_ e: MapLibrary.Entry) -> some View {
        List {
            Section {
                if let m = map {
                    MapCanvas(map: m, fingerprints: [], showFingerprints: false, productStyle: true, showsResetButton: false,
                              accessibilitySummary: "地图预览")
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                        .allowsHitTesting(false)
                        .listRowInsets(EdgeInsets())
                }
                LabeledContent("来源", value: MapLibrarySection.originText(e))
                LabeledContent("版本", value: MapLibrarySection.versionText(e))
                if let m = map {
                    LabeledContent("范围", value: "\(Fmt.f(m.width / 100, 1)) × \(Fmt.f(m.height / 100, 1)) m")
                }
                if e.id == lib.activeId {
                    Label("正在使用", systemImage: "checkmark.circle.fill").foregroundStyle(DS.Palette.success)
                } else {
                    Button {
                        run { try lib.activate(mapId) }
                        Haptics.success()
                    } label: {
                        Label("使用这张地图", systemImage: "arrow.triangle.swap")
                    }
                    .disabled(busy)
                }
            }

            if e.isRoom {
                Section {
                    Button { scanTarget = .append(mapId) } label: {
                        DSRowLabel(title: "接着扫（扩大范围）", systemImage: "plus.viewfinder", tint: DS.Palette.mapping,
                                   subtitle: "先在已扫过的地方认出位置，再走到新房间扫")
                    }
                    .foregroundStyle(DS.Palette.textPrimary)
                    Button { scanTarget = .append(mapId) } label: {
                        DSRowLabel(title: "重扫某块（精细化）", systemImage: "viewfinder.rectangular", tint: .teal,
                                   subtitle: "慢一点、贴近墙面和家具再扫一遍，合并时选「替换这块」")
                    }
                    .foregroundStyle(DS.Palette.textPrimary)
                    .disabled(busy)
                } header: { Text("扫描") } footer: {
                    Text("从已经扫过的地方开始（站在扫过的房间里转一圈，等「已认出」）。认不出也能扫：把门口、走廊这些扫过的地方再扫一小段，扫完按墙和门自动对齐。每段扫完都先看合并预览、确认后才合进地图。")
                }
                .disabled(busy)

                if let r = registry { scansSection(r) }

                Section {
                    NavigationLink {
                        UnitEditorView(mapId: mapId) { load() }
                    } label: {
                        Label("房间类别和名称（\(unitCount) 个房间）", systemImage: "square.split.2x2")
                    }
                }
            }

            Section {
                ShareLink(item: lib.mapURL(mapId)) { Label("导出地图（JSON）", systemImage: "square.and.arrow.up") }
                Button { newName = e.name; renaming = true } label: { Label("重命名", systemImage: "pencil") }
                Button(role: .destructive) { confirmDelete = e } label: { Label("删除这张地图", systemImage: "trash") }
                    .disabled(busy && e.id == lib.activeId)
                if let err = error ?? lib.lastError { ErrorBanner(message: err) }
            } footer: {
                Text("删除会删掉地图、扫描段和这张地图的建图进度、定位数据；采集记录保留。云端的地图不会被删，但不再自动下载到这台手机。")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func scansSection(_ r: ScanRegistry) -> some View {
        let enabledCount = r.scans.filter(\.enabled).count
        return Section {
            ForEach(Array(r.ordered.enumerated()), id: \.element.id) { i, s in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { s.enabled }, set: { on in run { try lib.setScanEnabled(mapId, s.id, on) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("第 \(i + 1) 段" + (s.name.map { "：\($0)" } ?? "")).font(.body.weight(.medium))
                            Text(Self.scanDetail(s)).font(.caption).foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .disabled(busy || (s.enabled && enabledCount <= 1))
                }
                .swipeActions {
                    if r.scans.count > 1 && !(s.enabled && enabledCount <= 1) {
                        Button("删除", role: .destructive) { confirmScanDelete = s }
                    }
                    Button("改名") { scanName = s.name ?? ""; renamingScan = s }.tint(DS.Palette.info)
                }
            }
        } header: {
            Text("扫描段（\(r.scans.count)）")
        } footer: {
            Text("每次扫描是一段，按时间顺序合成这张地图。关掉一段 = 撤销那次扫描：它加的东西消失，被它替换掉的旧内容回来；再打开就恢复。左滑可以改名或删除。地图变了之后本机的定位数据可能要重新采集。")
        }
    }

    /// 一段的说明：时间 · 房间数 · 对齐方式和偏差 · 合并方式
    static func scanDetail(_ s: ScanRegistry.ScanRecord) -> String {
        var parts: [String] = []
        if s.createdMs > 0 {
            let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
            parts.append(df.string(from: Date(timeIntervalSince1970: Double(s.createdMs) / 1000)))
        } else {
            parts.append("原有地图")
        }
        if let n = s.roomCount { parts.append("\(n) 个房间") }
        switch s.alignment {
        case .base: parts.append("基准")
        case .worldmap: parts.append("视觉认出")
        case .geometry: parts.append("墙和门自动对齐")
        case .manual: parts.append("手动对齐")
        }
        if let q = s.quality, s.alignment != .base {
            parts.append("重合 \(Fmt.f(q.overlapCm / 100, 1)) m · 偏差 \(Fmt.f(q.residualCm, 0)) cm")
        }
        if s.mode == .replace {
            parts.append("替换" + ((s.replaces?.isEmpty == false) ? "了 " + s.replaces!.joined(separator: "、") : "这块"))
        }
        if !s.enabled { parts.append("已关掉") }
        return parts.joined(separator: " · ")
    }
}
