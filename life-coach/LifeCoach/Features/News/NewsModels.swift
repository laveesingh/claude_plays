import Foundation

/// A free-text topic the user wants their coach to track. `normalizedLabel` is a
/// clean, stable display name ("AI regulation in the EU"); `normalizedKey`
/// (lowercased + trimmed) is the deterministic identity used for the topic→label
/// map and dedup, so the same topic always shows the same interest badge.
struct Topic: Codable, Identifiable, Hashable {
    let id: UUID
    var text: String
    var normalizedLabel: String

    /// Deterministic identity: lowercased, trimmed raw text.
    var normalizedKey: String {
        Topic.normalizeKey(text)
    }

    init(id: UUID = UUID(), text: String, normalizedLabel: String) {
        self.id = id
        self.text = text
        self.normalizedLabel = normalizedLabel
    }

    /// The deterministic key for a piece of topic text - lowercased, trimmed,
    /// internal whitespace collapsed.
    static func normalizeKey(_ text: String) -> String {
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.lowercased()
    }
}

/// What kind of writing a story is, derived by the aggregator's content-type gate
/// from the source domain and title signals. `.blog` items are dropped before the
/// LLM ever sees them; `.opinion` / `.analysis` survive but are tagged so the UI
/// can flag them. `.news` is the default for straight reporting.
enum NewsContentType: String, Codable {
    case news
    case opinion
    case analysis

    /// Tolerant decode: any unknown / missing value (e.g. old `news.json` that
    /// predates this field) falls back to `.news`.
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = NewsContentType(rawValue: raw) ?? .news
    }
}

/// How much we trust a story's date. `.high` means it came from a structured
/// source field (RSS `pubDate`, GDELT `seendate`, NewsData `pubDate`); `.low`
/// means it was only recovered heuristically by `DateExtractor` from web-search
/// text. Surfaced as an "as of" qualifier in the UI.
enum DateConfidence: String, Codable {
    case high
    case low

    /// Tolerant decode: unknown / missing (old data) falls back to `.high`, since
    /// pre-rebuild stories carried model/extractor dates we treated as canonical.
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = DateConfidence(rawValue: raw) ?? .high
    }
}

/// A web source backing a story: a human title and the URL the user can open.
struct NewsSource: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let url: String

    init(id: UUID = UUID(), title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// One clustered, merged story in the timeline. Built only from genuine web
/// results: every story cites at least one provided `NewsSource`. `signature`
/// (the normalized headline) is the dedup key; `storyNumber` is a stable,
/// monotonically increasing label shown as "#N".
struct NewsStory: Codable, Identifiable, Hashable {
    let id: UUID
    let storyNumber: Int
    let interestLabel: String
    let headline: String
    let summary1: String          // ~30-50 words, the card body
    let summary2: String          // ~150-300 words, the full read
    let sources: [NewsSource]
    let createdAt: Date           // when WE fetched it
    let publishedDate: Date?      // the story's own date, extracted from sources (nil if unknown)
    let signature: String         // normalized headline, used for dedup

    // New (TKT-0109) — all default-backed so pre-rebuild news.json still decodes.
    let outlet: String            // primary outlet name, e.g. "Reuters"
    let contentType: NewsContentType  // news / opinion / analysis
    let outletCount: Int          // distinct outlets that corroborated the story
    let dateConfidence: DateConfidence // high (structured date) / low (heuristic)

    /// The user's thumbs-up/down on this story — the signal that trains the News
    /// taste vector. Default-backed so older caches decode cleanly.
    var reaction: Reaction

    /// The date to file this story under in the timeline: its real publication
    /// date when we could extract one, else our fetch time as a fallback. Kept as
    /// a fallback for OLD cached stories; new stories never enter with a nil date,
    /// because `NewsAggregator`'s recency gate excludes dateless items up front.
    var displayDate: Date { publishedDate ?? createdAt }

    init(id: UUID = UUID(),
         storyNumber: Int,
         interestLabel: String,
         headline: String,
         summary1: String,
         summary2: String,
         sources: [NewsSource],
         createdAt: Date = Date(),
         publishedDate: Date? = nil,
         signature: String,
         outlet: String = "",
         contentType: NewsContentType = .news,
         outletCount: Int = 1,
         dateConfidence: DateConfidence = .high,
         reaction: Reaction = .none) {
        self.id = id
        self.storyNumber = storyNumber
        self.interestLabel = interestLabel
        self.headline = headline
        self.summary1 = summary1
        self.summary2 = summary2
        self.sources = sources
        self.createdAt = createdAt
        self.publishedDate = publishedDate
        self.signature = signature
        self.outlet = outlet
        self.contentType = contentType
        self.outletCount = outletCount
        self.dateConfidence = dateConfidence
        self.reaction = reaction
    }

    private enum CodingKeys: String, CodingKey {
        case id, storyNumber, interestLabel, headline, summary1, summary2
        case sources, createdAt, publishedDate, signature
        case outlet, contentType, outletCount, dateConfidence, reaction
    }

    /// Tolerant decode: the four TKT-0109 fields are read with `decodeIfPresent`
    /// and fall back to their defaults, so a `news.json` written before the rebuild
    /// (which has none of them) still loads cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        storyNumber = try c.decode(Int.self, forKey: .storyNumber)
        interestLabel = try c.decode(String.self, forKey: .interestLabel)
        headline = try c.decode(String.self, forKey: .headline)
        summary1 = try c.decode(String.self, forKey: .summary1)
        summary2 = try c.decode(String.self, forKey: .summary2)
        sources = try c.decode([NewsSource].self, forKey: .sources)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        publishedDate = try c.decodeIfPresent(Date.self, forKey: .publishedDate)
        signature = try c.decode(String.self, forKey: .signature)
        outlet = (try c.decodeIfPresent(String.self, forKey: .outlet)) ?? ""
        contentType = (try c.decodeIfPresent(NewsContentType.self, forKey: .contentType)) ?? .news
        outletCount = (try c.decodeIfPresent(Int.self, forKey: .outletCount)) ?? 1
        dateConfidence = (try c.decodeIfPresent(DateConfidence.self, forKey: .dateConfidence)) ?? .high
        reaction = (try c.decodeIfPresent(Reaction.self, forKey: .reaction)) ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(storyNumber, forKey: .storyNumber)
        try c.encode(interestLabel, forKey: .interestLabel)
        try c.encode(headline, forKey: .headline)
        try c.encode(summary1, forKey: .summary1)
        try c.encode(summary2, forKey: .summary2)
        try c.encode(sources, forKey: .sources)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(publishedDate, forKey: .publishedDate)
        try c.encode(signature, forKey: .signature)
        try c.encode(outlet, forKey: .outlet)
        try c.encode(contentType, forKey: .contentType)
        try c.encode(outletCount, forKey: .outletCount)
        try c.encode(dateConfidence, forKey: .dateConfidence)
        try c.encode(reaction, forKey: .reaction)
    }

    /// The dedup signature for a headline: lowercased, trimmed, punctuation
    /// stripped, internal whitespace collapsed. Stable across refreshes so the
    /// same event never re-enters the timeline.
    static func makeSignature(_ headline: String) -> String {
        let lowered = headline.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        let collapsed = String(stripped)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }
}
