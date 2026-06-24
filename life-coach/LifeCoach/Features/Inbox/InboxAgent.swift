import Foundation

/// The "Ask your inbox" agent (M3) — a small ReAct-style loop that lets the user
/// ask in natural language and have it run REAL inbox actions through the exact
/// same `InboxCapabilities` registry the tap UI uses. The agent never touches
/// Gmail or the store's mutators directly; every read and write goes through a
/// tool, so safety, optimism, and undo are inherited for free.
///
/// The one LLM primitive available is the provider's one-shot
/// `complete(systemPrompt:userText:model:)` — there is NO message-history API. So
/// the loop maintains a growing **scratchpad** string (the running ACTION /
/// OBSERVATION transcript) that is passed as `userText` each turn, and a separate,
/// bounded **conversation memory** across turns so a follow-up like "yes, do it"
/// resolves against what was proposed a moment ago.
///
/// Each turn the model must answer with EXACTLY ONE JSON object: either a tool
/// call or a `final` message to the user. After every tool call the outcome's
/// summary is appended as an `OBSERVATION:` line and the model is re-prompted, up
/// to a hard cap of `maxSteps` (after which a final is synthesized from what we
/// have). A bulk action over more than three messages is gated: the harness itself
/// pauses and asks the user to confirm before anything runs — the prompt can't be
/// talked out of it.
@MainActor
final class InboxAgent: ObservableObject {
    /// One streamed reasoning/acting step, surfaced to the chat UI as a live
    /// action log under the in-progress assistant turn.
    struct Step: Identifiable {
        let id: UUID
        let thought: String
        let tool: String?
        let args: String
        let observation: String
    }

    /// The steps of the CURRENT turn, in order. Reset at the start of each `ask`.
    @Published private(set) var steps: [Step] = []
    /// True while a turn is in flight, so the UI can disable input and show a
    /// thinking indicator.
    @Published private(set) var isThinking = false

    private let store: InboxStore
    private let capabilities: InboxCapabilities
    private let anthropic = AnthropicProvider()
    private let ollama = OllamaProvider()

    /// Bounded cross-turn memory: prior (user, assistant-final) pairs, prepended to
    /// the scratchpad so multi-turn confirmations and references resolve. Kept small
    /// so the prompt can't grow without bound.
    private var history: [(user: String, assistant: String)] = []

    /// A bulk action the harness asked the user to confirm last turn. Cleared at the
    /// start of every turn and re-set only when we pause for confirmation, so a
    /// large bulk can run on the FOLLOWING turn only if it matches what was approved.
    private var pendingBulk: (action: String, ids: [String])?

    /// Hard cap on tool-calling steps in a single turn.
    private let maxSteps = 6
    /// How many prior turns of conversation memory to carry.
    private let historyLimit = 6
    /// A bulk action affecting more than this many messages must be confirmed.
    private static let bulkConfirmThreshold = 3
    /// Tools that only READ — they never set the undo snackbar or trip the bulk gate.
    private static let readTools: Set<String> = ["search_emails", "get_email"]

    init(store: InboxStore, capabilities: InboxCapabilities) {
        self.store = store
        self.capabilities = capabilities
    }

    /// The active backend, resolved from persisted settings — the SAME rule the
    /// classifier and coach use, so Ask runs on whatever the user picked.
    private var currentProvider: ChatProvider {
        store.appStore.state.ai.provider == .ollama ? ollama : anthropic
    }

    // MARK: - One user turn

