import Foundation

/// On-device IMPORTANCE learning for the Inbox — the email analogue of Factscroll's
/// `TasteEngine`. It keeps recency-decayed, capped sets of the embeddings of mail
/// the user TREATED as important (positive) and mail they DISMISSED (negative). The
/// learned "importance direction" is `mean(positive) − mean(negative)`; an email's
/// importance is its cosine to that direction.
///
/// This is deliberately a NUDGE, never an override: the LLM taxonomy stays the
/// source of truth for the lane, and `importanceScore` is only blended into the
/// within-lane ordering so mail that looks like what the user usually engages with
/// rises gently and mail that looks like what they usually bin sinks. It can never
/// move a security/money/needsYou item into noise — that is the ranker's job, and it
/// only reorders inside a lane.
///
/// Signals (the caller passes each email's embedding via
/// `EmbeddingService.shared.vector(for: subject + " " + senderName + " " + summary)`):
///   - POSITIVE: the user opened the email in the reading drawer; marked the sender VIP.
///   - NEGATIVE: the user archived / unsubscribed / muted / snoozed-to-dismiss it.
///
/// Mirrors `TasteEngine`'s embedding layer exactly: same cap, same geometric recency
/// decay, same tolerant Codable so an older / missing `inbox-importance.json` loads.
struct ImportanceEngine: Codable {
    /// Embeddings of mail the user treated as important, oldest-first. Newer entries
    /// weigh more (recency decay).
    private(set) var positiveVectors: [[Double]]
    /// Embeddings of mail the user dismissed, oldest-first.
    private(set) var negativeVectors: [[Double]]

    init(positiveVectors: [[Double]] = [], negativeVectors: [[Double]] = []) {
        self.positiveVectors = positiveVectors
        self.negativeVectors = negativeVectors
    }

    // Tolerant decoding: a missing / older cache predates these sets.
    enum CodingKeys: String, CodingKey { case positiveVectors, negativeVectors }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positiveVectors = try c.decodeIfPresent([[Double]].self, forKey: .positiveVectors) ?? []
        negativeVectors = try c.decodeIfPresent([[Double]].self, forKey: .negativeVectors) ?? []
    }

    // MARK: - Tuning constants (mirrors TasteEngine)

    /// Cap on how many vectors we retain per side. Bounds memory and per-rank cost;
    /// oldest are evicted first.
    static let vectorSetCap = 50
    /// Geometric decay applied to older vectors when building the mean: the most
    /// recent signal has weight 1, the one before `decay`, etc. < 1 so importance
    /// follows recent behavior.
    static let recencyDecay = 0.92

    // MARK: - Updates

    /// Fold a signal's embedding into the matching set. `vector` may be nil
    /// (embedding unavailable) — then nothing is learned and the re-rank simply has
    /// one less signal, exactly like `TasteEngine`.
    mutating func reinforce(positive: Bool, vector: [Double]?) {
        guard let vector, !vector.isEmpty else { return }
        if positive {
            positiveVectors = Self.appending(vector, to: positiveVectors)
        } else {
            negativeVectors = Self.appending(vector, to: negativeVectors)
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

    // MARK: - Scoring

    /// How "important-looking" `vector` is in [-1, 1] — its cosine to the learned
    /// importance direction. `nil` when there is no signal yet (both sets empty), so
    /// the caller leaves ordering on pure recency rather than inventing a score.
    func importanceScore(for vector: [Double]) -> Double? {
        guard !vector.isEmpty, let taste = tasteVector() else { return nil }
        return EmbeddingService.cosine(taste, vector)
    }

    /// The learned importance direction: recency-weighted `mean(positive) −
    /// mean(negative)`. `nil` when there is no signal at all.
    func tasteVector() -> [Double]? {
        let positive = weightedMean(positiveVectors)
        let negative = weightedMean(negativeVectors)
        switch (positive, negative) {
        case let (p?, n?):
            guard p.count == n.count else { return p }
            return zip(p, n).map { $0 - $1 }
        case let (p?, nil):
            return p
        case let (nil, n?):
            return n.map { -$0 }
        case (nil, nil):
            return nil
        }
    }

    /// Recency-weighted mean of a vector set (last element = most recent = weight 1,
    /// earlier elements decayed by `recencyDecay`). Returns nil if empty.
    private func weightedMean(_ set: [[Double]]) -> [Double]? {
        guard let dim = set.last?.count, dim > 0 else { return nil }
        var sum = [Double](repeating: 0, count: dim)
        var totalWeight = 0.0
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
}
