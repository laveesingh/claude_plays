import Foundation

// MARK: - Tool contract

/// One declared parameter of an inbox tool. The kinds map cleanly to JSON types,
/// so the future agent (M3) can render them into a tool schema and the tap UI can
/// pass native Swift values for the same keys.
struct InboxToolParam {
    enum Kind: String { case string, bool, int, stringArray }
    let name: String
    let kind: Kind
    let required: Bool
    let description: String
}

/// The agent-facing description of a tool: a stable snake_case `name`, a one-line
/// `description`, and its `parameters`. `InboxCapabilities.specs` enumerates these
/// so M3 can drop them straight into a system prompt; the tap UI ignores them and
/// just calls `run`.
struct InboxToolSpec {
    let name: String
    let description: String
    let parameters: [InboxToolParam]
}

/// The result of running a tool — readable by both a human (the undo snackbar) and
/// the agent (M3).
///
/// - `undo` is nil for irreversible actions (e.g. unsubscribe), else an async
///   closure that reverses the action both locally and on Gmail.
/// - `openURL`, when set, is an external link the UI should OPEN because the action
///   couldn't complete fully in-app (an unsubscribe page or `mailto:`). The agent
///   ignores it.
struct InboxToolOutcome {
    let summary: String
    let affectedIDs: [String]
    let undo: (() async -> Void)?
    let openURL: URL?

    init(summary: String,
         affectedIDs: [String],
         undo: (() async -> Void)? = nil,
         openURL: URL? = nil) {
        self.summary = summary
        self.affectedIDs = affectedIDs
        self.undo = undo
        self.openURL = openURL
    }
}

/// Typed failures every tool can raise. `needsReconnect` is the recoverable
/// insufficient-scope case (Gmail 401/403) the UI turns into a "Reconnect Gmail"
/// prompt; the rest carry a user-readable message.
enum InboxToolError: LocalizedError {
    case needsReconnect
    case missingArgument(String)
    case notFound(String)
    case gmail(String)

    var errorDescription: String? {
        switch self {
        case .needsReconnect:
            return "Reconnect Gmail to enable actions."
        case .missingArgument(let name):
            return "Missing required argument: \(name)."
        case .notFound(let id):
            return "Couldn't find that message (\(id))."
        case .gmail(let message):
            return message
        }
    }
}

/// A single inbox capability. `spec` declares it; `run` performs it and returns an
/// outcome. The tap UI (M2) and the agent (M3) both invoke tools ONLY through
/// `InboxCapabilities.run` — never by touching Gmail directly. That uniformity is
/// what makes the M3 agent trivial: enumerate `specs`, emit `{name, args}`, call
/// `run`.
protocol InboxTool {
    var spec: InboxToolSpec { get }
    @MainActor func run(_ args: [String: Any]) async throws -> InboxToolOutcome
}

// MARK: - Registry

/// The one opinionated registry of inbox actions. Each tool performs its Gmail
/// call (optimistically updating the store's local state for an instant feel,
/// rolling back if the write fails), then returns an `InboxToolOutcome` with an
/// undo where the action is reversible.
@MainActor
final class InboxCapabilities {
    private var tools: [String: InboxTool] = [:]
    private var order: [String] = []

    /// `auth` is part of the contract (the M3 agent constructs the registry the
    /// same way) even though the write service already owns the token plumbing.
    init(store: InboxStore, gmail: GmailWriteService, auth: GoogleAuth) {
        // Read/query tools first so M3's prompt lists how to SEE before how to ACT.
        register(SearchEmailsTool(store: store))
        register(GetEmailTool(store: store))
        // Write tools.
        register(MarkReadTool(store: store, gmail: gmail))
        register(MarkUnreadTool(store: store, gmail: gmail))
        register(ArchiveTool(store: store, gmail: gmail))
        register(UnsubscribeTool(store: store, gmail: gmail))
        register(SnoozeTool(store: store))
        register(BulkApplyTool(capabilities: self))
        // Preference tools (M4): let the agent set standing rules from chat.
        register(SetPreferenceTool(store: store))
        register(AddKeywordRuleTool(store: store))
    }

    private func register(_ tool: InboxTool) {
        tools[tool.spec.name] = tool
        order.append(tool.spec.name)
    }

    /// Every tool's spec, in stable registration order — what M3 enumerates.
    var specs: [InboxToolSpec] { order.compactMap { tools[$0]?.spec } }

