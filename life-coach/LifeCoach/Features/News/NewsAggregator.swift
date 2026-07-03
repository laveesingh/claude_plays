import Foundation

/// One distilled story cluster, ready to hand to the LLM. The aggregator has
/// already fanned out across every enabled source, dropped anything dateless or
/// stale, deduplicated by URL, merged cross-source duplicates of the same event,
/// and dropped blog/press-release noise — so a cluster is a date-verified,
/// multi-source view of a single story.
struct AggregatedCluster {
    /// The headline of the cluster's representative (earliest-dated) item.
    let representativeTitle: String
    /// Every item folded into this cluster, across sources.
    let items: [NewsItem]
    /// The earliest real `publishedDate` among the items — the story broke then.
    /// Guaranteed non-nil because the recency gate drops dateless items first.
    let authoritativeDate: Date
    /// The primary outlet (most reputable when known, else the representative's).
    let outlet: String
    /// How many DISTINCT outlets corroborated the story.
    let outletCount: Int
    /// The gate's classification: `.news` / `.opinion` / `.analysis`. `.blog`
    /// clusters never reach here — they are dropped during aggregation.
    let contentType: NewsContentType
    /// `.high` when at least one item carried a structured source date; `.low`
    /// when only the web-search heuristic supplied dates.
    let dateConfidence: DateConfidence
    /// The cited URLs for the LLM (and ultimately the story's sources).
    let urls: [String]
    /// The text excerpts the LLM summarizes from.
    let snippets: [String]
}

/// The multi-source news pipeline. Stateless: a single `aggregate(topic:since:)`
/// entry point fans out to every enabled `NewsFeedSource`, then runs the recency
/// and content-type gates, URL + cross-source dedup, and outputs ready-to-summarize
/// `AggregatedCluster`s sorted newest-first.
///
/// It deliberately does NOT call the LLM — `NewsStore` owns that step, feeding it
/// these clusters. Everything here is plain `async` (URLSession / XMLParser /
/// JSONSerialization / NLEmbedding are all main-actor-free), so calling it from
/// `NewsStore.refresh()` (a `@MainActor` async context) suspends without ever
/// blocking the main thread.
enum NewsAggregator {

    // MARK: - Tuning

    /// Cosine-similarity threshold for "same story" via sentence embeddings.
    private static let clusterCosineThreshold = 0.82
    /// Token-overlap fraction for the embedding-unavailable fallback.
    private static let clusterTokenOverlapThreshold = 0.5

    /// Reputable straight-news domains → `.news`. Internal: `NewsRanker` also
    /// consults it for its reputable-outlet score bonus.
    static let reputableNews: Set<String> = [
        "reuters.com", "apnews.com", "bbc.com", "bbc.co.uk", "nytimes.com",
        "theguardian.com", "bloomberg.com", "wsj.com", "ft.com", "cnbc.com",
        "axios.com", "npr.org", "washingtonpost.com", "economist.com",
        "politico.com", "thehill.com", "techcrunch.com", "wired.com",
    ]

    /// Blog / marketing / press-release domains → `.blog` (dropped before the LLM).
    private static let blogPlatforms: Set<String> = [
        "medium.com", "substack.com", "businesswire.com", "prnewswire.com",
        "globenewswire.com", "marketwatch.com",
    ]

    /// Title prefixes that mark opinion / analysis writing.
    private static let opinionPrefixes = ["opinion:", "op-ed:", "editorial:"]
    private static let analysisPrefixes = ["analysis:"]

    // MARK: - Entry point

