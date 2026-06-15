import Foundation

/// The user's reaction to a fact. Feeds the `TasteEngine`: `like` lifts the
/// fact's topic weight, `dislike` lowers it. `none` is the default.
enum Reaction: String, Codable, CaseIterable, Identifiable {
    case none
    case like
    case dislike

    var id: String { rawValue }
}

/// A single AI-generated fact rendered as one full-screen slide in the feed.
///
/// `canonicalKey` is the model-emitted normalized subject-predicate-object key
/// (snake_case, e.g. `venus_day_longer_than_year`) — the first, cheapest dedup
/// layer: exact-key collisions are dropped before we ever embed. `signature` is
/// the token-overlap key derived by `FactDedup`, kept as the fallback dedup
/// signal when on-device embedding is unavailable. `topic` is the model's short
/// tag for the fact and is what the `TasteEngine` weights / leans on.
struct Fact: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let topic: String
    let signature: String
    /// Canonical claim key emitted by the generator (snake_case S-P-O). Default
    /// "" so caches written before this field decode cleanly.
    let canonicalKey: String
    let createdAt: Date
    var reaction: Reaction
    var note: String?

    init(id: UUID = UUID(),
         text: String,
         topic: String,
         signature: String,
         canonicalKey: String = "",
         createdAt: Date = Date(),
         reaction: Reaction = .none,
         note: String? = nil) {
        self.id = id
        self.text = text
        self.topic = topic
        self.signature = signature
        self.canonicalKey = canonicalKey
        self.createdAt = createdAt
        self.reaction = reaction
        self.note = note
    }

    // Tolerant decoding: old caches predate `canonicalKey`, so default it.
    enum CodingKeys: String, CodingKey {
        case id, text, topic, signature, canonicalKey, createdAt, reaction, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        topic = try c.decode(String.self, forKey: .topic)
        signature = try c.decode(String.self, forKey: .signature)
        canonicalKey = try c.decodeIfPresent(String.self, forKey: .canonicalKey) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        reaction = try c.decodeIfPresent(Reaction.self, forKey: .reaction) ?? .none
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}