    /// Run one user turn end-to-end. Streams `Step`s into `steps` as it goes and
    /// returns the agent's final user-facing message. Never throws — every failure
    /// degrades into a graceful sentence.
    func ask(_ message: String) async -> String {
        let provider = currentProvider
        guard provider.hasKey() else {
            return "Connect an AI provider in Settings to use Ask."
        }

        isThinking = true
        steps = []
        defer { isThinking = false }

        // Capture (and clear) any confirmation we were waiting on; a large bulk can
        // only proceed this turn if it matches `hadPending`.
        let hadPending = pendingBulk
        pendingBulk = nil

        let model = store.appStore.state.ai.activeModel
        let system = buildSystemPrompt()
        var scratchpad = buildScratchpad(userMessage: message)

        var result: String?
        var lastWrite: InboxToolOutcome?
        var didCorrectiveReprompt = false
        var step = 0

        while step < maxSteps {
            step += 1

            // 1) Ask the model for its next single-JSON decision.
            guard let raw = try? await provider.complete(systemPrompt: system,
                                                         userText: scratchpad,
                                                         model: model) else {
                result = "I hit a problem reaching the AI just now. Give it another try in a moment."
                break
            }

            // 2) Parse it. On the FIRST unparseable reply, re-prompt once; if it's
            //    still bad, bow out gracefully.
            guard let decision = Self.parseDecision(raw) else {
                if !didCorrectiveReprompt {
                    didCorrectiveReprompt = true
                    step -= 1   // the correction shouldn't cost a real step
                    scratchpad += "\n\nSYSTEM: Return ONLY the single JSON object per the protocol — no prose, no markdown."
                    continue
                }
                result = "I couldn't quite turn that into a plan. Could you rephrase what you'd like me to do?"
                break
            }

            // 3) A `final` ends the turn.
            if let final = decision.final {
                result = final
                break
            }

            guard let tool = decision.tool else {
                result = "I wasn't sure how to act on that. Could you say it a different way?"
                break
            }

            // 4) Bulk safety gate — the harness, not the model, is the guarantee.
            if tool == "bulk_apply" {
                let ids = Self.stringArray(decision.args["message_ids"])
                let action = (decision.args["action"] as? String) ?? ""
                if ids.count > Self.bulkConfirmThreshold {
                    let approved = hadPending.map { pending in
                        pending.action == action && !ids.isEmpty
                            && Set(ids).isSubset(of: Set(pending.ids))
                    } ?? false
                    if !approved {
                        pendingBulk = (action: action, ids: ids)
                        let prompt = Self.confirmationPrompt(action: action, count: ids.count)
                        steps.append(Step(id: UUID(), thought: decision.thought, tool: tool,
                                          args: decision.argsDisplay,
                                          observation: "Paused — awaiting your confirmation for \(ids.count) messages."))
                        result = prompt
                        break
                    }
                }
            }

            // 5) Run the tool through the capability registry.
            do {
                let outcome = try await capabilities.run(tool, args: decision.args)
                steps.append(Step(id: UUID(), thought: decision.thought, tool: tool,
                                  args: decision.argsDisplay, observation: outcome.summary))
                if !Self.readTools.contains(tool) { lastWrite = outcome }
                scratchpad += "\n\nACTION: \(tool) \(decision.argsDisplay)\nOBSERVATION: \(outcome.summary)"
            } catch InboxToolError.needsReconnect {
                steps.append(Step(id: UUID(), thought: decision.thought, tool: tool,
                                  args: decision.argsDisplay, observation: "Gmail needs reconnecting."))
                result = "I need you to reconnect Gmail before I can make changes. Close this, tap an action in the inbox to trigger the reconnect prompt, then ask me again."
                break
            } catch {
                let message = error.localizedDescription
                steps.append(Step(id: UUID(), thought: decision.thought, tool: tool,
                                  args: decision.argsDisplay, observation: "Error — \(message)"))
                scratchpad += "\n\nACTION: \(tool) \(decision.argsDisplay)\nOBSERVATION: Error — \(message). Reconsider and continue."
            }
        }

        // Cap reached without a final → synthesize one from the transcript.
        if result == nil {
            result = await synthesizeFinal(provider: provider, system: system,
                                           model: model, scratchpad: scratchpad)
        }

        let reply = result ?? "Here's where I got to. Let me know how you'd like to proceed."

        // Surface the last write so the inbox's existing undo snackbar can reverse
        // it — reuses M2's plumbing rather than inventing a second undo path.
        if let lastWrite { store.lastOutcome = lastWrite }

        appendHistory(user: message, assistant: reply)
        return reply
    }

    // MARK: - Cap fallback

    /// One last call asking the model to wrap up what it found/did into a `final`.
    /// On any failure, a deterministic sentence so the user is never left hanging.
    private func synthesizeFinal(provider: ChatProvider, system: String,
                                 model: String, scratchpad: String) async -> String {
        let prompt = scratchpad + "\n\nSYSTEM: You have reached the step limit. Reply NOW with ONLY a JSON object of the form {\"thought\":\"...\",\"final\":\"...\"} that tells the user what you found or did and any next step."
        guard let raw = try? await provider.complete(systemPrompt: system, userText: prompt, model: model),
              let decision = Self.parseDecision(raw),
              let final = decision.final, !final.isEmpty else {
            return "I've done a few steps but didn't fully wrap up. Tell me if you'd like me to keep going."
        }
        return final
    }

