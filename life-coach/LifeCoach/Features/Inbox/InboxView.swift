import SwiftUI
import UIKit
import AuthenticationServices

/// The Inbox tab — a read-only chief-of-staff over the user's unread mail. Leads
/// with a synthesized "Brief" line, offers a filter chip per lane, and groups the
/// triaged mail into lanes (rich attention cards for non-noise, compact rows for
/// noise) with a reading drawer for any message. Owns its `InboxStore` as a
/// `@StateObject`; because `InboxStore.init` needs the `AppStore` (which isn't
/// reachable through `@EnvironmentObject` inside `init`), `RootView` hands the
/// store in explicitly.
struct InboxView: View {
    @StateObject private var inbox: InboxStore
    @EnvironmentObject private var googleAuth: GoogleAuth

    /// The action registry every tap routes through (M2) and the agent reuses
    /// (M3). Built once alongside the store and shares its exact instance.
    @State private var capabilities: InboxCapabilities

    /// The "Ask your inbox" agent (M3). Built from the SAME store + capabilities
    /// instance the list uses, so its actions land in the same optimistic state and
    /// undo plumbing — never a second store.
    @StateObject private var agent: InboxAgent

    /// Whether the Ask chat sheet is presented.
    @State private var showingAsk = false

    /// Whether the preferences sheet (M4) is presented.
    @State private var showingPreferences = false

    /// The message the reading drawer is showing, if any.
    @State private var reading: ClassifiedEmail?

    /// The lane the filter chips are focused on; nil = "All".
    @State private var selectedLane: InboxLane?

    /// Auto-refresh on first appear is one-shot.
    @State private var didAutoRefresh = false

    /// Gmail connect flow state.
    @State private var connecting = false
    @State private var authError: String?

    /// Reconnect-to-enable-actions flow: when a write throws `needsReconnect` we
    /// stash the attempted call here and surface the prompt; reconnecting re-runs it.
    @State private var reconnectPrompt = false
    @State private var pendingAction: PendingAction?

    /// A pending tool call captured for retry after a reconnect.
    private struct PendingAction { let name: String; let args: [String: Any] }

    /// A cache older than this on first appear triggers an automatic refresh.
    private static let staleAfter: TimeInterval = 30 * 60