    /// Aggregate, gate, dedup, and cluster `topic`'s news since `since`.
    ///
    /// Fan-out ordering is deliberate: Google RSS and web search run concurrently
    /// (independent, fast), THEN GDELT runs sequentially (it self-imposes a 5.5s
    /// rate-limit sleep — running it concurrently would just pile a request behind
    /// that sleep), THEN the optional NewsData.io source. The result order doesn't
    /// matter; the final clusters are sorted by date.
    static func aggregate(topic: String, since: Date) async -> [AggregatedCluster] {
        let google = GoogleNewsRSSSource()
        let web = WebSearchNewsSource()
        let gdelt = GDELTSource()
        let keyed = KeyedNewsAPISource()

        // 1. Fan-out.
        async let googleItems = google.isEnabled ? google.fetch(topic: topic, since: since) : []
        async let webItems = web.isEnabled ? web.fetch(topic: topic, since: since) : []
        var items = await googleItems + (await webItems)

        // GDELT sequentially (owns its rate-limit delay).
        if gdelt.isEnabled {
            items += await gdelt.fetch(topic: topic, since: since)
        }
        // NewsData.io only when keyed.
        if keyed.isEnabled {
            items += await keyed.fetch(topic: topic, since: since)
        }

        // 2. Hard recency gate — THIS is the Bug A fix. No real date, or older than
        //    the window → gone. New stories can never be filed under fetch time.
        let fresh = items.filter { item in
            guard let date = item.publishedDate else { return false }
            return date >= since
        }
        guard !fresh.isEmpty else { return [] }

        // 3. URL dedup (normalized host/path), keeping the first occurrence.
        let deduped = dedupeByURL(fresh)

        // 4. Cross-source clustering by title similarity.
        let clusters = clusterByStory(deduped)

        // 5–7. Gate each cluster on content type, drop blogs, distill, sort.
        let distilled = clusters.compactMap { distill($0) }
        return distilled.sorted { $0.authoritativeDate > $1.authoritativeDate }
    }

    // MARK: - URL dedup

    /// Drop items whose normalized URL was already seen. Normalization lowercases
    /// the host, strips a leading "www.", and drops a single trailing slash so two
    /// links to the same article collapse to one.
    private static func dedupeByURL(_ items: [NewsItem]) -> [NewsItem] {
        var seen: Set<String> = []
        var out: [NewsItem] = []
        for item in items {
            let key = normalizeURL(item.url)
            if seen.insert(key).inserted {
                out.append(item)
            }
        }
        return out
    }

