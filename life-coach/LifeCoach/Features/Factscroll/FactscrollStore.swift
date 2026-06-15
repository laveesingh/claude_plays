import Foundation
import Combine

/// Drives the Factscroll feed: holds the published `facts`, generates batches via
/// `FactGenerator`, dedups + taste-ranks with a single on-device embedding pass
/// (`EmbeddingService`), learns taste with `TasteEngine`, and persists everything
/// to `factscroll.json` via the shared `FileStore` pattern.
///
/// Buffer policy (unchanged):
///   - On first load, frontload `frontloadCount` (5) facts so the feed opens full.
///   - When the user scrolls within `bufferAhead` (3) of the end, append
///     `topUpCount` (3) more.
/// A shimmer placeholder slide is shown while generating so the user never hits
/// an empty slide at the tail.
///
/// Pipeline per batch (the new internals):
///   1. **Over-generate** — ask for ~2x the screen count so dedup + taste-rank
///      have a pool.
///   2. **Dedup** — (a) drop exact canonical `claim_key` matches vs the persisted
///      recent-keys set and within the batch; (b) embed each survivor and drop it
///      if cosine ≥ `semanticDupThreshold` to any vector in the persisted
///      embedding ledger OR to an earlier accepted candidate this batch. If a
///      fact can't be embedded, fall back to `FactDedup`'s token-overlap check.
///   3. **Taste re-rank** — rank the deduped survivors by cosine to the learned
///      taste vector and keep the top N (= the requested screen count). No taste
///      yet → keep the first N.
@MainActor
final class FactscrollStore: ObservableObject {
    @Published private(set) var facts: [Fact] = []
    @Published private(set) var isGenerating = false
    /// True when the last generation attempt produced nothing usable (model error,
    /// empty reply, or all-duplicates). Drives a retry slide instead of a dead tail.
    @Published private(set) var lastLoadFailed = false

    private let generator: FactGenerator
    private let imageService: FactImageService
    private let fileStore = FileStore<Persisted>(filename: "factscroll.json")
    private let embeddings = EmbeddingService.shared

    /// In-memory cache of resolved cover images, keyed by topic, so re-rendering
    /// a slide (or two facts sharing a topic) doesn't re-derive the gradient.
    private var imageCache: [String: FactImage] = [:]

    // MARK: - Buffer policy constants
    static let frontloadCount = 5
    static let topUpCount = 3
    static let bufferAhead = 3
    /// Only the most-recent claim keys are fed back into the generation prompt.
    private static let ledgerWindow = 60
    /// Cap on persisted facts so the file (and memory) stay bounded.
    private static let maxStoredFacts = 200
    /// Cap on persisted canonical claim keys (exact-match dedup memory).
    private static let maxStoredKeys = 200
    /// Cap on the persisted embedding ledger (long-memory semantic dedup). Each
    /// vector is ~512 doubles, so ~150 keeps the file and per-batch cost bounded.
    private static let embeddingLedgerCap = 150

    // MARK: - Dedup thresholds (tunable)
    /// Cosine at/above this between two fact embeddings = semantic duplicate.
    /// 0.90 is intentionally conservative: it catches reworded restatements of
    /// the same claim without nuking merely same-topic facts. Tunable.
    private static let semanticDupThreshold = 0.90

    // MARK: - Persistence shape

    /// On-disk shape: recent facts, the exact-key dedup set, the semantic
    /// embedding ledger, and the taste model. All fields decode tolerantly so a
    /// cache written by the previous (signature-only) version still loads.
    private struct Persisted: Codable {
        var facts: [Fact]
        var recentKeys: [String]        // most-recent-first canonical claim keys
        var embeddingLedger: [[Double]] // recent fact embeddings, most-recent-first
        var taste: TasteEngine

        init(facts: [Fact] = [],
             recentKeys: [String] = [],
             embeddingLedger: [[Double]] = [],
             taste: TasteEngine = TasteEngine()) {
            self.facts = facts
            self.recentKeys = recentKeys
            self.embeddingLedger = embeddingLedger
            self.taste = taste
        }

