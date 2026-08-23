import Combine
import Foundation
import Security

final class QuboPreferences: ObservableObject {
    @Published private(set) var profiles: [String: QuboStoredProfile]
    @Published private(set) var wifiSSID: String
    @Published private(set) var hasSavedPassword: Bool

    private let defaults: UserDefaults
    private static let profilesKey = "qubo.profiles"
    private static let wifiSSIDKey = "qubo.wifiSSID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([String: QuboStoredProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = [:]
        }
        wifiSSID = defaults.string(forKey: Self.wifiSSIDKey) ?? ""
        hasSavedPassword = QuboCredentialStore.hasPassword
    }

    var storedProfiles: [QuboStoredProfile] {
        profiles.values.sorted { lhs, rhs in
            if lhs.nickname.isEmpty != rhs.nickname.isEmpty { return !lhs.nickname.isEmpty }
            return lhs.lastSeen > rhs.lastSeen
        }
    }

    func displayName(for hardwareID: String) -> String {
        if let nickname = profiles[hardwareID]?.nickname,
           !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nickname
        }
        return "Qubo \(hardwareID.suffix(4))"
    }

    func nickname(for hardwareID: String) -> String {
        profiles[hardwareID]?.nickname ?? ""
    }

    func setNickname(_ nickname: String, for hardwareID: String) {
        var profile = profiles[hardwareID] ?? QuboStoredProfile(
            hardwareID: hardwareID,
            nickname: "",
            lastAdvertisementName: "",
            lastRawState: nil,
            lastSeen: Date()
        )
        profile.nickname = nickname
        profiles[hardwareID] = profile
        persistProfiles()
    }

    func record(_ bulb: QuboBulbSnapshot) {
        let existing = profiles[bulb.id]
        let shouldPersist = existing == nil
            || existing?.lastAdvertisementName != bulb.advertisement.localName
            || existing?.lastRawState != bulb.rawState
            || abs(existing?.lastSeen.timeIntervalSince(bulb.lastSeen) ?? .infinity) > 10

        guard shouldPersist else { return }
        profiles[bulb.id] = QuboStoredProfile(
            hardwareID: bulb.id,
            nickname: existing?.nickname ?? "",
            lastAdvertisementName: bulb.advertisement.localName,
            lastRawState: bulb.rawState,
            lastSeen: bulb.lastSeen
        )
        persistProfiles()
    }

    func saveNetwork(ssid: String, password: String?) -> Result<Void, QuboCredentialError> {
        let cleanSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        wifiSSID = cleanSSID
        defaults.set(cleanSSID, forKey: Self.wifiSSIDKey)

        if let password, !password.isEmpty {
            do {
                try QuboCredentialStore.savePassword(password)
                hasSavedPassword = true
            } catch let error as QuboCredentialError {
                return .failure(error)
            } catch {
                return .failure(.unexpectedStatus(errSecInternalError))
            }
        }
        return .success(())
    }

    func deleteSavedPassword() {
        QuboCredentialStore.deletePassword()
        hasSavedPassword = false
    }

    func forgetProfile(hardwareID: String) {
        profiles.removeValue(forKey: hardwareID)
        persistProfiles()
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesKey)
    }
}

enum QuboCredentialError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Could not save the Wi-Fi password: \(detail)."
        }
    }
}

enum QuboCredentialStore {
    private static let service = "com.laveesingh.LifeCoach.qubo-wifi"
    private static let account = "default-network"

    static var hasPassword: Bool {
        loadPassword() != nil
    }

    static func savePassword(_ password: String) throws {
        let query = baseQuery
        let data = Data(password.utf8)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw QuboCredentialError.unexpectedStatus(updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw QuboCredentialError.unexpectedStatus(addStatus)
        }
    }

    static func loadPassword() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
