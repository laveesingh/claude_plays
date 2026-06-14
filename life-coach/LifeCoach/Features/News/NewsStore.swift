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

    private let store: AppStore
    private let grounding: Grounding
    private let anthropic = AnthropicProvider()
    private let ollama = OllamaProvider()
    private let fileStore = FileStore<Cache>(filename: "news.json")

    /// Dedup + numbering + label state, persisted alongside the timeline.
    private var seenSignatures: Set<String> = []
    private var storyCounter = 0
    /// normalizedKey -> stable display label, so a topic's interest badge never
    /// changes once assigned.
    private var topicLabels: [String: String] = [:]

    /// How many search hits per topic feed the model.
    private static let resultsPerTopic = 6

    /// The on-disk shape - everything the spec asks us to persist.
    private struct Cache: Codable {
        var topics: [Topic] = []
        var stories: [NewsStory] = []
        var seenSignatures: [String] = []
        var storyCounter: Int = 0
        var topicLabels: [String: String] = [:]
        var lastUpdated: Date?

        init() {}
    }

    init(store: AppStore, grounding: Grounding = GroundingService.shared) {
        self.store = store
        self.grounding = grounding

        // Load the last cache instantly so the timeline is on screen at launch.
        let cached = fileStore.load(default: Cache())
        topics = cached.topics
        stories = cached.stories
        seenSignatures = Set(cached.seenSignatures)
        storyCounter = cached.storyCounter
        topicLabels = cached.topicLabels
        lastUpdated = cached.lastUpdated
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

    /// For each topic: live web search -> one LLM call that clusters, merges, and
    /// returns ONLY new stories -> dedup by signature -> number + label -> prepend.
    /// Best-effort: a failure on one topic leaves the rest (and the existing
    /// timeline) intact.
    func refresh() async {
        guard !isRefreshing, !topics.isEmpty else { return }
        let provider = currentProvider
        guard provider.hasKey() else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let model = store.state.ai.activeModel
        var didChange = false

        for topic in topics {
            let results: [WebResult]
            do {
                results = try await grounding.search(topic.text, maxResults: Self.resultsPerTopic)
            } catch {
                continue // network/auth/etc. - skip this topic, keep going.
            }
            guard !results.isEmpty else { continue }

            let raw: String
            do {
                raw = try await provider.complete(
                    systemPrompt: Self.systemPrompt,
                    userText: Self.buildUserPayload(topic: topic,
                                                    results: results,
                                                    seenHeadlines: seenHeadlines(for: topic)),
                    model: model
                )
            } catch {
                continue
            }

            let drafts = Self.parseStories(raw)
            let allowedURLs = Set(results.map { $0.url })

            for draft in drafts {
                guard let story = makeStory(from: draft,
                                            topic: topic,
                                            allowedURLs: allowedURLs) else { continue }
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
    /// from the provided results, and a signature not already seen.
    private func makeStory(from draft: StoryDraft,
                           topic: Topic,
                           allowedURLs: Set<String>) -> NewsStory? {
        let headline = draft.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary1 = draft.summary1.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary2 = draft.summary2.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty, !summary1.isEmpty, !summary2.isEmpty else { return nil }

        // Keep only sources that point at a URL we actually provided - never let
        // the model invent a citation.
        let sources = draft.sources.filter { allowedURLs.contains($0.url) }
        guard !sources.isEmpty else { return nil }

        let signature = NewsStory.makeSignature(headline)
        guard !signature.isEmpty, !seenSignatures.contains(signature) else { return nil }

        storyCounter += 1
        return NewsStory(storyNumber: storyCounter,
                         interestLabel: topic.normalizedLabel,
                         headline: headline,
                         summary1: summary1,
                         summary2: summary2,
                         sources: sources,
                         publishedDate: draft.publishedDate,
                         signature: signature)
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
        fileStore.save(cache)
    }

    // MARK: - User payload

    /// One topic's raw search results plus the already-seen headlines, framed so
    /// the model knows exactly what it may cite and what it must not repeat.
    private static func buildUserPayload(topic: Topic,
                                         results: [WebResult],
                                         seenHeadlines: [String]) -> String {
        let resultBlocks = results.enumerated().map { index, result -> String in
            """
            [\(index + 1)]
            title: \(result.title)
            url: \(result.url)
            content: \(result.content)
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

        SEARCH RESULTS (these are your ONLY allowed facts and sources - cite by their exact url):
        \(resultBlocks)

        ALREADY-SEEN STORY HEADLINES for this topic (do NOT return any story about the same event as one of these):
        \(seenBlock)

        Cluster the search results into distinct news stories, drop anything already \
        seen above, and return ONLY the new stories as the JSON array specified in \
        your instructions.
        """
    }

    // MARK: - System prompt (clustering / dedup / summaries)

    static let systemPrompt = """
    You are a news editor. You are given live web search results for ONE topic (each result has a title, a url, and extracted content) and a list of story headlines the reader has ALREADY seen for this topic. Your job is to turn the raw results into a small set of clean, deduplicated news stories.

    HARD RULES - follow every one:
    1. Use ONLY the facts present in the provided search results. NEVER add information from your own knowledge, and NEVER invent or guess facts, numbers, quotes, dates, or sources. If the results do not say it, it does not exist.
    2. CLUSTER results that cover the same underlying event or development into a SINGLE story, and MERGE their information into one coherent account. Multiple articles about one event = one story, not many.
    3. Return ONLY genuinely NEW stories. If a story is about the same event as one of the ALREADY-SEEN headlines, OMIT it entirely. When in doubt that it is a duplicate, omit it.
    4. Every story MUST cite at least one source, and EVERY source you cite must be one of the provided results - copy its url and title EXACTLY as given. Do not cite a url that is not in the results.
    5. If the results contain nothing new and substantive for this topic, return an empty array [].

    For each new story produce:
    - "headline": a clear, specific, factual headline (no clickbait, no editorializing).
    - "summary1": roughly 30-50 words - a tight lede that captures the core of the story at a glance.
    - "summary2": roughly 150-300 words - the full essential understanding of the story: what happened, who is involved, why it matters, and the key specifics. Dense and factual, no fluff, no filler, no repetition of the headline.
    - "date": the story's publication / event date as "YYYY-MM-DD" if the results state it or clearly imply it (e.g. "Monday", "yesterday", an explicit date in the content); otherwise null. NEVER guess a date - if it isn't supported by the results, use null.
    - "sources": an array of the results this story is drawn from, each with "title" and "url" copied exactly from the provided results.

    Return ONLY a JSON array, no prose and no markdown code fences. Each element has exactly these keys:
    [
      {
        "headline": "<specific factual headline>",
        "summary1": "<~30-50 words>",
        "summary2": "<~150-300 words, full essential understanding, no fluff>",
        "date": "<YYYY-MM-DD, or null if unknown>",
        "sources": [ { "title": "<exact result title>", "url": "<exact result url>" } ]
      }
    ]

    If there are no new stories, return exactly: []
    """

    // MARK: - Parsing

    /// A parsed-but-unvalidated story from the model.
    private struct StoryDraft {
        let headline: String
        let summary1: String
        let summary2: String
        let sources: [NewsSource]
        let publishedDate: Date?
    }

    /// Parses the model's "YYYY-MM-DD" date string (UTC, fixed format) to a Date;
    /// returns nil for null/empty/malformed so we fall back to the fetch time.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func parseDay(_ any: Any?) -> Date? {
        guard let raw = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.lowercased() != "null" else { return nil }
        return dayParser.date(from: raw)
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
                              sources: sources,
                              publishedDate: parseDay(object["date"]))
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
