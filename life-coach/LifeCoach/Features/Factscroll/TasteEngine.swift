import Foundation

/// Learns the user's taste from their reactions so the generator can lean toward
/// topics they like and away from ones they dislike.
///
/// **v1 — to be refined after a brainstorm.** Today taste is a single flat map of
/// `topic -> weight`. A like adds, a dislike subtracts, a note is stored (and
/// nudges the topic up slightly, on the theory that taking the time to comment
/// signals engagement). `leanTopics()` / `avoidTopics()` surface the strongest
/// signals to the prompt. This is deliberately crude and modular — it knows
/// nothing about *why* a fact was liked (the actual interesting axis is probably
/// sub-topic / tone / surprise, not the coarse one-word tag). Candidates for the
/// brainstorm: decay over time, note sentiment, embedding-space taste vectors,
/// separating "topic" from "style".
struct TasteEngine: Codable {
    /// topic (lowercased) -> accumulated weight. Positive = liked, negative = disliked.
    private(set) var topicWeights: [String: Double]

    /// Freeform notes the user left on specific facts, newest last. Stored so a
    /// future, smarter taste model (or the generator directly) can use them.
    private(set) var notes: [TasteNote]

    init(topicWeights: [String: Double] = [:], notes: [TasteNote] = []) {
        self.topicWeights = topicWeights
        self.notes = notes
    }

    // MARK: - v1 tuning constants
    private static let likeDelta = 1.0
    private static let dislikeDelta = -1.0
    private static let noteNudge = 0.5
    /// How many topics we surface to the generator on each side.
    private static let leanCount = 4
    private static let avoidCount = 4
    /// A topic must clear this magnitude to be considered a real signal.
    private static let signalFloor = 0.5

    private static func normalize(_ topic: String) -> String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Updates

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

    private mutating func bump(_ topic: String, by delta: Double) {
        let key = Self.normalize(topic)
        guard !key.isEmpty else { return }
        topicWeights[key, default: 0] += delta
        if topicWeights[key] == 0 { topicWeights.removeValue(forKey: key) }
    }

    // MARK: - Signals for the generator

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