    /// Run the named tool. Throws `InboxToolError.notFound` for an unknown name.
    func run(_ name: String, args: [String: Any]) async throws -> InboxToolOutcome {
        guard let tool = tools[name] else { throw InboxToolError.notFound(name) }
        return try await tool.run(args)
    }
}

// MARK: - Read / query tools

/// Read-only search over the FULL triaged working set. Every argument is optional;
/// with none, it lists everything (newest, highest-priority first). The agent (M3)
/// calls this to SEE what's in the inbox before it acts, and to turn a vague ask
/// ("clear my promos") into the concrete ids it then feeds to a write tool. No
/// Gmail call, no mutation, no undo — the result is a compact list the agent reads
/// straight out of `InboxToolOutcome.summary`.
private struct SearchEmailsTool: InboxTool {
    let store: InboxStore

    /// At most this many matches are rendered, to keep the observation compact.
    private static let limit = 40

    var spec: InboxToolSpec {
        InboxToolSpec(
            name: "search_emails",
            description: "Search the inbox by lane, category, sender, free text, or unread/waiting flags. Returns matching message ids to act on. All arguments are optional — omit them to list everything.",
            parameters: [
                InboxToolParam(name: "lane", kind: .string, required: false,
                               description: "Restrict to one lane: needsYou, waiting, people, money, security, calendar, orders, noise."),
                InboxToolParam(name: "category", kind: .string, required: false,
                               description: "Restrict to one fine category, e.g. promotion, newsletter, receipt, replyRequested."),
                InboxToolParam(name: "sender", kind: .string, required: false,
                               description: "Case-insensitive substring matched against the sender's name or email."),
                InboxToolParam(name: "query", kind: .string, required: false,
                               description: "Case-insensitive substring matched against the subject, snippet, and summary."),
                InboxToolParam(name: "unread_only", kind: .bool, required: false,
                               description: "When true, only unread messages."),
                InboxToolParam(name: "waiting_only", kind: .bool, required: false,
                               description: "When true, only messages where a real person is awaiting your reply."),
            ])
    }

    func run(_ args: [String: Any]) async throws -> InboxToolOutcome {
        let lane = InboxQuery.lane(from: args.optionalString("lane"))
        let category = InboxQuery.category(from: args.optionalString("category"))
        let sender = args.optionalString("sender")?.lowercased()
        let query = args.optionalString("query")?.lowercased()
        let unreadOnly = args.optionalBool("unread_only") ?? false
        let waitingOnly = args.optionalBool("waiting_only") ?? false

        let matches = store.allClassified
            .filter { item in
                if let lane, item.lane != lane { return false }
                if let category, item.category != category { return false }
                if let sender,
                   !item.email.senderName.lowercased().contains(sender),
                   !item.email.senderEmail.lowercased().contains(sender) { return false }
                if let query {
                    let hay = "\(item.email.subject)\n\(item.email.snippet)\n\(item.summary)".lowercased()
                    if !hay.contains(query) { return false }
                }
                if unreadOnly && !item.email.isUnread { return false }
                if waitingOnly && !item.waitingOnYou { return false }
                return true
            }
            .sorted {
                if $0.lane.sortPriority != $1.lane.sortPriority {
                    return $0.lane.sortPriority < $1.lane.sortPriority
                }
                return $0.email.date > $1.email.date
            }

        let shown = Array(matches.prefix(Self.limit))
        var header = "\(matches.count) match\(matches.count == 1 ? "" : "es")"
        if matches.count > shown.count { header += " (showing first \(shown.count))" }
        let lines = shown.map { item -> String in
            let cat = item.category?.rawValue ?? "—"
            let unread = item.email.isUnread ? "unread" : "read"
            return "\(item.id) · \(item.email.senderName) · [\(item.lane.rawValue)/\(cat)] · \(unread) · \(item.email.subject) — \(InboxQuery.oneLine(item))"
        }
        let summary = ([header] + lines).joined(separator: "\n")
        return InboxToolOutcome(summary: summary, affectedIDs: shown.map { $0.id })
    }
}

/// Read-only fetch of one message's full detail — sender, subject, date,
/// lane/category, the AI summary, and the body (truncated) — so the agent can
/// answer "what does X actually say" without guessing. No mutation, no undo.
private struct GetEmailTool: InboxTool {
    let store: InboxStore

