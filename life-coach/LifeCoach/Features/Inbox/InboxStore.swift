import Foundation
import Combine

/// In-memory + on-disk cache of the triaged inbox. Loads the last cache instantly
/// on init, and `refresh()` fetches -> classifies -> briefs -> publishes ->
/// persists to `inbox-cache.json` via the shared `FileStore` pattern.
///
/// M2 adds an OPTIMISTIC local action layer: `allEmails` is the full triaged
/// working set, while the published `emails` is that set with snoozed-and-not-due
/// items filtered out. Tools (run through `InboxCapabilities`) mutate the local
/// state immediately so taps feel instant; Gmail is the source of truth and is
/// reconciled on the next `refresh()`. The most recent action's outcome is held in
/// `lastOutcome` for the undo snackbar.
@MainActor
final class InboxStore: ObservableObject {
    /// The VISIBLE working set: `allEmails` minus snoozed-and-not-yet-due items,
    /// newest first. This is what every view binds to.
    @Published private(set) var emails: [ClassifiedEmail] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    /// True count of everything unread (can far exceed the triaged working set).
    @Published private(set) var totalUnread = 0
    /// How many emails are currently visible (triaged minus snoozed/archived).
    @Published private(set) var triagedCount = 0
    /// The chief-of-staff one-liner shown at the top of the Inbox.
    @Published private(set) var brief = ""

    /// The most recent action's outcome — the view renders it as an undo snackbar.
    /// Settable so the UI can record the result of an `InboxCapabilities.run` call
    /// and clear it on dismiss.
    @Published var lastOutcome: InboxToolOutcome?

    /// The user's standing preferences (M4). Published so the preferences sheet binds
    /// to it live; every edit routes through a mutator that persists and re-applies.
    @Published private(set) var preferences: InboxPreferences

    /// Messages the most recent refresh auto-filed (archived) because they matched a
    /// mute rule or a high-confidence noise sender. Drives the "Auto-filed N — review"
    /// banner with its Undo-all. Empty until a sweep files something.
    @Published private(set) var autoFiled: [AutoFiledItem] = []

    /// Sender suggestions the user has dismissed this session, so a one-tap "mute X?"
    /// suggestion doesn't keep reappearing after they wave it off.
    @Published private(set) var dismissedSenderSuggestions: Set<String> = []

    /// The full triaged set behind `emails`. Archive removes from here; mark
    /// read/unread mutates an entry here; snooze leaves it here but hides it from
    /// the published `emails` until due.
    private var allEmails: [ClassifiedEmail] = []

    /// message id -> resurface date. An entry hides its message from `emails`
    /// until `Date() >= date`. Persisted separately in `inbox-snooze.json`.
    private var snoozes: [String: Date] = [:]

    /// The app store behind the inbox — retained so M3's `InboxAgent` can resolve
    /// the SAME active AI provider/model the classifier uses
    /// (`appStore.state.ai.provider` / `.activeModel`) without threading a second
    /// dependency through the view. AppStore is a long-lived top-level object, so
    /// the strong reference is safe and creates no cycle.
    let appStore: AppStore

    /// The capability registry, injected by the view AFTER construction (the registry
    /// needs the store, so the store can't own it at init). `weak` so there's no
    /// retain cycle. Used only by the auto-file sweep, which routes its archives
    /// through the same undoable/reconciled tools every other action uses.
    weak var capabilities: InboxCapabilities?

    /// On-device importance learning (M4). A NUDGE for within-lane ordering, never an
    /// override. Persisted to `inbox-importance.json`.
    private var importance: ImportanceEngine
    /// Per-sender behavioural stats (M4) driving dispositions, suggestions, and the
    /// auto-file sweep. Persisted to `inbox-senders.json`.
    private var senderMemory: SenderMemory

    /// The classifier's RAW verdicts for the current set, BEFORE preference overrides.
    /// Kept for the session so toggling a preference (e.g. un-suppressing a category)
    /// can re-derive lanes from the original verdict rather than from already-overridden
    /// data. Rebuilt on each refresh; on a cold launch it equals the cached
    /// (overridden) set, so an un-suppress before the first refresh only fully restores
    /// the natural lane after the next refresh.
    private var rawClassified: [ClassifiedEmail] = []

    /// id -> the email's embedding, computed once and reused for both importance
    /// signals and the nudge re-rank so we never re-embed on every sort.
    private var embeddingCache: [String: [Double]] = [:]
    /// id -> the soft nudge score (see `InboxRanker.nudge`). Recomputed on refresh and
    /// after every learning signal; read by `emails(in:)` to bias ordering.
    private var nudgeScores: [String: Double] = [:]

