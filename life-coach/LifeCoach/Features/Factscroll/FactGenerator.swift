import Foundation

/// Generates a BATCH of interesting facts in a single LLM call via the active
/// provider's `complete(...)` primitive. The active provider/model is resolved
/// from persisted AI settings, mirroring `CoachEngine.currentProvider` /
/// `InboxClassifier`.
///
/// The prompt takes two inputs that fight the two failure modes of a fact feed:
///   - the **dedup ledger**: recent fact signatures/claims the model must NOT
///     repeat or rephrase (the #1 failure — same fact in different words);
///   - **taste signals**: topics to lean toward (liked) and avoid (disliked),
///     plus recent freeform notes.
///
/// Output is strict JSON: `[{ "fact": "...", "topic": "..." }]`, parsed
/// robustly (fences stripped, leading/trailing prose tolerated).
@MainActor
final class FactGenerator {
    private let store: AppStore
    private let anthropic = AnthropicProvider()
    private let ollama = OllamaProvider()

    init(store: AppStore) {
        self.store = store
    }

    /// The active backend, resolved from persisted settings — same rule as the coach.
    private var currentProvider: ChatProvider {
        store.state.ai.provider == .ollama ? ollama : anthropic
    }

    /// A raw fact the model returned, before dedup/signature processing.
    struct RawFact {
        let text: String
        let topic: String
    }

    /// Generate up to `count` raw facts. Returns `[]` on any failure (no key,
    /// network/auth error, unparseable reply) so callers degrade gracefully.
    ///
    /// - Parameters:
    ///   - count: how many facts to ask for (frontload uses 5, top-ups use 3).
    ///   - recentSignatures: the dedup ledger — recent fact signatures the model
    ///     must not repeat or rephrase.
    ///   - leanTopics: topics to lean toward (from `TasteEngine.leanTopics()`).
    ///   - avoidTopics: topics to avoid (from `TasteEngine.avoidTopics()`).
    ///   - noteHints: recent freeform user notes for extra taste colour.
    func generate(count: Int,
                  recentSignatures: [String],
                  leanTopics: [String],
                  avoidTopics: [String],
                  noteHints: [String]) async -> [RawFact] {
        let provider = currentProvider
        guard provider.hasKey() else { return [] }

        let userText = Self.buildUserPayload(count: count,
                                             recentSignatures: recentSignatures,
                                             leanTopics: leanTopics,
                                             avoidTopics: avoidTopics,
                                             noteHints: noteHints)
        let model = store.state.ai.activeModel

        let raw: String
        do {
            raw = try await provider.complete(systemPrompt: Self.systemPrompt,
                                              userText: userText,
                                              model: model)
        } catch {
            return []
        }

        return Self.parseFacts(raw)
    }

    // MARK: - System prompt (verbatim)

    static let systemPrompt = """
    You generate short, genuinely interesting facts for a fast vertical "did you know" feed (think reels, but facts).

    Your ONE job is to be reliably surprising AND reliably accurate. Every fact must be:
    - TRUE. State only well-established facts you are confident are correct. If you are not sure a claim is accurate, do not use it. Never invent statistics, dates, or attributions.
    - SURPRISING. The reaction should be "wait, really?" — counterintuitive, little-known, or a striking number. Avoid tired clichés everyone has already heard a hundred times.
    - SELF-CONTAINED. One or two sentences, readable in a few seconds on a phone, no preamble like "Did you know" and no citations.
    - DISTINCT from every other fact in your batch — different claim, different domain, not five variations on one theme.

    Each fact gets a TOPIC: a single lowercase word or very short tag naming its domain (e.g. "space", "biology", "history", "ocean", "language", "human body", "physics"). Keep topic tags consistent and reusable so the feed can learn the user's taste.

    DO NOT REPEAT OR REPHRASE. You will be given a list of facts the user has already seen. You must not produce any fact that states the same underlying claim as one of those — not even reworded, reordered, or with a different number framing. A disguised duplicate is the single worst thing you can return. When in doubt, pick a different claim entirely.

    TASTE. You may be given topics the user leans toward and topics they dislike. Favour the liked topics and adjacent ones; avoid the disliked ones. If no taste signals are given, range widely across domains for variety.

    Return ONLY a JSON array, no prose, no markdown code fences. Exactly the requested number of objects, each with exactly these two keys:
    [
      { "fact": "<one or two sentence surprising, true fact>", "topic": "<short lowercase tag>" }
    ]
    """

    // MARK: - User payload

    /// Builds the per-request payload: how many facts, the dedup ledger, and the
    /// taste signals. Each section is omitted cleanly when empty so a cold-start
    /// request stays short and unbiased.
    static func buildUserPayload(count: Int,
                                 recentSignatures: [String],
                                 leanTopics: [String],
                                 avoidTopics: [String],
                                 noteHints: [String]) -> String {
        var sections: [String] = []

        sections.append("Generate exactly \(count) facts as the JSON array described in your instructions.")

        // Dedup ledger — the recent fact signatures/claims the model must avoid.
        if !recentSignatures.isEmpty {
            let ledger = recentSignatures
                .prefix(ledgerLimit)
                .map { "- \($0)" }
                .joined(separator: "\n")
            sections.append("""
            ALREADY SEEN — do NOT repeat or rephrase any of these claims (these are normalized keyword signatures of facts the user has already been shown):
            \(ledger)
            """)
        }

        // Taste signals.
        if !leanTopics.isEmpty {
            sections.append("LEAN TOWARD these topics the user likes (and closely related ones): \(leanTopics.joined(separator: ", ")).")
        }
        if !avoidTopics.isEmpty {
            sections.append("AVOID these topics the user dislikes: \(avoidTopics.joined(separator: ", ")).")
        }
        if !noteHints.isEmpty {
            let notes = noteHints.map { "- \"\($0)\"" }.joined(separator: "\n")
            sections.append("""
            The user left these notes on facts they reacted to — use them as soft taste hints:
            \(notes)
            """)
        }

        if leanTopics.isEmpty && avoidTopics.isEmpty && noteHints.isEmpty {
            sections.append("No taste signals yet — range widely across domains for variety.")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Cap on how many ledger signatures we send so the prompt stays bounded.
    private static let ledgerLimit = 60

    // MARK: - Parsing

    /// Parse the model's reply into raw facts. Strips code fences, tolerates
    /// leading/trailing prose, extracts the first balanced top-level array, and
    /// drops any object missing a non-empty `fact`.
    static func parseFacts(_ raw: String) -> [RawFact] {
        guard let json = extractJSONArray(raw),
              let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { object in
            guard let text = (object["fact"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let topic = ((object["topic"] as? String) ?? "general")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return RawFact(text: text, topic: topic.isEmpty ? "general" : topic)
        }
    }

    /// Pull the first balanced top-level `[ ... ]` out of arbitrary model text,
    /// after stripping any ```json fences. (Same robust scanner the Inbox uses.)
    static func extractJSONArray(_ raw: String) -> String? {
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
