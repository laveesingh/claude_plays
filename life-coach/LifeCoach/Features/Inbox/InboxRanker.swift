import Foundation

/// The post-classifier pass that folds the user's PREFERENCES and LEARNED behaviour
/// into the triaged set. It has two strictly separated layers, in line with the
/// product rule "explicit prefs win, learning only nudges":
///
///   1. **HARD overrides (`override`).** The user's explicit preferences win over the
///      LLM's lane. Applied lowest-priority-first so the strongest pref is applied
///      last and therefore wins on conflict:
///        elevate → suppress → keyword rule → mute → VIP.
///      So a VIP sender is ALWAYS surfaced (never noise), a muted sender is always
///      noise unless they're also VIP, etc. These genuinely re-file the email.
///
///   2. **SOFT nudge (`nudge`).** A small per-email score blended into the
///      within-lane ordering only — it NEVER changes a lane, so it can't move a
///      security / money / needsYou item into noise. It combines the on-device
///      `ImportanceEngine` cosine with the sender's learned disposition so mail that
///      looks like what the user engages with rises and mail that looks binned sinks.
///
/// All methods are pure (no I/O, no state) so the store can call them freely and the
/// behaviour is trivial to reason about.
enum InboxRanker {
    // MARK: - Hard overrides

    /// Apply the user's explicit preferences to one classified email, returning the
    /// (possibly re-filed) result. Pure; safe to map over the whole set.
    static func override(_ item: ClassifiedEmail, preferences: InboxPreferences) -> ClassifiedEmail {
        var result = item
        let senderHay = senderHaystack(item.email)
        let contentHay = contentHaystack(item)

        // 1. elevate (weakest): lift an elevated category out of noise so it surfaces.
        if let category = item.category,
           preferences.elevatedCategories.contains(where: { $0.caseInsensitiveCompare(category.rawValue) == .orderedSame }),
           result.lane == .noise {
            result = result.withLane(category.lane == .noise ? .people : category.lane)
        }

        // 2. suppress: push a suppressed category down to noise.
        if let category = item.category,
           preferences.suppressedCategories.contains(where: { $0.caseInsensitiveCompare(category.rawValue) == .orderedSame }) {
            result = result.withLane(.noise)
        }

        // 3. keyword rules: force a lane (or flag → Needs you) when a rule matches the
        //    sender or content. Later rules win if several match.
        for rule in preferences.keywordRules {
            let key = rule.normalizedKeyword
            guard !key.isEmpty, senderHay.contains(key) || contentHay.contains(key) else { continue }
            result = result.withLane(rule.lane ?? .needsYou)
        }

        // 4. mute: a muted sender is always noise…
        if matchesAny(senderHay, preferences.mutedSenders) {
            result = result.withLane(.noise)
        }

        // 5. VIP (strongest): …unless they're VIP, who are never noise. Lift to the
        //    category's natural lane, or People when there is none.
        if matchesAny(senderHay, preferences.vipSenders), result.lane == .noise {
            result = result.withLane(item.category?.lane.nonNoise ?? .people)
        }

        return result
    }

    // MARK: - Soft nudge

    /// A small ordering bias in roughly [-1.5, 1.5] for one email. Positive lifts it
    /// within its lane, negative sinks it. `vector` is the email's embedding (nil when
    /// unavailable — then only the sender disposition contributes).
    static func nudge(for item: ClassifiedEmail,
                      vector: [Double]?,
                      importance: ImportanceEngine,
                      senders: SenderMemory) -> Double {
        var score = 0.0
        if let vector, let importanceScore = importance.importanceScore(for: vector) {
            score += importanceScore
        }
        let email = item.email.senderEmail
        if senders.isVipLeaning(email) { score += 0.5 }
        if senders.isNoiseLeaning(email) { score -= 0.5 }
        return max(-1.5, min(1.5, score))
    }

    // MARK: - Matching helpers

    /// True when any of `patterns` (trimmed, lowercased substrings) is contained in
    /// `haystack`. Empty patterns are ignored so a stray blank rule matches nothing.
    static func matchesAny(_ haystack: String, _ patterns: [String]) -> Bool {
        for pattern in patterns {
            let needle = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !needle.isEmpty, haystack.contains(needle) { return true }
        }
        return false
    }

    /// The lowercased sender identity (email + display name) that VIP / mute / keyword
    /// rules match against — so "linkedin", "noreply@x.com", or a person's name all work.
    static func senderHaystack(_ email: EmailMessage) -> String {
        "\(email.senderEmail) \(email.senderName)".lowercased()
    }

    /// The lowercased content a keyword rule can also match (subject + snippet +
    /// summary), so "invoice" or "urgent" rules catch the body, not just the sender.
    private static func contentHaystack(_ item: ClassifiedEmail) -> String {
        "\(item.email.subject) \(item.email.snippet) \(item.summary)".lowercased()
    }
}

private extension InboxLane {
    /// This lane unless it is noise, in which case nil — used to find a VIP email's
    /// natural non-noise home.
    var nonNoise: InboxLane? { self == .noise ? nil : self }
}