    /// Normalize a URL for dedup: lowercase scheme+host, drop "www.", drop a single
    /// trailing slash. Path case is preserved (paths are case-sensitive).
    private static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed), let host = comps.host else {
            return trimmed.lowercased()
        }
        let scheme = (comps.scheme ?? "https").lowercased()
        var h = host.lowercased()
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        var path = comps.path
        if path.count > 1, path.hasSuffix("/") { path = String(path.dropLast()) }
        let query = comps.query.map { "?\($0)" } ?? ""
        return "\(scheme)://\(h)\(path)\(query)"
    }

    // MARK: - Cross-source clustering

    /// Group items that cover the same underlying story. Each new item is compared
    /// against the existing cluster representatives: first by exact normalized-
    /// headline signature, then by sentence-embedding cosine (> 0.82), and finally
    /// — when embeddings are unavailable — by normalized token overlap (> 50%).
    private static func clusterByStory(_ items: [NewsItem]) -> [[NewsItem]] {
        // Precompute each item's signature + embedding once.
        let indexed = items.map { item -> IndexedItem in
            let sig = NewsStory.makeSignature(item.title)
            return IndexedItem(item: item,
                               signature: sig,
                               vector: EmbeddingService.shared.vector(for: item.title),
                               tokens: tokenSet(sig))
        }

        var clusters: [[IndexedItem]] = []
        outer: for entry in indexed {
            for i in clusters.indices {
                if let rep = clusters[i].first, isSameStory(entry, rep) {
                    clusters[i].append(entry)
                    continue outer
                }
            }
            clusters.append([entry])
        }
        return clusters.map { $0.map { $0.item } }
    }

    /// Whether two indexed items are the same story, by the layered rule.
    private static func isSameStory(_ a: IndexedItem, _ b: IndexedItem) -> Bool {
        // Exact signature match is unambiguous.
        if !a.signature.isEmpty, a.signature == b.signature { return true }
        // Embedding cosine when both vectors exist.
        if let va = a.vector, let vb = b.vector {
            return EmbeddingService.cosine(va, vb) > clusterCosineThreshold
        }
        // Fallback: token overlap (Jaccard-ish — shared / smaller set).
        guard !a.tokens.isEmpty, !b.tokens.isEmpty else { return false }
        let shared = a.tokens.intersection(b.tokens).count
        let denom = min(a.tokens.count, b.tokens.count)
        return denom > 0 && Double(shared) / Double(denom) > clusterTokenOverlapThreshold
    }

    /// Split a normalized signature into a token set for the overlap fallback.
    private static func tokenSet(_ signature: String) -> Set<String> {
        Set(signature.split(separator: " ").map(String.init).filter { $0.count > 2 })
    }

    // MARK: - Content-type gate + distillation

    /// Classify a cluster, drop it if it's a blog/press-release, and otherwise pack
    /// it into an `AggregatedCluster` with its authoritative date, outlet stats, and
    /// citation material. Returns `nil` for dropped clusters.
    private static func distill(_ items: [NewsItem]) -> AggregatedCluster? {
        guard !items.isEmpty else { return nil }

        // Representative = earliest dated item (the date is the story's break time).
        // All items here are post-recency-gate, so every publishedDate is non-nil.
        let dated = items.compactMap { item -> (NewsItem, Date)? in
            item.publishedDate.map { (item, $0) }
        }
        guard let (representative, authoritativeDate) = dated.min(by: { $0.1 < $1.1 }) else {
            return nil
        }

        // Content-type gate.
        let contentType = classify(items: items)
        if case .blog = contentType { return nil }   // dropped — never reaches the LLM

        // Distinct outlets (by normalized name) for the corroboration badge.
        let distinctOutlets = Set(items.map { $0.outlet.lowercased() }.filter { !$0.isEmpty })
        let outletCount = max(1, distinctOutlets.count)

        // Primary outlet: prefer a reputable-domain item's outlet, else the rep's.
        let primaryOutlet = items.first(where: { reputableNews.contains($0.domain) })?.outlet
            ?? representative.outlet

        // Date confidence: high if ANY item came from a structured-date source.
        let hasStructuredDate = items.contains { ["google_news_rss", "gdelt", "newsdata_io"].contains($0.connector) && $0.publishedDate != nil }
        let dateConfidence: DateConfidence = hasStructuredDate ? .high : .low

        return AggregatedCluster(
            representativeTitle: representative.title,
            items: items,
            authoritativeDate: authoritativeDate,
            outlet: primaryOutlet,
            outletCount: outletCount,
            contentType: contentType.asStoryType,
            dateConfidence: dateConfidence,
            urls: items.map { $0.url },
            snippets: items.map { $0.snippet }.filter { !$0.isEmpty }
        )
    }

    /// The internal gate verdict — adds `.blog` (a drop signal) on top of the
    /// public `NewsContentType`.
    private enum GateType {
        case news
        case opinion
        case analysis
        case blog

        /// Map the surviving verdicts onto the persisted `NewsContentType`.
        /// `.blog` never survives, so it maps to `.news` defensively.
        var asStoryType: NewsContentType {
            switch self {
            case .opinion: return .opinion
            case .analysis: return .analysis
            case .news, .blog: return .news
            }
        }
    }

    /// Classify a cluster by examining every item's domain and title. Precedence:
    /// 1. Any blog/marketing/press-release domain → `.blog` (the whole cluster is
    ///    dropped; we don't surface PR-wire stories).
    /// 2. Any opinion / analysis title signal → `.opinion` / `.analysis`.
    /// 3. Otherwise `.news` (reputable domains and everything unknown alike — the
    ///    default; no LLM tiebreaker needed at this stage).
    private static func classify(items: [NewsItem]) -> GateType {
        // 1. Blog / press-release domain anywhere → drop.
        for item in items where isBlogDomain(item.domain) {
            return .blog
        }
        // 2. Opinion / analysis title signals.
        for item in items {
            let lowered = item.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if opinionPrefixes.contains(where: { lowered.hasPrefix($0) }) { return .opinion }
            if analysisPrefixes.contains(where: { lowered.hasPrefix($0) }) { return .analysis }
        }
        // 3. Default.
        return .news
    }

    /// Whether a domain is a blog / marketing / press-release host: an exact match
    /// in `blogPlatforms`, or a wildcard suffix (`*.blog`, `*.wordpress.com`).
    private static func isBlogDomain(_ domain: String) -> Bool {
        if blogPlatforms.contains(domain) { return true }
        if domain.hasSuffix(".blog") { return true }
        if domain.hasSuffix(".wordpress.com") { return true }
        return false
    }
}

/// One item pre-indexed for clustering: its normalized-headline signature, its
/// (optional) sentence-embedding vector, and its token set for the fallback. Kept
/// at file scope so `isSameStory(_:_:)` has a clean, named parameter type.
private struct IndexedItem {
    let item: NewsItem
    let signature: String
    let vector: [Double]?
    let tokens: Set<String>
}