    /// How much of the body the agent sees; the full body stays on the message.
    private static let bodyTruncation = 1500

    var spec: InboxToolSpec {
        InboxToolSpec(
            name: "get_email",
            description: "Fetch one message's full detail (sender, subject, date, lane/category, summary, and body) so you can answer questions about its contents.",
            parameters: [
                InboxToolParam(name: "message_id", kind: .string, required: true,
                               description: "The id of the message to read in full."),
            ])
    }

    func run(_ args: [String: Any]) async throws -> InboxToolOutcome {
        let id = try args.requireString("message_id")
        guard let item = store.email(for: id) else { throw InboxToolError.notFound(id) }
        let email = item.email
        let cat = item.category?.rawValue ?? "—"
        let body = email.body.count > Self.bodyTruncation
            ? String(email.body.prefix(Self.bodyTruncation)) + "…"
            : email.body
        let summary = """
        id: \(email.id)
        from: \(email.senderName) <\(email.senderEmail)>
        date: \(InboxQuery.date(email.date))
        lane/category: \(item.lane.rawValue)/\(cat)
        waiting_on_you: \(item.waitingOnYou ? "yes" : "no")
        subject: \(email.subject)
        summary: \(item.summary.isEmpty ? "—" : item.summary)
        body: \(body.isEmpty ? "(empty)" : body)
        """
        return InboxToolOutcome(summary: summary, affectedIDs: [id])
    }
}

/// Shared, tolerant parsing/formatting for the read tools — kept in one place so
/// `search_emails` and `get_email` agree on lane/category coercion and one-line
/// rendering.
private enum InboxQuery {
    /// Lane from a rawValue, tolerant of case; nil when unknown/empty.
    static func lane(from raw: String?) -> InboxLane? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let exact = InboxLane(rawValue: raw) { return exact }
        return InboxLane.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
    }

    /// Category from a rawValue, tolerant of case; nil when unknown/empty.
    static func category(from raw: String?) -> EmailCategory? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let exact = EmailCategory(rawValue: raw) { return exact }
        return EmailCategory.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
    }

    /// The first line of the AI summary (or the snippet), clipped to a tidy length.
    static func oneLine(_ item: ClassifiedEmail) -> String {
        let source = item.summary.isEmpty ? item.email.snippet : item.summary
        let first = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? source
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 140 ? String(trimmed.prefix(140)) + "…" : trimmed
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, h:mm a"
        return f
    }()

    static func date(_ date: Date) -> String { dateFormatter.string(from: date) }
}

// MARK: - Tools

/// Mark one message as read (remove `UNREAD`). Optimistic: flips the local unread
/// state immediately and rolls back if Gmail rejects the write. Undo = mark unread.
private struct MarkReadTool: InboxTool {
    let store: InboxStore
    let gmail: GmailWriteService

    var spec: InboxToolSpec {
        InboxToolSpec(
            name: "mark_read",
            description: "Mark a single message as read.",
            parameters: [
                InboxToolParam(name: "message_id", kind: .string, required: true,
                               description: "The id of the message to mark read."),
            ])
    }

    func run(_ args: [String: Any]) async throws -> InboxToolOutcome {
        let id = try args.requireString("message_id")
        let sender = store.senderName(for: id)
        store.setUnread(false, id: id)                  // optimistic
        do {
            try await gmail.markRead(id: id)
        } catch {
            store.setUnread(true, id: id)               // rollback
            throw error
        }
        return InboxToolOutcome(
            summary: "Marked read" + (sender.map { " · \($0)" } ?? ""),
            affectedIDs: [id],
            undo: {
                await store.setUnread(true, id: id)
                try? await gmail.markUnread(id: id)
            })
    }
}

/// Mark one message as unread (add `UNREAD`). Undo = mark read.
private struct MarkUnreadTool: InboxTool {
    let store: InboxStore
    let gmail: GmailWriteService

    var spec: InboxToolSpec {
        InboxToolSpec(
            name: "mark_unread",
            description: "Mark a single message as unread.",
            parameters: [
                InboxToolParam(name: "message_id", kind: .string, required: true,
                               description: "The id of the message to mark unread."),
            ])
    }

