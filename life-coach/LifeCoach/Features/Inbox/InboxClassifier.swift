import Foundation

/// Batched triage classifier + summarizer for the Inbox, plus the one-line
/// "Brief" generator. `classify` sends the whole fetched batch (sender, subject,
/// snippet, truncated body, addressing signals) in ONE prompt and requires a
/// strict JSON array back, then maps the verdicts onto the original
/// `EmailMessage`s by id and derives each lane from its fine category. `brief`
/// makes one small follow-up call summarizing what needs attention into a single
/// warm chief-of-staff line. The active provider/model is resolved from persisted
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
    /// On any whole-batch failure the caller gets a best-effort all-noise result
    /// instead of an exception, so the Inbox always renders something.
    ///
    /// `preferencesHint` is the user's standing-preference summary (M4); it's woven
    /// into the prompt so the model leans the user's way, while the store still
    /// enforces the HARD overrides deterministically after this returns.
    func classify(_ emails: [EmailMessage], preferencesHint: String = "") async -> [ClassifiedEmail] {
        guard !emails.isEmpty else { return [] }

        let provider = currentProvider
        guard provider.hasKey() else {
            return emails.map(Self.fallback)
        }

        let userText = Self.buildUserPayload(emails, preferencesHint: preferencesHint)
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
        // ids fall back to noise rather than dropping the email.
        return emails.map { email in
            guard let verdict = verdicts[email.id] else {
                return Self.fallback(email)
            }
            return verdict.classified(for: email)
        }
    }

    /// One small call that turns the triaged batch into a single warm
    /// chief-of-staff line (≤ ~40 words) over `totalUnread`. Feeds the model only
    /// the non-noise items plus counts. On no-key / empty / failure it returns a
    /// deterministic fallback line built from the counts so the header is never
    /// blank.
    func brief(for classified: [ClassifiedEmail], totalUnread: Int) async -> String {
        let nonNoise = classified.filter { $0.lane != .noise }
        let needsYou = classified.filter { $0.lane == .needsYou }.count
        let waiting = classified.filter { $0.lane == .waiting }.count
        // Everything we didn't surface as needing attention is "handled".
        let handled = max(0, totalUnread - nonNoise.count)
        let fallback = Self.fallbackBrief(needsYou: needsYou,
                                          waiting: waiting,
                                          handled: handled,
                                          totalUnread: totalUnread)

        let provider = currentProvider
        guard provider.hasKey(), !nonNoise.isEmpty else { return fallback }

        let payload = Self.buildBriefPayload(nonNoise: nonNoise,
                                             totalUnread: totalUnread,
                                             handled: handled)
        do {
            let line = try await provider.complete(systemPrompt: Self.briefSystemPrompt,
                                                   userText: payload,
                                                   model: store.state.ai.activeModel)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        } catch {
            return fallback
        }
    }

    // MARK: - Fallback

    /// A safe noise default used when a verdict is missing or the batch fails to
    /// parse.
    private static func fallback(_ email: EmailMessage) -> ClassifiedEmail {
        ClassifiedEmail(email: email,
                        lane: .noise,
                        category: nil,
                        confidence: 0,
                        waitingOnYou: false,
                        reason: "",
                        summary: "")
    }

    /// Deterministic "N need you · M waiting · K can wait" line for when the brief
    /// model is unavailable.
    private static func fallbackBrief(needsYou: Int, waiting: Int, handled: Int, totalUnread: Int) -> String {
        var parts: [String] = []
        if needsYou > 0 { parts.append("\(needsYou) need you") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        let canWait = max(0, totalUnread - needsYou - waiting)
        if canWait > 0 { parts.append("\(canWait) can wait") }
        if parts.isEmpty {
            return totalUnread == 0 ? "Inbox zero — nothing unread." : "\(totalUnread) unread, nothing urgent."
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - User payload

    /// One compact, numbered block per email so the model has the signal it needs
    /// (sender identity, recipients, bulk-mail flag, subject, snippet, truncated
    /// body) without the full bodies blowing up the context.
    private static func buildUserPayload(_ emails: [EmailMessage], preferencesHint: String = "") -> String {
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
            to: \(email.toRecipients)
            bulk: \(email.hasUnsubscribe ? "yes (has List-Unsubscribe)" : "no")
            date: \(formatter.string(from: email.date))
            subject: \(email.subject)
            snippet: \(email.snippet)
            body: \(truncated)
            """
        }.joined(separator: "\n")

        // Lean the model toward the user's standing preferences. The store still
        // enforces these as hard overrides afterward; this just improves first-pass fit.
        let prefsBlock = preferencesHint.isEmpty ? "" : "\n\(preferencesHint)\n"

        return """
        Triage and summarize the following \(emails.count) emails. Return ONLY the \
        JSON array described in your instructions - one object per email, in the \
        same order, each keyed by its exact id.
        \(prefsBlock)
        \(blocks)
        """
    }

    /// Compact payload for the brief: just the items that need attention plus the
    /// surrounding counts.
    private static func buildBriefPayload(nonNoise: [ClassifiedEmail], totalUnread: Int, handled: Int) -> String {
        let lines = nonNoise
            .sorted { $0.lane.sortPriority < $1.lane.sortPriority }
            .map { item -> String in
                let firstLine = item.summary
                    .split(separator: "\n", maxSplits: 1)
                    .first.map(String.init) ?? item.summary
                let label = item.category?.label ?? item.lane.title
                let waiting = item.waitingOnYou ? " (awaiting your reply)" : ""
                return "- \(item.email.senderName) — \(label) [\(item.lane.title)]\(waiting): \(firstLine)"
            }
            .joined(separator: "\n")

        return """
        Total unread: \(totalUnread)
        Need attention (\(nonNoise.count)):
        \(lines)
        Routine / handled: \(handled)
        """
    }

    // MARK: - System prompt (triage taxonomy)

    static let systemPrompt = """
    You are the user's chief-of-staff triaging their email inbox. For EACH email, assign:
    - "category": the single best fine-grained category from the list below, or null if nothing fits and it is unimportant.
    - "confidence": a number 0.0–1.0, how sure you are of the category.
    - "waitingOnYou": true ONLY when a real person is awaiting THIS user's reply — a direct question or request addressed to them, last message inbound. Automated, bulk, or marketing mail is ALWAYS false.
    - "reason" and "summary" (see rules below).

    CATEGORIES — use the EXACT string. Each belongs to a lane.

    NEEDS YOU (the user must personally act):
    - "failedPayment" — a payment failed / card was declined and needs fixing.
    - "duePayment" — a bill or invoice is due or overdue and needs paying.
    - "kyc" — identity / document verification required to keep an account working.
    - "deadline" — a concrete deadline or expiring action the user must meet.
    - "accountIssue" — an account is limited/suspended and must be resolved.
    - "rsvp" — an invitation or request needing the user's yes/no.

    WAITING ON YOU (a real person awaits your reply):
    - "replyRequested" — someone explicitly asked the user to reply / get back to them.
    - "questionPending" — a real person asked the user a question that is still unanswered.

    PEOPLE (written by a real human, not bulk or automated):
    - "personal" — a friend / family / personal contact.
    - "work" — a colleague or client about work.
    - "recruiter" — a recruiter or hiring contact.
    - "coldOutreach" — a real person reaching out cold (sales / networking).

    MONEY (actual money or financial records, no personal action needed):
    - "charge" — a charge / debit / transaction notice.
    - "statement" — a statement is ready.
    - "receipt" — a receipt or routine payment confirmation.
    - "refund" — a refund was issued.
    - "invoice" — an invoice provided for information.
    - "renewal" — an upcoming subscription renewal / autopay reminder.
    - "fraud" — a suspected-fraud or unusual-charge alert.

    SECURITY (account security signals):
    - "loginAlert" — a new or unusual sign-in notice.
    - "passwordChange" — a password was changed or reset.
    - "suspiciousAccess" — suspicious / unrecognized access detected.
    - "twoFactor" — a 2FA / verification code or prompt.

    CALENDAR & TRAVEL:
    - "calendarInvite" — a meeting or event invite.
    - "reschedule" — a meeting or event time changed.
    - "itinerary" — a flight / hotel / travel itinerary.
    - "booking" — a reservation or booking confirmation.

    ORDERS:
    - "shipping" — a shipping / delivery / tracking update.
    - "orderConfirm" — an order confirmation.
    - "returnUpdate" — a return / exchange update.

    NOISE (everything that can wait — use null OR one of these):
    - "newsletter" — newsletters.
    - "promotion" — promotions, sales, deals, discounts.
    - "socialNotification" — social / app notifications, profile views, "you appeared in N searches".
    - "productUpdate" — product announcements / feature updates.
    - "digest" — automated digests / roundups.

    RULES:
    - Marketing ABOUT money (offers, "save $X", deals) is "promotion", NOT money.
    - A statement merely being "ready", or a routine receipt, is "statement" / "receipt" — never "needs you".
    - Bulk mail (the block shows bulk: yes, or it has an unsubscribe link) is almost never needsYou / waiting / people — prefer a noise, money, or orders category.
    - Pick exactly ONE category. If nothing genuinely fits and it is unimportant, use null.

    SUMMARY rules:
    - If the chosen category's lane is NOT noise: write a 2–3 line summary of what it is and what to know or do.
    - If it is noise (or null): write exactly ONE line.
    - Plain text, no markdown, written for a busy person glancing at their phone.

    REASON rules:
    - Non-noise: one short line stating the concrete fact that makes it matter.
    - Noise / null: reason must be an empty string "".

    Return ONLY a JSON array, no prose, no markdown code fences. One object per email, in the same order you received them. Each object has exactly these keys:
    [
      {
        "id": "<the email's exact id>",
        "category": "<one of the category strings above> | null",
        "confidence": 0.0,
        "waitingOnYou": true | false,
        "reason": "<one line if non-noise, else \\"\\">",
        "summary": "<2–3 lines if non-noise, 1 line if noise>"
      }
    ]
    """

    /// System prompt for the single-line brief.
    static let briefSystemPrompt = """
    You are the user's warm, sharp chief-of-staff. Given the emails that need attention and the surrounding counts, write ONE natural sentence (no more than ~40 words; no markdown, no lists, no line breaks) that tells the user what actually needs them right now and reassures them the rest is handled. Name the few most important senders or items concretely, and mention how many others are handled. Example: "3 things need you today: a failed Netflix payment, a Wise identity check, and Priya's waited 2 days on a dinner RSVP. 41 others are handled." Return only the sentence.
    """

    // MARK: - Parsing

    /// One parsed verdict from the model, independent of the email it maps to.
    private struct Verdict {
        let category: EmailCategory?
        let confidence: Double
        let waitingOnYou: Bool
        let reason: String
        let summary: String

        func classified(for email: EmailMessage) -> ClassifiedEmail {
            let lane = category?.lane ?? .noise
            let important = lane != .noise
            return ClassifiedEmail(
                email: email,
                lane: lane,
                category: category,
                confidence: min(max(confidence, 0), 1),
                // A waiting flag only makes sense on non-noise mail.
                waitingOnYou: important && waitingOnYou,
                reason: important ? reason : "",
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
            let category = matchCategory(object["category"] as? String)
            let confidence = (object["confidence"] as? Double) ?? 0
            let waiting = (object["waitingOnYou"] as? Bool) ?? false
            let reason = (object["reason"] as? String) ?? ""
            let summary = (object["summary"] as? String) ?? ""
            result[id] = Verdict(category: category,
                                 confidence: confidence,
                                 waitingOnYou: waiting,
                                 reason: reason,
                                 summary: summary)
        }
        return result
    }

    /// Tolerant category lookup: exact rawValue first, then a case-insensitive
    /// match; null / unknown / empty all decode to nil (→ noise).
    private static func matchCategory(_ raw: String?) -> EmailCategory? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.lowercased() != "null" else { return nil }
        if let exact = EmailCategory(rawValue: raw) { return exact }
        return EmailCategory.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
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
