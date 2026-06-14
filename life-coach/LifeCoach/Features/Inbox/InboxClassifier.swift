import Foundation

/// Batched importance classifier + summarizer for the Inbox. Sends the whole
/// fetched batch (sender, subject, snippet, truncated body) in ONE prompt and
/// requires a strict JSON array back, then maps the verdicts onto the original
/// `EmailMessage`s by id. The active provider/model is resolved from persisted
/// AI settings, mirroring `CoachEngine.currentProvider`.
@MainActor
final class InboxClassifier {
    private let store: AppStore
    private let anthropic = AnthropicProvider()
    private let ollama = OllamaProvider()

    init(store: AppStore) {
        self.store = store
    }

    /// The active backend, resolved from persisted settings - same rule as the coach.
    private var currentProvider: ChatProvider {
        store.state.ai.provider == .ollama ? ollama : anthropic
    }

    /// How much of each body the model sees. The full body stays on the message.
    private static let bodyTruncation = 600

    /// Classify + summarize the batch in as few LLM calls as possible (one).
    /// On any whole-batch failure the caller gets a best-effort all-non-important
    /// result instead of an exception, so the Inbox always renders something.
    func classify(_ emails: [EmailMessage]) async -> [ClassifiedEmail] {
        guard !emails.isEmpty else { return [] }

        let provider = currentProvider
        guard provider.hasKey() else {
            return emails.map(Self.fallback)
        }

        let userText = Self.buildUserPayload(emails)
        let model = store.state.ai.activeModel

        let raw: String
        do {
            raw = try await provider.complete(systemPrompt: Self.systemPrompt,
                                              userText: userText,
                                              model: model)
        } catch {
            // Whole batch failed (network/auth/etc.) - degrade gracefully.
            return emails.map(Self.fallback)
        }

        let verdicts = Self.parseVerdicts(raw)
        guard !verdicts.isEmpty else {
            return emails.map(Self.fallback)
        }

        // Map verdicts back onto the original emails by id. Missing/unparseable
        // ids fall back to non-important rather than dropping the email.
        return emails.map { email in
            guard let verdict = verdicts[email.id] else {
                return Self.fallback(email)
            }
            return verdict.classified(for: email)
        }
    }

    // MARK: - Fallback

    /// A safe non-important default used when a verdict is missing or the batch
    /// fails to parse.
    private static func fallback(_ email: EmailMessage) -> ClassifiedEmail {
        ClassifiedEmail(email: email, important: false, category: nil, reason: "", summary: "")
    }

    // MARK: - User payload

    /// One compact, numbered block per email so the model has the signal it
    /// needs (sender identity, subject, snippet, truncated body) without the
    /// full bodies blowing up the context.
    private static func buildUserPayload(_ emails: [EmailMessage]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d, h:mm a"

        let blocks = emails.map { email -> String in
            let truncated = email.body.count > bodyTruncation
                ? String(email.body.prefix(bodyTruncation)) + "…"
                : email.body
            return """
            ---
            id: \(email.id)
            from: \(email.senderName) <\(email.senderEmail)>
            date: \(formatter.string(from: email.date))
            subject: \(email.subject)
            snippet: \(email.snippet)
            body: \(truncated)
            """
        }.joined(separator: "\n")

        return """
        Classify and summarize the following \(emails.count) emails. Return ONLY \
        the JSON array described in your instructions - one object per email, in \
        the same order, each keyed by its exact id.

        \(blocks)
        """
    }

    // MARK: - System prompt (importance rules verbatim from spec)

    static let systemPrompt = """
    You triage a user's email inbox. For each email you decide whether it is IMPORTANT and write a short summary.

    An email is IMPORTANT only if it matches one of these FOUR rules. Use the matching rule's name as the category.

    - "action" — the user must DO something: confirm a refund, a failed or due payment, a deadline, a KYC / identity verification request, an account issue that needs resolving. Routine statements and receipts do NOT count.
    - "human" — the email was written personally by a real person, not automated, marketing, or transactional. A real human typing to this specific user.
    - "money" — actual money moved: a charge, a debit, a transaction. Upcoming autopay reminders count. Marketing ABOUT money (offers, deals, "save $X") does NOT count.
    - "security" — a login alert, a password change, or suspicious-activity / unrecognized-access notice.

    NEVER important — if it is one of these, mark it not important with category null:
    - promotions, sales, discounts, deals
    - newsletters and digests
    - statements (a statement being "ready" is routine, even with a balance)
    - receipts and routine payment confirmations
    - routine notifications (social updates, "you appeared in N searches", profile views, app notifications)

    If an email genuinely matches more than one rule, pick the single most relevant category.

    SUMMARY rules:
    - If the email IS important: write a 2–3 line summary capturing what it is and what the user should know or do.
    - If the email is NOT important: write a 1 line summary.
    - The summary is plain text, no markdown, written for a busy person glancing at their phone.

    REASON rules:
    - If important: write a single short line stating why it is important (which rule it hit and the concrete fact).
    - If not important: reason must be an empty string "".

    Return ONLY a JSON array, no prose, no markdown code fences. One object per email, in the same order you received them. Each object has exactly these keys:
    [
      {
        "id": "<the email's exact id>",
        "important": true | false,
        "category": "action" | "human" | "money" | "security" | null,
        "reason": "<one line if important, else \\"\\">",
        "summary": "<2–3 lines if important, 1 line if not>"
      }
    ]

    "category" must be null whenever "important" is false, and one of the four strings whenever "important" is true.
    """

    // MARK: - Parsing

    /// One parsed verdict from the model, independent of the email it maps to.
    private struct Verdict {
        let important: Bool
        let category: EmailCategory?
        let reason: String
        let summary: String

        func classified(for email: EmailMessage) -> ClassifiedEmail {
            // Defensive: only honor a category when the model said important.
            let effectiveCategory = important ? category : nil
            let effectiveImportant = important && effectiveCategory != nil
            return ClassifiedEmail(
                email: email,
                important: effectiveImportant,
                category: effectiveCategory,
                reason: effectiveImportant ? reason : "",
                summary: summary
            )
        }
    }

    /// Robustly parse the model's reply: strip code fences, tolerate leading or
    /// trailing prose, and extract the first top-level JSON array. Returns a map
    /// from email id -> verdict.
    private static func parseVerdicts(_ raw: String) -> [String: Verdict] {
        guard let json = extractJSONArray(raw),
              let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var result: [String: Verdict] = [:]
        for object in array {
            guard let id = object["id"] as? String, !id.isEmpty else { continue }
            let important = (object["important"] as? Bool) ?? false
            let categoryRaw = object["category"] as? String
            let category = categoryRaw.flatMap { EmailCategory(rawValue: $0.lowercased()) }
            let reason = (object["reason"] as? String) ?? ""
            let summary = (object["summary"] as? String) ?? ""
            result[id] = Verdict(important: important,
                                 category: category,
                                 reason: reason,
                                 summary: summary)
        }
        return result
    }

    /// Pull the first balanced top-level `[ ... ]` out of arbitrary model text,
    /// after stripping any ```json fences.
    private static func extractJSONArray(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip code fences if present.
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fenceRange = text.range(of: "```", options: .backwards) {
                text = String(text[..<fenceRange.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Find the first balanced top-level array.
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
