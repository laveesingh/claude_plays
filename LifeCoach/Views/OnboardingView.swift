import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: CoachEngine

    @State private var step = 0
    @State private var name = ""
    @State private var fitnessGoal = ""
    @State private var fitnessWhy = ""
    @State private var professionalGoal = ""
    @State private var professionalWhy = ""
    @State private var intensity: CoachIntensity = .balanced
    @State private var morningHour = 7
    @State private var eveningHour = 21
    @State private var apiKey = ""

    private let lastStep = 5

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step + 1), total: Double(lastStep + 1))
                    .padding(.horizontal)
                    .padding(.top, 8)

                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: nameStep
                    case 2: goalsStep
                    case 3: intensityStep
                    case 4: scheduleStep
                    default: apiKeyStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                navigationButtons
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.mind.and.body")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Meet your full-time coach")
                .font(.title2.bold())
            Text("A coach that runs your day: it sets your plan every morning, pings you when you're slipping, and reviews your results every night. You set the goals — it makes sure you stop taking them slow.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .padding()
    }

    private var nameStep: some View {
        Form {
            Section("What should your coach call you?") {
                TextField("Your name", text: $name)
                    .textContentType(.givenName)
            }
        }
    }

    private var goalsStep: some View {
        Form {
            Section("Fitness goal") {
                TextField("e.g. Run a sub-25 5K by September", text: $fitnessGoal, axis: .vertical)
                TextField("Why it matters to you", text: $fitnessWhy, axis: .vertical)
            }
            Section("Professional goal") {
                TextField("e.g. Ship my side project and get 100 users", text: $professionalGoal, axis: .vertical)
                TextField("Why it matters to you", text: $professionalWhy, axis: .vertical)
            }
        }
    }

    private var intensityStep: some View {
        Form {
            Section("How hard should your coach push?") {
                ForEach(CoachIntensity.allCases) { option in
                    Button {
                        intensity = option
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.headline)
                                Text(option.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if intensity == option {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                Text("Feeling like you've been taking it too slow? Drill Sergeant is for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scheduleStep: some View {
        Form {
            Section("Daily check-ins") {
                Picker("Morning check-in", selection: $morningHour) {
                    ForEach(4..<13, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
                Picker("Evening review", selection: $eveningHour) {
                    ForEach(17..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
            }
            Section {
                Text("Your coach will ping you at these times every day. It can also schedule extra nudges when it doesn't trust you to follow through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var apiKeyStep: some View {
        Form {
            Section("Anthropic API key") {
                SecureField("sk-ant-...", text: $apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section {
                Text("The coach is powered by Claude. Create a key at console.anthropic.com → API Keys, then paste it here. It's stored only in this device's Keychain. You can also add it later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Button(step == lastStep ? "Start coaching" : "Next") {
                if step == lastStep {
                    finish()
                } else {
                    step += 1
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdvance)
        }
        .padding()
    }

    private var canAdvance: Bool {
        switch step {
        case 1: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case 2: return !fitnessGoal.trimmingCharacters(in: .whitespaces).isEmpty
            && !professionalGoal.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter.string(from: date)
    }

    private func finish() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            KeychainHelper.save(trimmedKey)
        }

        var goals: [Goal] = []
        goals.append(Goal(category: .fitness,
                          title: fitnessGoal.trimmingCharacters(in: .whitespacesAndNewlines),
                          why: fitnessWhy.trimmingCharacters(in: .whitespacesAndNewlines)))
        goals.append(Goal(category: .professional,
                          title: professionalGoal.trimmingCharacters(in: .whitespacesAndNewlines),
                          why: professionalWhy.trimmingCharacters(in: .whitespacesAndNewlines)))

        let profile = UserProfile(name: name.trimmingCharacters(in: .whitespaces),
                                  intensity: intensity,
                                  morningHour: morningHour,
                                  eveningHour: eveningHour)

        Task {
            _ = await NotificationManager.requestPermission()
            store.completeOnboarding(profile: profile, goals: goals)
            if engine.hasAPIKey {
                await engine.send(
                    "(The client just finished setting up the app. Introduce yourself in your coaching style, react to their goals, set their first daily plan with set_daily_plan, and schedule one nudge for today's hardest task.)",
                    hidden: true
                )
            }
        }
    }
}
