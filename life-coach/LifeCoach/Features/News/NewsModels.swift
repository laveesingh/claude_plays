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

    /// The date to file this story under in the timeline: its real publication
    /// date when we could extract one, else our fetch time as a fallback.
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
         signature: String) {
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
