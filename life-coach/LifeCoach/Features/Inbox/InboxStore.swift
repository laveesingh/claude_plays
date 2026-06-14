import Foundation
import Combine

/// In-memory + on-disk cache of the triaged inbox. Loads the last cache
/// instantly on init, and `refresh()` fetches -> classifies -> publishes ->
/// persists to `inbox-cache.json` via the shared `FileStore` pattern. No timer
/// or auto-refresh yet - that lands with the live Gmail wiring.
@MainActor
final class InboxStore: ObservableObject {
    @Published private(set) var emails: [ClassifiedEmail] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    private let service: EmailService
    private let classifier: InboxClassifier
    private let fileStore = FileStore<Cache>(filename: "inbox-cache.json")

    /// The on-disk shape: the classified emails plus when they were last refreshed.
    private struct Cache: Codable {
        var emails: [ClassifiedEmail]
        var lastUpdated: Date?

        init(emails: [ClassifiedEmail] = [], lastUpdated: Date? = nil) {
            self.emails = emails
            self.lastUpdated = lastUpdated
        }
    }

    init(store: AppStore, service: EmailService = MockEmailService()) {
        self.service = service
        self.classifier = InboxClassifier(store: store)

        // Load the last cache instantly so the UI has something to show on launch.
        let cached = fileStore.load(default: Cache())
        emails = cached.emails
        lastUpdated = cached.lastUpdated
    }

    /// Convenience for the two important sections the UI renders later.
    var needsAttention: [ClassifiedEmail] { emails.filter { $0.important } }
    var everythingElse: [ClassifiedEmail] { emails.filter { !$0.important } }

    /// Fetch the latest inbox, classify it, publish, and persist. Best-effort:
    /// a fetch/classify failure leaves the previous cache intact.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let fetched: [EmailMessage]
        do {
            fetched = try await service.fetchRecent()
        } catch {
            // Keep whatever we already had cached.
            return
        }

        let classified = await classifier.classify(fetched)
        // Newest first, important emails surfaced by the UI's own filtering.
        let sorted = classified.sorted { $0.email.date > $1.email.date }

        emails = sorted
        lastUpdated = Date()
        fileStore.save(Cache(emails: sorted, lastUpdated: lastUpdated))
    }
}
