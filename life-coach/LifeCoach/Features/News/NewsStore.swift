import Foundation
import Combine

/// The News feature's brain and on-disk cache. Owns the user's topics and the
/// newest-first story timeline, persists everything to `news.json` via the shared
/// `FileStore` pattern, and runs `refresh()`: per topic it web-searches (live, via
/// `GroundingService`), then asks the active LLM to cluster + merge + dedup the
/// raw results into NEW stories only, never inventing facts or sources.
///
/// The provider/model is resolved from persisted AI settings each refresh, exactly
/// like `CoachEngine.currentProvider` / `InboxClassifier`.
@MainActor
final class NewsStore: ObservableObject {
    @Published private(set) var topics: [Topic] = []
    @Published private(set) var stories: [NewsStory] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    /// The recency window, in days, that bounds BOTH the aggregator's hard recency
    /// gate (no story older than this enters) and the UI's freshness filter (the
    /// "1d / 3d / 7d" picker re-filters the visible timeline). Persisted in `Cache`.
    @Published var freshnessWindow: Double = 7.0 {
        didSet { if oldValue != freshnessWindow { persist() } }
    }

    private let store: AppStore
    private let anthropic = AnthropicProvider()
    private let ollama = OllamaProvider()
    private let fileStore = FileStore<Cache>(filename: "news.json")

    /// Dedup + numbering + label state, persisted alongside the timeline.
    private var seenSignatures: Set<String> = []
    private var storyCounter = 0
    /// normalizedKey -> stable display label, so a topic's interest badge never
    /// changes once assigned.
    private var topicLabels: [String: String] = [:]

    /// The on-disk shape - everything the spec asks us to persist.
    private struct Cache: Codable {
        var topics: [Topic] = []
        var stories: [NewsStory] = []
        var seenSignatures: [String] = []
        var storyCounter: Int = 0
        var topicLabels: [String: String] = [:]
        var lastUpdated: Date?
        var freshnessWindow: Double = 7.0

        init() {}

        private enum CodingKeys: String, CodingKey {
            case topics, stories, seenSignatures, storyCounter, topicLabels, lastUpdated, freshnessWindow
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            topics = (try? c.decode([Topic].self, forKey: .topics)) ?? []
            stories = (try? c.decode([NewsStory].self, forKey: .stories)) ?? []
            seenSignatures = (try? c.decode([String].self, forKey: .seenSignatures)) ?? []
            storyCounter = (try? c.decode(Int.self, forKey: .storyCounter)) ?? 0
            topicLabels = (try? c.decode([String: String].self, forKey: .topicLabels)) ?? [:]
            lastUpdated = try? c.decodeIfPresent(Date.self, forKey: .lastUpdated)
            freshnessWindow = (try? c.decodeIfPresent(Double.self, forKey: .freshnessWindow)) ?? 7.0
        }
    }

    init(store: AppStore) {
        self.store = store

        // Load the last cache instantly so the timeline is on screen at launch.
        let cached = fileStore.load(default: Cache())
        topics = cached.topics
        stories = cached.stories
        seenSignatures = Set(cached.seenSignatures)
        storyCounter = cached.storyCounter
        topicLabels = cached.topicLabels
        lastUpdated = cached.lastUpdated
        freshnessWindow = cached.freshnessWindow
    }

    /// The active backend, resolved from persisted settings - same rule as the coach.
    private var currentProvider: ChatProvider {
        store.state.ai.provider == .ollama ? ollama : anthropic
    }

    // MARK: - Topic management

    /// Add a new free-text topic. Idempotent on the normalized key - re-adding an
    /// existing topic is a no-op so its interest label stays stable.
    func addTopic(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = Topic.normalizeKey(trimmed)
        guard !topics.contains(where: { $0.normalizedKey == key }) else { return }

        let label = label(forKey: key, fallbackText: trimmed)
        topics.append(Topic(text: trimmed, normalizedLabel: label))
        persist()
    }

    /// Remove a topic. Its already-published stories stay in the timeline.
    func removeTopic(_ topic: Topic) {
        topics.removeAll { $0.id == topic.id }
        persist()
    }

    /// Rename a topic's free text. The interest label follows the new normalized
    /// key (reusing the persisted label if that key was seen before).
    func updateTopic(_ topic: Topic, to newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = topics.firstIndex(where: { $0.id == topic.id }) else { return }
        let key = Topic.normalizeKey(trimmed)
        // Don't collide onto another existing topic's key.
        if key != topics[index].normalizedKey,
           topics.contains(where: { $0.normalizedKey == key }) {
            return
        }
        topics[index].text = trimmed
        topics[index].normalizedLabel = label(forKey: key, fallbackText: trimmed)
        persist()
    }

