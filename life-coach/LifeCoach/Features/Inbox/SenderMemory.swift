import Foundation

/// Per-sender behavioural stats, keyed by lowercased `senderEmail`. The Inbox feeds
/// it from the central action path — every time mail is seen, opened, archived,
/// marked read, or unsubscribed from — and derives two soft dispositions from the
/// counts:
///
///   - `isNoiseLeaning` — the user has dismissed this sender several times WITHOUT
///     ever opening one (archived or marked-read-without-open ≥ 3, opened == 0). A
///     strong "this is noise" signal that drives the rule SUGGESTIONS and, only once
///     it is high-confidence, the auto-file sweep.
///   - `isVipLeaning` — the user keeps opening this sender (opened ≥ 3). Gently lifts
///     their mail within its lane.
///
/// Both are NUDGES, not overrides: they reorder inside a lane and propose rules, but
/// never reclassify on their own. Tolerant Codable so a missing / older
/// `inbox-senders.json` loads as empty.
struct SenderMemory: Codable {
    /// lowercased sender email -> its rolling stats.
    private(set) var senders: [String: SenderStat]

    init(senders: [String: SenderStat] = [:]) { self.senders = senders }

    enum CodingKeys: String, CodingKey { case senders }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        senders = try c.decodeIfPresent([String: SenderStat].self, forKey: .senders) ?? [:]
    }

    // MARK: - Tuning constants

    /// Dismissals (archives or marks-read), with zero opens, needed before a sender
    /// is treated as noise-leaning.
    static let noiseThreshold = 3
    /// Opens needed before a sender is treated as VIP-leaning.
    static let vipThreshold = 3

    private static func key(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Updates

    /// Increment any subset of a sender's counters in one call. No-op for an empty
    /// email so we never accumulate a junk "" bucket.
    mutating func record(_ email: String,
                         seen: Int = 0,
                         opened: Int = 0,
                         archived: Int = 0,
                         unsubscribed: Int = 0,
                         markedRead: Int = 0) {
        let k = Self.key(email)
        guard !k.isEmpty else { return }
        var stat = senders[k] ?? SenderStat()
        stat.seen += seen
        stat.opened += opened
        stat.archived += archived
        stat.unsubscribed += unsubscribed
        stat.markedRead += markedRead
        senders[k] = stat
    }

    // MARK: - Lookups / dispositions

    /// The stats for `email`, or nil if the sender is unseen.
    func stat(for email: String) -> SenderStat? { senders[Self.key(email)] }

    /// True when the user has repeatedly dismissed this sender unread — archived or
    /// marked-read at least `noiseThreshold` times and never opened one.
    func isNoiseLeaning(_ email: String) -> Bool {
        guard let stat = stat(for: email) else { return false }
        return stat.opened == 0
            && (stat.archived >= Self.noiseThreshold || stat.markedRead >= Self.noiseThreshold)
    }

    /// True when the user keeps opening this sender (opened ≥ `vipThreshold`).
    func isVipLeaning(_ email: String) -> Bool {
        guard let stat = stat(for: email) else { return false }
        return stat.opened >= Self.vipThreshold
    }

    /// How many times the user dismissed this sender unread (archived + marked-read),
    /// or 0 if they've ever opened one. Drives the suggestion copy ("you've binned
    /// the last N from X untouched").
    func dismissCount(for email: String) -> Int {
        guard let stat = stat(for: email), stat.opened == 0 else { return 0 }
        return stat.archived + stat.markedRead
    }
}

/// One sender's rolling counters. Tolerant Codable so adding a counter later won't
/// invalidate an existing `inbox-senders.json`.
struct SenderStat: Codable, Hashable {
    var seen: Int
    var opened: Int
    var archived: Int
    var unsubscribed: Int
    var markedRead: Int

    init(seen: Int = 0,
         opened: Int = 0,
         archived: Int = 0,
         unsubscribed: Int = 0,
         markedRead: Int = 0) {
        self.seen = seen
        self.opened = opened
        self.archived = archived
        self.unsubscribed = unsubscribed
        self.markedRead = markedRead
    }

    enum CodingKeys: String, CodingKey { case seen, opened, archived, unsubscribed, markedRead }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seen = try c.decodeIfPresent(Int.self, forKey: .seen) ?? 0
        opened = try c.decodeIfPresent(Int.self, forKey: .opened) ?? 0
        archived = try c.decodeIfPresent(Int.self, forKey: .archived) ?? 0
        unsubscribed = try c.decodeIfPresent(Int.self, forKey: .unsubscribed) ?? 0
        markedRead = try c.decodeIfPresent(Int.self, forKey: .markedRead) ?? 0
    }
}
