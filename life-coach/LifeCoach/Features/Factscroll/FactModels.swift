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
/// `signature` is the normalized dedup key derived by `FactDedup` (see that
/// file) - it is what the generator's dedup ledger is built from and what we
/// collision-check new facts against. `topic` is the model's short tag for the
/// fact and is what the `TasteEngine` weights.
struct Fact: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let topic: String
    let signature: String
    let createdAt: Date
    var reaction: Reaction
    var note: String?

    init(id: UUID = UUID(),
         text: String,
         topic: String,
         signature: String,
         createdAt: Date = Date(),
         reaction: Reaction = .none,
         note: String? = nil) {
        self.id = id
        self.text = text
        self.topic = topic
        self.signature = signature
        self.createdAt = createdAt
        self.reaction = reaction
        self.note = note
    }
}
