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
/// Pipeline per batch (updated internals):
///   1. **Over-generate** — ask for ~2x the screen count so dedup + taste-rank
///      have a pool.
///   2. **Dedup** — (a) drop exact canonical `claim_key` matches vs the persisted
///      recent-keys set and within the batch; (b) embed each survivor and drop it
///      if cosine ≥ `semanticDupThreshold` to any vector in the persisted
///      embedding ledger OR to an earlier accepted candidate this batch. If a
///      fact can't be embedded, fall back to `FactDedup`'s token-overlap check.
///   3. **Gentle taste re-rank (MMR + exploration quota)** — taste is a NUDGE, not a
///      hard filter. Strength is evidence-scaled (one reaction ≈ 0.06, cap 0.35 at
///      ~6 reactions). A blended score combines intrinsic order with cosine-to-taste,
///      then MMR greedily picks diverse items; 40 % of slots are reserved for
///      exploration facts least similar to taste (novelty quota). With no taste
///      signal the feed stays in model order — the algorithm is a no-op.
@MainActor
final class FactscrollStore: ObservableObject {
    @Published private(set) var facts: [Fact] = []
    @Published private(set) var isGenerating = false
    /// True when the last generation attempt produced nothing usable (model error,
    /// empty reply, or all-duplicates). Drives a retry slide instead of a dead tail.
    @Published private(set) var lastLoadFailed = false

    /// The current topic weights, sorted by |weight| descending, for display in
    /// the "Your taste" panel. Updated whenever taste changes.
    @Published private(set) var topicTaste: [(topic: String, weight: Double)] = []

    /// Number of explicit reactions (likes + dislikes) recorded so far. Published
    /// so the "Your taste" panel can show taste strength as live evidence.
    @Published private(set) var reactionCount: Int = 0

    /// The evidence-scaled taste strength currently applied to the feed:
    /// `min(cap, perReaction × reactionCount)`. Surfaced in the taste panel so the
    /// user can SEE tuning take hold as they react.
    var tasteStrength: Double {
        min(Self.tasteStrengthCap, Self.tasteStrengthPerReaction * Double(reactionCount))
    }

    /// `tasteStrength` normalised to [0, 1] of its cap, for gauge display.
    var tasteStrengthFraction: Double {
        Self.tasteStrengthCap > 0 ? tasteStrength / Self.tasteStrengthCap : 0
    }

    private let generator: FactGenerator
    /// Test/preview override. When nil, `imageService` resolves live from whether
    /// an Unsplash key is present, so adding the key lights up real photos.
    private let overrideImageService: FactImageService?
    private let unsplashService = UnsplashImageService()
    private let mockImageService = MockFactImageService()
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

    // MARK: - Gentle re-rank tuning (MMR + exploration quota)

    /// How strongly taste can nudge the feed. Starts near 0 and grows with each
    /// explicit reaction; capped so taste NEVER dominates the feed entirely.
    ///   strength = min(0.5, 0.12 × reactionCount)
    /// One like → ~0.12 (noticeable but gentle); cap reached at ~4 reactions.
    /// (Was 0.06/0.35 — user feedback: reactions felt like they did nothing.)
    private static let tasteStrengthPerReaction = 0.12
    private static let tasteStrengthCap = 0.5

    /// How strongly an EXPLICIT taste-panel topic weight (the +/- controls)
    /// biases a fact whose topic matches: `topicBiasWeight × tanh(weight / 2)`.
    /// A couple of taps visibly move the feed; heavy weights saturate instead of
    /// monopolising. A deliberate user dial deserves more authority than an
    /// inferred reaction, hence a flat term outside the evidence-scaled blend.
    private static let topicBiasWeight = 0.3

    /// MMR diversity weight. λ=0.7 means picks care 70 % about quality/taste and
    /// 30 % about staying different from already-selected items.
    private static let mmrLambda = 0.7

    /// Fraction of kept slots reserved for EXPLORATION — facts least similar to
    /// the taste vector (novelty). Ensures fresh topics always appear.
    /// (Was 0.4 — with almost half the feed reserved for anti-taste picks,
    /// tuning felt inert. A quarter keeps serendipity without drowning taste.)
    private static let explorationFraction = 0.25

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