    // MARK: - Conversation memory

    private func appendHistory(user: String, assistant: String) {
        history.append((user: user, assistant: assistant))
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    /// The per-turn `userText`: bounded prior conversation, then the new request,
    /// then the kickoff instruction. ACTION/OBSERVATION lines are appended onto this
    /// as the loop runs.
    private func buildScratchpad(userMessage: String) -> String {
        var parts: [String] = []
        if !history.isEmpty {
            let convo = history.suffix(historyLimit)
                .map { "User: \($0.user)\nYou: \($0.assistant)" }
                .joined(separator: "\n")
            parts.append("CONVERSATION SO FAR:\n\(convo)")
        }
        parts.append("CURRENT REQUEST:\n\(userMessage)")
        parts.append("Begin. Reply with exactly one JSON object per the protocol.")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - System prompt

    /// Assemble the full system prompt: persona, a live inbox snapshot, the tool
    /// catalog rendered from `capabilities.specs`, the JSON protocol, and the safety
    /// rules.
    private func buildSystemPrompt() -> String {
        """
        \(Self.persona)

        \(buildSnapshot())

        TOOLS — call one at a time by name. Each entry is `name(param:type, …) — description`, then its parameters:
        \(buildToolCatalog())

        \(Self.protocolBlock)

        \(Self.safetyBlock)
        """
    }

    /// A compact, live view of the inbox the agent reasons over without a tool call:
    /// the brief line, per-lane counts, and up to 60 of the highest-priority visible
    /// emails. For anything beyond that, the agent uses `search_emails`.
    private func buildSnapshot() -> String {
        let brief = store.brief.isEmpty ? "—" : store.brief
        let laneCounts = store.activeLanes
            .map { "\($0.title) \(store.count(for: $0))" }
            .joined(separator: " · ")

        let sorted = store.emails.sorted {
            if $0.lane.sortPriority != $1.lane.sortPriority {
                return $0.lane.sortPriority < $1.lane.sortPriority
            }
            return $0.email.date > $1.email.date
        }
        let cap = 60
        let shown = sorted.prefix(cap)
        let lines = shown.map { item -> String in
            let cat = item.category?.rawValue ?? "—"
            let unread = item.email.isUnread ? "unread" : "read"
            return "\(item.id) · \(item.email.senderName) · \(item.lane.rawValue)/\(cat) · \(unread) · \(snapshotLine(item))"
        }.joined(separator: "\n")

        // The user's standing preferences (M4), so the agent honours them and can
        // tell when a request is already covered by an existing rule.
        let prefs = store.preferences.promptSummary()
        let prefsBlock = prefs.isEmpty ? "" : "\n\n\(prefs)"

        return """
        LIVE INBOX SNAPSHOT
        Brief: \(brief)
        Lane counts: \(laneCounts.isEmpty ? "empty" : laneCounts)
        Watching \(store.totalUnread) unread · \(store.triagedCount) triaged.

        Visible emails (\(shown.count) of \(sorted.count); use search_emails for the rest):
        \(lines.isEmpty ? "(none)" : lines)\(prefsBlock)
        """
    }

    /// First line of an email's summary (or snippet), clipped for the snapshot.
    private func snapshotLine(_ item: ClassifiedEmail) -> String {
        let source = item.summary.isEmpty ? item.email.snippet : item.summary
        let first = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? source
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }

    /// Render every registered tool spec into the prompt's tool catalog.
    private func buildToolCatalog() -> String {
        capabilities.specs.map { spec -> String in
            let signature = spec.parameters
                .map { "\($0.name):\($0.kind.rawValue)" }
                .joined(separator: ", ")
            let head = "\(spec.name)(\(signature)) — \(spec.description)"
            let detail = spec.parameters
                .map { "    • \($0.name) (\($0.kind.rawValue), \($0.required ? "required" : "optional")): \($0.description)" }
                .joined(separator: "\n")
            return detail.isEmpty ? head : "\(head)\n\(detail)"
        }
        .joined(separator: "\n")
    }

    // MARK: - JSON decision parsing

    /// The model's single-JSON decision for a turn: a tool call OR a final.
    private struct Decision {
        let thought: String
        let tool: String?
        let args: [String: Any]
        let argsDisplay: String   // compact one-liner for the action log
        let final: String?
    }

    /// Parse the model's reply into a `Decision`. Tolerant of code fences and
    /// surrounding prose: extracts the first balanced top-level `{ … }`. A `tool`
    /// (non-empty) takes precedence; otherwise a `final` (even empty) ends the turn.
    /// Returns nil when neither is present — the caller re-prompts once.
    private static func parseDecision(_ raw: String) -> Decision? {
        guard let json = extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let thought = (object["thought"] as? String) ?? ""

        if let tool = (object["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tool.isEmpty {
            let args = (object["args"] as? [String: Any]) ?? [:]
            return Decision(thought: thought, tool: tool, args: args,
                            argsDisplay: displayArgs(args), final: nil)
        }
        if let final = object["final"] as? String {
            return Decision(thought: thought, tool: nil, args: [:], argsDisplay: "", final: final)
        }
        return nil
    }

    /// A short, human-readable rendering of a tool's args for the action log, e.g.
    /// `action=archive, message_ids=[12 ids]`.
    private static func displayArgs(_ args: [String: Any]) -> String {
        guard !args.isEmpty else { return "" }
        return args.keys.sorted().map { key -> String in
            let value = args[key]
            if let array = value as? [Any] {
                return "\(key)=[\(array.count) id\(array.count == 1 ? "" : "s")]"
            }
            return "\(key)=\(value.map { "\($0)" } ?? "")"
        }
        .joined(separator: ", ")
    }

    /// Coerce a JSON array value into `[String]`, tolerating `[Any]`.
    private static func stringArray(_ value: Any?) -> [String] {
        if let value = value as? [String] { return value }
        if let value = value as? [Any] { return value.compactMap { $0 as? String } }
        return []
    }

    /// Pull the first balanced top-level `{ … }` out of arbitrary model text, after
    /// stripping any ``` fences — the object analogue of the classifier's array
    /// extractor, so single-object replies parse just as robustly.
    private static func extractJSONObject(_ raw: String) -> String? {
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

        guard let start = text.firstIndex(of: "{") else { return nil }
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
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Static prompt blocks

    private static let persona = """
    You are Sapiod, the user's warm, sharp chief-of-staff for their email inbox. \
    You answer questions about their mail and take real, safe actions on it through \
    tools. Be concise and reassuring, and act decisively — but never do anything \
    destructive or large without confirmation. When you act, prefer the smallest set \
    of messages that satisfies the request.
    """

    private static let protocolBlock = """
    PROTOCOL — every reply MUST be EXACTLY ONE JSON object and nothing else (no \
    prose, no markdown, no code fences). Either:
      {"thought":"<brief reasoning>","tool":"<tool name>","args":{ ... }}   to call a tool, or
      {"thought":"<brief reasoning>","final":"<message to the user>"}        when you are done.
    After each tool call you will be shown an `OBSERVATION:` line with the result; \
    then reply again with one JSON object. Keep `thought` to one short sentence. Use \
    ONLY tool names listed above and ids that appear in the snapshot or were returned \
    by search_emails / get_email — never invent an id.
    """

    private static let safetyBlock = """
    SAFETY:
    - Single, undoable actions on ONE message — mark_read, mark_unread, archive, \
    snooze, and unsubscribe — may be performed directly without asking.
    - A bulk_apply over MORE THAN 3 messages is gated. State plainly what you will \
    do and the EXACT count, then call bulk_apply with the ids: the system will pause \
    and ask the user to confirm before anything runs, and will run it only after they \
    agree on the next turn. Never claim a bulk action is done before it has run.
    - Unsubscribing CANNOT be undone — call that out when you propose it, especially \
    in bulk.
    - If a tool reports it needs Gmail reconnected, stop and tell the user to reconnect.
    - Never fabricate message ids. Only use ids from the snapshot or from \
    search_emails / get_email.
    """

    /// The confirmation question the harness asks before a large bulk action.
    private static func confirmationPrompt(action: String, count: Int) -> String {
        let verb: String
        switch action {
        case "mark_read": verb = "mark \(count) messages as read"
        case "archive": verb = "archive \(count) messages"
        case "unsubscribe": verb = "unsubscribe from \(count) senders (this can't be undone)"
        default: verb = "update \(count) messages"
        }
        return "Just to confirm — you'd like me to \(verb)? Reply \"yes\" and I'll do it."
    }
}
