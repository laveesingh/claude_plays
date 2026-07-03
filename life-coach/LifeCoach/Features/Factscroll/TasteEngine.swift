import Foundation

/// Learns the user's taste from their reactions. It now has two cooperating
/// layers:
///
///   1. **Embedding taste vector (the real personalization).** Decayed, capped
///      sets of the embeddings of liked and disliked facts. The taste vector is
///      `mean(liked) − mean(disliked)`; the store re-ranks deduped candidates
///      using a blended MMR pass that NUDGES rather than hard-filters. Most-recent
///      reactions are weighted heaviest (older ones decay), so taste tracks the
///      user as it shifts.
///   2. **Topic weights (a light prompt hint).** The original flat
///      `topic -> weight` map, still used only to nudge the generator's prompt
///      ("lean toward / avoid these topics"). The heavy lifting is the re-rank;
///      this just biases what the model produces in the first place.
///
/// Freeform notes are also kept as soft prompt hints.
struct TasteEngine: Codable {
    /// topic (lowercased) -> accumulated weight. Positive = liked, negative = disliked.
    /// Used ONLY for the light prompt lean/avoid hints, not the re-rank.
    private(set) var topicWeights: [String: Double]

    /// Freeform notes the user left on specific facts, newest last.
    private(set) var notes: [TasteNote]

    /// Embeddings of liked facts, oldest-first. Newer entries weigh more (decay).
    private(set) var likedVectors: [[Double]]
    /// Embeddings of disliked facts, oldest-first.
    private(set) var dislikedVectors: [[Double]]

    init(topicWeights: [String: Double] = [:],
         notes: [TasteNote] = [],
         likedVectors: [[Double]] = [],
         dislikedVectors: [[Double]] = []) {
        self.topicWeights = topicWeights
        self.notes = notes
        self.likedVectors = likedVectors
        self.dislikedVectors = dislikedVectors
    }

    // Tolerant decoding: old caches predate the embedding sets.
    enum CodingKeys: String, CodingKey {
        case topicWeights, notes, likedVectors, dislikedVectors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topicWeights = try c.decodeIfPresent([String: Double].self, forKey: .topicWeights) ?? [:]
        notes = try c.decodeIfPresent([TasteNote].self, forKey: .notes) ?? []
        likedVectors = try c.decodeIfPresent([[Double]].self, forKey: .likedVectors) ?? []
        dislikedVectors = try c.decodeIfPresent([[Double]].self, forKey: .dislikedVectors) ?? []
    }

    // MARK: - v1 tuning constants (topic-weight prompt hint)
    private static let likeDelta = 1.0
    private static let dislikeDelta = -1.0
    private static let noteNudge = 0.5
    /// How many topics we surface to the generator on each side.
    private static let leanCount = 4
    private static let avoidCount = 4
    /// A topic must clear this magnitude to be considered a real signal.
    private static let signalFloor = 0.5

    // MARK: - Embedding-taste tuning constants (tunable)
    /// Cap on how many liked / disliked vectors we retain. Bounds memory and the
    /// per-rank cost; oldest are evicted first.
    static let vectorSetCap = 50
    /// Geometric decay applied to older vectors when building the mean: the most
    /// recent reaction has weight 1, the one before `decay`, etc. < 1 so taste
    /// follows recent behavior. Tunable.
    static let recencyDecay = 0.92

    private static func normalize(_ topic: String) -> String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Taste strength (evidence-scaled)

    /// Total number of explicit reactions (likes + dislikes) accumulated so far.
    /// Used by the store's re-rank to scale how strongly taste nudges the feed.
    var reactionCount: Int { likedVectors.count + dislikedVectors.count }

    // MARK: - Updates (topic-weight hint)

    mutating func like(topic: String) {
        bump(topic, by: Self.likeDelta)
    }

    mutating func dislike(topic: String) {
        bump(topic, by: Self.dislikeDelta)
    }

    /// Reverses a previously-applied reaction's weight (used when a user toggles
    /// a like/dislike off or flips it), so weights don't drift on re-taps.
    mutating func undo(_ reaction: Reaction, topic: String) {
        switch reaction {
        case .like: bump(topic, by: -Self.likeDelta)
        case .dislike: bump(topic, by: -Self.dislikeDelta)
        case .none: break
        }
    }

    mutating func addNote(_ text: String, topic: String, factID: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.append(TasteNote(factID: factID, topic: Self.normalize(topic), text: trimmed))
        // A note is mild positive engagement with the topic. v1 heuristic.
        bump(topic, by: Self.noteNudge)
    }

    /// Public wrapper for the bump logic so `FactscrollStore` can expose
    /// direct topic weight controls to the "Your taste" panel.
    ///
    /// - Parameters:
    ///   - topic: The topic to adjust (normalized internally).
    ///   - delta: The amount to add (positive = lean toward, negative = avoid).
    ///     If the weight returns to 0 it is removed from the map.
    mutating func adjust(topic: String, by delta: Double) {
        bump(topic, by: delta)
    }

    private mutating func bump(_ topic: String, by delta: Double) {
        let key = Self.normalize(topic)
        guard !key.isEmpty else { return }
        topicWeights[key, default: 0] += delta
        if topicWeights[key] == 0 { topicWeights.removeValue(forKey: key) }
    }