        enum CodingKeys: String, CodingKey {
            case facts, recentKeys, embeddingLedger, taste
            // Legacy key from the v1 token-overlap store.
            case seenSignatures
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            facts = try c.decodeIfPresent([Fact].self, forKey: .facts) ?? []
            // Prefer the new key list; fall back to legacy signatures so an old
            // cache still seeds the (now) exact-key dedup memory harmlessly.
            recentKeys = try c.decodeIfPresent([String].self, forKey: .recentKeys)
                ?? c.decodeIfPresent([String].self, forKey: .seenSignatures)
                ?? []
            embeddingLedger = try c.decodeIfPresent([[Double]].self, forKey: .embeddingLedger) ?? []
            taste = try c.decodeIfPresent(TasteEngine.self, forKey: .taste) ?? TasteEngine()
        }

        // Explicit encode: the legacy `seenSignatures` key in `CodingKeys` (kept
        // only to read old caches) defeats synthesized `Encodable`, so we write
        // the current shape ourselves and never emit the legacy key.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(facts, forKey: .facts)
            try c.encode(recentKeys, forKey: .recentKeys)
            try c.encode(embeddingLedger, forKey: .embeddingLedger)
            try c.encode(taste, forKey: .taste)
        }
    }

    /// Most-recent-first canonical claim keys (exact-match dedup memory).
    private var recentKeys: [String]
    /// Most-recent-first fact embeddings (semantic dedup long memory).
    private var embeddingLedger: [[Double]]
    private var taste: TasteEngine

    init(store: AppStore,
         imageService: FactImageService = MockFactImageService()) {
        self.generator = FactGenerator(store: store)
        self.imageService = imageService

        let cached = fileStore.load(default: Persisted())
        facts = cached.facts
        recentKeys = cached.recentKeys
        embeddingLedger = cached.embeddingLedger
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

    /// Retry after a failed/empty load (driven by the retry slide's button).
    func retry() async {
        await generateMore(count: facts.isEmpty ? Self.frontloadCount : Self.topUpCount)
    }

    /// Generate (over-generated), dedup, taste-rank, append, and persist a batch.
    /// `count` is the number of NEW facts that should land on screen. On a failed
    /// or empty result it sets `lastLoadFailed` so the UI can offer a retry
    /// instead of silently stalling on an empty tail.
    private func generateMore(count: Int) async {
        guard !isGenerating else { return }
        isGenerating = true
        lastLoadFailed = false
        defer { isGenerating = false }

        // Over-generate: ~2x so dedup + taste-rank have a real pool to pick from.
        let requestCount = count + max(3, count)

        let raw = await generator.generate(
            count: requestCount,
            recentKeys: Array(recentKeys.prefix(Self.ledgerWindow)),
            leanTopics: taste.leanTopics(),
            avoidTopics: taste.avoidTopics(),
            noteHints: taste.recentNoteTexts()
        )

        // --- Dedup pass (layered) ----------------------------------------
        var candidates: [(fact: Fact, vector: [Double]?)] = []
        var batchKeys: [String] = []          // within-batch exact-key guard
        var batchVectors: [[Double]] = []     // within-batch semantic guard
        var batchSignatures: [String] = []    // within-batch token-overlap fallback

        for item in raw {
            // (a) exact canonical claim_key — cheapest layer, before embedding.
            if !item.claimKey.isEmpty {
                if recentKeys.contains(item.claimKey) || batchKeys.contains(item.claimKey) {
                    continue
                }
            }

            let signature = FactDedup.signature(for: item.text)

            // (b) semantic dedup via on-device embedding; token-overlap fallback.
            if let vector = embeddings.vector(for: item.text) {
                if isSemanticDuplicate(vector, against: embeddingLedger)
                    || isSemanticDuplicate(vector, against: batchVectors) {
                    continue
                }
                if !item.claimKey.isEmpty { batchKeys.append(item.claimKey) }
                batchVectors.append(vector)
                batchSignatures.append(signature)
                candidates.append((Fact(text: item.text,
                                        topic: item.topic,
                                        signature: signature,
                                        canonicalKey: item.claimKey), vector))
            } else {
                // Embedding unavailable for this fact — never silently skip dedup.
                if FactDedup.isDuplicate(candidateSignature: signature,
                                         against: seenSignaturesFallback(),
                                         withinBatch: batchSignatures) {
                    continue
                }
                if !item.claimKey.isEmpty { batchKeys.append(item.claimKey) }
                batchSignatures.append(signature)
                candidates.append((Fact(text: item.text,
                                        topic: item.topic,
                                        signature: signature,
                                        canonicalKey: item.claimKey), nil))
            }
        }

        // --- Taste re-rank -------------------------------------------------
        let accepted = tasteRanked(candidates, keep: count)

        guard !accepted.isEmpty else {
            // Nothing usable — surface a retry affordance rather than a dead tail.
            lastLoadFailed = true
            return
        }

        facts.append(contentsOf: accepted.map(\.fact))
        // Feed accepted keys + embeddings back into the long-memory ledgers,
        // most-recent-first.
        let acceptedKeys = accepted.map(\.fact.canonicalKey).filter { !$0.isEmpty }
        recentKeys.insert(contentsOf: acceptedKeys, at: 0)
        let acceptedVectors = accepted.compactMap(\.vector)
        embeddingLedger.insert(contentsOf: acceptedVectors, at: 0)
        trimAndPersist()
    }

    /// Cosine ≥ `semanticDupThreshold` to ANY vector in `others` ⇒ duplicate.
    private func isSemanticDuplicate(_ vector: [Double], against others: [[Double]]) -> Bool {
        for other in others {
            if EmbeddingService.cosine(vector, other) >= Self.semanticDupThreshold {
                return true
            }
        }
        return false
    }

    /// Token-overlap fallback ledger: the signatures of the facts we've shown.
    /// Derived from stored facts so the fallback path still has long memory even
    /// though the primary memory is now keys + embeddings.
    private func seenSignaturesFallback() -> [String] {
        facts.suffix(Self.ledgerWindow).map(\.signature)
    }

    /// Rank deduped candidates by cosine to the learned taste vector and keep the
    /// top `keep`. With no taste signal (or no taste vector / unembeddable
    /// candidates), preserves the model's order and keeps the first `keep`.
    private func tasteRanked(_ candidates: [(fact: Fact, vector: [Double]?)],
                             keep: Int) -> [(fact: Fact, vector: [Double]?)] {
        guard let taste = taste.tasteVector(), !taste.isEmpty else {
            return Array(candidates.prefix(keep))
        }
        // Stable sort by descending cosine; unembeddable candidates score 0 and
        // sink below anything with positive taste alignment, but stay in the pool.
        let scored = candidates.enumerated().map { index, candidate -> (Int, Double, (fact: Fact, vector: [Double]?)) in
            let score = candidate.vector.map { EmbeddingService.cosine($0, taste) } ?? 0
            return (index, score, candidate)
        }
        let ranked = scored.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
        }
        return ranked.prefix(keep).map(\.2)
    }

    // MARK: - Reactions / notes (update TasteEngine + persist)

    /// Toggle a like/dislike on a fact. Re-tapping the same reaction clears it;
    /// switching flips it. Both the topic-weight prompt hint and the embedding
    /// taste sets are kept consistent: the old reaction is undone, then the new
    /// one folded in (the fact's embedding goes into the right set).
    func react(_ fact: Fact, _ reaction: Reaction) {
        guard let index = facts.firstIndex(where: { $0.id == fact.id }) else { return }
        let current = facts[index].reaction
        let newReaction: Reaction = (current == reaction) ? .none : reaction

        // Topic-weight hint.
        taste.undo(current, topic: facts[index].topic)
        switch newReaction {
        case .like: taste.like(topic: facts[index].topic)
        case .dislike: taste.dislike(topic: facts[index].topic)
        case .none: break
        }

        // Embedding taste vector — the real personalization.
        let vector = embeddings.vector(for: facts[index].text)
        taste.applyReaction(old: current, new: newReaction, vector: vector)

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
        if recentKeys.count > Self.maxStoredKeys {
            recentKeys.removeLast(recentKeys.count - Self.maxStoredKeys)
        }
        if embeddingLedger.count > Self.embeddingLedgerCap {
            embeddingLedger.removeLast(embeddingLedger.count - Self.embeddingLedgerCap)
        }
        fileStore.save(Persisted(facts: facts,
                                 recentKeys: recentKeys,
                                 embeddingLedger: embeddingLedger,
                                 taste: taste))
    }
}
