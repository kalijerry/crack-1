import Foundation

// MARK: - 鉴权方式

/// 鉴权方式。具体的头名 / 参数名由用户在界面上填写，代码里不写死任何服务端约定。
enum AuthMode: String, Codable, CaseIterable {
    case none, bearer, header, basic, query

    var title: String {
        switch self {
        case .none: return "无"
        case .bearer: return "Bearer 令牌"
        case .header: return "自定义请求头"
        case .basic: return "Basic（用户名+密码）"
        case .query: return "URL 查询参数"
        }
    }

    /// 是否需要填「头名 / 参数名」
    var needsName: Bool { self == .header || self == .query }

    /// 是否需要用户名
    var needsUsername: Bool { self == .basic }
}

// MARK: - 服务器配置

/// 服务器形态全部由用户在运行时填写，便于对接不同部署。
/// 本结构体只保存「非敏感」配置，持久化在 UserDefaults；凭据另走钥匙串。
struct ServerConfig: Codable, Equatable {
    var baseURL: String = ""            // 形如 https://…
    var mapPath: String = ""            // 路径或完整地址，可含 {store} {floor} 占位符
    var fingerprintPath: String = ""
    var eslPath: String = ""
    var storeCode: String = ""
    var floorId: String = ""
    var authMode: AuthMode = .none
    var authHeaderName: String = ""     // .header / .query 时使用
    var extraHeadersText: String = ""   // 每行一条 "Name: Value"
    var allowInsecureTLS: Bool = false  // 自签名内网服务器用，默认关

    func path(for kind: StoreDataStore.FileKind) -> String {
        switch kind {
        case .map: return mapPath
        case .fingerprint: return fingerprintPath
        case .esl: return eslPath
        }
    }

    // MARK: 持久化（只存配置，不含凭据）

    private static let defaultsKey = "storeData.serverConfig"

    static func load() -> ServerConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let cfg = try? JSONDecoder().decode(ServerConfig.self, from: data) else {
            return ServerConfig()
        }
        return cfg
    }

    func persist() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - 错误

enum StoreDataClientError: LocalizedError {
    case missingConfig(String)
    case badURL(String)
    case network(String)
    case httpStatus(Int, String)
    case emptyBody
    case notJSON(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingConfig(let what):
            return "配置不完整：\(what)"
        case .badURL(let s):
            return "地址无法解析：\(s)"
        case .network(let s):
            return "网络请求失败：\(s)"
        case .httpStatus(let code, let excerpt):
            return excerpt.isEmpty
                ? "服务器返回 HTTP \(code)"
                : "服务器返回 HTTP \(code)：\(excerpt)"
        case .emptyBody:
            return "服务器返回了空内容"
        case .notJSON(let s):
            return "返回内容不是合法 JSON：\(s)"
        case .cancelled:
            return "已取消"
        }
    }
}

// MARK: - 接受自签名证书的会话代理

