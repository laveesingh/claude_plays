import SwiftUI

// MARK: - Keyword rule

/// One user keyword rule: when `keyword` (a case-insensitive substring) appears in an
/// email's sender or content, force it into `lane` — or, when `laneRaw` is nil, FLAG
/// it (lift it into Needs you). Lets "anything saying invoice → Money" or "urgent →
/// flag" be expressed in the preferences sheet AND added by the agent via chat.
struct KeywordRule: Codable, Identifiable, Hashable {
    let id: UUID
    var keyword: String
    /// Target lane rawValue, or nil to FLAG (force into Needs you).
    var laneRaw: String?

    init(id: UUID = UUID(), keyword: String, laneRaw: String? = nil) {
        self.id = id
        self.keyword = keyword
        self.laneRaw = laneRaw
    }

    /// The resolved target lane, or nil for a flag rule.
    var lane: InboxLane? { laneRaw.flatMap { InboxLane(rawValue: $0) } }

    /// Deterministic match key: trimmed, lowercased keyword.
    var normalizedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A short human description of the target for the editor row.
    var targetLabel: String { lane?.title ?? "Flag (Needs you)" }

    enum CodingKeys: String, CodingKey { case id, keyword, laneRaw }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        keyword = try c.decodeIfPresent(String.self, forKey: .keyword) ?? ""
        laneRaw = try c.decodeIfPresent(String.self, forKey: .laneRaw)
    }
}

// MARK: - Category disposition

/// The user's per-category override: leave it where the classifier put it, always
/// surface it (elevate out of noise), or always bin it (suppress to noise).
enum CategoryDisposition: String, CaseIterable, Identifiable {
    case normal, elevate, suppress
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return "Normal"
        case .elevate: return "Elevate"
        case .suppress: return "Suppress"
        }
    }
}

// MARK: - Preferences model

/// The user's durable Inbox preferences, persisted to `inbox-prefs.json`. Every list
/// is a set of case-insensitive substrings (senders) or `EmailCategory` rawValues
/// (categories). `InboxRanker` reads this to apply HARD overrides; the classifier and
/// the agent get a short text summary so the LLM respects it too.
///
/// Tolerant Codable: an older / missing file loads with sane defaults — crucially
/// `autoFileEnabled` defaults to **true**, which is safe by construction because the
/// mute / learned-noise sets it acts on start empty (a fresh install auto-files
/// nothing until the user accumulates signals or adds an explicit rule).
struct InboxPreferences: Codable {
    /// Senders to ALWAYS surface (never noise) — email/domain/name substrings.
    var vipSenders: [String]
    /// Senders to ALWAYS treat as noise (auto-file candidates) — substrings.
    var mutedSenders: [String]
    /// `EmailCategory` rawValues to push to noise.
    var suppressedCategories: [String]
    /// `EmailCategory` rawValues to lift out of noise.
    var elevatedCategories: [String]
    /// Keyword → lane/flag rules.
    var keywordRules: [KeywordRule]
    /// Whether the refresh sweep auto-files high-confidence noise. Default true.
    var autoFileEnabled: Bool
    /// The hour (0–23) the user wants a daily brief notification. Nil = disabled.
    var dailyBriefHour: Int?
    /// Whether the user wants a local notification when important new mail arrives
    /// in the background. Default false (opt-in; permission is requested on enable).
    var notifyImportantMail: Bool

    init(vipSenders: [String] = [],
         mutedSenders: [String] = [],
         suppressedCategories: [String] = [],
         elevatedCategories: [String] = [],
         keywordRules: [KeywordRule] = [],
         autoFileEnabled: Bool = true,
         dailyBriefHour: Int? = nil,
         notifyImportantMail: Bool = false) {
        self.vipSenders = vipSenders
        self.mutedSenders = mutedSenders
        self.suppressedCategories = suppressedCategories
        self.elevatedCategories = elevatedCategories
        self.keywordRules = keywordRules
        self.autoFileEnabled = autoFileEnabled
        self.dailyBriefHour = dailyBriefHour
        self.notifyImportantMail = notifyImportantMail
    }

