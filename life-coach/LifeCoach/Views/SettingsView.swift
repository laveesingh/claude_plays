import SwiftUI
import AuthenticationServices

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: CoachEngine
    @EnvironmentObject private var googleAuth: GoogleAuth

    @State private var showingResetConfirm = false
    @State private var connectingGmail = false
    @State private var gmailError: String?

    var body: some View {
        NavigationStack {
            Form {
                aiSection
                APIKeyField(provider: .ollama)
                APIKeyField(provider: .claude)
                UnsplashKeyField()
                gmailSection
                coachSection
                integrationsSection
                scheduleSection
                dangerSection
            }
            .navigationTitle("Settings")
            .alert("Gmail", isPresented: Binding(get: { gmailError != nil }, set: { if !$0 { gmailError = nil } })) {
                Button("OK", role: .cancel) { gmailError = nil }
            } message: {
                Text(gmailError ?? "")
            }
        }
    }

    private var gmailSection: some View {
        Section {
            if googleAuth.isSignedIn {
                HStack {
                    Label("Gmail connected", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Disconnect", role: .destructive) { googleAuth.signOut() }
                }
            } else {
                Button {
                    Task { await connectGmail() }
                } label: {
                    HStack {
                        Label("Connect Gmail", systemImage: "link")
                        if connectingGmail {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(connectingGmail)
            }
        } header: {
            Text("Inbox (Gmail)")
        } footer: {
            Text("Read-only access to triage your last 2 days of mail. Tokens are stored only in this device's Keychain; disconnect anytime.")
        }
    }

    private func connectGmail() async {
        connectingGmail = true
        defer { connectingGmail = false }
        do {
            try await googleAuth.signIn()
        } catch {
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionErrorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                return
            }
            gmailError = error.localizedDescription
        }
    }

    private var aiSection: some View {
        Section {
            Picker("Provider", selection: providerBinding) {
                ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Model", selection: modelBinding) {
                ForEach(AIModels.list(for: store.state.ai.provider)) { Text($0.label).tag($0.tag) }
            }
        } header: {
            Text("AI provider & model")
        } footer: {
            Text("Using \(store.state.ai.provider.displayName) · \(AIModels.label(for: store.state.ai.activeModel)). Switching is manual — there is no automatic fallback.")
        }
    }

    private var coachSection: some View {
        Section("Coach") {
            Picker("Intensity", selection: intensityBinding) {
                ForEach(CoachIntensity.allCases) { Text($0.label).tag($0) }
            }
            Text(intensityBinding.wrappedValue.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var integrationsSection: some View {
        Section {
            Button {
                Task { await HealthManager.requestPermission() }
            } label: {
                Label("Request Health access", systemImage: "heart.fill")
            }
            Button {
                Task { _ = await CalendarManager.requestPermission() }
            } label: {
                Label(CalendarManager.isAuthorized ? "Calendar access granted ✓" : "Request Calendar access",
                      systemImage: "calendar")
            }
            Toggle("Coach writes blocks to my calendar", isOn: calendarWriteBinding)
        } header: {
            Text("Integrations")
        } footer: {
            Text("Health data verifies workouts, steps, and sleep. Calendar access lets the coach plan around real meetings and, if enabled, write its time blocks as events.")
        }
    }

    private var scheduleSection: some View {
        Section("Daily session notifications") {
            Picker("Morning brief", selection: morningBinding) {
                ForEach(4..<13, id: \.self) { Text(hourLabel($0)).tag($0) }
            }
            Picker("Evening debrief", selection: eveningBinding) {
                ForEach(17..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
            }
            Text("Weekly review pings every Sunday. Block check-ins are scheduled automatically with each day's plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Reset everything", role: .destructive) {
                showingResetConfirm = true
            }
            .confirmationDialog("Delete all goals, history, dossier, and chat?",
                                isPresented: $showingResetConfirm,
                                titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    KeychainHelper.deleteAll()
                    store.resetAll()
                }
            }
        }
    }

    // MARK: - Bindings

    private var providerBinding: Binding<AIProvider> {
        Binding(
            get: { store.state.ai.provider },
            set: { store.state.ai.provider = $0 }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { store.state.ai.activeModel },
            set: { newTag in
                switch store.state.ai.provider {
                case .ollama: store.state.ai.ollamaModel = newTag
                case .claude: store.state.ai.claudeModel = newTag
                }
            }
        )
    }

    private var intensityBinding: Binding<CoachIntensity> {
        Binding(
            get: { store.state.profile?.intensity ?? .balanced },
            set: { store.state.profile?.intensity = $0 }
        )
    }

    private var calendarWriteBinding: Binding<Bool> {
        Binding(
            get: { store.state.profile?.calendarWriteEnabled ?? false },
            set: { store.state.profile?.calendarWriteEnabled = $0 }
        )
    }

    private var morningBinding: Binding<Int> {
        Binding(
            get: { store.state.profile?.morningHour ?? 7 },
            set: { newValue in
                store.state.profile?.morningHour = newValue
                rescheduleCheckIns()
            }
        )
    }

    private var eveningBinding: Binding<Int> {
        Binding(
            get: { store.state.profile?.eveningHour ?? 21 },
            set: { newValue in
                store.state.profile?.eveningHour = newValue
                rescheduleCheckIns()
            }
        )
    }

    private func rescheduleCheckIns() {
        guard let profile = store.state.profile else { return }
        NotificationManager.scheduleDailyCheckIns(morningHour: profile.morningHour,
                                                  eveningHour: profile.eveningHour)
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter.string(from: date)
    }
}

/// API key entry that is read-only until the user taps Edit — protects the key
/// from accidental changes.
private struct APIKeyField: View {
    let provider: AIProvider

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Section {
            if editing {
                SecureField(provider.keyPlaceholder, text: $draft)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Button("Save") {
                        KeychainHelper.save(draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                            provider: provider)
                        editing = false
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        editing = false
                        draft = ""
                    }
                }
            } else {
                HStack {
                    Label(KeychainHelper.hasKey(provider: provider) ? "Key saved" : "No key set",
                          systemImage: KeychainHelper.hasKey(provider: provider) ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(KeychainHelper.hasKey(provider: provider) ? Color.secondary : Color.orange)
                    Spacer()
                    Button("Edit") {
                        draft = KeychainHelper.load(provider: provider) ?? ""
                        editing = true
                    }
                }
            }
        } header: {
            Text(provider.keyLabel)
        } footer: {
            Text(provider.keyFooter)
        }
    }
}

/// Unsplash access-key entry — same edit-protected pattern as `APIKeyField`, but
/// backed by the Keychain's named-secret store. When set, Factscroll pulls real
/// cover photos for each fact's topic; with no key it falls back to gradients.
private struct UnsplashKeyField: View {
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Section {
            if editing {
                SecureField("Unsplash Access Key", text: $draft)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Button("Save") {
                        KeychainHelper.save(draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                            secret: .unsplash)
                        editing = false
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        editing = false
                        draft = ""
                    }
                }
            } else {
                HStack {
                    Label(KeychainHelper.hasKey(secret: .unsplash) ? "Key saved" : "No key set",
                          systemImage: KeychainHelper.hasKey(secret: .unsplash) ? "checkmark.seal.fill" : "photo")
                        .foregroundStyle(KeychainHelper.hasKey(secret: .unsplash) ? Color.secondary : Color.orange)
                    Spacer()
                    Button("Edit") {
                        draft = KeychainHelper.load(secret: .unsplash) ?? ""
                        editing = true
                    }
                }
            }
        } header: {
            Text("Unsplash (Factscroll photos)")
        } footer: {
            Text("Gives Factscroll real cover photos per topic. Create a free key at unsplash.com/developers → New Application → Access Key. Stored only in this device's Keychain. Takes effect on next launch.")
        }
    }
}