    /// Test/preview override. When nil, the service resolves live from Gmail
    /// sign-in state, so connecting Gmail switches the source with no re-init.
    private let overrideService: EmailService?
    private let mockService = MockEmailService()
    private let gmailService = GmailService(auth: .shared)
    private let classifier: InboxClassifier
    private let fileStore = FileStore<Cache>(filename: "inbox-cache.json")
    private let snoozeStore = FileStore<SnoozeCache>(filename: "inbox-snooze.json")
    private let prefsStore = FileStore<InboxPreferences>(filename: "inbox-prefs.json")
    private let importanceStore = FileStore<ImportanceEngine>(filename: "inbox-importance.json")
    private let senderStore = FileStore<SenderMemory>(filename: "inbox-senders.json")
    /// M5: incremental sync state (historyId) + dedup of already-notified ids.
    private let watchStore = FileStore<WatchState>(filename: "inbox-watch.json")

    /// The active source: a test override if injected, else live Gmail when the
    /// user is connected, else the built-in mock demo inbox.
    private var service: EmailService {
        if let overrideService { return overrideService }
        return GoogleAuth.shared.isSignedIn ? gmailService : mockService
    }

    /// M5 watch state: the last-seen Gmail historyId for incremental sync, and the
    /// set of message IDs already notified so the same message is never alerted twice.
    private var watchState: WatchState

    /// The on-disk shape: the (full) classified set, when they were last refreshed,
    /// the unread total, and the cached brief line.
    private struct Cache: Codable {
        var emails: [ClassifiedEmail]
        var lastUpdated: Date?
        var totalUnread: Int
        var brief: String

        init(emails: [ClassifiedEmail] = [],
             lastUpdated: Date? = nil,
             totalUnread: Int = 0,
             brief: String = "") {
            self.emails = emails
            self.lastUpdated = lastUpdated
            self.totalUnread = totalUnread
            self.brief = brief
        }

        enum CodingKeys: String, CodingKey { case emails, lastUpdated, totalUnread, brief }