    init(store: AppStore) {
        let inboxStore = InboxStore(store: store)
        let caps = InboxCapabilities(store: inboxStore,
                                     gmail: GmailWriteService(auth: .shared),
                                     auth: .shared)
        // The store drives the auto-file sweep (M4) through this same registry, so it
        // gets the same undoable/reconciled action path as every tap and the agent.
        inboxStore.capabilities = caps
        _inbox = StateObject(wrappedValue: inboxStore)
        _capabilities = State(wrappedValue: caps)
        _agent = StateObject(wrappedValue: InboxAgent(store: inboxStore, capabilities: caps))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Inbox")
                .navigationBarTitleDisplayMode(.inline)
                .overlay(alignment: .bottom) { undoToast }
                .animation(.spring(response: 0.35, dampingFraction: 0.85),
                           value: inbox.lastOutcome?.summary)
                .alert("Reconnect Gmail", isPresented: $reconnectPrompt) {
                    Button("Reconnect") { Task { await reconnectAndRetry() } }
                    Button("Cancel", role: .cancel) { pendingAction = nil }
                } message: {
                    Text("Gmail needs permission to make changes. Reconnect to enable actions like archive, mark read, and unsubscribe.")
                }
        }
        .sheet(item: $reading) { item in
            ReadingDrawer(classified: item) { name, args in
                await perform(name, args: args)
            }
        }
        .sheet(isPresented: $showingAsk) {
            AskInboxView(agent: agent)
        }
        .sheet(isPresented: $showingPreferences) {
            InboxPreferencesView(inbox: inbox)
        }
        .alert("Couldn't connect Gmail",
               isPresented: Binding(get: { authError != nil }, set: { if !$0 { authError = nil } })) {
            Button("OK", role: .cancel) { authError = nil }
        } message: {
            Text(authError ?? "")
        }
        .task { await autoRefreshIfNeeded() }
    }

    /// The bottom undo snackbar shown after any action, while `lastOutcome` is set.
    @ViewBuilder
    private var undoToast: some View {
        if let outcome = inbox.lastOutcome {
            UndoToast(summary: outcome.summary,
                      canUndo: outcome.undo != nil,
                      onUndo: { Task { await inbox.undoLast() } },
                      onDismiss: { inbox.dismissOutcome() })
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !googleAuth.isSignedIn {
            connectState
        } else if inbox.emails.isEmpty {
            if inbox.isRefreshing {
                loadingState
            } else {
                emptyState
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                BriefHeader(
                    brief: inbox.brief,
                    totalUnread: inbox.totalUnread,
                    triagedCount: inbox.triagedCount,
                    lastUpdated: inbox.lastUpdated,
                    isRefreshing: inbox.isRefreshing,
                    onRefresh: { Task { await inbox.refresh() } },
                    onAsk: { showingAsk = true },
                    onPreferences: { showingPreferences = true }
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                if !laneChips.isEmpty {
                    LaneChips(chips: laneChips, total: inbox.triagedCount, selected: $selectedLane)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if !inbox.autoFiled.isEmpty {
                    AutoFileBanner(items: inbox.autoFiled,
                                   onUndoAll: { Task { await inbox.undoAllAutoFiled() } },
                                   onDismiss: { inbox.dismissAutoFiled() })
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            ForEach(displayedLanes, id: \.self) { lane in
                laneSection(lane)
            }
        }
        .listStyle(.plain)
        .refreshable { await inbox.refresh() }
    }

    /// A section for one lane: a colored header (with a bulk menu on the noise
    /// lane), then its rows — attention cards for non-noise, compact rows for noise.
    /// Each row carries swipe actions and a context menu, all routed through the
    /// capability registry.
    @ViewBuilder
    private func laneSection(_ lane: InboxLane) -> some View {
        let items = inbox.emails(in: lane)
        if !items.isEmpty {
            Section {
                // A subtle, dismissible "mute this sender?" suggestion at the top of
                // the noise lane (M4 rule suggestions).
                if lane == .noise, let suggestion = inbox.senderSuggestions.first {
                    SuggestionRow(suggestion: suggestion,
                                  onMute: { inbox.acceptSuggestion(suggestion) },
                                  onDismiss: { inbox.dismissSenderSuggestion(suggestion) })
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(items) { item in
                    laneRow(item, lane: lane)
                }
            } header: {
                laneHeader(lane, items: items)
            }
        }
    }

    /// One tappable row plus its swipe actions and context menu.
    @ViewBuilder
    private func laneRow(_ item: ClassifiedEmail, lane: InboxLane) -> some View {
        Button {
            inbox.signalOpened(item.id)     // positive learning signal (M4)
            reading = item
        } label: {
            if lane.usesCard {
                AttentionCard(classified: item)
            } else {
                CompactRow(classified: item)
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(lane.usesCard
                       ? EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
                       : EdgeInsets())
        .listRowSeparator(lane.usesCard ? .hidden : .automatic)
        .listRowBackground(lane.usesCard ? Color.clear : Color(.secondarySystemBackground))
        .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipe(item) }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingSwipe(item) }
        .contextMenu { rowMenu(for: item) }
    }

    /// A lane's section header, with a bulk "clear" menu on the noise lane.
    @ViewBuilder
    private func laneHeader(_ lane: InboxLane, items: [ClassifiedEmail]) -> some View {
        HStack(spacing: 8) {
            LaneSectionHeader(lane: lane, count: items.count)
            if lane == .noise && items.count > 1 {
                Menu {
                    Button {
                        Task { await bulk("mark_read", items: items) }
                    } label: { Label("Mark all read", systemImage: "envelope.open") }
                    Button(role: .destructive) {
                        Task { await bulk("archive", items: items) }
                    } label: { Label("Archive all", systemImage: "archivebox") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear everything else")
            }
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 6, trailing: 16))
    }

    // MARK: - States

    /// Shown when Gmail isn't connected: a single call-to-action that runs the
    /// OAuth flow, then refreshes into the live inbox.
    private var connectState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Connect your Gmail")
                .font(.title3.weight(.semibold))
            Text("Sapiod watches everything unread and triages it into what actually needs you — Needs you, Waiting, Money, Security and more — led by one chief-of-staff line. Read-only access, tokens stay in your device's Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                Task { await connect() }
            } label: {
                if connecting {
                    ProgressView()
                } else {
                    Label("Connect Gmail", systemImage: "link")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(connecting)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Inbox clear")
                .font(.title3.weight(.semibold))
            Text("Nothing unread to triage right now. Pull to refresh or tap below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Task { await inbox.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Triaging your inbox…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived data

    /// (lane, count) pairs for every active lane, in priority order — the chip row.
    private var laneChips: [(lane: InboxLane, count: Int)] {
        inbox.activeLanes.map { ($0, inbox.count(for: $0)) }
    }

    /// The lanes the list renders: just the selected one (if it still has mail),
    /// otherwise every active lane in priority order.
    private var displayedLanes: [InboxLane] {
        if let selectedLane, inbox.count(for: selectedLane) > 0 {
            return [selectedLane]
        }
        return inbox.activeLanes
    }

    // MARK: - Auto refresh

    /// Run the Gmail OAuth flow, then pull the live inbox on success.
    private func connect() async {
        connecting = true
        defer { connecting = false }
        do {
            try await googleAuth.signIn()
            await inbox.refresh()
        } catch is CancellationError {
            // User dismissed the sheet — no error to show.
        } catch {
            // ASWebAuthenticationSession cancellation surfaces as a specific code;
            // treat it as a silent dismissal, surface anything else.
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionErrorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                return
            }
            authError = error.localizedDescription
        }
    }

    private func autoRefreshIfNeeded() async {
        guard !didAutoRefresh, googleAuth.isSignedIn else { return }
        didAutoRefresh = true

        let isStale: Bool
        if let last = inbox.lastUpdated {
            isStale = Date().timeIntervalSince(last) > Self.staleAfter
        } else {
            isStale = true
        }

        if inbox.emails.isEmpty || isStale {
            await inbox.refresh()
        }
    }

    // MARK: - Actions

    /// Run a tool through the capability registry, record its outcome for the undo
    /// snackbar, open any returned link, and convert a `needsReconnect` failure
    /// into the reconnect prompt. EVERY inbox action funnels through here — the UI
    /// never calls Gmail directly.
    @MainActor
    private func perform(_ name: String, args: [String: Any]) async {
        do {
            let outcome = try await capabilities.run(name, args: args)
            inbox.lastOutcome = outcome
            if let url = outcome.openURL {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        } catch InboxToolError.needsReconnect {
            pendingAction = PendingAction(name: name, args: args)
            reconnectPrompt = true
        } catch {
            // Surface the failure in the same snackbar slot (no undo).
            inbox.lastOutcome = InboxToolOutcome(
                summary: "Couldn't complete: \(error.localizedDescription)",
                affectedIDs: [])
        }
    }

    /// Apply a per-item action across a whole lane via the `bulk_apply` tool.
    private func bulk(_ action: String, items: [ClassifiedEmail]) async {
        await perform("bulk_apply",
                      args: ["action": action, "message_ids": items.map { $0.id }])
    }

    /// Re-run the OAuth flow (re-requesting the `gmail.modify` scope), refresh, then
    /// retry the action that triggered the reconnect.
    private func reconnectAndRetry() async {
        do {
            try await googleAuth.signIn()
            await inbox.refresh()
            if let pending = pendingAction {
                pendingAction = nil
                await perform(pending.name, args: pending.args)
            }
        } catch is CancellationError {
            pendingAction = nil
        } catch {
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionErrorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                pendingAction = nil
                return
            }
            authError = error.localizedDescription
            pendingAction = nil
        }
    }

    /// Hours from now until ~8am tomorrow, for the "Until tomorrow" snooze.
    private func snoozeHoursUntilTomorrow() -> Int {
        let cal = Calendar.current
        let now = Date()
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
              let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) else {
            return 24
        }
        return max(1, Int(ceil(morning.timeIntervalSince(now) / 3600)))
    }

    // MARK: - Row actions (swipe + context menu)

    /// Leading swipe: toggle read / unread.
    @ViewBuilder
    private func leadingSwipe(_ item: ClassifiedEmail) -> some View {
        let isUnread = item.email.isUnread
        Button {
            Task { await perform(isUnread ? "mark_read" : "mark_unread",
                                 args: ["message_id": item.id]) }
        } label: {
            Label(isUnread ? "Read" : "Unread",
                  systemImage: isUnread ? "envelope.open" : "envelope.badge")
        }
        .tint(.blue)
    }

    /// Trailing swipe: Archive, plus Unsubscribe for bulk mail.
    @ViewBuilder
    private func trailingSwipe(_ item: ClassifiedEmail) -> some View {
        Button(role: .destructive) {
            Task { await perform("archive", args: ["message_id": item.id]) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        if item.email.hasUnsubscribe {
            Button {
                Task { await perform("unsubscribe", args: ["message_id": item.id]) }
            } label: {
                Label("Unsubscribe", systemImage: "hand.raised")
            }
            .tint(.orange)
        }
    }

    /// Long-press context menu mirroring the swipe actions plus Snooze + Open.
    @ViewBuilder
    private func rowMenu(for item: ClassifiedEmail) -> some View {
        let isUnread = item.email.isUnread
        Button {
            Task { await perform(isUnread ? "mark_read" : "mark_unread",
                                 args: ["message_id": item.id]) }
        } label: {
            Label(isUnread ? "Mark read" : "Mark unread",
                  systemImage: isUnread ? "envelope.open" : "envelope.badge")
        }
        Button {
            Task { await perform("archive", args: ["message_id": item.id]) }
        } label: { Label("Archive", systemImage: "archivebox") }
        Menu {
            Button("In 3 hours") {
                Task { await perform("snooze", args: ["message_id": item.id, "hours": 3]) }
            }
            Button("Until tomorrow") {
                Task { await perform("snooze",
                                     args: ["message_id": item.id, "hours": snoozeHoursUntilTomorrow()]) }
            }
        } label: { Label("Snooze", systemImage: "clock") }
        if item.email.hasUnsubscribe {
            Button {
                Task { await perform("unsubscribe", args: ["message_id": item.id]) }
            } label: { Label("Unsubscribe", systemImage: "hand.raised") }
        }
        Divider()
        Button {
            InboxLinks.openInGmail(item.email)
        } label: { Label("Open in Gmail", systemImage: "arrow.up.forward.app") }
    }
}

// MARK: - Brief header

/// The chief-of-staff brief line, plus a stats row ("Watching N unread · triaged
/// M" / "Updated <relative>") and the Refresh button.
private struct BriefHeader: View {
    let brief: String
    let totalUnread: Int
    let triagedCount: Int
    let lastUpdated: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    /// Opens the "Ask your inbox" chat (M3).
    let onAsk: () -> Void
    /// Opens the inbox preferences sheet (M4).
    let onPreferences: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !brief.isEmpty {
                Text(brief)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(watchLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(updatedLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button(action: onAsk) {
                    Label("Ask", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Ask your inbox")
                Button(action: onPreferences) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .accessibilityLabel("Inbox preferences")
                Button(action: onRefresh) {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh inbox")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var watchLine: String {
        let unread = totalUnread == 1 ? "Watching 1 unread" : "Watching \(totalUnread) unread"
        return "\(unread) · triaged \(triagedCount)"
    }

    private var updatedLine: String {
        guard let lastUpdated else { return "Not refreshed yet" }
        return "Updated \(InboxFormat.relative(lastUpdated))"
    }
}

// MARK: - Filter chips

/// A horizontally scrolling row of lane filter chips plus an "All" chip. Each chip
/// shows its lane title + live count, tinted with the lane color; tapping toggles
/// the focus.
private struct LaneChips: View {
    let chips: [(lane: InboxLane, count: Int)]
    let total: Int
    @Binding var selected: InboxLane?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "All",
                     count: total,
                     color: .accentColor,
                     isSelected: selected == nil) {
                    selected = nil
                }
                ForEach(chips, id: \.lane) { item in
                    Chip(title: item.lane.title,
                         count: item.count,
                         color: item.lane.color,
                         isSelected: selected == item.lane) {
                        selected = (selected == item.lane) ? nil : item.lane
                    }
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 1)
        }
    }

    private struct Chip: View {
        let title: String
        let count: Int
        let color: Color
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? .white : .secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : color)
                .background(isSelected ? color : color.opacity(0.12), in: Capsule())
                .overlay(
                    Capsule().stroke(color.opacity(isSelected ? 0 : 0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(count)")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
    }
}

// MARK: - Lane section header

/// A lane's section header: its icon + title + count, in the lane color.
private struct LaneSectionHeader: View {
    let lane: InboxLane
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: lane.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(lane.color)
            Text(lane.title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Attention card (non-noise lanes)

/// A rich card for an attention email: sender + time, prominent subject, the 2–3
/// line AI summary, a fine-category badge in the lane color, an optional "Waiting
/// on you" badge, an unread dot, and the de-emphasized one-line reason footnote.
private struct AttentionCard: View {
    let classified: ClassifiedEmail

    private var email: EmailMessage { classified.email }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if email.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                }
                Text(email.senderName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(InboxFormat.relative(email.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(email.subject)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if !classified.summary.isEmpty {
                Text(classified.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let category = classified.category {
                        CategoryBadge(category: category)
                    }
                    if classified.waitingOnYou {
                        WaitingBadge()
                    }
                    Spacer(minLength: 0)
                }
                if !classified.reason.isEmpty {
                    Text(classified.reason)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Compact row (noise)

/// A single-line compact row: sender · subject · 1-line AI summary · time. Unread
/// rows are bolder with a filled dot.
private struct CompactRow: View {
    let classified: ClassifiedEmail

    private var email: EmailMessage { classified.email }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(email.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(email.senderName)
                        .font(.subheadline.weight(email.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(email.subject)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(InboxFormat.relative(email.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// Prefer the 1-line AI summary; fall back to the snippet if absent.
    private var summaryLine: String {
        classified.summary.isEmpty ? email.snippet : classified.summary
    }
}

// MARK: - Badges

/// A small, tasteful filled capsule for an email's fine `EmailCategory`, tinted
/// with its lane color.
private struct CategoryBadge: View {
    let category: EmailCategory

    var body: some View {
        Text(category.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(category.badgeColor, in: Capsule())
    }
}

/// The "Waiting on you" badge shown when a real person awaits the user's reply.
private struct WaitingBadge: View {
    var body: some View {
        Label("Waiting on you", systemImage: "arrowshape.turn.up.left")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(InboxLane.waiting.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(InboxLane.waiting.color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Reading drawer

/// The bottom drawer for reading a single email: subject/sender/time header, the
/// AI summary up top, then the real full body. A single nav action opens Gmail.
private struct ReadingDrawer: View {
    let classified: ClassifiedEmail
    /// Routes the drawer's actions through the same capability registry the list
    /// uses (mark read/unread, archive, unsubscribe).
    let perform: (String, [String: Any]) async -> Void
    @Environment(\.dismiss) private var dismiss

    private var email: EmailMessage { classified.email }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if !classified.summary.isEmpty {
                        summaryBlock
                    }

                    Divider()

                    Text(email.body)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding()
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            act(email.isUnread ? "mark_read" : "mark_unread")
                        } label: {
                            Label(email.isUnread ? "Mark read" : "Mark unread",
                                  systemImage: email.isUnread ? "envelope.open" : "envelope.badge")
                        }
                        Button {
                            act("archive", dismissAfter: true)
                        } label: { Label("Archive", systemImage: "archivebox") }
                        if email.hasUnsubscribe {
                            Button {
                                act("unsubscribe")
                            } label: { Label("Unsubscribe", systemImage: "hand.raised") }
                        }
                        Divider()
                        Button {
                            InboxLinks.openInGmail(email)
                        } label: { Label("Open in Gmail", systemImage: "arrow.up.forward.app") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Run an action for this message, optionally dismissing the drawer after
    /// (e.g. archive, which removes it from the list behind the sheet).
    private func act(_ name: String, dismissAfter: Bool = false) {
        Task {
            await perform(name, ["message_id": classified.id])
            if dismissAfter { dismiss() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let category = classified.category {
                    CategoryBadge(category: category)
                }
                if classified.waitingOnYou {
                    WaitingBadge()
                }
                Spacer(minLength: 0)
                Text(InboxFormat.absolute(email.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(email.subject)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(email.senderName) · \(email.senderEmail)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Summary", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(classified.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Undo snackbar

/// A bottom snackbar showing the last action's summary with an optional Undo
/// button. Auto-dismisses after a few seconds; tapping ✕ dismisses immediately.
private struct UndoToast: View {
    let summary: String
    let canUndo: Bool
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if canUndo {
                Button(action: onUndo) {
                    Text("Undo").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(.systemBlue))
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .task(id: summary) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            onDismiss()
        }
    }
}

// MARK: - Auto-file review banner (M4)

/// A dismissible banner summarizing what the refresh sweep auto-filed. Tapping it
/// expands the list of filed messages; "Undo all" reverses every archive in one go.
/// Surfaces the app's autonomy transparently — nothing is filed silently.
private struct AutoFileBanner: View {
    let items: [AutoFiledItem]
    let onUndoAll: () -> Void
    let onDismiss: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 10 : 0) {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Auto-filed \(items.count) — review")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }

            if expanded {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(item.senderName) · \(item.subject)")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(item.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button("Undo all", action: onUndoAll)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Dismiss", action: onDismiss)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InboxLane.noise.color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(InboxLane.noise.color.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rule suggestion row (M4)

/// A subtle, dismissible one-tap suggestion at the top of the noise lane: mute a
/// sender the user keeps binning unread.
private struct SuggestionRow: View {
    let suggestion: SenderSuggestion
    let onMute: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Always file \(suggestion.senderName) as noise?")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("You've binned the last \(suggestion.dismissCount) untouched")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Mute", action: onMute)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Gmail linking

/// Centralized "Open in Gmail" routing. Tries the Gmail web permalink (the
/// universal link), then falls back to the Gmail app's custom scheme.
enum InboxLinks {
    static func openInGmail(_ email: EmailMessage) {
        // TODO: exact thread deep-link finalized during live Gmail wiring
        let permalink = URL(string: "https://mail.google.com/mail/u/0/#all/\(email.threadId)")
        let scheme = URL(string: "googlegmail://")

        if let permalink {
            UIApplication.shared.open(permalink, options: [:]) { opened in
                if !opened, let scheme {
                    UIApplication.shared.open(scheme)
                }
            }
        } else if let scheme {
            UIApplication.shared.open(scheme)
        }
    }
}

// MARK: - Formatting

/// Shared, locale-aware date formatting for the Inbox.
private enum InboxFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// e.g. "3h ago", "now".
    static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// e.g. "Jun 14, 3:42 PM" for the reading drawer header.
    static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Ask your inbox (M3)

/// The "Ask your inbox" chat surface. A scroll of user/assistant bubbles; beneath
/// an in-progress assistant turn it renders `agent.steps` as a live, monospaced
/// action log so the user watches the agent search and act in real time. Suggested
/// prompts seed first use; the send bar is disabled while the agent is thinking.
/// The agent shares the inbox's store + capabilities, so any write it makes surfaces
/// in the inbox's existing undo snackbar behind this sheet.
///
/// Voice layer (on top of the unchanged text path):
/// - **Mic button**: tap to start recording (InboxVoiceRecorder), tap again to stop
///   → InboxVoiceSTT transcribes → transcript lands in the text field and is
///   auto-sent through the same `send()` path the keyboard send button uses. The
///   agent logic is untouched.
/// - **Speak replies toggle**: when enabled, each completed assistant reply is
///   spoken via InboxVoiceTTS (AVSpeechSynthesizer, on-device, no download).
/// - Both wrappers are initialized lazily — non-voice users pay nothing.
private struct AskInboxView: View {
    @ObservedObject var agent: InboxAgent
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    /// Completed exchanges, oldest first.
    @State private var turns: [Turn] = []
    /// The user message currently being processed, shown above the live action log.
    @State private var pending: String?
    @FocusState private var inputFocused: Bool

    // MARK: Voice state (lazy — nil until first use)

    @StateObject private var recorder = InboxVoiceRecorder()
    @StateObject private var stt = InboxVoiceSTT()
    @StateObject private var tts = InboxVoiceTTS()

    /// Whether voice speak-back is enabled. Persisted per session only (no
    /// UserDefaults — the toggle is visible in the toolbar).
    @State private var speakReplies = false

    /// Any inline error from the voice layer (STT failure, no mic permission, etc.).
    @State private var voiceError: String?

    /// One completed user → assistant exchange.
    private struct Turn: Identifiable {
        let id = UUID()
        let user: String
        let assistant: String
    }

    private static let suggestions = [
        "What needs me today?",
        "Anything waiting on my reply?",
        "Clear my promos",
        "Unsubscribe from newsletters I never open",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                conversation
                // Inline voice-error banner (dismissible).
                if let voiceError {
                    VoiceErrorBanner(message: voiceError) {
                        self.voiceError = nil
                    }
                }
                Divider()
                inputBar
            }
            .navigationTitle("Ask your inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Speak-replies toggle: microphone.badge.waveform when ON.
                    Button {
                        speakReplies.toggle()
                        if !speakReplies { tts.stop() }
                    } label: {
                        Image(systemName: speakReplies
                              ? "speaker.wave.2.fill"
                              : "speaker.slash")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(speakReplies ? Color.accentColor : Color.secondary)
                    }
                    .accessibilityLabel(speakReplies ? "Speak replies on" : "Speak replies off")
                    .accessibilityHint("Toggle spoken read-back of assistant replies")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        tts.stop()
                        if recorder.isRecording { _ = recorder.stop() }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if turns.isEmpty && pending == nil {
                        intro
                    }
                    ForEach(turns) { turn in
                        ChatBubble(role: .user, text: turn.user)
                        ChatBubble(role: .assistant, text: turn.assistant)
                    }
                    if let pending {
                        ChatBubble(role: .user, text: pending)
                        AgentActionLog(steps: agent.steps, isThinking: agent.isThinking)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: agent.steps.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: turns.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: pending) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    /// First-use intro plus tappable suggested prompts.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Ask your inbox", systemImage: "sparkles")
                    .font(.headline)
                Text("Ask in plain language and I'll search, summarize, and act on your mail — safely. Bulk changes are confirmed first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button { send(suggestion) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text(suggestion)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    /// The input bar: mic button + text field + send button. The mic button
    /// replaces the send button while recording, but the text field remains
    /// editable so the user can correct the transcript if needed.
    private var inputBar: some View {
        HStack(spacing: 10) {
            // Mic button — toggles recording; shows a level bar while active.
            MicButton(recorder: recorder,
                      isDisabled: agent.isThinking || stt.status == .downloading) {
                Task { await toggleRecording() }
            }

            TextField("Ask your inbox…", text: $input)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .focused($inputFocused)
                .disabled(agent.isThinking || recorder.isRecording)
                .submitLabel(.send)
                .onSubmit { send(input) }

            Button {
                send(input)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(agent.isThinking
                      || recorder.isRecording
                      || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Send

    /// Send a message: stash it as the pending turn, run the agent, then file the
    /// completed exchange. Guards against sending while a turn is in flight.
    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !agent.isThinking, pending == nil else { return }
        input = ""
        inputFocused = false
        pending = trimmed
        Task {
            let reply = await agent.ask(trimmed)
            turns.append(Turn(user: trimmed, assistant: reply))
            pending = nil
            // Speak the reply if voice mode is on.
            if speakReplies {
                tts.speak(reply)
            }
        }
    }

    // MARK: - Voice recording + STT

    /// Toggle recording: start if idle, stop + transcribe if already recording.
    private func toggleRecording() async {
        voiceError = nil
        if recorder.isRecording {
            guard let fileURL = recorder.stop() else { return }
            await transcribeAndSend(fileURL: fileURL)
        } else {
            tts.stop()      // silence TTS before the mic opens
            let granted = await recorder.start()
            if !granted {
                voiceError = "Allow microphone access in Settings to use voice input."
            }
        }
    }

    /// Run STT on the recorded file; put the transcript in the text field and
    /// auto-send it through the existing agent path.
    private func transcribeAndSend(fileURL: URL) async {
        do {
            let transcript = try await stt.transcribe(audioPath: fileURL)
            guard !transcript.isEmpty else { return }
            // Put text in field (visible feedback) then send immediately.
            input = transcript
            send(transcript)
        } catch {
            voiceError = "Couldn't transcribe: \(error.localizedDescription). Check your connection for the first model download."
        }
    }
}

// MARK: - Mic button

/// A small mic button that shows the current audio level as a growing circle
/// while recording. Tapping it calls `action`.
private struct MicButton: View {
    @ObservedObject var recorder: InboxVoiceRecorder
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if recorder.isRecording {
                    // Level ring: grows with audio loudness.
                    Circle()
                        .fill(Color.red.opacity(0.15 + Double(recorder.audioLevel) * 0.45))
                        .frame(width: 36, height: 36)
                        .animation(.easeOut(duration: 0.08), value: recorder.audioLevel)
                }
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start voice input")
    }
}

// MARK: - Voice error banner

/// A slim inline banner that shows a voice-layer error with a dismiss button.
/// Sits between the conversation and the input divider so it never pushes the
/// input bar off screen.
private struct VoiceErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemBackground))
    }
}

/// A single chat bubble — user (accent, trailing) or assistant (neutral, leading).
private struct ChatBubble: View {
    enum Role { case user, assistant }
    let role: Role
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if role == .user { Spacer(minLength: 44) }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(role == .user ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(role == .user ? Color.accentColor : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if role == .assistant { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The live action log under an in-progress assistant turn: one subtle, monospaced
/// row per `InboxAgent.Step` (the tool it ran + a one-line "what it did"), plus a
/// thinking indicator while the agent is still working.
private struct AgentActionLog: View {
    let steps: [InboxAgent.Step]
    let isThinking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: icon(for: step.tool))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 15)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label(for: step))
                            .font(.caption.weight(.medium))
                            .monospaced()
                            .foregroundStyle(.secondary)
                        if !step.observation.isEmpty {
                            Text(firstLine(step.observation))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            if isThinking {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(steps.isEmpty ? "Thinking…" : "Working…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "tool (args)" for the action log's primary line.
    private func label(for step: InboxAgent.Step) -> String {
        guard let tool = step.tool else { return "thinking" }
        return step.args.isEmpty ? tool : "\(tool) (\(step.args))"
    }

    private func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private func icon(for tool: String?) -> String {
        switch tool {
        case "search_emails": return "magnifyingglass"
        case "get_email": return "doc.text"
        case "mark_read", "mark_unread": return "envelope"
        case "archive": return "archivebox"
        case "unsubscribe": return "hand.raised"
        case "snooze": return "clock"
        case "bulk_apply": return "square.stack.3d.up"
        default: return "circle.dotted"
        }
    }
}
