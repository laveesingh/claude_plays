import Foundation

struct CoachError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Talks to the Claude API (raw HTTPS + SSE streaming) and executes the coach's
/// tool calls against local app state: setting the daily plan, scheduling
/// nudge notifications, and logging goal progress.
@MainActor
final class CoachEngine: ObservableObject {
    @Published var isResponding = false
    @Published var streamingText = ""
    @Published var lastError: String?

    private let store: AppStore
    private let model = "claude-opus-4-8"
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(store: AppStore) {
        self.store = store
    }

    var hasAPIKey: Bool {
        guard let key = KeychainHelper.load() else { return false }
        return !key.isEmpty
    }

    /// Sends a message to the coach. When `hidden` is true the user turn is not
    /// shown in the transcript (used for app-generated check-in triggers); the
    /// coach's reply is always persisted.
    func send(_ userText: String, hidden: Bool = false) async {
        guard !isResponding else { return }
        guard let apiKey = KeychainHelper.load(), !apiKey.isEmpty else {
            lastError = "Add your Anthropic API key in Settings so your coach can respond."
            return
        }
        if !hidden {
            store.appendChat(role: "user", text: userText)
        }
        isResponding = true
        streamingText = ""
        lastError = nil
        defer { isResponding = false }

        var apiMessages = buildHistory()
        apiMessages.append(["role": "user", "content": userText])

        do {
            var rounds = 0
            while rounds < 6 {
                rounds += 1
                let round = try await streamOnce(apiKey: apiKey, messages: apiMessages)
                guard round.stopReason == "tool_use", !round.toolUses.isEmpty else { break }

                apiMessages.append(["role": "assistant", "content": round.contentBlocks])
                var toolResults: [[String: Any]] = []
                for tool in round.toolUses {
                    let output = handleTool(name: tool.name, input: tool.input)
                    toolResults.append([
                        "type": "tool_result",
                        "tool_use_id": tool.id,
                        "content": output,
                    ])
                }
                apiMessages.append(["role": "user", "content": toolResults])
                if !streamingText.isEmpty, !streamingText.hasSuffix("\n") {
                    streamingText += "\n\n"
                }
            }
        } catch {
            lastError = (error as? CoachError)?.message ?? error.localizedDescription
        }

        let finalText = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            store.appendChat(role: "assistant", text: finalText)
        }
        streamingText = ""
    }

    // MARK: - History

    private func buildHistory() -> [[String: Any]] {
        let recent = store.state.chat.suffix(40)
        var history: [[String: Any]] = recent.map { ["role": $0.role, "content": $0.text] }
        // The API requires the first message to be a user turn; hidden check-in
        // triggers mean the persisted transcript can start with the assistant.
        if let first = history.first, (first["role"] as? String) == "assistant" {
            history.insert(["role": "user", "content": "(Session resumed.)"], at: 0)
        }
        return history
    }

    // MARK: - Streaming request

    private struct ToolUse {
        let id: String
        let name: String
        let input: [String: Any]
    }

    private struct RoundResult {
        let stopReason: String?
        let contentBlocks: [[String: Any]]
        let toolUses: [ToolUse]
    }

    private func streamOnce(apiKey: String, messages: [[String: Any]]) async throws -> RoundResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "system": systemPrompt(),
            "tools": Self.toolDefinitions,
            "messages": messages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoachError(message: "Invalid response from the API.")
        }
        guard http.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw CoachError(message: Self.apiErrorMessage(from: errorBody, status: http.statusCode))
        }

        var stopReason: String?
        var order: [Int] = []
        var blockTypes: [Int: String] = [:]
        var textBlocks: [Int: String] = [:]
        var thinkingBlocks: [Int: String] = [:]
        var thinkingSignatures: [Int: String] = [:]
        var redactedData: [Int: String] = [:]
        var toolMeta: [Int: (id: String, name: String)] = [:]
        var toolJSON: [Int: String] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                guard let index = event["index"] as? Int,
                      let block = event["content_block"] as? [String: Any],
                      let blockType = block["type"] as? String else { continue }
                order.append(index)
                blockTypes[index] = blockType
                switch blockType {
                case "text":
                    textBlocks[index] = ""
                case "thinking":
                    thinkingBlocks[index] = (block["thinking"] as? String) ?? ""
                    thinkingSignatures[index] = (block["signature"] as? String) ?? ""
                case "redacted_thinking":
                    redactedData[index] = (block["data"] as? String) ?? ""
                case "tool_use":
                    toolMeta[index] = (block["id"] as? String ?? "", block["name"] as? String ?? "")
                    toolJSON[index] = ""
                default:
                    break
                }
            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { continue }
                switch deltaType {
                case "text_delta":
                    if let text = delta["text"] as? String {
                        textBlocks[index, default: ""] += text
                        streamingText += text
                    }
                case "thinking_delta":
                    if let text = delta["thinking"] as? String {
                        thinkingBlocks[index, default: ""] += text
                    }
                case "signature_delta":
                    if let signature = delta["signature"] as? String {
                        thinkingSignatures[index, default: ""] += signature
                    }
                case "input_json_delta":
                    if let partial = delta["partial_json"] as? String {
                        toolJSON[index, default: ""] += partial
                    }
                default:
                    break
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String
                throw CoachError(message: message ?? "The API returned a stream error.")
            default:
                break
            }
        }

        // Rebuild the assistant content blocks in order. Thinking blocks must be
        // echoed back unchanged (signature included) when continuing a tool loop.
        var contentBlocks: [[String: Any]] = []
        var toolUses: [ToolUse] = []
        for index in order {
            switch blockTypes[index] {
            case "text":
                let text = textBlocks[index] ?? ""
                if !text.isEmpty {
                    contentBlocks.append(["type": "text", "text": text])
                }
            case "thinking":
                contentBlocks.append([
                    "type": "thinking",
                    "thinking": thinkingBlocks[index] ?? "",
                    "signature": thinkingSignatures[index] ?? "",
                ])
            case "redacted_thinking":
                contentBlocks.append([
                    "type": "redacted_thinking",
                    "data": redactedData[index] ?? "",
                ])
            case "tool_use":
                guard let meta = toolMeta[index] else { continue }
                var input: [String: Any] = [:]
                let json = toolJSON[index] ?? ""
                if let data = json.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    input = parsed
                }
                contentBlocks.append(["type": "tool_use", "id": meta.id, "name": meta.name, "input": input])
                toolUses.append(ToolUse(id: meta.id, name: meta.name, input: input))
            default:
                break
            }
        }

        if stopReason == "refusal" {
            throw CoachError(message: "The coach declined to respond to that request.")
        }
        return RoundResult(stopReason: stopReason, contentBlocks: contentBlocks, toolUses: toolUses)
    }

    private static func apiErrorMessage(from body: String, status: Int) -> String {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        switch status {
        case 401: return "Invalid API key. Check it in Settings."
        case 429: return "Rate limited — wait a moment and try again."
        case 529: return "The API is overloaded. Try again shortly."
        default: return "API error (HTTP \(status))."
        }
    }

    // MARK: - Tools

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "set_daily_plan",
            "description": "Replace the client's task plan for today. Use this whenever you assign or revise the day's commitments — every morning check-in, and any time the plan needs to change. Keep plans realistic: 3 to 6 concrete tasks tied to the client's goals.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "tasks": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": [
                                    "type": "string",
                                    "description": "Short, concrete, measurable action. e.g. '45 min strength training — push day' not 'exercise'.",
                                ],
                                "category": [
                                    "type": "string",
                                    "enum": ["fitness", "professional", "other"],
                                ],
                            ],
                            "required": ["title", "category"],
                        ],
                    ],
                ],
                "required": ["tasks"],
            ],
        ],
        [
            "name": "schedule_nudge",
            "description": "Schedule a push notification to nudge the client at a specific time, in their local time. Use this to enforce follow-through: before a planned workout, at the end of a focus block, or to check whether a commitment happened. The message should sound like you.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "message": ["type": "string", "description": "The notification text, max ~120 characters."],
                    "hour": ["type": "integer", "description": "Hour 0-23 in the client's local time."],
                    "minute": ["type": "integer", "description": "Minute 0-59."],
                    "day": ["type": "string", "enum": ["today", "tomorrow"]],
                ],
                "required": ["message", "hour", "minute", "day"],
            ],
        ],
        [
            "name": "record_goal_progress",
            "description": "Log progress (or a setback) against one of the client's goals. Use when the client reports something meaningful: a milestone hit, a measurable improvement, or a slip worth recording. Update percent_complete when you can estimate overall progress.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "goal_title": ["type": "string", "description": "The goal's title; matched loosely against the client's goals."],
                    "note": ["type": "string", "description": "One or two sentences describing the progress or setback."],
                    "percent_complete": ["type": "number", "description": "New overall completion estimate, 0-100. Optional."],
                ],
                "required": ["goal_title", "note"],
            ],
        ],
    ]

    private func handleTool(name: String, input: [String: Any]) -> String {
        switch name {
        case "set_daily_plan":
            guard let rawTasks = input["tasks"] as? [[String: Any]], !rawTasks.isEmpty else {
                return "Error: no tasks provided."
            }
            let tasks = rawTasks.compactMap { raw -> DailyTask? in
                guard let title = raw["title"] as? String, !title.isEmpty else { return nil }
                let category = GoalCategory(rawValue: raw["category"] as? String ?? "other") ?? .other
                return DailyTask(title: title, category: category)
            }
            store.setTodayPlan(tasks)
            return "Today's plan saved with \(tasks.count) tasks. The client sees it on their Today screen."

        case "schedule_nudge":
            guard let message = input["message"] as? String,
                  let hour = input["hour"] as? Int,
                  let minute = input["minute"] as? Int else {
                return "Error: message, hour, and minute are required."
            }
            let tomorrow = (input["day"] as? String) == "tomorrow"
            let scheduled = NotificationManager.scheduleNudge(
                message: message, hour: hour, minute: minute, tomorrow: tomorrow
            )
            return scheduled
                ? "Nudge scheduled for \(String(format: "%02d:%02d", hour, minute)) \(tomorrow ? "tomorrow" : "today")."
                : "Error: that time is in the past. Pick a future time."

        case "record_goal_progress":
            guard let title = input["goal_title"] as? String,
                  let note = input["note"] as? String else {
                return "Error: goal_title and note are required."
            }
            let percent = input["percent_complete"] as? Double
            let matched = store.recordProgress(goalTitle: title, note: note, percent: percent)
            return matched
                ? "Progress logged against the goal."
                : "Error: no goal matched '\(title)'. The client's goals are: \(store.state.goals.map { $0.title }.joined(separator: "; "))."

        default:
            return "Error: unknown tool '\(name)'."
        }
    }

    // MARK: - System prompt

    private func systemPrompt() -> String {
        let profile = store.state.profile
        let name = profile?.name ?? "the client"
        let intensity = profile?.intensity ?? .balanced

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let now = dateFormatter.string(from: Date())

        var goalLines: [String] = []
        for goal in store.state.goals {
            var line = "- [\(goal.category.label)] \(goal.title) — \(Int(goal.progressPercent))% complete. Why it matters to them: \(goal.why)"
            if let lastNote = goal.progressNotes.last {
                line += " Latest note: \(lastNote.note)"
            }
            goalLines.append(line)
        }
        let goalsSection = goalLines.isEmpty ? "No goals defined yet." : goalLines.joined(separator: "\n")

        let today = store.today
        let planSection: String
        if today.tasks.isEmpty {
            planSection = "No plan set for today yet. Set one with set_daily_plan."
        } else {
            planSection = today.tasks
                .map { "- [\($0.isDone ? "DONE" : "PENDING")] \($0.title) (\($0.category.label))" }
                .joined(separator: "\n")
        }

        let stats = store.weeklyStats
        let weekLine = stats.assigned == 0
            ? "No tasks were assigned in the last 7 days."
            : "Last 7 days: \(stats.completed) of \(stats.assigned) assigned tasks completed."

        return """
        You are \(name)'s personal full-time life coach inside their iOS app. They hired you because they feel they have been moving too slowly on their fitness and professional goals and taking things for granted. Your job is to run their days: assign plans, enforce follow-through, and track progress honestly.

        \(intensity.promptDescription)

        Current local time: \(now).

        CLIENT GOALS:
        \(goalsSection)

        TODAY'S PLAN:
        \(planSection)

        TRACK RECORD:
        Current streak (days where every assigned task was completed): \(store.streak).
        \(weekLine)

        HOW TO COACH:
        - You have real control: set_daily_plan writes the plan the client sees on their Today screen; schedule_nudge sends them real push notifications; record_goal_progress updates their goal tracker. Use these tools — don't just talk about plans, set them.
        - At a morning check-in, set the day's plan with set_daily_plan and schedule at least one nudge for the hardest task.
        - At an evening review, compare the plan against what got done, respond in your coaching style, and log anything meaningful with record_goal_progress.
        - Ground everything in the actual data above. Reference specific tasks, streaks, and numbers — never invent progress.
        - Be concrete: amounts, durations, times. Never assign vague tasks.
        - Keep replies short: a few sentences, or a tight list for a plan. One question maximum per reply. No lectures.
        - You are a coach, not a doctor, therapist, or financial adviser. For injuries, health conditions, or crises, tell them to see a professional.
        """
    }
}
