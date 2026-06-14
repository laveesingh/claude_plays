import Foundation
import Security

/// Per-provider API key storage. Claude maps to the original "anthropic" account
/// so any key saved before multi-provider support is preserved untouched.
enum KeychainHelper {
    private static let service = "com.lifecoach.apikey"

    private static func account(for provider: AIProvider) -> String {
        switch provider {
        case .claude: return "anthropic"
        case .ollama: return "ollama"
        }
    }

    static func save(_ value: String, provider: AIProvider) {
        let account = account(for: provider)
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

    static func load(provider: AIProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasKey(provider: AIProvider) -> Bool {
        guard let key = load(provider: provider) else { return false }
        return !key.isEmpty
    }

    static func delete(provider: AIProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        for provider in AIProvider.allCases { delete(provider: provider) }
    }
}