/// 仅在用户显式打开「允许自签名证书」时使用的会话代理。
private final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    /// 由创建方决定；为 false 时走系统默认校验。
    let allowInsecure: Bool

    init(allowInsecure: Bool) {
        self.allowInsecure = allowInsecure
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard allowInsecure,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        AppLog.w("门店下载", "已跳过 TLS 证书校验（用户已开启自签名证书选项）")
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - 客户端

/// 门店数据下载客户端。所有服务端信息来自 `ServerConfig`，代码内不含任何地址或密钥。
final class StoreDataClient: @unchecked Sendable {
    static let shared = StoreDataClient()

    private static let timeout: TimeInterval = 60
    /// 出错时回显的响应体长度上限
    private static let excerptLimit = 400

    private let insecureSession: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = StoreDataClient.timeout
        cfg.timeoutIntervalForResource = StoreDataClient.timeout
        insecureSession = URLSession(configuration: cfg,
                                     delegate: InsecureTLSDelegate(allowInsecure: true),
                                     delegateQueue: nil)
    }

    deinit {
        insecureSession.finishTasksAndInvalidate()
    }

    // MARK: 下载

    /// 下载一项门店数据，返回原始字节，交给 `StoreDataStore.save(_:as:)` 落盘。
    func fetch(_ kind: StoreDataStore.FileKind,
               config: ServerConfig,
               credential: String,
               username: String) async throws -> Data {
        let template = config.path(for: kind)
        let request = try buildRequest(kind, config: config, credential: credential, username: username)
        let shape = Self.pathShape(template, config: config)
        AppLog.i("门店下载", "开始请求 \(Self.label(kind)) GET \(shape)" +
                 (credential.isEmpty ? "（无凭据）" : "（已设置凭据）"))

        let session = config.allowInsecureTLS ? insecureSession : URLSession.shared
        let started = Date()
        let received: (Data, URLResponse)
        do {
            received = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            AppLog.w("门店下载", "\(Self.label(kind)) 请求已取消")
            throw StoreDataClientError.cancelled
        } catch is CancellationError {
            AppLog.w("门店下载", "\(Self.label(kind)) 请求已取消")
            throw StoreDataClientError.cancelled
        } catch {
            AppLog.e("门店下载", "\(Self.label(kind)) 网络失败：\(error.localizedDescription)")
            throw StoreDataClientError.network(error.localizedDescription)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let data = received.0
        let status = (received.1 as? HTTPURLResponse)?.statusCode ?? 0
        AppLog.i("门店下载", "\(Self.label(kind)) HTTP \(status)，" +
                 "\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))，\(ms) ms")

        guard (200...299).contains(status) else {
            let excerpt = Self.excerpt(data)
            AppLog.e("门店下载", "\(Self.label(kind)) 状态码异常 HTTP \(status)：\(excerpt)")
            throw StoreDataClientError.httpStatus(status, excerpt)
        }
        do {
            try Self.sanityCheck(data, kind: kind)
        } catch {
            AppLog.e("门店下载", "\(Self.label(kind)) 内容校验失败：\(error.localizedDescription)")
            throw error
        }
        return data
    }

    /// 批量下载：逐项进行，允许部分成功。
    func fetchAll(_ kinds: [StoreDataStore.FileKind],
                  config: ServerConfig,
                  credential: String,
                  username: String) async -> [StoreDataStore.FileKind: Result<Data, Error>] {
        var out: [StoreDataStore.FileKind: Result<Data, Error>] = [:]
        for kind in kinds {
            do {
                let data = try await fetch(kind, config: config, credential: credential, username: username)
                out[kind] = .success(data)
            } catch {
                out[kind] = .failure(error)
            }
        }
        return out
    }

    // MARK: 请求构造

    func buildRequest(_ kind: StoreDataStore.FileKind,
                      config: ServerConfig,
                      credential: String,
                      username: String) throws -> URLRequest {
        let template = config.path(for: kind)
        var url = try Self.resolveURL(template: template, baseURL: config.baseURL,
                                      storeCode: config.storeCode, floorId: config.floorId)

        if config.authMode == .query, !config.authHeaderName.isEmpty, !credential.isEmpty {
            url = Self.appendingQuery(url, name: config.authHeaderName, value: credential)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = Self.timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        switch config.authMode {
        case .none, .query:
            break
        case .bearer:
            if !credential.isEmpty {
                req.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            }
        case .header:
            if !config.authHeaderName.isEmpty, !credential.isEmpty {
                req.setValue(credential, forHTTPHeaderField: config.authHeaderName)
            }
        case .basic:
            let raw = "\(username):\(credential)"
            if let d = raw.data(using: .utf8) {
                req.setValue("Basic \(d.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        for (name, value) in Self.parseHeaders(config.extraHeadersText) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        return req
    }

    /// 把模板解析成完整地址：支持「完整地址」或「相对路径 + 基地址」，并替换 {store} {floor}。
    static func resolveURL(template: String, baseURL: String,
                           storeCode: String, floorId: String) throws -> URL {
        let path = substitute(template.trimmingCharacters(in: .whitespacesAndNewlines),
                             storeCode: storeCode, floorId: floorId)
        guard !path.isEmpty else { throw StoreDataClientError.missingConfig("接口路径为空") }

        let lower = path.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let u = URL(string: path) else { throw StoreDataClientError.badURL(path) }
            return u
        }

        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw StoreDataClientError.missingConfig("服务器地址为空") }
        var trimmedBase = base
        while trimmedBase.hasSuffix("/") { trimmedBase.removeLast() }
        var suffix = path
        while suffix.hasPrefix("/") { suffix.removeFirst() }
        guard let u = URL(string: trimmedBase + "/" + suffix) else {
            throw StoreDataClientError.badURL(trimmedBase + "/" + suffix)
        }
        guard u.scheme != nil, u.host != nil else {
            throw StoreDataClientError.badURL("缺少协议或主机名")
        }
        return u
    }

    /// 替换 {store} {floor}，其余占位符原样保留。替换值做百分号编码。
    static func substitute(_ template: String, storeCode: String, floorId: String) -> String {
        var s = template
        s = s.replacingOccurrences(of: "{store}", with: encode(storeCode))
        s = s.replacingOccurrences(of: "{floor}", with: encode(floorId))
        return s
    }

    private static let allowed: CharacterSet =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func appendingQuery(_ url: URL, name: String, value: String) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: name, value: value))
        comps.queryItems = items
        return comps.url ?? url
    }

    /// 解析「每行一条 Name: Value」的附加请求头。
    static func parseHeaders(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty || value.isEmpty { continue }
            out.append((name, value))
        }
        return out
    }

    // MARK: 校验

    /// 落盘前的基本校验：非空 + 是合法 JSON。
    /// 指纹文件可能是「包着 JSON 的 JSON 字符串」，所以允许顶层为字符串片段，由 StoreDataLoader 再解一层。
    static func sanityCheck(_ data: Data, kind: StoreDataStore.FileKind) throws {
        guard !data.isEmpty else { throw StoreDataClientError.emptyBody }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw StoreDataClientError.notJSON("\(label(kind))：\(excerpt(data))")
        }
    }

    /// 下载前的配置自检，返回给界面展示的中文提示。
    static func validationIssues(for kinds: [StoreDataStore.FileKind], config: ServerConfig) -> [String] {
        var out: [String] = []
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsBase = kinds.contains { kind in
            let p = config.path(for: kind).lowercased()
            return !(p.hasPrefix("http://") || p.hasPrefix("https://"))
        }
        if needsBase {
            if base.isEmpty {
                out.append("服务器地址为空（或把接口路径填成完整地址）")
            } else if !(base.lowercased().hasPrefix("http://") || base.lowercased().hasPrefix("https://")) {
                out.append("服务器地址需以 http:// 或 https:// 开头")
            }
        }
        for kind in kinds {
            let p = config.path(for: kind).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty {
                out.append("\(label(kind)) 的接口路径为空")
                continue
            }
            if p.contains("{store}") && config.storeCode.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("\(label(kind)) 路径含 {store}，但门店编码为空")
            }
            if p.contains("{floor}") && config.floorId.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("\(label(kind)) 路径含 {floor}，但楼层 ID 为空")
            }
        }
        if config.authMode.needsName && config.authHeaderName.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append("当前鉴权方式需要填写请求头 / 参数名")
        }
        return out
    }

    // MARK: 工具

    static func label(_ kind: StoreDataStore.FileKind) -> String {
        switch kind {
        case .map: return "地图"
        case .fingerprint: return "指纹库"
        case .esl: return "价签/商品"
        }
    }

    /// 日志里只记录路径「形状」：保留占位符，并把已填的门店编码 / 楼层回写成占位符，
    /// 不输出完整地址，避免把门店标识写进日志。
    static func pathShape(_ template: String, config: ServerConfig) -> String {
        var s = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = config.storeCode.trimmingCharacters(in: .whitespaces)
        let floor = config.floorId.trimmingCharacters(in: .whitespaces)
        if !store.isEmpty { s = s.replacingOccurrences(of: store, with: "{store}") }
        if !floor.isEmpty { s = s.replacingOccurrences(of: floor, with: "{floor}") }
        if let r = s.range(of: "://") {
            // 去掉协议和主机部分，只留路径形状
            let rest = s[r.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                s = "…" + String(rest[slash...])
            } else {
                s = "…/"
            }
        }
        return s
    }

    static func excerpt(_ data: Data) -> String {
        let text = String(data: data.prefix(2048), encoding: .utf8)
            ?? "（\(data.count) 字节二进制内容）"
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= excerptLimit { return flat }
        return String(flat.prefix(excerptLimit)) + "…"
    }
}
