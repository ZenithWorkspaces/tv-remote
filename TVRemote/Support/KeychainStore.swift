import Foundation
import Security

protocol SecretProviding: AnyObject {
    func string(for account: String) -> String?
    func set(_ value: String?, for account: String)
}

enum SecretAccount {
    static func lgClientKey(_ id: String) -> String { "lg.client-key.\(id)" }
    static func samsungToken(_ id: String) -> String { "samsung.token.\(id)" }
    static func sonyPSK(_ id: String) -> String { "sony.psk.\(id)" }
    static func vizioAuth(_ id: String) -> String { "vizio.auth.\(id)" }
    static func vizioDevice(_ id: String) -> String { "vizio.device.\(id)" }
}

final class KeychainStore: SecretProviding {
    private let service = "com.zenithworkspaces.tvremote"

    func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }
}
