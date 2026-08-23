import SwiftUI

struct QuboBulbsView: View {
    @StateObject private var manager = QuboBulbManager()
    @StateObject private var preferences = QuboPreferences()

    @State private var ssidDraft = ""
    @State private var passwordDraft = ""
    @State private var networkMessage: NetworkMessage?

    private var discoveredIDs: Set<String> {
        Set(manager.bulbs.map(\.id))
    }

    private var missingProfiles: [QuboStoredProfile] {
        preferences.storedProfiles.filter { !discoveredIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                scanSection
                poweredBulbsSection
                if !missingProfiles.isEmpty { knownBulbsSection }
                recoveryNetworkSection
                recoveryStatusSection
                localControlsSection
            }
            .navigationTitle("Bulbs")
            .onAppear {
                ssidDraft = preferences.wifiSSID
            }
            .onDisappear {
                manager.stopAllActivity()
            }
            .onChange(of: manager.bulbs) { _, bulbs in
                for bulb in bulbs { preferences.record(bulb) }
            }
        }
    }

    private var scanSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: radioIcon)
                    .font(.title2)
                    .foregroundStyle(radioColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(manager.isScanning ? "Scanning nearby bulbs" : manager.radioState.title)
                        .font(.headline)
                    Text(scanDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if manager.isScanning { ProgressView() }
            }

            HStack {
                Button {
                    manager.startScanning()
                } label: {
                    Label("Start scan", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isScanning || manager.hasActiveRead || scanIsUnavailable)

                Button {
                    manager.stopScanning()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!manager.isScanning)

                Spacer()

                Button("Clear", role: .destructive) {
                    manager.clearResults()
                }
                .disabled(manager.isScanning || manager.bulbs.isEmpty)
            }
        } footer: {
            Text("Nothing starts automatically. Start scan reports each nearby bulb once. Tap Stop before using Read details on one bulb.")
        }
    }

    @ViewBuilder
    private var poweredBulbsSection: some View {
        Section("Powered bulbs nearby") {
            if manager.bulbs.isEmpty {
                ContentUnavailableView {
                    Label("No Qubo bulbs yet", systemImage: "lightbulb.slash")
                } description: {
                    Text(emptyStateDetail)
                }
            } else {
                ForEach(manager.bulbs) { bulb in
                    QuboBulbRow(
                        bulb: bulb,
                        preferences: preferences,
                        readIsDisabled: manager.isScanning || manager.hasActiveRead,
                        onRead: { manager.readDetails(for: bulb.id) },
                        onCancelRead: { manager.cancelRead(for: bulb.id) }
                    )
                }
            }
        }
    }

    private var knownBulbsSection: some View {
        Section {
            ForEach(missingProfiles) { profile in
                QuboKnownBulbRow(profile: profile, preferences: preferences)
            }
        } header: {
            Text("Known but not seen")
        } footer: {
            Text("A missing bulb may be powered off, out of Bluetooth range, or temporarily connected to another phone.")
        }
    }

    private var recoveryNetworkSection: some View {
        Section {
            TextField("2.4 GHz Wi-Fi name", text: $ssidDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField(
                preferences.hasSavedPassword ? "New password (optional)" : "Wi-Fi password",
                text: $passwordDraft
            )
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Button("Save recovery details") {
                saveNetworkDetails()
            }
            .disabled(ssidDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if preferences.hasSavedPassword {
                HStack {
                    Label("Password saved in Keychain", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget", role: .destructive) {
                        preferences.deleteSavedPassword()
                        networkMessage = .success("Saved password removed.")
                    }
                }
            }

            if let networkMessage {
                Label(networkMessage.text, systemImage: networkMessage.icon)
                    .font(.caption)
                    .foregroundStyle(networkMessage.color)
            }
        } header: {
            Text("Recovery Wi-Fi")
        } footer: {
            Text("The password stays in this device's Keychain. It is not stored in Sapiod data or displayed again. Qubo bulbs require 2.4 GHz Wi-Fi.")
        }
    }

    private var recoveryStatusSection: some View {
        Section("Recovery status") {
            Label("Protocol capture needed", systemImage: "wave.3.right.circle")
                .foregroundStyle(.orange)
            Text("The app can identify reset bulbs and keep your Wi-Fi details ready. It cannot safely reconnect a bulb yet because Qubo does not publish the Bluetooth provisioning frame or cloud-binding token.")
                .font(.subheadline)

            DisclosureGroup("What unlocks one-tap reconnect") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Record one official Qubo pairing with Apple PacketLogger.")
                    Text("2. Extract the write sent to characteristic EE01.")
                    Text("3. Repeat once to separate Wi-Fi fields from any account token.")
                    Text("4. Add reconnect only after the bulb changes from S_01 to S_06.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }

            Link(destination: URL(string: "https://www.quboworld.com/pages/qubo-smart-bulb-faqs")!) {
                Label("Open Qubo's bulb guide", systemImage: "safari")
            }
        }
    }

    private var localControlsSection: some View {
        Section("Local controls") {
            Label("Brightness and color are not enabled yet", systemImage: "slider.horizontal.3")
                .foregroundStyle(.secondary)
            Text("The bulb exposes a writable light-state field, but an accepted test write did not change the reset bulb. A watched test on a configured bulb or an official-app capture is required before controls are safe to ship.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveNetworkDetails() {
        let newPassword = passwordDraft.isEmpty ? nil : passwordDraft
        switch preferences.saveNetwork(ssid: ssidDraft, password: newPassword) {
        case .success:
            passwordDraft = ""
            networkMessage = .success("Recovery details saved.")
        case .failure(let error):
            networkMessage = .error(error.localizedDescription)
        }
    }

    private var radioIcon: String {
        switch manager.radioState {
        case .ready: return "antenna.radiowaves.left.and.right"
        case .unauthorized: return "hand.raised.fill"
        case .poweredOff: return "bolt.slash.fill"
        case .unsupported, .failed: return "exclamationmark.triangle.fill"
        case .idle, .preparing: return "wave.3.right"
        }
    }

    private var radioColor: Color {
        switch manager.radioState {
        case .ready: return .blue
        case .unauthorized, .poweredOff, .unsupported, .failed: return .orange
        case .idle, .preparing: return .secondary
        }
    }

    private var scanDetail: String {
        switch manager.radioState {
        case .ready:
            return manager.isScanning ? "Each powered Qubo bulb will be added once." : "Tap Start scan when you want a new scan."
        case .unauthorized:
            return "Allow Bluetooth for Sapiod in iOS Settings."
        case .poweredOff:
            return "Turn on Bluetooth, then tap Start scan."
        case .unsupported:
            return "Use a real iPhone with Bluetooth Low Energy."
        case .failed(let message):
            return message
        case .idle:
            return "Tap Start scan."
        case .preparing:
            return "Waiting for iOS Bluetooth status."
        }
    }

    private var scanIsUnavailable: Bool {
        manager.radioState == .unauthorized || manager.radioState == .unsupported
    }

    private var emptyStateDetail: String {
        switch manager.radioState {
        case .ready:
            return manager.isScanning
                ? "Keep this page open and make sure at least one bulb has wall power."
                : "Tap Start scan when you want to look for powered bulbs."
        case .unauthorized: return "Bluetooth permission is required to find bulbs."
        case .poweredOff: return "Turn on Bluetooth to scan."
        case .unsupported: return "The iOS Simulator cannot scan physical bulbs."
        case .idle: return "Tap Start scan when you want to look for powered bulbs."
        case .preparing, .failed: return "Waiting for the Bluetooth scanner."
        }
    }
}

private struct QuboBulbRow: View {
    let bulb: QuboBulbSnapshot
    @ObservedObject var preferences: QuboPreferences
    let readIsDisabled: Bool
    let onRead: () -> Void
    let onCancelRead: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: bulb.state.icon)
                    .font(.title2)
                    .foregroundStyle(bulb.state.color)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preferences.displayName(for: bulb.id))
                        .font(.headline)
                    Text(bulb.advertisement.macAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(bulb.state.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(bulb.state.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(bulb.state.color.opacity(0.12), in: Capsule())
            }

            TextField("Name this bulb", text: nicknameBinding)
                .textInputAutocapitalization(.words)

            Text(bulb.state.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if bulb.connectionPhase == .connecting || bulb.connectionPhase == .reading {
                Button(role: .cancel, action: onCancelRead) {
                    Label("Stop reading", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else {
                Button(action: onRead) {
                    Label("Read details", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(readIsDisabled)
                Text(readIsDisabled
                     ? "Stop the scan or current read first."
                     : "Connects once, reads the current fields, then disconnects.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = bulb.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            DisclosureGroup("Diagnostics") {
                VStack(alignment: .leading, spacing: 5) {
                    diagnostic("Advertised", bulb.advertisement.localName)
                    diagnostic("Model", bulb.model ?? "Reading…")
                    diagnostic("State", bulb.rawState ?? "No GATT value yet")
                    diagnostic("Light data", bulb.rawLightState ?? "No GATT value yet")
                    diagnostic("Signal", "\(bulb.rssi) dBm")
                    diagnostic("Last seen", bulb.lastSeen.formatted(date: .abbreviated, time: .standard))
                }
                .padding(.vertical, 5)
            }
            .font(.caption)
        }
        .padding(.vertical, 5)
    }

    private var nicknameBinding: Binding<String> {
        Binding(
            get: { preferences.nickname(for: bulb.id) },
            set: { preferences.setNickname($0, for: bulb.id) }
        )
    }

    private func diagnostic(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .fontDesign(.monospaced)
                .textSelection(.enabled)
        }
    }
}

private struct QuboKnownBulbRow: View {
    let profile: QuboStoredProfile
    @ObservedObject var preferences: QuboPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(preferences.displayName(for: profile.id), systemImage: "lightbulb.slash")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Forget", role: .destructive) {
                    preferences.forgetProfile(hardwareID: profile.id)
                }
                .font(.caption)
            }
            Text(profile.macAddress)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Last seen \(profile.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

private struct NetworkMessage: Equatable {
    enum Kind { case success, error }

    let kind: Kind
    let text: String

    static func success(_ text: String) -> NetworkMessage { NetworkMessage(kind: .success, text: text) }
    static func error(_ text: String) -> NetworkMessage { NetworkMessage(kind: .error, text: text) }

    var icon: String { kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
    var color: Color { kind == .success ? .green : .orange }
}

private extension QuboBulbState {
    var icon: String {
        switch self {
        case .needsSetup: return "exclamationmark.triangle.fill"
        case .configured: return "lightbulb.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .needsSetup: return .orange
        case .configured: return .green
        case .unknown: return .secondary
        }
    }
}