    /// Resolve (and persist, on first sight) the stable display label for a
    /// normalized key. Title-cases the raw text and dedupes against the existing
    /// label set so two different topics never share a badge.
    private func label(forKey key: String, fallbackText: String) -> String {
        if let existing = topicLabels[key] { return existing }

        var candidate = Self.titleCased(fallbackText)
        let taken = Set(topicLabels.values)
        if taken.contains(candidate) {
            var suffix = 2
            while taken.contains("\(candidate) (\(suffix))") { suffix += 1 }
            candidate = "\(candidate) (\(suffix))"
        }
        topicLabels[key] = candidate
        return candidate
    }

    private static func titleCased(_ text: String) -> String {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return text }
        return words.map { word -> String in
            // Preserve already-capitalized / all-caps tokens (e.g. "EU", "AI").
            if word == word.uppercased() { return word }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    // MARK: - Refresh

    /// For each topic: aggregate from every enabled source (Google News RSS, GDELT,
    /// web search, and optional NewsData.io) into date-verified, deduplicated,
    /// content-type-gated clusters -> one LLM call that writes summaries from those
    /// clusters (copying their authoritative dates, never inventing) -> dedup by
    /// signature -> number + label -> prepend. Best-effort: a failure on one topic
    /// leaves the rest (and the existing timeline) intact.
    func refresh() async {
        guard !isRefreshing, !topics.isEmpty else { return }
        let provider = currentProvider
        guard provider.hasKey() else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let model = store.state.ai.activeModel
        var didChange = false
        // The hard recency floor for this refresh — the aggregator drops anything
        // older (or dateless), so no new story can be filed under fetch time.
        let since = Date().addingTimeInterval(-freshnessWindow * 86_400)

        for topic in topics {
            // 1. Multi-source aggregation (off the main thread under the hood).
            let clusters = await NewsAggregator.aggregate(topic: topic.text, since: since)
            guard !clusters.isEmpty else { continue }

            // 2. One LLM call over the pre-clustered, date-verified material.
            let raw: String
            do {
                raw = try await provider.complete(
                    systemPrompt: Self.systemPrompt,
                    userText: Self.buildUserPayload(topic: topic,
                                                    clusters: clusters,
                                                    seenHeadlines: seenHeadlines(for: topic)),
                    model: model
                )
            } catch {
                continue
            }

            // 3. Parse + make stories, snapping citations + dates + metadata back to
            //    the clusters (never trusting model-invented URLs or dates).
            let drafts = Self.parseStories(raw)
            for draft in drafts {
                guard let story = makeStory(from: draft, topic: topic, clusters: clusters) else { continue }
                seenSignatures.insert(story.signature)
                stories.insert(story, at: 0) // newest-first
                didChange = true
            }
        }

        lastUpdated = Date()
        if didChange || lastUpdated != nil { persist() }
    }

    /// Headlines already published for a topic, so the model can avoid repeats.
    private func seenHeadlines(for topic: Topic) -> [String] {
        stories
            .filter { $0.interestLabel == topic.normalizedLabel }
            .map { $0.headline }
    }

    /// Build a real `NewsStory` from a parsed draft, enforcing the hard rules:
    /// non-empty headline + summaries, at least one source, every source URL drawn
    /// from the aggregated clusters, a signature not already seen — and copying the
    /// authoritative date + outlet + content-type + corroboration count from the
    /// matched cluster, never from the model.
    private func makeStory(from draft: StoryDraft,
                           topic: Topic,
                           clusters: [AggregatedCluster]) -> NewsStory? {
        let headline = draft.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary1 = draft.summary1.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary2 = draft.summary2.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty, !summary1.isEmpty, !summary2.isEmpty else { return nil }

        // Tolerant URL → cluster index built once per draft. A model citation that
        // differs only by trailing slash / host case still resolves to a real item.
        let urlToCluster = Self.urlClusterMap(clusters)

        // Keep only sources that resolve to a URL we actually provided. We snap the
        // source back to OUR exact url so it opens, and remember which cluster(s)
        // the cited URLs came from so the story inherits that cluster's metadata.
        var sources: [NewsSource] = []
        var matchedClusterIndices: Set<Int> = []
        for source in draft.sources {
            guard let (canonical, clusterIndex) = urlToCluster[Self.normalizeURL(source.url)] else { continue }
            sources.append(NewsSource(title: source.title, url: canonical))
            matchedClusterIndices.insert(clusterIndex)
        }
        guard !sources.isEmpty else { return nil }

        let signature = NewsStory.makeSignature(headline)
        guard !signature.isEmpty, !seenSignatures.contains(signature) else { return nil }

        // The story's authoritative cluster: the earliest-dated among the clusters
        // its cited URLs touched. Everything date/outlet-related comes from here —
        // NOT from the model — which is the whole point of the rebuild.
        let matched = matchedClusterIndices.compactMap { clusters.indices.contains($0) ? clusters[$0] : nil }
        guard let primary = matched.min(by: { $0.authoritativeDate < $1.authoritativeDate }) else { return nil }

        storyCounter += 1
        return NewsStory(storyNumber: storyCounter,
                         interestLabel: topic.normalizedLabel,
                         headline: headline,
                         summary1: summary1,
                         summary2: summary2,
                         sources: sources,
                         publishedDate: primary.authoritativeDate,
                         signature: signature,
                         outlet: primary.outlet,
                         contentType: primary.contentType,
                         outletCount: primary.outletCount,
                         dateConfidence: primary.dateConfidence)
    }

    /// Tolerant map: normalized url -> (exact url, owning cluster index). Lets a
    /// model citation resolve to a real cluster item even with a trailing-slash or
    /// host-case nudge, and carries which cluster it belongs to so the story can
    /// inherit that cluster's date/outlet metadata.
    private static func urlClusterMap(_ clusters: [AggregatedCluster]) -> [String: (url: String, index: Int)] {
        var map: [String: (url: String, index: Int)] = [:]
        for (index, cluster) in clusters.enumerated() {
            for item in cluster.items {
                map[normalizeURL(item.url)] = (item.url, index)
            }
        }
        return map
    }

    /// Normalize a url for tolerant matching: lowercase scheme+host, drop a single
    /// trailing slash, drop a leading "www.". Path case is preserved (paths are
    /// case-sensitive).
    private static func normalizeURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hashIndex = s.firstIndex(of: "#") { s = String(s[..<hashIndex]) }
        guard let comps = URLComponents(string: s), let host = comps.host else {
            return s.lowercased()
        }
        let scheme = (comps.scheme ?? "https").lowercased()
        var h = host.lowercased()
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        var path = comps.path
        if path.count > 1, path.hasSuffix("/") { path = String(path.dropLast()) }
        let query = comps.query.map { "?\($0)" } ?? ""
        return "\(scheme)://\(h)\(path)\(query)"
    }