    func run(_ args: [String: Any]) async throws -> InboxToolOutcome {
        let id = try args.requireString("message_id")
        let sender = store.senderName(for: id)
        store.setUnread(true, id: id)                   // optimistic
        do {
            try await gmail.markUnread(id: id)
        } catch {
            store.setUnread(false, id: id)              // rollback
            throw error
        }
        return InboxToolOutcome(
            summary: "Marked unread" + (sender.map { " · \($0)" } ?? ""),
            affectedIDs: [id],
            undo: {
                await store.setUnread(false, id: id)
                try? await gmail.markRead(id: id)
            })
    }
}

/// Archive one message (remove `INBOX`). Optimistically removes it from the list
/// and re-inserts it on failure. Undo = un-archive (re-add `INBOX`, re-insert).
private struct ArchiveTool: InboxTool {
    let store: InboxStore
    let gmail: GmailWriteService

    var spec: InboxToolSpec {
        InboxToolSpec(
            name: "archive",
            description: "Archive a single message (remove it from the inbox).",
            parameters: [
                InboxToolParam(name: "message_id", kind: .string, required: true,
                               description: "The id of the message to archive."),
            ])
    }

    func run(_ args: [String: Any]) async throws -> InboxToolOutcome {
        let id = try args.requireString("message_id")
        guard let removed = store.removeEmail(id: id) else { throw InboxToolError.notFound(id) }
        do {
            try await gmail.archive(id: id)
        } catch {
            store.insertEmail(removed)                  // rollback
            throw error
        }
        return InboxToolOutcome(
            summary: "Archived · \(removed.email.senderName)",
            affectedIDs: [id],
            undo: {
                await store.insertEmail(removed)
                try? await gmail.unarchive(id: id)
            })
    }
}

/// Unsubscribe from a bulk sender. One-click (RFC 8058) when possible; otherwise
/// returns an `openURL` for the UI to open. Irreversible (undo = nil).
private struct UnsubscribeTool: InboxTool {
    let store: InboxStore
    let gmail: GmailWriteService

    var spec: InboxToolSpec {
        InboxToolSpec(
            name: "unsubscribe",
            description: "Unsubscribe from a bulk sender (one-click when supported, else returns a link to open).",
            parameters: [
                InboxToolParam(name: "message_id", kind: .string, required: true,
                               description: "The id of a message from the sender to unsubscribe from."),
            ])
    }

    func run(_ args: [String: Any]) async throws -> InboxToolOutcome {
        let id = try args.requireString("message_id")
        guard let item = store.email(for: id) else { throw InboxToolError.notFound(id) }
        let sender = item.email.senderName

        switch try await gmail.unsubscribe(message: item.email) {
        case .oneClickDone:
            store.signalUnsubscribed(id)        // negative learning signal
            return InboxToolOutcome(summary: "Unsubscribed · \(sender)", affectedIDs: [id])
        case .openURL(let url):
            store.signalUnsubscribed(id)
            return InboxToolOutcome(summary: "Opening unsubscribe for \(sender)…",
                                    affectedIDs: [id], openURL: url)
        case .none:
            throw InboxToolError.gmail("No unsubscribe option found for \(sender).")
        }
    }
}

/// Snooze one message: hide it locally until a resurface time (now + `hours`).
/// LOCAL only — no Gmail call. Undo = un-snooze. See `InboxStore` for persistence.
private struct SnoozeTool: InboxTool {
    let store: InboxStore

    var spec: InboxToolSpec {
        InboxToolSpec(
            name: "snooze",
            description: "Hide a message from the inbox until a number of hours from now.",
            parameters: [
                InboxToolParam(name: "message_id", kind: .string, required: true,
                               description: "The id of the message to snooze."),
                InboxToolParam(name: "hours", kind: .int, required: true,
                               description: "How many hours from now to resurface the message."),
            ])
    }

    func run(_ args: [String: Any]) async throws -> InboxToolOutcome {
        let id = try args.requireString("message_id")
        let hours = try args.requireInt("hours")
        guard let item = store.email(for: id) else { throw InboxToolError.notFound(id) }
        let until = Date().addingTimeInterval(TimeInterval(max(1, hours)) * 3600)
        store.snooze(id: id, until: until)
        return InboxToolOutcome(
            summary: "Snoozed \(hours)h · \(item.email.senderName)",
            affectedIDs: [id],
            undo: { await store.unsnooze(id: id) })
    }
}

