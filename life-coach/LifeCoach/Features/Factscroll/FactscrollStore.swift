import Foundation
import Combine

/// Drives the Factscroll feed: holds the published `facts`, generates batches via
/// `FactGenerator`, dedups with `FactDedup`, learns taste with `TasteEngine`, and
/// persists everything to `factscroll.json` via the shared `FileStore` pattern.
///
/// Buffer policy:
///   - On first load, frontload `frontloadCount` (5) facts so the feed opens full.
///   - When the user scrolls within `bufferAhead` (3) of the end, append
///     `topUpCount` (3) more.
/// A shimmer placeholder slide is shown while generating so the user never hits
/// an empty slide at the tail.
@MainActor
final class FactscrollStore: ObservableObject {
    @Published private(set) var facts: [Fact] = []
    @Published private(set) var isGenerating = false

    private let generator: FactGenerator
    private let imageService: FactImageService
    private let fileStore = FileStore<Persisted>(filename: "factscroll.json")

    /// In-memory cache of resolved cover images, keyed by topic, so re-rendering
    /// a slide (or two facts sharing a topic) doesn't re-derive the gradient.
    private var imageCache: [String: FactImage] = [:]

    // MARK: - Buffer policy constants
    static let frontloadCount = 5
    static let topUpCount = 3
    static let bufferAhead = 3
    /// Only the most-recent signatures are fed back into the generation prompt.
    private static let ledgerWindow = 60
    /// Cap on persisted facts so the file (and memory) stay bounded.
    private static let maxStoredFacts = 200

    // MARK: - Persistence shape

    /// On-disk shape: the recent facts, the dedup ledger, and the taste model.
    private struct Persisted: Codable {
        var facts: [Fact]
        var seenSignatures: [String]   // most-recent-first
        var taste: TasteEngine

        init(facts: [Fact] = [], seenSignatures: [String] = [], taste: TasteEngine = TasteEngine()) {
            self.facts = facts
            self.seenSignatures = seenSignatures
            self.taste = taste
        }
    }

    private var seenSignatures: [String]
    private var taste: TasteEngine

    init(store: AppStore,
         imageService: FactImageService = MockFactImageService()) {
        self.generator = FactGenerator(store: store)
        self.imageService = imageService

        let cached = fileStore.load(default: Persisted())
        facts = cached.facts
        seenSignatures = cached.seenSignatures
        taste = cached.taste
    }

    // MARK: - Loading / buffering

    /// Called when the feed first appears. Frontloads facts if the feed is empty.
    func loadInitialIfNeeded() async {
        guard facts.isEmpty else { return }
        await generateMore(count: Self.frontloadCount)
    }

    /// Called as the visible index changes. Tops up when the user is within
    /// `bufferAhead` of the end and we're not already generating.
    func bufferIfNeeded(visibleIndex: Int) async {
        guard !isGenerating else { return }
        let remainingAhead = facts.count - 1 - visibleIndex
        guard remainingAhead < Self.bufferAhead else { return }
        await generateMore(count: Self.topUpCount)
    }

    /// Generate, dedup, sign, append, and persist a batch. Best-effort: a failed
    /// generation simply appends nothing.
    private func generateMore(count: Int) async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }

        let raw = await generator.generate(
            count: count,
            recentSignatures: Array(seenSignatures.prefix(Self.ledgerWindow)),
            leanTopics: taste.leanTopics(),
            avoidTopics: taste.avoidTopics(),
            noteHints: taste.recentNoteTexts()
        )
        guard !raw.isEmpty else { return }

        var accepted: [Fact] = []
        var batchSignatures: [String] = []   // within-batch dedup guard

        for item in raw {
            let signature = FactDedup.signature(for: item.text)
            // v1 dedup: drop exact/near-duplicate (Jaccard > threshold) facts,
            // checking both the persisted ledger and earlier facts in THIS batch.
            if FactDedup.isDuplicate(candidateSignature: signature,
                                     against: seenSignatures,
                                     withinBatch: batchSignatures) {
                continue
            }
            batchSignatures.append(signature)
            accepted.append(Fact(text: item.text, topic: item.topic, signature: signature))
        }

        guard !accepted.isEmpty else { return }

        facts.append(contentsOf: accepted)
        // Feed accepted signatures back into the ledger, most-recent-first.
        seenSignatures.insert(contentsOf: accepted.map(\.signature), at: 0)
        trimAndPersist()
    }

    // MARK: - Reactions / notes (update TasteEngine + persist)

    /// Toggle a like/dislike on a fact. Re-tapping the same reaction clears it;
    /// switching flips it. Taste weights are kept consistent by undoing the old
    /// reaction before applying the new one.
    func react(_ fact: Fact, _ reaction: Reaction) {
        guard let index = facts.firstIndex(where: { $0.id == fact.id }) else { return }
        let current = facts[index].reaction
        let newReaction: Reaction = (current == reaction) ? .none : reaction

        taste.undo(current, topic: facts[index].topic)
        switch newReaction {
        case .like: taste.like(topic: facts[index].topic)
        case .dislike: taste.dislike(topic: facts[index].topic)
        case .none: break
        }

        facts[index].reaction = newReaction
        trimAndPersist()
    }

    /// Attach (or clear) a note on a fact. A non-empty note nudges taste.
    func addNote(_ fact: Fact, text: String) {
        guard let index = facts.firstIndex(where: { $0.id == fact.id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        facts[index].note = trimmed.isEmpty ? nil : trimmed
        if !trimmed.isEmpty {
            taste.addNote(trimmed, topic: facts[index].topic, factID: fact.id)
        }
        trimAndPersist()
    }

    // MARK: - Images

    /// Resolve (and cache) the cover image for a fact's topic.
    func cover(for fact: Fact) async -> FactImage {
        if let cached = imageCache[fact.topic] { return cached }
        let image = await imageService.cover(for: fact.topic)
        imageCache[fact.topic] = image
        return image
    }

    // MARK: - Persistence

    private func trimAndPersist() {
        if facts.count > Self.maxStoredFacts {
            facts.removeFirst(facts.count - Self.maxStoredFacts)
        }
        if seenSignatures.count > Self.maxStoredFacts {
            seenSignatures.removeLast(seenSignatures.count - Self.maxStoredFacts)
        }
        fileStore.save(Persisted(facts: facts, seenSignatures: seenSignatures, taste: taste))
    }
}