    // MARK: - Persistence

    private func persist() {
        var cache = Cache()
        cache.topics = topics
        cache.stories = stories
        cache.seenSignatures = Array(seenSignatures)
        cache.storyCounter = storyCounter
        cache.topicLabels = topicLabels
        cache.lastUpdated = lastUpdated
        cache.freshnessWindow = freshnessWindow
        fileStore.save(cache)
    }

    // MARK: - User payload

    /// One topic's PRE-CLUSTERED stories plus the already-seen headlines, framed so
    /// the model knows exactly what it may cite, what each cluster's authoritative
    /// date is (to copy verbatim), and what it must not repeat. Each cluster is one
    /// already-deduplicated, date-verified story — the model only writes prose.
    private static func buildUserPayload(topic: Topic,
                                         clusters: [AggregatedCluster],
                                         seenHeadlines: [String]) -> String {
        let clusterBlocks = clusters.enumerated().map { index, cluster -> String in
            let day = DateExtractor.dayFormatter.string(from: cluster.authoritativeDate)
            let opinionTag = cluster.contentType == .news ? "" : " [\(cluster.contentType.rawValue.uppercased())]"
            let sources = cluster.urls.map { "  - \($0)" }.joined(separator: "\n")
            let snippets = cluster.snippets.prefix(4)
                .map { "  • \($0)" }
                .joined(separator: "\n")
            return """
            [CLUSTER \(index + 1)]\(opinionTag)
            title: \(cluster.representativeTitle)
            date: \(day)            (authoritative — copy this EXACT date)
            outlet: \(cluster.outlet) (\(cluster.outletCount) outlet\(cluster.outletCount == 1 ? "" : "s") reporting)
            sources (cite by these exact urls):
            \(sources)
            facts:
            \(snippets.isEmpty ? "  • (use only the title above)" : snippets)
            """
        }.joined(separator: "\n\n")

        let seenBlock: String
        if seenHeadlines.isEmpty {
            seenBlock = "(none yet - every genuine story is new)"
        } else {
            seenBlock = seenHeadlines.map { "- \($0)" }.joined(separator: "\n")
        }

        return """
        TOPIC: \(topic.text)

        PRE-CLUSTERED STORIES (each is ONE deduplicated, date-verified story — write a summary for each, citing its exact urls and copying its exact date):
        \(clusterBlocks)

        ALREADY-SEEN STORY HEADLINES for this topic (do NOT return any story about the same event as one of these):
        \(seenBlock)

        Write one story per NEW cluster above, drop any cluster that matches an \
        already-seen headline, and return ONLY the new stories as the JSON array \
        specified in your instructions.
        """
    }

