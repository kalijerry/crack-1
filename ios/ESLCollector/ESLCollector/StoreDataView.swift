import SwiftUI
import UniformTypeIdentifiers

/// 门店数据页：查看本地状态、从自建服务器下载、或离线从「文件」App 导入。
///
/// 服务器地址、路径、门店编码等全部由用户在此页填写；代码里不含任何地址或密钥。
/// 凭据默认只存在内存里，只有打开「记住凭据」才写入钥匙串。
@MainActor
struct StoreDataView: View {
    @ObservedObject private var store = StoreDataStore.shared

    // 服务器配置（非敏感，持久化在 UserDefaults）
    @State private var config = ServerConfig.load()
    // 凭据：默认仅内存
    @State private var username = ""
    @State private var credential = ""
    @State private var remember = false

    @State private var inFlight = false
    @State private var results: [String: DownloadResult] = [:]
    @State private var formErrors: [String] = []
    @State private var showIssues = false
    @State private var loaded = false

    @State private var importing = false
    @State private var importKind: StoreDataStore.FileKind = .map
    @State private var importError: String?
    @State private var confirmClearAll = false

    private struct DownloadResult {
        var ok: Bool
        var text: String
    }

    private static let rememberKey = "storeData.rememberCredential"
    private static let userKey = "storeData.username"
    private static let credKey = "storeData.credential"