        /// Tolerant decode so an older cache (no `totalUnread` / `brief`) loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            emails = try c.decodeIfPresent([ClassifiedEmail].self, forKey: .emails) ?? []
            lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated)
            totalUnread = try c.decodeIfPresent(Int.self, forKey: .totalUnread) ?? 0
            brief = try c.decodeIfPresent(String.self, forKey: .brief) ?? ""
        }
    }

    /// On-disk shape for the local snooze map.
    private struct SnoozeCache: Codable {
        var entries: [String: Date]

        init(entries: [String: Date] = [:]) { self.entries = entries }

        enum CodingKeys: String, CodingKey { case entries }

        /// Tolerant decode so a missing/old file just yields an empty map.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entries = try c.decodeIfPresent([String: Date].self, forKey: .entries) ?? [:]
        }
    }

    init(store: AppStore, service: EmailService? = nil) {
        self.appStore = store
        self.overrideService = service
        self.classifier = InboxClassifier(store: store)

        // Load the last cache + snooze map + learning + prefs instantly so the UI has
        // something to show on launch.
        let cached = fileStore.load(default: Cache())
        allEmails = cached.emails
        // The cache holds the already-overridden set; until the next refresh rebuilds
        // it, treat it as the raw base too (see `rawClassified`).
        rawClassified = cached.emails
        snoozes = snoozeStore.load(default: SnoozeCache()).entries
        preferences = prefsStore.load(default: InboxPreferences())
        importance = importanceStore.load(default: ImportanceEngine())
        senderMemory = senderStore.load(default: SenderMemory())
        watchState = watchStore.load(default: WatchState())
        lastUpdated = cached.lastUpdated
        brief = cached.brief
        // Old caches predate `totalUnread`; fall back to the unread count we have.
        totalUnread = cached.totalUnread > 0
            ? cached.totalUnread
            : cached.emails.filter { $0.email.isUnread }.count

        scheduleNudgeRecompute()
        republish()
    }

    /// Convenience for the two original sections - kept for any older consumer.
    var needsAttention: [ClassifiedEmail] { emails.filter { $0.important } }
    var everythingElse: [ClassifiedEmail] { emails.filter { !$0.important } }

    // MARK: - Lane buckets

    /// Emails in `lane`, newest first — with the soft learning nudge blended in so a
    /// VIP-leaning / important-looking sender rises a little and a noise-leaning one
    /// sinks. The nudge only ever reorders WITHIN the lane; it can never move an email
    /// to another lane, so recency stays primary and the taxonomy is untouched.
    func emails(in lane: InboxLane) -> [ClassifiedEmail] {
        emails.filter { $0.lane == lane }
            .sorted { nudgedSortDate($0) > nudgedSortDate($1) }
    }

    /// An email's date shifted by its nudge: a strong positive nudge pulls it up to a
    /// few hours "newer" in the ordering, a negative one pushes it down. Gentle by
    /// design — it only flips genuinely near-tied items.
    private func nudgedSortDate(_ item: ClassifiedEmail) -> Date {
        let nudge = nudgeScores[item.id] ?? 0
        // Up to ±9h of reordering pull at the ±1.5 nudge extremes.
        return item.email.date.addingTimeInterval(nudge * 6 * 3600)
    }

    /// How many emails are in `lane`.
    func count(for lane: InboxLane) -> Int {
        emails.reduce(0) { $0 + ($1.lane == lane ? 1 : 0) }
    }

    /// Lanes that currently hold at least one email, in display priority order.
    var activeLanes: [InboxLane] {
        InboxLane.allCases
            .filter { count(for: $0) > 0 }
            .sorted { $0.sortPriority < $1.sortPriority }
    }

    // MARK: - Lookups (used by the tools)

    /// The FULL triaged working set (including snoozed/hidden items), newest first
    /// — the read-only surface M3's `search_emails` query tool enumerates. Distinct
    /// from the published `emails`, which hides snoozed-and-not-due mail.
    var allClassified: [ClassifiedEmail] { allEmails }

    /// The classified email with `id`, searched across the FULL set (including
    /// snoozed/hidden), or nil.
    func email(for id: String) -> ClassifiedEmail? {
        allEmails.first { $0.id == id }
    }

    /// The sender display name for `id`, for action summaries; nil if unknown.
    func senderName(for id: String) -> String? {
        email(for: id)?.email.senderName
    }

    // MARK: - Optimistic local mutations (driven by InboxCapabilities tools)

    /// Flip the unread flag on a message locally and republish. No-op if absent.
    /// Marking a message READ is a learning signal: a `markedRead` sender stat (and,
    /// when the sender keeps being binned unread, a contributor to noise-leaning).
    func setUnread(_ isUnread: Bool, id: String) {
        guard let index = allEmails.firstIndex(where: { $0.id == id }) else { return }
        var email = allEmails[index].email
        guard email.isUnread != isUnread else { return }
        let wasUnread = email.isUnread
        email.isUnread = isUnread
        allEmails[index] = allEmails[index].withEmail(email)
        // Unread -> read without ever opening is the "dismissed it from the list" signal.
        if wasUnread && !isUnread {
            senderMemory.record(email.senderEmail, markedRead: 1)
            persistLearning()
            scheduleNudgeRecompute()
        }
        republish()
        persist()
    }

    /// Remove a message from the working set entirely (optimistic archive),
    /// returning the removed item so an undo can re-insert it. nil if absent.
    /// Archiving is a NEGATIVE importance signal plus an `archived` sender stat — this
    /// is the single central archive path (taps, the agent, and the auto-file sweep all
    /// funnel through it), so learning is captured once, here.
    @discardableResult
    func removeEmail(id: String) -> ClassifiedEmail? {
        guard let index = allEmails.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = allEmails.remove(at: index)
        senderMemory.record(removed.email.senderEmail, archived: 1)
        importance.reinforce(positive: false, vector: embedding(for: removed))
        persistLearning()
        republish()
        persist()
        scheduleNudgeRecompute()
        return removed
    }

    /// Re-insert a previously removed message (the undo of archive), newest first.
    func insertEmail(_ classified: ClassifiedEmail) {
        guard !allEmails.contains(where: { $0.id == classified.id }) else { return }
        allEmails.append(classified)
        allEmails.sort { $0.email.date > $1.email.date }
        republish()
        persist()
    }

    /// Hide a message until `date`, persisting the snooze map. Snoozing is treated as
    /// a mild NEGATIVE importance signal (the user pushed it away for now).
    func snooze(id: String, until date: Date) {
        snoozes[id] = date
        if let item = email(for: id) {
            importance.reinforce(positive: false, vector: embedding(for: item))
            persistLearning()
            scheduleNudgeRecompute()
        }
        persistSnoozes()
        republish()
    }

    // MARK: - Learning signals (M4)

    /// Record that the user OPENED `id` in the reading drawer — a POSITIVE importance
    /// signal plus an `opened` sender stat (which can flip a sender to VIP-leaning).
    /// Called from the view the moment the drawer opens.
    func signalOpened(_ id: String) {
        guard let item = email(for: id) else { return }
        senderMemory.record(item.email.senderEmail, opened: 1)
        importance.reinforce(positive: true, vector: embedding(for: item))
        persistLearning()
        scheduleNudgeRecompute()
        republish()
    }

    /// Record that the user UNSUBSCRIBED from `id`'s sender — a NEGATIVE importance
    /// signal plus an `unsubscribed` sender stat. Called from the unsubscribe tool.
    func signalUnsubscribed(_ id: String) {
        guard let item = email(for: id) else { return }
        senderMemory.record(item.email.senderEmail, unsubscribed: 1)
        importance.reinforce(positive: false, vector: embedding(for: item))
        persistLearning()
        scheduleNudgeRecompute()
    }

    /// Cancel a snooze (the undo of snooze).
    func unsnooze(id: String) {
        guard snoozes.removeValue(forKey: id) != nil else { return }
        persistSnoozes()
        republish()
    }

    // MARK: - Undo snackbar

    /// Run the last action's undo (if any) and clear the snackbar.
    func undoLast() async {
        guard let undo = lastOutcome?.undo else { lastOutcome = nil; return }
        await undo()
        lastOutcome = nil
    }

    /// Dismiss the snackbar without undoing.
    func dismissOutcome() { lastOutcome = nil }

    // MARK: - Refresh

    /// Fetch the latest inbox, classify it, build the brief, publish, and persist.
    /// Best-effort: a fetch failure leaves the previous cache intact. Refreshing
    /// reconciles the optimistic local state with Gmail (the source of truth).
    ///
    /// After a successful full fetch, the current mailbox `historyId` is captured
    /// so subsequent `backgroundRefresh()` calls can use the cheaper incremental
    /// `history.list` path instead of paging through all unread messages.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let fetch: InboxFetch
        do {
            fetch = try await service.fetchRecent()
        } catch {
            // Keep whatever we already had cached.
            return
        }

        // Capture historyId after a successful full fetch so the next background
        // refresh can use the incremental path. Only meaningful for the live service.
        if GoogleAuth.shared.isSignedIn {
            let freshHistoryId = try? await gmailService.currentHistoryId()
            if let hid = freshHistoryId, hid != watchState.historyId {
                watchState.historyId = hid
                persistWatchState()
            }
        }

        let classified = await classifier.classify(fetch.messages,
                                                    preferencesHint: preferences.promptSummary())
        // Newest first; the UI groups by lane from here. Keep the raw verdicts so a
        // later preference toggle can re-derive lanes from the original classification.
        let sorted = classified.sorted { $0.email.date > $1.email.date }
        rawClassified = sorted
        // Apply the user's HARD preference overrides on top of the classifier.
        let overridden = sorted.map { InboxRanker.override($0, preferences: preferences) }
        let line = await classifier.brief(for: overridden, totalUnread: fetch.totalUnread)

        allEmails = overridden
        totalUnread = fetch.totalUnread
        brief = line
        lastUpdated = Date()

        // Every sender in the batch was "seen" once this refresh — the denominator
        // behind the noise/VIP dispositions.
        for item in overridden { senderMemory.record(item.email.senderEmail, seen: 1) }
        persistLearning()

        // Prune stale snoozes: drop any that are past-due or whose message Gmail no
        // longer returns, so the map can't grow without bound.
        pruneSnoozes()
        // Drop cached embeddings/scores for messages Gmail no longer returns.
        pruneEmbeddingCache()

        scheduleNudgeRecompute()
        republish()
        persist()

        // Auto-file the high-confidence noise (muted senders + learned-noise senders)
        // through the capability registry so each archive is undoable and reconciled.
        await autoFileIfEnabled()
    }

    // MARK: - Background incremental refresh (M5)

    /// Runs an incremental refresh (via `history.list` when a historyId is stored,
    /// full fetch otherwise), classifies only the newly-arrived messages, and returns
    /// an `InboxWatchResult` describing new important mail. The caller (the
    /// `BGAppRefreshTask` handler) decides whether to fire a local notification.
    ///
    /// This method is safe to call from a background task. It MAY execute a full
    /// fetch when the stored historyId is stale/expired — background tasks should
    /// set an expiration handler before calling.
    ///
    /// Does NOT update `isRefreshing` (that flag is for foreground UI spinners).
    func backgroundRefresh() async -> InboxWatchResult {
        guard GoogleAuth.shared.isSignedIn, overrideService == nil else {
            return InboxWatchResult(newImportant: [], updatedBrief: brief)
        }

        let newMessages: [EmailMessage]
        let updatedHistoryId: String?

        if let storedHistoryId = watchState.historyId {
            // Fast path: fetch only changes since the last known historyId.
            let result = (try? await gmailService.fetchIncremental(sinceHistoryId: storedHistoryId))
            newMessages = result?.0 ?? []
            updatedHistoryId = result?.1
        } else {
            // Cold start: full fetch; its historyId becomes the new baseline.
            let fetch = (try? await gmailService.fetchRecent())
            newMessages = fetch?.messages ?? []
            updatedHistoryId = try? await gmailService.currentHistoryId()
        }

        // Update historyId baseline.
        if let hid = updatedHistoryId, hid != watchState.historyId {
            watchState.historyId = hid
            persistWatchState()
        }

        guard !newMessages.isEmpty else {
            return InboxWatchResult(newImportant: [], updatedBrief: brief)
        }

        // Classify only the new messages; they may be important.
        let classified = await classifier.classify(newMessages,
                                                    preferencesHint: preferences.promptSummary())
        let overridden = classified.map { InboxRanker.override($0, preferences: preferences) }

        // Merge new messages into the in-memory set (deduplicated by id).
        let existingIDs = Set(allEmails.map { $0.id })
        let fresh = overridden.filter { !existingIDs.contains($0.id) }
        if !fresh.isEmpty {
            allEmails = (fresh + allEmails).sorted { $0.email.date > $1.email.date }
            for item in fresh { senderMemory.record(item.email.senderEmail, seen: 1) }
            persistLearning()
            scheduleNudgeRecompute()
            republish()
            persist()
        }

        // Important lanes that should trigger a notification.
        let alertLanes: Set<InboxLane> = [.needsYou, .waiting, .security]
        let newImportant = overridden.filter {
            alertLanes.contains($0.lane) && !watchState.notifiedIDs.contains($0.id)
        }

        // Mark those ids as notified so we never re-alert the same message.
        if !newImportant.isEmpty {
            for item in newImportant { watchState.notifiedIDs.insert(item.id) }
            // Cap the notified set so it doesn't grow without bound.
            if watchState.notifiedIDs.count > 500 {
                let excess = watchState.notifiedIDs.count - 400
                watchState.notifiedIDs = Set(watchState.notifiedIDs.dropFirst(excess))
            }
            persistWatchState()
        }

        return InboxWatchResult(newImportant: newImportant, updatedBrief: brief)
    }

    // MARK: - M5 read-only accessors

    /// A snapshot of the sender-memory stats for the weekly-recap notification.
    /// The scheduler reads this from a background task after `backgroundRefresh()`
    /// has already updated the in-memory state.
    var senderMemorySnapshot: SenderMemory { senderMemory }

    // MARK: - Subscription-unsubscribe candidates (M5)

    /// Noise-lane senders the user has never opened AND that have at least one
    /// visible email with an unsubscribe affordance. Drives the subscription-cleanup
    /// sweep. Sorted descending by dismiss count (strongest noise signal first).
    var neverOpenedNoiseSenders: [UnsubscribeCandidate] {
        var bySender: [String: UnsubscribeCandidate] = [:]
        for item in allEmails where item.lane == .noise && item.email.hasUnsubscribe {
            let key = item.email.senderEmail.lowercased()
            guard !key.isEmpty, senderMemory.stat(for: key)?.opened == 0 else { continue }
            if var existing = bySender[key] {
                existing.count += 1
                bySender[key] = existing
            } else {
                bySender[key] = UnsubscribeCandidate(
                    senderEmail: item.email.senderEmail,
                    senderName: item.email.senderName,
                    count: 1,
                    exampleID: item.id
                )
            }
        }
        return bySender.values.sorted { $0.count > $1.count }
    }

    // MARK: - Preference mutators (M5 additions)

    /// Enable or disable the important-mail notification. When enabling, requests
    /// notification permission via the existing `NotificationManager`; if the user
    /// denies, the preference stays false so we don't silently enable without consent.
    func setNotifyImportantMail(_ enabled: Bool) async {
        if enabled {
            let granted = await NotificationManager.requestPermission()
            guard granted else { return }
        }
        preferences.notifyImportantMail = enabled
        persistPreferences()
        // Reschedule (or cancel) the daily brief and weekly recap whenever notification
        // prefs change, so the schedule reflects the new state immediately.
        NotificationManager.scheduleInboxDailyBrief(hour: preferences.dailyBriefHour, brief: brief)
        NotificationManager.scheduleInboxWeeklyRecap(senderMemory: senderMemory)
    }

    // MARK: - Internals

    /// Recompute the published `emails` (and `triagedCount`) from `allEmails` and
    /// the snooze map. A message is hidden while it has a future resurface date.
    private func republish() {
        let now = Date()
        let visible = allEmails
            .filter { item in
                guard let due = snoozes[item.id] else { return true }
                return due <= now
            }
            .sorted { $0.email.date > $1.email.date }
        emails = visible
        triagedCount = visible.count
    }

    /// Keep only snoozes that are still in the future AND still refer to a message
    /// in the current set.
    private func pruneSnoozes() {
        let now = Date()
        let present = Set(allEmails.map { $0.id })
        let pruned = snoozes.filter { present.contains($0.key) && $0.value > now }
        if pruned.count != snoozes.count {
            snoozes = pruned
            persistSnoozes()
        }
    }

    private func persist() {
        fileStore.save(Cache(emails: allEmails,
                             lastUpdated: lastUpdated,
                             totalUnread: totalUnread,
                             brief: brief))
    }

    private func persistSnoozes() {
        snoozeStore.save(SnoozeCache(entries: snoozes))
    }

    /// Persist the two learning files. Small and best-effort, matching `FileStore`.
    private func persistLearning() {
        importanceStore.save(importance)
        senderStore.save(senderMemory)
    }

    private func persistPreferences() {
        prefsStore.save(preferences)
    }

    private func persistWatchState() {
        watchStore.save(watchState)
    }

    // MARK: - Embeddings & nudge (M4 learning re-rank)

    /// The embedding for `item`, computed once from subject + sender + summary and
    /// cached for the session. nil when on-device embedding is unavailable.
    private func embedding(for item: ClassifiedEmail) -> [Double]? {
        if let cached = embeddingCache[item.id] { return cached }
        let text = "\(item.email.subject) \(item.email.senderName) \(item.summary)"
        guard let vector = EmbeddingService.shared.vector(for: text) else { return nil }
        embeddingCache[item.id] = vector
        return vector
    }

    /// Recompute every message's nudge score WITHOUT blocking the main thread.
    /// Embedding any not-yet-cached message — the expensive part (on-device
    /// `NLEmbedding`) — runs OFF the main actor via `computeNudges`; only the cache
    /// merge + score assignment + re-render hop back. Fire-and-forget: ordering stays
    /// by recency until the fresh scores land, so this never stalls construction, a
    /// refresh, or a tap. `ImportanceEngine`/`SenderMemory` are value types, so the
    /// snapshots are safe to read off-actor.
    private func scheduleNudgeRecompute() {
        let items = allEmails
        let known = embeddingCache
        let importanceSnapshot = importance
        let sendersSnapshot = senderMemory
        Task { [weak self] in
            let (fresh, scores) = await Self.computeNudges(items: items,
                                                           known: known,
                                                           importance: importanceSnapshot,
                                                           senders: sendersSnapshot)
            guard let self else { return }
            for (id, vector) in fresh { self.embeddingCache[id] = vector }
            self.nudgeScores = scores
            // Re-render so `emails(in:)` re-sorts with the new nudges.
            self.republish()
        }
    }

    /// Pure, off-actor work for `scheduleNudgeRecompute`: embed the cache-missing
    /// messages and score them all. `nonisolated` so it runs on the global executor,
    /// keeping the heavy embedding off the main thread.
    private nonisolated static func computeNudges(
        items: [ClassifiedEmail],
        known: [String: [Double]],
        importance: ImportanceEngine,
        senders: SenderMemory
    ) async -> (fresh: [String: [Double]], scores: [String: Double]) {
        var fresh: [String: [Double]] = [:]
        for item in items where known[item.id] == nil {
            let text = "\(item.email.subject) \(item.email.senderName) \(item.summary)"
            if let vector = EmbeddingService.shared.vector(for: text) {
                fresh[item.id] = vector
            }
        }
        var scores: [String: Double] = [:]
        for item in items {
            let vector = known[item.id] ?? fresh[item.id]
            scores[item.id] = InboxRanker.nudge(for: item,
                                                vector: vector,
                                                importance: importance,
                                                senders: senders)
        }
        return (fresh, scores)
    }

    /// Evict cached embeddings/scores for messages no longer in the working set.
    private func pruneEmbeddingCache() {
        let present = Set(allEmails.map { $0.id })
        embeddingCache = embeddingCache.filter { present.contains($0.key) }
        nudgeScores = nudgeScores.filter { present.contains($0.key) }
    }

    // MARK: - Auto-file (M4)

    /// Auto-file high-confidence noise on refresh, SAFE BY CONSTRUCTION. Only acts on
    /// mail ALREADY in the `.noise` lane (so Needs you / Waiting / Security / Money /
    /// People / Calendar / Orders are never touched) that ALSO matches an explicit
    /// mute rule or a learned noise-leaning sender. Each archive runs through
    /// `InboxCapabilities` so it is undoable and reconciled; failures (e.g. Gmail not
    /// connected) are swallowed per-item. Because mutes + learned-noise start empty, a
    /// fresh install files nothing until signals accumulate.
    private func autoFileIfEnabled() async {
        guard preferences.autoFileEnabled, let capabilities else { return }

        // Snapshot candidates up front; archiving mutates `allEmails`.
        let candidates: [(item: ClassifiedEmail, reason: String)] = allEmails.compactMap { item in
            guard item.lane == .noise else { return nil }          // protected: noise only
            let hay = InboxRanker.senderHaystack(item.email)
            if InboxRanker.matchesAny(hay, preferences.mutedSenders) {
                return (item, "Muted sender")
            }
            if senderMemory.isNoiseLeaning(item.email.senderEmail) {
                return (item, "Usually archived unread")
            }
            return nil
        }
        guard !candidates.isEmpty else { return }

        var filed: [AutoFiledItem] = []
        for (item, reason) in candidates {
            do {
                let outcome = try await capabilities.run("archive", args: ["message_id": item.id])
                guard let undo = outcome.undo else { continue }
                filed.append(AutoFiledItem(id: item.id,
                                           senderName: item.email.senderName,
                                           subject: item.email.subject,
                                           reason: reason,
                                           undo: undo))
            } catch {
                // Best-effort: skip an item we couldn't archive (e.g. needs reconnect).
            }
        }

        guard !filed.isEmpty else { return }
        // Accumulate across sweeps, newest first, deduped by id, capped.
        let existingIDs = Set(autoFiled.map { $0.id })
        let fresh = filed.filter { !existingIDs.contains($0.id) }
        autoFiled = Array((fresh + autoFiled).prefix(50))
    }

    /// Undo every auto-file in the banner (reversed), then clear it.
    func undoAllAutoFiled() async {
        let items = autoFiled
        autoFiled = []
        for item in items.reversed() { await item.undo() }
    }

    /// Dismiss the auto-file banner WITHOUT undoing — the mail stays filed.
    func dismissAutoFiled() { autoFiled = [] }

    // MARK: - Rule suggestions (M4)

    /// One-tap "always file X as noise?" suggestions: senders the user keeps binning
    /// unread (noise-leaning) that aren't muted yet and haven't been dismissed this
    /// session. Computed from the current set, strongest first.
    var senderSuggestions: [SenderSuggestion] {
        var seen = Set<String>()
        var result: [SenderSuggestion] = []
        for item in allEmails {
            let email = item.email.senderEmail.lowercased()
            guard !email.isEmpty, !seen.contains(email) else { continue }
            seen.insert(email)
            guard senderMemory.isNoiseLeaning(email),
                  !dismissedSenderSuggestions.contains(email),
                  !InboxRanker.matchesAny(InboxRanker.senderHaystack(item.email),
                                          preferences.mutedSenders) else { continue }
            result.append(SenderSuggestion(id: email,
                                           senderName: item.email.senderName,
                                           senderEmail: item.email.senderEmail,
                                           dismissCount: senderMemory.dismissCount(for: email)))
        }
        return result.sorted { $0.dismissCount > $1.dismissCount }
    }

    /// Accept a suggestion → mute that sender (its email address).
    func acceptSuggestion(_ suggestion: SenderSuggestion) {
        addMute(suggestion.senderEmail)
    }

    /// Wave off a suggestion for the rest of the session.
    func dismissSenderSuggestion(_ suggestion: SenderSuggestion) {
        dismissedSenderSuggestions.insert(suggestion.id)
    }

    // MARK: - Preference mutators (M4)

    /// Re-derive `allEmails` from the raw classifier verdicts under the CURRENT
    /// preferences, preserving each message's optimistic state (e.g. unread) and the
    /// fact that archived/snoozed messages are gone. Lets a preference edit take effect
    /// instantly without a network refresh. (See `rawClassified` for the cold-launch
    /// caveat.)
    private func reapplyPreferences() {
        let rawByID = Dictionary(rawClassified.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        allEmails = allEmails.map { current in
            // Restore the original verdict (lane/category) but keep the live email
            // (unread flag etc.), then re-apply overrides.
            let base = (rawByID[current.id] ?? current).withEmail(current.email)
            return InboxRanker.override(base, preferences: preferences)
        }
        scheduleNudgeRecompute()
        republish()
        persist()
    }

    @discardableResult
    func addVIP(_ value: String) -> Bool {
        let added = appendUnique(value, to: \.vipSenders)
        if added {
            persistPreferences()
            // "Marked VIP" is a POSITIVE importance signal for that sender's mail.
            let needle = InboxPreferences.normalize(value)
            for item in allEmails where InboxRanker.senderHaystack(item.email).contains(needle) {
                importance.reinforce(positive: true, vector: embedding(for: item))
            }
            persistLearning()
            reapplyPreferences()
        }
        return added
    }

    func removeVIP(_ value: String) {
        if removeMatching(value, from: \.vipSenders) { persistPreferences(); reapplyPreferences() }
    }

    @discardableResult
    func addMute(_ value: String) -> Bool {
        let added = appendUnique(value, to: \.mutedSenders)
        if added { persistPreferences(); reapplyPreferences() }
        return added
    }

    func removeMute(_ value: String) {
        if removeMatching(value, from: \.mutedSenders) { persistPreferences(); reapplyPreferences() }
    }

    @discardableResult
    func addSuppressedCategory(_ raw: String) -> Bool {
        let added = appendUnique(raw, to: \.suppressedCategories, normalizeForCompare: { $0.lowercased() })
        if added { persistPreferences(); reapplyPreferences() }
        return added
    }

    func removeSuppressedCategory(_ raw: String) {
        if removeMatching(raw, from: \.suppressedCategories, normalizeForCompare: { $0.lowercased() }) {
            persistPreferences(); reapplyPreferences()
        }
    }

    @discardableResult
    func addElevatedCategory(_ raw: String) -> Bool {
        let added = appendUnique(raw, to: \.elevatedCategories, normalizeForCompare: { $0.lowercased() })
        if added { persistPreferences(); reapplyPreferences() }
        return added
    }

    func removeElevatedCategory(_ raw: String) {
        if removeMatching(raw, from: \.elevatedCategories, normalizeForCompare: { $0.lowercased() }) {
            persistPreferences(); reapplyPreferences()
        }
    }

    @discardableResult
    func addKeywordRule(keyword: String, laneRaw: String?) -> KeywordRule? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let rule = KeywordRule(keyword: trimmed, laneRaw: laneRaw)
        preferences.keywordRules.append(rule)
        persistPreferences()
        reapplyPreferences()
        return rule
    }

    func removeKeywordRule(_ id: UUID) {
        guard preferences.keywordRules.contains(where: { $0.id == id }) else { return }
        preferences.keywordRules.removeAll { $0.id == id }
        persistPreferences()
        reapplyPreferences()
    }

    func setAutoFileEnabled(_ enabled: Bool) {
        guard preferences.autoFileEnabled != enabled else { return }
        preferences.autoFileEnabled = enabled
        persistPreferences()
    }

    func setDailyBriefHour(_ hour: Int?) {
        preferences.dailyBriefHour = hour
        persistPreferences()
        // Reschedule the daily brief immediately so the change takes effect without
        // waiting for the next background refresh.
        NotificationManager.scheduleInboxDailyBrief(hour: hour, brief: brief)
    }

    /// The current elevate/suppress disposition of a category (for the prefs picker).
    func disposition(for category: EmailCategory) -> CategoryDisposition {
        let raw = category.rawValue
        if preferences.suppressedCategories.contains(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
            return .suppress
        }
        if preferences.elevatedCategories.contains(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
            return .elevate
        }
        return .normal
    }

    /// Set a category's disposition, keeping the suppress/elevate lists mutually
    /// exclusive for that category.
    func setDisposition(_ disposition: CategoryDisposition, for category: EmailCategory) {
        let raw = category.rawValue
        preferences.suppressedCategories.removeAll { $0.caseInsensitiveCompare(raw) == .orderedSame }
        preferences.elevatedCategories.removeAll { $0.caseInsensitiveCompare(raw) == .orderedSame }
        switch disposition {
        case .suppress: preferences.suppressedCategories.append(raw)
        case .elevate: preferences.elevatedCategories.append(raw)
        case .normal: break
        }
        persistPreferences()
        reapplyPreferences()
    }

    // MARK: - Preference list helpers

    /// Append `value` to a string-list preference if not already present (compared via
    /// `normalizeForCompare`, default trimmed+lowercased). Returns whether it was added.
    private func appendUnique(_ value: String,
                              to keyPath: WritableKeyPath<InboxPreferences, [String]>,
                              normalizeForCompare: (String) -> String = InboxPreferences.normalize) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = normalizeForCompare(trimmed)
        if preferences[keyPath: keyPath].contains(where: { normalizeForCompare($0) == key }) { return false }
        preferences[keyPath: keyPath].append(trimmed)
        return true
    }

    /// Remove every entry matching `value` from a string-list preference. Returns
    /// whether anything was removed.
    @discardableResult
    private func removeMatching(_ value: String,
                               from keyPath: WritableKeyPath<InboxPreferences, [String]>,
                               normalizeForCompare: (String) -> String = InboxPreferences.normalize) -> Bool {
        let key = normalizeForCompare(value)
        let before = preferences[keyPath: keyPath].count
        preferences[keyPath: keyPath].removeAll { normalizeForCompare($0) == key }
        return preferences[keyPath: keyPath].count != before
    }
}