    /// The furthest fact index the user has had on screen (fed by
    /// `bufferIfNeeded(visibleIndex:)`). Post-reaction re-ranks only reorder facts
    /// strictly AFTER this, so slides already seen never move under the user.
    private var lastVisibleIndex = 0

    /// Monotonic token so only the LATEST scheduled tail re-rank applies; a rapid
    /// burst of reactions/panel taps schedules several and stale ones no-op.
    private var rerankToken = 0

    /// Most-recent-first canonical claim keys (exact-match dedup memory).
    private var recentKeys: [String]
    /// Most-recent-first fact embeddings (semantic dedup long memory).
    private var embeddingLedger: [[Double]]
    private var taste: TasteEngine

    init(store: AppStore,
         imageService: FactImageService? = nil) {
        self.generator = FactGenerator(store: store)
        self.overrideImageService = imageService

        let cached = fileStore.load(default: Persisted())
        facts = cached.facts
        recentKeys = cached.recentKeys
        embeddingLedger = cached.embeddingLedger
        taste = cached.taste
        topicTaste = cached.taste.topicWeightsSorted()
        reactionCount = cached.taste.reactionCount
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
        // Track the furthest slide the user is on, so post-reaction re-ranks never
        // touch anything at or before it (reordering seen slides breaks scrolling).
        lastVisibleIndex = max(lastVisibleIndex, visibleIndex)
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

    /// Gently re-rank deduped candidates using a blended MMR strategy that
    /// NUDGES the feed toward taste without collapsing it.
    ///
    /// ## Algorithm
    ///
    /// **Evidence-scaled strength.**
    /// `tasteStrength = min(0.5, 0.12 × reactionCount)` — one reaction ≈ 0.12;
    /// cap reached after ~4 reactions. With no reactions AND no panel weights
    /// the function degenerates to "keep the first N" (model order).
    ///
    /// **Blended score per candidate.**
    /// `tasteScore = (cosine(v, tasteVec) + 1) / 2` in [0, 1] (neutral 0.5 when
    /// unembedded or no taste vector yet).
    /// `baseScore` = rank-normalised intrinsic order (first = 1.0, last ≈ 0).
    /// `topicBias = topicBiasWeight × tanh(panelWeight(fact.topic) / 2)` — the
    /// taste panel's explicit +/- dials, applied directly so manual tuning moves
    /// the feed even with zero reactions.
    /// `blended = (1 − strength) × baseScore + strength × tasteScore + topicBias`.
    ///
    /// **MMR selection** (λ = 0.7).
    /// Greedily pick `keep − explorationCount` items maximising
    /// `λ × blended − (1 − λ) × maxCosineToAlreadySelected`.
    /// This keeps the selected set diverse from ITSELF — no homogeneous runs
    /// even within a liked topic.
    ///
    /// **Exploration quota** (40 % of slots).
    /// The remaining `explorationCount` slots are filled from candidates NOT
    /// chosen by MMR, picking those LEAST similar to the taste vector (maximum
    /// novelty). Exploration picks are interleaved with taste picks at fixed
    /// positions so fresh topics appear throughout the batch.
    ///
    /// **Net result:** a single like visibly nudges the feed (≈ 12 %); a panel
    /// dial moves matching topics immediately; a consistent pattern over several
    /// reactions shifts the mix decisively — while MMR diversity and the
    /// exploration quota keep the feed from fixating on a single topic.
    private func tasteRanked(_ candidates: [(fact: Fact, vector: [Double]?)],
                             keep: Int) -> [(fact: Fact, vector: [Double]?)] {
        guard keep > 0 else { return [] }
        let n = candidates.count
        guard n > 0 else { return [] }

        // Evidence-scaled strength — zero strength = preserve model order exactly.
        let strength = min(Self.tasteStrengthCap,
                           Self.tasteStrengthPerReaction * Double(taste.reactionCount))
        let tasteVec = taste.tasteVector()

        // Re-rank when there is ANY taste signal: reactions (strength) or explicit
        // taste-panel topic weights. With neither, keep the model order.
        let hasPanelSignal = !taste.topicWeightsSorted().isEmpty
        guard (strength > 1e-6 && tasteVec != nil) || hasPanelSignal else {
            return Array(candidates.prefix(keep))
        }

        // --- Blended scores (one per candidate) ---
        //
        // baseScore is rank-normalised [0, 1]: the first candidate in the pool
        // (= best novelty order from the generator/dedup) scores 1.0; the last
        // scores 0.  For n==1 avoid /0 by pinning to 1.
        struct Scored {
            let index: Int
            let candidate: (fact: Fact, vector: [Double]?)
            let blended: Double
            let tasteCosineMapped: Double  // tasteScore in [0,1] — kept for novelty sort
        }

        let scored: [Scored] = candidates.enumerated().map { idx, candidate in
            let baseScore = n > 1 ? 1.0 - Double(idx) / Double(n - 1) : 1.0
            // Neutral 0.5 when there's no vector on either side, so unembedded
            // facts are neither punished nor boosted by the taste term.
            let tasteScore: Double
            if let tasteVec, let v = candidate.vector {
                tasteScore = (EmbeddingService.cosine(v, tasteVec) + 1.0) / 2.0
            } else {
                tasteScore = 0.5
            }
            // Explicit panel dial for this fact's topic, saturating via tanh.
            let topicBias = Self.topicBiasWeight * tanh(taste.weight(forTopic: candidate.fact.topic) / 2.0)
            let blended = (1.0 - strength) * baseScore + strength * tasteScore + topicBias
            return Scored(index: idx, candidate: candidate, blended: blended,
                          tasteCosineMapped: tasteScore)
        }

        // --- Slot budget ---
        let explorationCount = max(1, Int((Double(keep) * Self.explorationFraction).rounded()))
        let tasteSlots = keep - explorationCount

        // --- MMR selection for the taste-influenced portion ---
        var remaining = scored
        var selected: [Scored] = []
        var selectedVectors: [[Double]] = []

        for _ in 0..<tasteSlots where !remaining.isEmpty {
            let lambda = Self.mmrLambda
            var bestScore = -Double.infinity
            var bestIdx = remaining.startIndex

            for i in remaining.indices {
                let s = remaining[i]
                // Maximum cosine similarity to any already-selected item.
                let maxSim: Double
                if selectedVectors.isEmpty {
                    maxSim = 0.0
                } else if let v = s.candidate.vector {
                    maxSim = selectedVectors.map { EmbeddingService.cosine(v, $0) }.max() ?? 0.0
                } else {
                    maxSim = 0.0
                }
                let mmrScore = lambda * s.blended - (1.0 - lambda) * maxSim
                if mmrScore > bestScore {
                    bestScore = mmrScore
                    bestIdx = i
                }
            }

            let pick = remaining[bestIdx]
            selected.append(pick)
            if let v = pick.candidate.vector { selectedVectors.append(v) }
            remaining.remove(at: bestIdx)
        }

        // --- Exploration quota: candidates NOT in MMR set, sorted by novelty ---
        // "Novelty" = lowest taste cosine → most different from the taste direction.
        let explorationPool = remaining.sorted { $0.tasteCosineMapped < $1.tasteCosineMapped }
        let explorationPicks = Array(explorationPool.prefix(explorationCount))

        // --- Interleave: spread exploration picks among taste picks ---
        // Place each exploration fact at evenly-spaced positions so fresh topics
        // appear throughout the batch rather than bunched at the end.
        var result = selected.map(\.candidate)
        let step = tasteSlots > 0 ? max(1, (tasteSlots + 1) / max(1, explorationCount)) : 1
        for (i, ep) in explorationPicks.enumerated() {
            let insertAt = min(i * step + i, result.count)
            result.insert(ep.candidate, at: insertAt)
        }

        return Array(result.prefix(keep))
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

        // Make the reaction feel IMMEDIATE: re-rank the not-yet-seen tail of the
        // current feed so the very next swipes reflect it — not just the next batch.
        rerankUpcoming(afterIndex: index)
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

    // MARK: - Immediate tail re-rank (reaction responsiveness)

    /// Re-rank the not-yet-seen tail of the feed with the just-updated taste, so a
    /// reaction (or a taste-panel dial) changes what the user swipes to NEXT — not
    /// only the next generated batch.
    ///
    /// Safety properties:
    ///   - Only facts strictly after both `anchorIndex` (the slide reacted on) and
    ///     `lastVisibleIndex` (the furthest seen slide) are considered, so nothing
    ///     the user scrolled past ever moves and scroll position is stable.
    ///   - Embedding the tail (the expensive part) runs OFF the main actor, same
    ///     pattern as `InboxStore.computeNudges`; only the cheap `tasteRanked` math
    ///     and the array splice hop back to the main actor.
    ///   - The splice applies only if the tail slice is unchanged (id match) and no
    ///     newer re-rank superseded this one — otherwise it silently no-ops.
    private func rerankUpcoming(afterIndex anchorIndex: Int) {
        let start = max(anchorIndex, lastVisibleIndex) + 1
        guard start >= 0, facts.count - start > 1 else { return }
        let tail = Array(facts[start...])

        rerankToken += 1
        let token = rerankToken
        let texts = tail.map(\.text)
        let ids = tail.map(\.id)

        Task { [weak self] in
            let vectors = await Self.embedOffMain(texts)
            guard let self, self.rerankToken == token else { return }
            self.applyRerankedTail(ids: ids, vectors: vectors, from: start)
        }
    }

    /// Embed each text on the global executor (nonisolated ⇒ off the main actor),
    /// keeping the heavy `NLEmbedding` work out of the render loop.
    private nonisolated static func embedOffMain(_ texts: [String]) async -> [[Double]?] {
        texts.map { EmbeddingService.shared.vector(for: $0) }
    }

    /// Hop-back half of `rerankUpcoming`: verify the tail is untouched and unseen,
    /// then splice in the taste-ranked order. Uses the LIVE fact values (not the
    /// captured snapshot) so any interim mutations (notes, reactions) survive.
    private func applyRerankedTail(ids: [UUID], vectors: [[Double]?], from start: Int) {
        let end = start + ids.count
        guard end <= facts.count else { return }
        let range = start..<end
        let current = Array(facts[range])
        guard current.map(\.id) == ids else { return }      // feed shifted — skip
        guard start > lastVisibleIndex else { return }       // user caught up — skip

        let candidates = zip(current, vectors).map { (fact: $0, vector: $1) }
        let ranked = tasteRanked(candidates, keep: candidates.count)
        guard ranked.count == candidates.count else { return }
        facts.replaceSubrange(range, with: ranked.map(\.fact))
    }

    // MARK: - Images

    /// Resolve (and cache) the cover image for a fact's topic.
    func cover(for fact: Fact) async -> FactImage {
        if let cached = imageCache[fact.topic] { return cached }
        let image = await imageService.cover(for: fact.topic)
        imageCache[fact.topic] = image
        return image
    }

    /// The active image source: a test override if injected, else Unsplash when a
    /// key is set, else the no-network gradient mock. Resolved per call so adding
    /// the key in Settings lights up real photos for any not-yet-cached topic.
    private var imageService: FactImageService {
        if let overrideImageService { return overrideImageService }
        return KeychainHelper.hasKey(secret: .unsplash) ? unsplashService : mockImageService
    }

    // MARK: - Taste controls (exposed to the "Your taste" panel)

    /// Adjust a topic's weight directly. Positive = lean toward, negative = avoid.
    /// A delta of ±0.5 is a gentle nudge; the generator's lean/avoid hints pick
    /// this up on the next batch. Change is persisted and published immediately.
    func adjustTopicWeight(_ topic: String, by delta: Double) {
        taste.adjust(topic: topic, by: delta)
        topicTaste = taste.topicWeightsSorted()
        trimAndPersist()
        // A panel dial should also move the CURRENT feed, not just the next batch.
        rerankUpcoming(afterIndex: lastVisibleIndex)
    }

    /// Full taste reset: clears all embedding sets, topic weights, and notes.
    /// The feed returns to its default (novelty / model) ordering immediately.
    /// The existing fact buffer is kept — the user doesn't lose what's on screen.
    func resetTaste() {
        taste.reset()
        topicTaste = []
        trimAndPersist()
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
        // Keep the published taste snapshots in sync whenever we save.
        topicTaste = taste.topicWeightsSorted()
        reactionCount = taste.reactionCount
        fileStore.save(Persisted(facts: facts,
                                 recentKeys: recentKeys,
                                 embeddingLedger: embeddingLedger,
                                 taste: taste))
    }
}