    /// The accumulated weight for one topic (0 when unseen). Normalized like every
    /// other topic lookup, so `FactscrollStore`'s re-rank can bias by a fact's
    /// topic exactly as the taste panel's +/- controls recorded it.
    func weight(forTopic topic: String) -> Double {
        topicWeights[Self.normalize(topic)] ?? 0
    }

    /// Sorted snapshot of all non-trivial topic weights for display in the taste
    /// panel. Entries with |weight| < 0.1 are omitted as noise.
    func topicWeightsSorted() -> [(topic: String, weight: Double)] {
        topicWeights
            .filter { abs($0.value) >= 0.1 }
            .map { (topic: $0.key, weight: $0.value) }
            .sorted { abs($0.weight) > abs($1.weight) }
    }

    /// Full taste reset: clears all embedding sets, topic weights, and notes.
    /// After a reset `reactionCount == 0` and `tasteVector() == nil`, so the
    /// feed returns to its default (novelty / model) ordering immediately.
    mutating func reset() {
        topicWeights = [:]
        notes = []
        likedVectors = []
        dislikedVectors = []
    }

    // MARK: - Embedding taste vector

    /// Fold a fact's embedding into the taste sets when a reaction changes. The
    /// caller passes the OLD reaction (so a like→dislike flip removes the most
    /// recent liked vector) and the NEW one. Appending to the end keeps the
    /// most-recent-weighted ordering used by `tasteVector`.
    ///
    /// `vector` may be nil (embedding unavailable) — then only the topic-weight
    /// hint updates and the re-rank simply has one less signal.
    mutating func applyReaction(old: Reaction, new: Reaction, vector: [Double]?) {
        // Remove the contribution of the reaction being replaced. We remove the
        // most-recent matching vector (best-effort: reactions are typically
        // undone right after they're made, and the vector is identical anyway).
        guard let vector, !vector.isEmpty else { return }
        switch old {
        case .like: likedVectors = Self.removingLast(likedVectors, matching: vector)
        case .dislike: dislikedVectors = Self.removingLast(dislikedVectors, matching: vector)
        case .none: break
        }
        switch new {
        case .like: likedVectors = Self.appending(vector, to: likedVectors)
        case .dislike: dislikedVectors = Self.appending(vector, to: dislikedVectors)
        case .none: break
        }
    }

    /// Append `vector`, evicting oldest entries beyond `vectorSetCap`.
    private static func appending(_ vector: [Double], to set: [[Double]]) -> [[Double]] {
        var result = set
        result.append(vector)
        if result.count > vectorSetCap {
            result.removeFirst(result.count - vectorSetCap)
        }
        return result
    }

    /// Remove the most-recent (last) entry equal to `vector`, if present.
    private static func removingLast(_ set: [[Double]], matching vector: [Double]) -> [[Double]] {
        var result = set
        if let idx = result.lastIndex(where: { $0 == vector }) {
            result.remove(at: idx)
        }
        return result
    }

    /// The learned taste direction: recency-weighted `mean(liked) − mean(disliked)`.
    /// `nil` when there is no taste signal yet (both sets empty) — the store then
    /// keeps the first N candidates rather than re-ranking.
    func tasteVector() -> [Double]? {
        let liked = weightedMean(likedVectors)
        let disliked = weightedMean(dislikedVectors)
        switch (liked, disliked) {
        case let (l?, d?):
            guard l.count == d.count else { return l }
            return zip(l, d).map { $0 - $1 }
        case let (l?, nil):
            return l
        case let (nil, d?):
            return d.map { -$0 }
        case (nil, nil):
            return nil
        }
    }

    /// Recency-weighted mean of a vector set (last element = most recent = weight
    /// 1, earlier elements decayed by `recencyDecay`). Returns nil if empty.
    private func weightedMean(_ set: [[Double]]) -> [Double]? {
        guard let dim = set.last?.count, dim > 0 else { return nil }
        var sum = [Double](repeating: 0, count: dim)
        var totalWeight = 0.0
        // Most recent is the last element; give it the largest weight.
        let n = set.count
        for (offset, vector) in set.enumerated() where vector.count == dim {
            // offset 0 is oldest; weight grows toward the newest.
            let weight = pow(Self.recencyDecay, Double(n - 1 - offset))
            for i in 0..<dim { sum[i] += vector[i] * weight }
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        return sum.map { $0 / totalWeight }
    }

    // MARK: - Signals for the generator (light prompt hint)

    /// Topics the user has signalled they like most (strongest positive weights).
    func leanTopics() -> [String] {
        topicWeights
            .filter { $0.value >= Self.signalFloor }
            .sorted { $0.value > $1.value }
            .prefix(Self.leanCount)
            .map(\.key)
    }

    /// Topics the user has signalled they dislike most (strongest negative weights).
    func avoidTopics() -> [String] {
        topicWeights
            .filter { $0.value <= -Self.signalFloor }
            .sorted { $0.value < $1.value }
            .prefix(Self.avoidCount)
            .map(\.key)
    }

    /// The most recent freeform notes, surfaced to the generator as extra taste
    /// colour. Capped so the prompt stays small.
    func recentNoteTexts(limit: Int = 5) -> [String] {
        notes.suffix(limit).map(\.text)
    }
}

/// A note the user attached to a specific fact.
struct TasteNote: Codable, Hashable {
    let factID: UUID
    let topic: String
    let text: String
    let createdAt: Date

    init(factID: UUID, topic: String, text: String, createdAt: Date = Date()) {
        self.factID = factID
        self.topic = topic
        self.text = text
        self.createdAt = createdAt
    }
}