    enum CodingKeys: String, CodingKey {
        case vipSenders, mutedSenders, suppressedCategories, elevatedCategories
        case keywordRules, autoFileEnabled, dailyBriefHour, notifyImportantMail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vipSenders = try c.decodeIfPresent([String].self, forKey: .vipSenders) ?? []
        mutedSenders = try c.decodeIfPresent([String].self, forKey: .mutedSenders) ?? []
        suppressedCategories = try c.decodeIfPresent([String].self, forKey: .suppressedCategories) ?? []
        elevatedCategories = try c.decodeIfPresent([String].self, forKey: .elevatedCategories) ?? []
        keywordRules = try c.decodeIfPresent([KeywordRule].self, forKey: .keywordRules) ?? []
        autoFileEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoFileEnabled) ?? true
        dailyBriefHour = try c.decodeIfPresent(Int.self, forKey: .dailyBriefHour)
        notifyImportantMail = try c.decodeIfPresent(Bool.self, forKey: .notifyImportantMail) ?? false
    }

    /// True when the user has set nothing — used to decide whether to bother the
    /// classifier prompt with a preferences block.
    var isEmpty: Bool {
        vipSenders.isEmpty && mutedSenders.isEmpty && suppressedCategories.isEmpty
            && elevatedCategories.isEmpty && keywordRules.isEmpty
    }

    /// Normalize a free-text sender pattern to a stable key (trimmed, lowercased) so
    /// the same rule is never stored twice in different cases.
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A compact, bounded summary fed to BOTH the classifier prompt and the agent's
    /// system snapshot so the LLM respects the user's standing preferences. Empty
    /// string when nothing is set.
    func promptSummary() -> String {
        guard !isEmpty else { return "" }
        var lines: [String] = ["USER INBOX PREFERENCES (respect these):"]
        if !vipSenders.isEmpty {
            lines.append("- Always important (VIP) senders: \(vipSenders.joined(separator: ", "))")
        }
        if !mutedSenders.isEmpty {
            lines.append("- Always noise (muted) senders: \(mutedSenders.joined(separator: ", "))")
        }
        if !elevatedCategories.isEmpty {
            lines.append("- Elevate categories: \(elevatedCategories.joined(separator: ", "))")
        }
        if !suppressedCategories.isEmpty {
            lines.append("- Suppress categories (treat as noise): \(suppressedCategories.joined(separator: ", "))")
        }
        if !keywordRules.isEmpty {
            let rules = keywordRules
                .map { "\"\($0.keyword)\" → \($0.targetLabel)" }
                .joined(separator: ", ")
            lines.append("- Keyword rules: \(rules)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Preferences sheet

/// The Inbox preferences sheet, reachable from the gear button in the header. Mirrors
/// News's topic editor: free-text add/remove rows for VIP and muted senders and for
/// keyword rules, an elevate/suppress control per category, the auto-file toggle, and
/// any one-tap rule suggestions the app has learned. Every edit routes through the
/// `InboxStore`, which persists and re-applies the overrides live.
struct InboxPreferencesView: View {
    @ObservedObject var inbox: InboxStore
    @Environment(\.dismiss) private var dismiss

    @State private var newVIP = ""
    @State private var newMuted = ""
    @State private var newKeyword = ""
    @State private var newKeywordLane: InboxLane? = nil
    @State private var showSubscriptionCleanup = false

    var body: some View {
        NavigationStack {
            List {
                notificationsSection
                automationSection
                cleanupSection
                suggestionsSection
                vipSection
                mutedSection
                keywordSection
                categorySection
            }
            .navigationTitle("Inbox preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSubscriptionCleanup) {
                SubscriptionCleanupView(inbox: inbox)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section {
            // Important-mail alert toggle.
            Toggle(isOn: Binding(
                get: { inbox.preferences.notifyImportantMail },
                set: { enabled in
                    Task { await inbox.setNotifyImportantMail(enabled) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify me about important mail")
                    Text("A banner when new Needs-you, Waiting, or Security mail arrives while the app is in the background.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Daily brief time picker.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily brief")
                    Text("A notification at the chosen hour with your current inbox summary.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { inbox.preferences.dailyBriefHour ?? -1 },
                    set: { hour in inbox.setDailyBriefHour(hour == -1 ? nil : hour) }
                )) {
                    Text("Off").tag(-1)
                    ForEach(0..<24) { h in
                        Text(Self.hourLabel(h)).tag(h)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Background alerts are opportunistic — iOS decides when to wake the app. A weekly recap always fires on Sunday evenings.")
        }
    }

    // MARK: Automation

    private var automationSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { inbox.preferences.autoFileEnabled },
                set: { inbox.setAutoFileEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-file noise")
                    Text("Quietly archive mail from muted senders and senders you always bin unread. Everything else waits for you.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Automation")
        } footer: {
            Text("Auto-file only ever touches the Everything-else lane — it never archives anything in Needs you, Waiting, Money, Security, People, Calendar or Orders.")
        }
    }

    // MARK: Subscription cleanup

    private var cleanupSection: some View {
        Section {
            Button {
                showSubscriptionCleanup = true
            } label: {
                HStack {
                    Label("Unsubscribe sweep", systemImage: "xmark.seal.fill")
                    Spacer()
                    if !inbox.neverOpenedNoiseSenders.isEmpty {
                        Text("\(inbox.neverOpenedNoiseSenders.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        } header: {
            Text("Cleanup")
        } footer: {
            Text("Senders you never open that have an unsubscribe option. Batch-unsubscribe in one tap.")
        }
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        let suggestions = inbox.senderSuggestions
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggestion in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.senderName)
                                .foregroundStyle(.primary)
                            Text("Binned \(suggestion.dismissCount) unread")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Mute") { inbox.acceptSuggestion(suggestion) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button {
                            inbox.dismissSenderSuggestion(suggestion)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss suggestion")
                    }
                }
            } header: {
                Text("Suggested rules")
            } footer: {
                Text("Senders you keep binning without opening. Mute one to always file it as noise.")
            }
        }
    }

    // MARK: VIP senders

    private var vipSection: some View {
        Section {
            addRow(placeholder: "Add a VIP sender…", text: $newVIP) {
                inbox.addVIP(newVIP); newVIP = ""
            }
            ForEach(inbox.preferences.vipSenders, id: \.self) { sender in
                Text(sender)
            }
            .onDelete { offsets in
                offsets.map { inbox.preferences.vipSenders[$0] }.forEach(inbox.removeVIP)
            }
        } header: {
            Text("VIP senders")
        } footer: {
            Text("Email, domain, or name — always surfaced, never noise. e.g. boss@acme.com or a friend's name.")
        }
    }

    // MARK: Muted senders

    private var mutedSection: some View {
        Section {
            addRow(placeholder: "Add a muted sender…", text: $newMuted) {
                inbox.addMute(newMuted); newMuted = ""
            }
            ForEach(inbox.preferences.mutedSenders, id: \.self) { sender in
                Text(sender)
            }
            .onDelete { offsets in
                offsets.map { inbox.preferences.mutedSenders[$0] }.forEach(inbox.removeMute)
            }
        } header: {
            Text("Muted senders")
        } footer: {
            Text("Always treated as noise and eligible for auto-file. e.g. linkedin or noreply@.")
        }
    }

    // MARK: Keyword rules

    private var keywordSection: some View {
        Section {
            HStack {
                TextField("Keyword…", text: $newKeyword)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(addKeyword)
                Picker("", selection: $newKeywordLane) {
                    Text("Flag").tag(InboxLane?.none)
                    ForEach(InboxLane.allCases) { lane in
                        Text(lane.title).tag(InboxLane?.some(lane))
                    }
                }
                .labelsHidden()
                Button(action: addKeyword) {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(inbox.preferences.keywordRules) { rule in
                HStack {
                    Text("\"\(rule.keyword)\"")
                    Spacer()
                    Text(rule.targetLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                offsets.map { inbox.preferences.keywordRules[$0].id }.forEach(inbox.removeKeywordRule)
            }
        } header: {
            Text("Keyword rules")
        } footer: {
            Text("When a keyword appears in the sender or text, force the email into a lane — or Flag it into Needs you.")
        }
    }

    // MARK: Category elevate / suppress

    private var categorySection: some View {
        Section {
            ForEach(EmailCategory.assignable) { category in
                HStack {
                    Text(category.label)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { inbox.disposition(for: category) },
                        set: { inbox.setDisposition($0, for: category) }
                    )) {
                        ForEach(CategoryDisposition.allCases) { disposition in
                            Text(disposition.label).tag(disposition)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("Elevate a category to always surface it; suppress one to always file it as noise.")
        }
    }

    // MARK: Helpers

    /// A News-style add row: a text field plus a plus button, disabled while empty.
    private func addRow(placeholder: String, text: Binding<String>, add: @escaping () -> Void) -> some View {
        HStack {
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(add)
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
            }
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func addKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inbox.addKeywordRule(keyword: trimmed, laneRaw: newKeywordLane?.rawValue)
        newKeyword = ""
        newKeywordLane = nil
    }

    // MARK: Hour label helper

    private static func hourLabel(_ hour: Int) -> String {
        let comps = DateComponents(hour: hour, minute: 0)
        guard let date = Calendar.current.date(from: comps) else { return "\(hour):00" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
