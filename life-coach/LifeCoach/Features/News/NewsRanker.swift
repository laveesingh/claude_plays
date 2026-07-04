import Foundation

/// Personal relevance ranking for aggregated news clusters — the step between the
/// aggregator's mechanical gates and the LLM. The aggregator guarantees clusters
/// are fresh, deduplicated, and not blog spam; it says nothing about whether they
/// are actually ABOUT the user's topic (GDELT keyword matches drift badly) or
/// whether the user would care. This ranker fixes both:
///
///   1. **Topic relevance gate.** Each cluster's headline is embedded and compared
///      to the topic text. Clusters far off the best match are dropped — a
///      scale-free relative gate (no absolute cosine threshold to mis-calibrate).
///   2. **Blended score.** Topic similarity + corroboration (more outlets = more
///      newsworthy) + reputable-outlet bonus + recency + the user's learned taste
///      (evidence-scaled, same philosophy as Factscroll's re-rank: a NUDGE that
///      grows with reaction count, never a hard filter).
///   3. **Cap.** Only the top clusters per topic reach the LLM, so the feed is the
///      juicy few, not everything the databases coughed up.
///
/// Declared `async` so it hops off the caller's actor — the embedding calls run
/// off the main thread even when invoked from `NewsStore.refresh()`.
enum NewsRanker {

    // MARK: - Tuning

    /// How many clusters per topic survive to the LLM.
    static let maxClustersPerTopic = 8
    /// A cluster whose topic similarity is below this fraction of the BEST
    /// cluster's similarity is considered off-topic noise and dropped.
    static let relativeRelevanceFloor = 0.55
    /// Score weight for corroboration: log2(1 + outletCount).
    static let corroborationWeight = 0.08
    /// Flat bonus when a reputable outlet carried the story.
    static let reputableBonus = 0.06
    /// Score weight for freshness (1.0 = published this instant, 0 = window edge).
    static let recencyWeight = 0.12

    /// How strongly taste bends the ranking, scaled by evidence: each reaction
    /// adds 0.08, capped at 0.4 — mirrors Factscroll's evidence-scaled blend so a
    /// single thumb can't collapse the feed.
    static func tasteStrength(reactionCount: Int) -> Double {
        min(0.4, 0.08 * Double(reactionCount))
    }

    // MARK: - Entry point

    /// Rank `clusters` for `topic`, gate off-topic noise, and cap to the best
    /// `maxClustersPerTopic`. `windowSeconds` is the freshness window backing the
    /// recency term; `taste` supplies the learned direction (may be signal-free).
    static func rank(_ clusters: [AggregatedCluster],
                     topic: String,
                     taste: TasteEngine,
                     windowSeconds: TimeInterval,
                     now: Date = Date()) async -> [AggregatedCluster] {
        guard clusters.count > 1 else { return clusters }

        let topicVector = EmbeddingService.shared.vector(for: topic)
        let topicTokens = tokenSet(topic)
        let tasteVector = taste.tasteVector()
        let strength = tasteStrength(reactionCount: taste.reactionCount)

        let scored = clusters.map { cluster -> (cluster: AggregatedCluster, topicSim: Double, score: Double) in
            let headlineVector = EmbeddingService.shared.vector(for: cluster.representativeTitle)

            // Topic relevance: embedding cosine when possible, token overlap as
            // the embedding-unavailable fallback (same layering as clustering).
            let topicSim: Double
            if let tv = topicVector, let hv = headlineVector {
                topicSim = EmbeddingService.cosine(tv, hv)
            } else {
                topicSim = tokenOverlap(topicTokens, tokenSet(cluster.representativeTitle))
            }

            // Taste: cosine against the learned direction, evidence-scaled.
            var tasteTerm = 0.0
            if strength > 0, let taste = tasteVector, let hv = headlineVector {
                tasteTerm = strength * EmbeddingService.cosine(taste, hv)
            }

            let corroboration = corroborationWeight * log2(1.0 + Double(cluster.outletCount))
            let reputable = cluster.items.contains { NewsAggregator.reputableNews.contains($0.domain) }
                ? reputableBonus : 0.0
            let age = now.timeIntervalSince(cluster.authoritativeDate)
            let freshness = max(0.0, 1.0 - age / max(windowSeconds, 1))

            let score = topicSim + corroboration + reputable
                + recencyWeight * freshness + tasteTerm
            return (cluster, topicSim, score)
        }

        // Relative relevance gate: measured against the best on-topic cluster, so
        // it adapts to whatever range the embedding produces for this topic. Only
        // applied when there is a real positive best (no signal -> no gate).
        let bestSim = scored.map(\.topicSim).max() ?? 0
        let gated = bestSim > 0
            ? scored.filter { $0.topicSim >= bestSim * relativeRelevanceFloor }
            : scored

        return gated
            .sorted { $0.score > $1.score }
            .prefix(maxClustersPerTopic)
            .map(\.cluster)
    }

    // MARK: - Token fallback

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(NewsStory.makeSignature(text).split(separator: " ").map(String.init).filter { $0.count > 2 })
    }

    /// Shared-over-smaller-set overlap in [0, 1]; 0 when either set is empty.
    private static func tokenOverlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
}