/// Run one per-item action across many messages. `action` is one of `mark_read`,
/// `archive`, `unsubscribe`; `message_ids` is the list to apply it to. The outcome
/// summarizes the count and composes the per-item undos (reversed) into one undo.
private struct BulkApplyTool: InboxTool {
    /// `unowned` — the registry owns this tool, so the back-reference never
    /// outlives the registry; this avoids a retain cycle.
    unowned let capabilities: InboxCapabilities

    private static let allowed = ["mark_read", "archive", "unsubscribe"]

    var spec: InboxToolSpec {
        InboxToolSpec(
            name: "bulk_apply",
            description: "Apply one per-item action (mark_read, archive, or unsubscribe) across many messages.",
            parameters: [
                InboxToolParam(name: "action", kind: .string, required: true,
                               description: "The per-item action to run: mark_read, archive, or unsubscribe."),
                InboxToolParam(name: "message_ids", kind: .stringArray, required: true,
                               description: "The ids of the messages to apply the action to."),
            ])
    }

    func run(_ args: [String: Any]) async throws -> InboxToolOutcome {
        let action = try args.requireString("action")
        let ids = try args.requireStringArray("message_ids")
        guard Self.allowed.contains(action) else {
            throw InboxToolError.missingArgument("action (one of: \(Self.allowed.joined(separator: ", ")))")
        }

        var affected: [String] = []
        var undos: [() async -> Void] = []
        var failed = 0
        for id in ids {
            do {
                let outcome = try await capabilities.run(action, args: ["message_id": id])
                affected.append(contentsOf: outcome.affectedIDs)
                if let undo = outcome.undo { undos.append(undo) }
            } catch InboxToolError.needsReconnect {
                throw InboxToolError.needsReconnect     // stop — the user must reconnect first
            } catch {
                failed += 1                             // skip a single bad item, keep going
            }
        }

        var summary = "\(Self.label(for: action)) \(affected.count) message\(affected.count == 1 ? "" : "s")"
        if failed > 0 { summary += ", \(failed) failed" }
        let undo: (() async -> Void)? = undos.isEmpty ? nil : {
            for undo in undos.reversed() { await undo() }
        }
        return InboxToolOutcome(summary: summary, affectedIDs: affected, undo: undo)
    }

    private static func label(for action: String) -> String {
        switch action {
        case "mark_read": return "Marked read"
        case "archive": return "Archived"
        case "unsubscribe": return "Unsubscribed from"
        default: return "Updated"
        }
    }
}

// MARK: - Preference tools (M4)

/// Add a standing PREFERENCE so future triage goes the user's way: mark a sender VIP
/// (always surfaced) or muted (always noise), or suppress/elevate a whole category.
/// This is how "never show me LinkedIn emails" becomes durable from chat. The change
/// applies immediately (the store re-files the current set) and is undoable by
/// removing the rule.
private struct SetPreferenceTool: InboxTool {
    let store: InboxStore

    private static let kinds = ["vip", "mute", "suppress_category", "elevate_category"]

    var spec: InboxToolSpec {
        InboxToolSpec(
            name: "set_preference",
            description: "Add a standing preference so future mail is triaged the user's way. Use this for durable rules like 'always treat my boss as important' or 'never show me LinkedIn'.",
            parameters: [
                InboxToolParam(name: "kind", kind: .string, required: true,
                               description: "One of: vip (always surface a sender), mute (always treat a sender as noise), suppress_category (push a category to noise), elevate_category (lift a category out of noise)."),
                InboxToolParam(name: "value", kind: .string, required: true,
                               description: "For vip/mute: an email address, domain, or name substring (e.g. boss@acme.com, linkedin). For suppress_category/elevate_category: a category name like promotion, newsletter, invoice, or receipt."),
            ])
    }

    func run(_ args: [String: Any]) async throws -> InboxToolOutcome {
        let kind = try args.requireString("kind").lowercased()
        let value = try args.requireString("value")

        let added: Bool
        let undo: (() async -> Void)?
        let label: String

        switch kind {
        case "vip":
            added = store.addVIP(value)
            undo = added ? { await store.removeVIP(value) } : nil
            label = "Always surfacing mail from \(value)"
        case "mute":
            added = store.addMute(value)
            undo = added ? { await store.removeMute(value) } : nil
            label = "Muting \(value) (always noise)"
        case "suppress_category":
            let raw = Self.resolveCategory(value)
            added = store.addSuppressedCategory(raw)
            undo = added ? { await store.removeSuppressedCategory(raw) } : nil
            label = "Suppressing \(raw) to noise"
        case "elevate_category":
            let raw = Self.resolveCategory(value)
            added = store.addElevatedCategory(raw)
            undo = added ? { await store.removeElevatedCategory(raw) } : nil
            label = "Elevating \(raw)"
        default:
            throw InboxToolError.missingArgument("kind (one of: \(Self.kinds.joined(separator: ", ")))")
        }

        return InboxToolOutcome(summary: added ? label : "\(value) was already set",
                                affectedIDs: [], undo: undo)
    }

