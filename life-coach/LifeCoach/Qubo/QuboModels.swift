import Foundation

struct QuboAdvertisement: Equatable {
    let localName: String
    /// Uppercase hexadecimal identity embedded by the bulb, without separators.
    let hardwareID: String
    /// Weak fallback only. GATT state is the primary classifier.
    let configuredHint: Bool

    var macAddress: String {
        stride(from: 0, to: hardwareID.count, by: 2).map { offset in
            let start = hardwareID.index(hardwareID.startIndex, offsetBy: offset)
            let end = hardwareID.index(start, offsetBy: 2)
            return String(hardwareID[start..<end])
        }.joined(separator: ":")
    }

    static func parse(localName: String) -> QuboAdvertisement? {
        let normalized = localName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let configuredHint = normalized.hasPrefix("*")
        let name = configuredHint ? String(normalized.dropFirst()) : normalized

        let acceptedPrefixes = ["QBO_L_", "QUBO_L_"]
        guard let prefix = acceptedPrefixes.first(where: { name.hasPrefix($0) }) else { return nil }

        let hardwareID = String(name.dropFirst(prefix.count))
        guard hardwareID.count == 12,
              hardwareID.allSatisfy({ $0.isHexDigit }) else { return nil }

        return QuboAdvertisement(
            localName: localName,
            hardwareID: hardwareID,
            configuredHint: configuredHint
        )
    }
}

enum QuboBulbState: String, Codable, Equatable {
    case needsSetup
    case configured
    case unknown

    static func classify(rawState: String?, advertisement: QuboAdvertisement) -> QuboBulbState {
        switch rawState?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "S_01": return .needsSetup
        case "S_06": return .configured
        case .some: return .unknown
        case .none: return advertisement.configuredHint ? .configured : .needsSetup
        }
    }

    var title: String {
        switch self {
        case .needsSetup: return "Needs setup"
        case .configured: return "Configured signal"
        case .unknown: return "Unknown state"
        }
    }

    var explanation: String {
        switch self {
        case .needsSetup:
            return "The bulb reports the setup state observed on a reset, blinking bulb."
        case .configured:
            return "The bulb reports the configured state. The iPhone cannot independently confirm Qubo cloud access."
        case .unknown:
            return "The bulb returned a state that has not been mapped yet."
        }
    }
}

enum QuboConnectionPhase: String, Equatable {
    case discovered
    case connecting
    case reading
    case ready
    case disconnected
    case failed
}

struct QuboBulbSnapshot: Identifiable, Equatable {
    var id: String { advertisement.hardwareID }

    var advertisement: QuboAdvertisement
    var rssi: Int
    var lastSeen: Date
    var connectionPhase: QuboConnectionPhase = .discovered
    var model: String?
    var rawState: String?
    var rawLightState: String?
    var errorMessage: String?

    var state: QuboBulbState {
        QuboBulbState.classify(rawState: rawState, advertisement: advertisement)
    }

    var isIdentityConfirmed: Bool {
        model?.uppercased().hasPrefix("HLB10") == true
    }
}

struct QuboStoredProfile: Codable, Equatable, Identifiable {
    var id: String { hardwareID }

    let hardwareID: String
    var nickname: String
    var lastAdvertisementName: String
    var lastRawState: String?
    var lastSeen: Date

    var macAddress: String {
        guard hardwareID.count == 12 else { return hardwareID }
        return stride(from: 0, to: hardwareID.count, by: 2).map { offset in
            let start = hardwareID.index(hardwareID.startIndex, offsetBy: offset)
            let end = hardwareID.index(start, offsetBy: 2)
            return String(hardwareID[start..<end])
        }.joined(separator: ":")
    }
}