    var body: some View {
        Form {
            MapLibrarySection()
            CloudMapsSection()
            EslListSection()
            TelemetrySection()
            statusSection
            if Features.bluetooth { selfCheckSection }
            serverSection
            importSection
        }
        .navigationTitle("门店数据")
        .scrollDismissesKeyboard(.interactively)
        .onAppear(perform: loadOnce)
        .onChange(of: config) { newValue in
            newValue.persist()
        }
        .onChange(of: username) { newValue in
            if remember { Keychain.set(newValue, for: Self.userKey) }
        }
        .onChange(of: credential) { newValue in
            if remember { Keychain.set(newValue, for: Self.credKey) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .confirmationDialog("确定清空全部门店数据？", isPresented: $confirmClearAll, titleVisibility: .visible) {
            LoggedButton("清空全部", role: .destructive) {
                store.deleteAll()
                results = [:]
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 状态

    private var statusSection: some View {
        Section {
            ForEach(StoreDataStore.FileKind.visible) { kind in
                fileRow(kind)
            }
            HStack {
                Text("整体状态")
                Spacer()
                if Features.bluetooth ? store.isReady : store.map != nil {
                    Text("就绪").foregroundStyle(.green)
                } else {
                    Text("数据不完整").foregroundStyle(.orange)
                }
            }
            if let err = store.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("状态")
        } footer: {
            Text(Features.bluetooth ? "三个文件存放在 App 的 Documents/store-data 目录，也可以用「文件」App 直接放入。"
                                    : "地图文件存放在 App 的 Documents/store-data 目录，也可以用「文件」App 直接放入。")
        }
    }

    private func fileRow(_ kind: StoreDataStore.FileKind) -> some View {
        let info = store.files[kind.rawValue]
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(kind.title)
                Spacer()
                Text(info?.summary ?? "未导入")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if let info, info.exists {
                Text("\(Self.bytesText(info.bytes)) · \(Self.dateText(info.modified))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let e = info?.error, !e.isEmpty {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            if let r = results[kind.rawValue] {
                Text(r.text)
                    .font(.caption)
                    .foregroundStyle(r.ok ? .green : .red)
            }
        }
    }

    // MARK: 自检

    private var selfCheckSection: some View {
        Section("自检") {
            if store.issues.isEmpty {
                if store.isReady {
                    Text("通过").foregroundStyle(.green)
                } else {
                    Text("数据不完整，暂未自检").foregroundStyle(.secondary)
                }
            } else {
                LoggedButton(name: showIssues ? "收起问题列表" : "展开问题列表",
                             detail: "\(store.issues.count) 个") {
                    showIssues.toggle()
                } label: {
                    HStack {
                        Text("发现 \(store.issues.count) 个问题").foregroundStyle(.orange)
                        Spacer()
                        Image(systemName: showIssues ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                }
                if showIssues {
                    ForEach(Array(store.issues.enumerated()), id: \.offset) { pair in
                        Text(pair.element)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 服务器

    private var serverSection: some View {
        Section {
            urlFields
            authFields
            Toggle("允许自签名证书（不校验 TLS）", isOn: $config.allowInsecureTLS)
                .onChange(of: config.allowInsecureTLS) { on in
                    AppLog.tap("允许自签名证书", on ? "开" : "关")
                    if on { AppLog.w("门店下载", "已开启跳过 TLS 校验，仅限内网自建服务器") }
                }
            downloadControls
        } header: {
            Text("服务器")
        } footer: {
            Text("路径可填相对路径或完整地址，支持占位符 {store} {floor}。"
                 + "「允许自签名证书」会关闭 TLS 校验，只在确认是公司内网服务器时打开。"
                 + "凭据默认只保存在内存，关掉 App 即丢失。")
        }
    }

    private var urlFields: some View {
        Group {
            TextField("服务器地址（https://…）", text: $config.baseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("地图接口路径", text: $config.mapPath)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("指纹库接口路径", text: $config.fingerprintPath)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("价签/商品接口路径", text: $config.eslPath)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("门店编码（{store}）", text: $config.storeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("楼层 ID（{floor}）", text: $config.floorId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var authFields: some View {
        Group {
            Picker("鉴权方式", selection: $config.authMode) {
                ForEach(AuthMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .onChange(of: config.authMode) { mode in
                AppLog.tap("鉴权方式", mode.title)
            }
            if config.authMode.needsName {
                TextField(config.authMode == .query ? "查询参数名" : "请求头名称",
                          text: $config.authHeaderName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if config.authMode.needsUsername {
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if config.authMode != .none {
                SecureField("凭据 / 令牌 / 密码", text: $credential)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("附加请求头（每行 Name: Value）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $config.extraHeadersText)
                    .frame(minHeight: 72)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Toggle("记住凭据（写入钥匙串）", isOn: $remember)
                .onChange(of: remember) { on in
                    AppLog.tap("记住凭据", on ? "开" : "关")
                    applyRemember(on)
                }
        }
    }

    private var downloadControls: some View {
        Group {
            if !formErrors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(formErrors.enumerated()), id: \.offset) { pair in
                        Text(pair.element).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            if inFlight {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("下载中…").foregroundStyle(.secondary)
                }
            }
            LoggedButton(name: "下载全部") {
                download(StoreDataStore.FileKind.visible)
            } label: {
                Text("下载全部").frame(maxWidth: .infinity).fontWeight(.semibold)
            }
            .disabled(inFlight)

            VStack(alignment: .leading, spacing: 6) {
                Text("分别下载每一项").font(.caption).foregroundStyle(.secondary)
                ForEach(StoreDataStore.FileKind.visible) { kind in
                    LoggedButton(name: "下载\(kind.title)", detail: kind.rawValue) {
                        download([kind])
                    } label: {
                        HStack {
                            Text("下载 \(kind.title)")
                            Spacer()
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                    .disabled(inFlight)
                }
            }

            LoggedButton(name: "清空凭据", role: .destructive) {
                clearCredentials()
            } label: {
                Text("清空凭据").foregroundStyle(.red)
            }
            .disabled(inFlight)
        }
    }

    // MARK: 本地导入

    private var importSection: some View {
        Section {
            if let importError {
                Text(importError).font(.caption).foregroundStyle(.red)
            }
            ForEach(StoreDataStore.FileKind.visible) { kind in
                HStack {
                    Text(kind.title)
                    Spacer()
                    LoggedButton(name: "导入文件", detail: kind.rawValue) {
                        importKind = kind
                        importError = nil
                        importing = true
                    } label: {
                        Text("导入")
                    }
                    .buttonStyle(.bordered)
                    .disabled(inFlight)
                    LoggedButton(name: "删除文件", detail: kind.rawValue, role: .destructive) {
                        store.delete(kind)
                        results[kind.rawValue] = nil
                    } label: {
                        Text("删除").foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!(store.files[kind.rawValue]?.exists ?? false) || inFlight)
                }
            }
            LoggedButton(name: "全部清空", role: .destructive) {
                confirmClearAll = true
            } label: {
                Text("全部清空").foregroundStyle(.red)
            }
            .disabled(inFlight)
        } header: {
            Text("本地导入")
        } footer: {
            Text("没有网络时，可以把导出的 .json 文件通过「文件」App 选入，三项可分别导入。")
        }
    }

    // MARK: 动作

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        remember = UserDefaults.standard.bool(forKey: Self.rememberKey)
        if remember {
            username = Keychain.get(Self.userKey) ?? ""
            credential = Keychain.get(Self.credKey) ?? ""
            AppLog.i("门店数据", "已从钥匙串恢复凭据：\(credential.isEmpty ? "未设置" : "已设置")")
        }
        store.reload()
    }

    private func applyRemember(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.rememberKey)
        if on {
            Keychain.set(username, for: Self.userKey)
            Keychain.set(credential, for: Self.credKey)
            AppLog.i("门店数据", "凭据已写入钥匙串（仅本机、解锁后可读）")
        } else {
            Keychain.remove(Self.userKey)
            Keychain.remove(Self.credKey)
            AppLog.i("门店数据", "已从钥匙串移除凭据，凭据仅保留在内存")
        }
    }

    private func clearCredentials() {
        username = ""
        credential = ""
        Keychain.remove(Self.userKey)
        Keychain.remove(Self.credKey)
        AppLog.i("门店数据", "已清空内存与钥匙串中的凭据")
    }

    private func download(_ kinds: [StoreDataStore.FileKind]) {
        let issues = StoreDataClient.validationIssues(for: kinds, config: config)
        formErrors = issues
        guard issues.isEmpty else {
            AppLog.w("门店下载", "配置自检未通过：\(issues.count) 项")
            return
        }
        for kind in kinds { results[kind.rawValue] = nil }
        inFlight = true
        let cfg = config
        let cred = credential
        let user = username
        Task { @MainActor in
            let out = await StoreDataClient.shared.fetchAll(kinds, config: cfg,
                                                            credential: cred, username: user)
            for kind in kinds {
                guard let r = out[kind] else { continue }
                switch r {
                case .success(let data):
                    do {
                        try store.save(data, as: kind)
                        results[kind.rawValue] = DownloadResult(
                            ok: true, text: "已下载 \(Self.bytesText(Int64(data.count)))")
                    } catch {
                        results[kind.rawValue] = DownloadResult(
                            ok: false, text: "保存失败：\(error.localizedDescription)")
                        AppLog.e("门店下载", "\(kind.title) 保存失败：\(error.localizedDescription)")
                    }
                case .failure(let err):
                    results[kind.rawValue] = DownloadResult(ok: false, text: err.localizedDescription)
                }
            }
            inFlight = false
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try store.importFile(at: url, as: importKind)
                importError = nil
                results[importKind.rawValue] = DownloadResult(ok: true, text: "已从文件导入")
            } catch {
                importError = "\(importKind.title) 导入失败：\(error.localizedDescription)"
                AppLog.e("门店数据", "导入失败：\(error.localizedDescription)")
            }
        case .failure(let err):
            importError = "选择文件失败：\(err.localizedDescription)"
        }
    }

    // MARK: 格式化

    private static func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "时间未知" }
        return dateFormatter.string(from: date)
    }
}

/// 云端后台设置：地址、口令、开关、状态
struct TelemetrySection: View {
    @ObservedObject private var tel = Telemetry.shared
    @State private var token = Telemetry.shared.token

    var body: some View {
        Section {
            TextField("后台地址，例如 hpass-telemetry.xxx.workers.dev", text: $tel.serverURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("口令", text: $token)
                .onSubmit { tel.token = token }
                .onChange(of: token) { tel.token = $0 }
            Toggle("连接后台（实时日志和定位状态）", isOn: $tel.enabled)
            Toggle("采集结束自动上传会话", isOn: $tel.autoUpload)
            HStack {
                Text("状态")
                Spacer()
                Text(tel.statusText).font(.footnote).foregroundStyle(tel.status == .connected ? .green : .secondary)
            }
            if tel.queued > 0 { Text("待发 \(tel.queued) 条（断网时攒着，连上补发）").font(.caption).foregroundStyle(.secondary) }
            if let u = tel.lastUpload { Text(u).font(.caption).foregroundStyle(.secondary) }
            Text("设备名：\(tel.deviceName)").font(.caption).foregroundStyle(.secondary)
        } header: { Text("云端后台") } footer: {
            Text("在电脑浏览器打开后台地址、输入同一个口令，就能实时看到这台手机的位置、日志，下载上传的会话和评估报告。只在 App 打开时发送。")
        }
    }
}

/// 价签名单：蓝牙粗定位只认名单里的价签（门店系统导出的价签 ID 列表）
struct EslListSection: View {
    @ObservedObject private var store = StoreDataStore.shared
    @State private var importing = false
    @State private var importingLoc = false
    @State private var message: String?

    var body: some View {
        Section {
            HStack {
                Text("价签位置表")
                Spacer()
                Text(store.eslLocCount > 0 ? "\(store.eslLocCount) 个（对上货架 \(store.eslLocations.filter { $0.position != nil }.count) 个）" : "未导入")
                    .foregroundStyle(.secondary).font(.footnote)
            }
            Button("导入价签位置表（esl_locations_*.csv）") { importingLoc = true }
            HStack {
                Text("价签名单")
                Spacer()
                Text(store.eslIdCount > 0 ? "\(store.eslIdCount) 个" : "未导入").foregroundStyle(.secondary)
            }
            Button("导入价签名单（CSV / TXT）") { importing = true }
            if store.eslIdCount > 0 {
                Button("清除名单", role: .destructive) { store.clearEslIds() }
            }
            if let m = message { Text(m).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("蓝牙") } footer: {
            Text("价签位置表（门店系统导出的 esl_locations_*.csv）：每个价签在哪个通道、段、层，对上地图货架后当蓝牙定位的底图（全店不用采集也有粗定位，实测中位 1.6～3.4 m），也能在「定位 → 找价签」里找具体价签；导入时自动当价签名单，并传到后台给云端融合用。价签广播用厂商 ID 0x000D、内容是 4 字节价签编号，App 只收这种广播。")
        }
        .fileImporter(isPresented: $importingLoc, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { r in
            switch r {
            case .success(let u):
                do { let (n, s) = try store.importEslLocations(from: u); message = "已导入 \(n) 个价签，\(s) 个对上了地图货架" }
                catch { message = "导入失败：\(error)" }
            case .failure(let e): message = "导入失败：\(e.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .json]) { r in
            switch r {
            case .success(let u):
                do { message = "已导入 \(try store.importEslIds(from: u)) 个价签" } catch { message = "导入失败：\(error)" }
            case .failure(let e): message = "导入失败：\(e.localizedDescription)"
            }
        }
    }
}
