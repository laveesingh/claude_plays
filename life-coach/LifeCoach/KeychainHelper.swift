import Foundation
import Security

/// Per-provider (and other named-secret) API key storage. Claude maps to the
/// original "anthropic" account so any key saved before multi-provider support is
/// preserved untouched. Non-AI secrets (e.g. Unsplash) live here too, keyed by a
/// `Secret` account so the whole app has one Keychain story.
enum KeychainHelper {
    private static let service = "com.lifecoach.apikey"

    /// Named secrets that aren't an `AIProvider` (image services, etc.).
    enum Secret: String, CaseIterable {
        case unsplash
    }

    private static func account(for provider: AIProvider) -> String {
        switch provider {
        case .claude: return "anthropic"
        case .ollama: return "ollama"
        }
    }

    // MARK: - Raw account-keyed core

    private static func saveRaw(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func loadRaw(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteRaw(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - AIProvider keys

    static func save(_ value: String, provider: AIProvider) {
        saveRaw(value, account: account(for: provider))
    }

    static func load(provider: AIProvider) -> String? {
        loadRaw(account: account(for: provider))
    }

    static func hasKey(provider: AIProvider) -> Bool {
        guard let key = load(provider: provider) else { return false }
        return !key.isEmpty
    }

    static func delete(provider: AIProvider) {
        deleteRaw(account: account(for: provider))
    }

    // MARK: - Named secrets (Unsplash, …)

    static func save(_ value: String, secret: Secret) {
        saveRaw(value, account: secret.rawValue)
    }

    static func load(secret: Secret) -> String? {
        loadRaw(account: secret.rawValue)
    }

    static func hasKey(secret: Secret) -> Bool {
        guard let key = load(secret: secret) else { return false }
        return !key.isEmpty
    }

    static func delete(secret: Secret) {
        deleteRaw(account: secret.rawValue)
    }

    // MARK: - Bulk

    static func deleteAll() {
        for provider in AIProvider.allCases { delete(provider: provider) }
        for secret in Secret.allCases { delete(secret: secret) }
    }
}
