import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: CoachEngine

    @State private var apiKey = KeychainHelper.load() ?? ""
    @State private var keySaved = false
    @State private var showingResetConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                apiKeySection
                coachSection
                integrationsSection
                scheduleSection
                dangerSection
            }
            .navigationTitle("Settings")
        }
    }

    private var apiKeySection: some View {
        Section {
            SecureField("sk-ant-...", text: $apiKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(keySaved ? "Saved ✓" : "Save key") {
                KeychainHelper.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                keySaved = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    keySaved = false
                }
            }
        } header: {
            Text("Anthropic API key")
        } footer: {
            Text("Powers your coach (Claude). Create one at console.anthropic.com -> API Keys. Stored only in this device's Keychain.")
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
                    KeychainHelper.delete()
                    store.resetAll()
                }
            }
        }
    }

    // MARK: - Bindings

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
