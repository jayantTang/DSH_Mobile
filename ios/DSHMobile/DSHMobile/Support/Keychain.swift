import Foundation
import Security

/// Minimal Keychain wrapper for connection secrets.
///
/// Launch tokens and device tokens are bearer credentials: they must not sit in
/// `UserDefaults`, which is backed by an unprotected plist and included in
/// unencrypted backups. Profiles keep only a reference; the secret lives here.
enum Keychain {
    private static let service = "com.jayanttang.dsh"

    enum Failure: Error, LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            switch self {
            case .status(let code):
                return "钥匙串操作失败（OSStatus \(code)）"
            }
        }
    }

    /// Stores or replaces one secret.
    static func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Replace rather than add: this runs on every credential rotation.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.status(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    /// Reads one secret, or nil when it was never stored.
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes one secret, ignoring absence.
    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