    /// Resolve a free-text category to a canonical `EmailCategory` rawValue, tolerant
    /// of case; falls back to the trimmed input (matching stays case-insensitive).
    private static func resolveCategory(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = EmailCategory(rawValue: trimmed) { return exact.rawValue }
        if let match = EmailCategory.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
        }) { return match.rawValue }
        return trimmed
    }
}

/// Add a KEYWORD RULE: when `keyword` appears in a message's sender or text, force it
/// into `lane` (or flag it into Needs you). Lets "anything saying invoice → Money" be
/// set from chat. Undo removes the rule.
private struct AddKeywordRuleTool: InboxTool {
    let store: InboxStore

    var spec: InboxToolSpec {
        InboxToolSpec(
            name: "add_keyword_rule",
            description: "Add a rule that forces any email whose sender or text contains a keyword into a given lane (or flags it into Needs you).",
            parameters: [
                InboxToolParam(name: "keyword", kind: .string, required: true,
                               description: "The substring to match, e.g. invoice, standup, urgent."),
                InboxToolParam(name: "lane", kind: .string, required: true,
                               description: "Target lane: needsYou, waiting, people, money, security, calendar, orders, or noise. Use 'flag' to force it into Needs you."),
            ])
    }

    func run(_ args: [String: Any]) async throws -> InboxToolOutcome {
        let keyword = try args.requireString("keyword")
        let laneArg = try args.requireString("lane")
        let laneRaw = Self.resolveLane(laneArg)
        guard let rule = store.addKeywordRule(keyword: keyword, laneRaw: laneRaw) else {
            throw InboxToolError.missingArgument("keyword")
        }
        let ruleID = rule.id
        return InboxToolOutcome(summary: "Rule added: \"\(keyword)\" → \(rule.targetLabel)",
                                affectedIDs: [],
                                undo: { await store.removeKeywordRule(ruleID) })
    }

    /// Resolve a free-text lane to an `InboxLane` rawValue, or nil for a flag rule
    /// (empty / "flag" / unknown all flag into Needs you).
    private static func resolveLane(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("flag") != .orderedSame else { return nil }
        if let exact = InboxLane(rawValue: trimmed) { return exact.rawValue }
        if let match = InboxLane.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.title.caseInsensitiveCompare(trimmed) == .orderedSame
        }) { return match.rawValue }
        return nil
    }
}

// MARK: - Argument coercion

/// Tolerant typed argument access shared by every tool — so the same call works
/// whether the args came from a native UI tap (real `Int`/`[String]`) or from the
/// agent's JSON (`NSNumber`, `[Any]`, stringified numbers).
private extension Dictionary where Key == String, Value == Any {
    func requireString(_ key: String) throws -> String {
        if let value = self[key] as? String, !value.isEmpty { return value }
        throw InboxToolError.missingArgument(key)
    }

    func requireInt(_ key: String) throws -> Int {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? NSNumber { return value.intValue }
        if let value = self[key] as? String, let parsed = Int(value) { return parsed }
        throw InboxToolError.missingArgument(key)
    }

    func requireStringArray(_ key: String) throws -> [String] {
        if let value = self[key] as? [String] { return value }
        if let value = self[key] as? [Any] {
            let strings = value.compactMap { $0 as? String }
            if !strings.isEmpty { return strings }
        }
        throw InboxToolError.missingArgument(key)
    }

    /// A non-empty trimmed string for an OPTIONAL key, else nil. Used by the read
    /// tools, whose every filter argument is optional.
    func optionalString(_ key: String) -> String? {
        guard let value = self[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A boolean for an OPTIONAL key — tolerant of real `Bool`, `NSNumber`, and the
    /// stringified forms the agent's JSON can carry ("true"/"yes"/"1"). nil when
    /// absent or unrecognized.
    func optionalBool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? NSNumber { return value.boolValue }
        if let value = self[key] as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