// MARK: - M4 surface types

/// A message the refresh sweep auto-filed, shown in the "Auto-filed N — review"
/// banner. `undo` reverses that single archive (re-inserts + un-archives on Gmail).
struct AutoFiledItem: Identifiable {
    let id: String
    let senderName: String
    let subject: String
    let reason: String
    let undo: () async -> Void
}

/// A learned "mute this sender?" suggestion — a sender the user keeps binning unread.
struct SenderSuggestion: Identifiable, Hashable {
    /// Lowercased sender email — the stable identity.
    let id: String
    let senderName: String
    let senderEmail: String
    let dismissCount: Int
}

// MARK: - M5 surface types

/// The on-disk shape for incremental-sync state (persisted to `inbox-watch.json`).
/// Tolerant Codable so a missing or older file loads as empty defaults.
struct WatchState: Codable {
    /// The Gmail mailbox `historyId` captured after the last successful full fetch.
    /// nil = no baseline yet; `backgroundRefresh()` will do a full fetch.
    var historyId: String?
    /// Message IDs the watch layer has already alerted the user about. Capped at 500
    /// entries to prevent unbounded growth.
    var notifiedIDs: Set<String>

    init(historyId: String? = nil, notifiedIDs: Set<String> = []) {
        self.historyId = historyId
        self.notifiedIDs = notifiedIDs
    }

    enum CodingKeys: String, CodingKey { case historyId, notifiedIDs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        historyId = try c.decodeIfPresent(String.self, forKey: .historyId)
        notifiedIDs = try c.decodeIfPresent(Set<String>.self, forKey: .notifiedIDs) ?? []
    }
}

/// What a background refresh surfaced: the set of NEWLY-arrived important
/// messages (for building a notification) and the refreshed brief line (for
/// the daily brief notification copy).
struct InboxWatchResult {
    /// Classified emails that are NEW (not previously notified) and in an alertable
    /// lane (Needs you, Waiting, Security).
    let newImportant: [ClassifiedEmail]
    /// The store's current brief line at the time of the refresh.
    let updatedBrief: String

    /// True when there is something worth notifying about.
    var hasNewImportantMail: Bool { !newImportant.isEmpty }
}

/// One sender candidate for the subscription-cleanup sweep: a noise-lane sender
/// the user has never opened, with at least one email carrying an unsubscribe link.
struct UnsubscribeCandidate: Identifiable {
    let senderEmail: String
    let senderName: String
    /// How many unsubscribable messages from this sender are currently visible.
    var count: Int
    /// The message ID to target for the unsubscribe action.
    let exampleID: String

    var id: String { senderEmail }
}