    // MARK: - System prompt (clustering / dedup / summaries)

    static let systemPrompt = """
    You are a news editor. You are given PRE-CLUSTERED stories for ONE topic and a list of story headlines the reader has ALREADY seen. Each cluster has ALREADY been deduplicated across sources and date-verified for you — your only job is to write a clean summary for each new cluster. Do NOT re-cluster, re-date, or merge clusters together.

    HARD RULES - follow every one:
    1. Use ONLY the facts present in the provided clusters (their title + facts). NEVER add information from your own knowledge, and NEVER invent or guess facts, numbers, quotes, dates, or sources. If a cluster does not say it, it does not exist.
    2. Write EXACTLY ONE story per cluster. Each cluster is already one story — never split a cluster into several, never merge two clusters into one.
    3. The DATE is already set for you on each cluster's "date:" line. Copy it EXACTLY into the story's "date" field. Do NOT compute, infer, or invent a date — just copy the cluster's date verbatim.
    4. Every story MUST cite at least one source, and EVERY source you cite must be one of THAT cluster's listed urls - copy the url EXACTLY as given. Do not cite a url that is not in the cluster. Give each source a short, accurate title.
    5. Omit a cluster ONLY when it clearly covers the SAME event as one of the ALREADY-SEEN headlines. A genuinely distinct development is NOT a duplicate — INCLUDE it. Lean toward surfacing news.
    6. Return an empty array [] only when EVERY cluster is a duplicate of an already-seen headline.

    For each new story produce:
    - "headline": a clear, specific, factual headline (no clickbait, no editorializing).
    - "summary1": roughly 30-50 words - a tight lede that captures the core of the story at a glance.
    - "summary2": roughly 150-300 words - the full essential understanding of the story: what happened, who is involved, why it matters, and the key specifics. Dense and factual, no fluff, no filler, no repetition of the headline.
    - "date": copy the cluster's "date:" value EXACTLY as "YYYY-MM-DD".
    - "sources": an array of that cluster's sources you drew from, each with "title" and "url" copied exactly from the cluster.

    Return ONLY a JSON array, no prose and no markdown code fences. Each element has exactly these keys:
    [
      {
        "headline": "<specific factual headline>",
        "summary1": "<~30-50 words>",
        "summary2": "<~150-300 words, full essential understanding, no fluff>",
        "date": "<the cluster's exact date, YYYY-MM-DD>",
        "sources": [ { "title": "<short accurate title>", "url": "<exact cluster url>" } ]
      }
    ]

    If there are no new stories, return exactly: []
    """

    // MARK: - Parsing

    /// A parsed-but-unvalidated story from the model. The date is NOT read from the
    /// model — it comes from the matched cluster — so it isn't carried here.
    private struct StoryDraft {
        let headline: String
        let summary1: String
        let summary2: String
        let sources: [NewsSource]
    }

    /// Robustly parse the model's reply into drafts: strip code fences, tolerate
    /// surrounding prose, and read the first top-level JSON array.
    private static func parseStories(_ raw: String) -> [StoryDraft] {
        guard let json = extractJSONArray(raw),
              let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { object in
            let headline = (object["headline"] as? String) ?? ""
            let summary1 = (object["summary1"] as? String) ?? ""
            let summary2 = (object["summary2"] as? String) ?? ""
            let rawSources = (object["sources"] as? [[String: Any]]) ?? []
            let sources = rawSources.compactMap { src -> NewsSource? in
                guard let url = (src["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !url.isEmpty else { return nil }
                let title = (src["title"] as? String) ?? url
                return NewsSource(title: title, url: url)
            }
            guard !headline.isEmpty else { return nil }
            return StoryDraft(headline: headline,
                              summary1: summary1,
                              summary2: summary2,
                              sources: sources)
        }
    }

    /// Pull the first balanced top-level `[ ... ]` out of arbitrary model text,
    /// after stripping any ``` fences. Mirrors the Inbox classifier's extractor.
    private static func extractJSONArray(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fenceRange = text.range(of: "```", options: .backwards) {
                text = String(text[..<fenceRange.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let start = text.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "[" {
                    depth += 1
                } else if char == "]" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
