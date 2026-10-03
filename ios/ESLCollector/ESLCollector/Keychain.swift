import Foundation
import Security

/// 极简钥匙串封装（通用密码项）。
///
/// 只用于保存用户主动勾选「记住凭据」后的服务器用户名 / 凭据。
/// 访问级别为 `WhenUnlockedThisDeviceOnly`：不进 iCloud、不进备份、锁屏后不可读。
/// 凭据不会写入 UserDefaults、日志或任何磁盘文件。
enum Keychain {
    /// 服务名。取 bundle id，避免在代码里写死任何业务标识。
    private static let service: String =
        (Bundle.main.bundleIdentifier ?? "ESLCollector") + ".credentials"

    /// 写入；传 nil 等同删除。
    static func set(_ value: String?, for key: String) {
        guard let value, !value.isEmpty else {
            remove(key)
            return
        }
        guard let data = value.data(using: .utf8) else {
            remove(key)
            return
        }
        remove(key)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            // 只记录是否成功，绝不记录内容
            AppLog.w("钥匙串", "写入 \(key) 失败：OSStatus \(status)")
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecSuccess && status != errSecItemNotFound {
                AppLog.w("钥匙串", "读取 \(key) 失败：OSStatus \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
