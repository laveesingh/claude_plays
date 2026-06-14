import Foundation

/// The session being run determines the coach's protocol and reasoning effort.
enum CoachSession {
    case intake
    case morningBrief
    case middayCorrection
    case eveningDebrief
    case weeklyReview
    case adHoc

    var effort: String {
        switch self {
        case .intake, .weeklyReview: return "high"
        default: return "medium"
        }
    }

    var instruction: String? {
        switch self {
        case .intake:
            return """
            SESSION: INTAKE INTERVIEW. The client is new. Run a proper intake before coaching: \
            interview them ONE question at a time (8-12 questions total) covering: weekly schedule \
            and fixed commitments; current fitness baseline and training history; injuries or health \
            constraints; sleep and energy patterns; work setup and deep-work capacity; past attempts \
            at these goals and why they failed; what motivates them and what makes them quit; how \
            much time they can honestly commit daily. After each answer, save what you learned to \
            the dossier with update_dossier (sections like 'Schedule & constraints', 'Fitness \
            baseline', 'History & failure patterns', 'Motivation profile'). When the interview is \
            complete: call mark_intake_complete, set their starting habits with set_habits, break \
            each goal into milestones with deadlines using update_goal, then timebox the rest of \
            today with timebox_day. Start now with a short introduction and your first question.
            """
        case .morningBrief:
            return """
            SESSION: MORNING BRIEF. Run the morning protocol: 1) Check the calendar (read_calendar) \
            and health data (read_health) — plan around real meetings and react to actual sleep and \
            yesterday's training. 2) Review yesterday's record above; open with a one-line verdict \
            on it. 3) Timebox today with timebox_day — workouts, deep work blocks, recovery — around \
            their calendar, with schedule_checkins true so every block gets a lock-screen check-in. \
            4) Name the one block that matters most today and why. Keep the whole brief tight.
            """
        case .middayCorrection:
            return """
            SESSION: MIDDAY CORRECTION. There are unresolved or missed blocks (see today's schedule \
            above). Confront what slipped — specifically, with the block names — get a one-line \
            explanation, then replan the REMAINDER of the day with timebox_day (keep resolved blocks, \
            reschedule what can still be saved, drop what can't with status skipped). Do not let the \
            day quietly fall apart.
            """
        case .eveningDebrief:
            return """
            SESSION: EVENING DEBRIEF. Compare the plan against what actually happened, block by \
            block. Verify fitness claims against read_health where possible. Give your verdict in \
            your coaching style — cite the record, not vibes. Log anything measurable with \
            log_metric, update goal progress with update_goal, and save durable observations \
            (patterns, excuses, wins) to the dossier with update_dossier. End by naming tomorrow's \
            single priority.
            """
        case .weeklyReview:
            return """
            SESSION: WEEKLY REVIEW. This is the deep session. Audit the full 14-day record, habit \
            adherence, and metric trends above. Identify the 2-3 patterns that matter (what's \
            working, what keeps slipping, and the likely root cause). Renegotiate any milestone \
            deadlines that are no longer honest — out loud, never silently. Set each goal's \
            weekly_target for next week with update_goal. Update the dossier's 'Patterns & risks' \
            section. Finally, write a structured report card (grade, wins, failures, focus for next \
            week) and save it with save_weekly_report, then summarize it conversationally.
            """
        case .adHoc:
            return nil
        }
    }
}

/// The agent: talks to the Claude API (streaming over HTTPS), runs a tool-use
/// loop, and executes the coach's actions against app state, notifications,
/// HealthKit, and the calendar.
@MainActor
final class CoachEngine: ObservableObject {
    @Published var isResponding = false
    @Published var streamingText = ""
    @Published var lastError: String?

    private let store: AppStore
    private let anthropic = AnthropicProvider()
    private let ollama = OllamaProvider()

    /// The active backend, resolved from persisted settings each send.
    private var currentProvider: ChatProvider {
        store.state.ai.provider == .ollama ? ollama : anthropic
    }

    /// Pre-fetched once per send so the prompt reflects current reality.
    private var healthSummaryCache: String?
    private var calendarSummaryCache: String?

    /// Set when the coach asks for structured input; ends the turn so the client
    /// can render the controls and the user's selection becomes the next message.
    private var pendingInputRequest: InputRequest?

    init(store: AppStore) {
        self.store = store
    }

    var hasAPIKey: Bool { currentProvider.hasKey() }

    /// Sends a message to the coach. `hidden` user turns are not shown in the
    /// transcript (app-generated session triggers); the reply is always shown.
    func send(_ userText: String, hidden: Bool = false, session: CoachSession = .adHoc) async {
        guard !isResponding else { return }
        let provider = currentProvider
        guard provider.hasKey() else {
            lastError = "Add your \(store.state.ai.provider.keyLabel) in Settings so your coach can respond."
            return
        }
        if !hidden {
            store.appendChat(role: "user", text: userText)
        }
        isResponding = true
        streamingText = ""
        lastError = nil
        pendingInputRequest = nil
        defer { isResponding = false }

        // Ground the prompt in reality before reasoning.
        healthSummaryCache = await HealthManager.summary()
        calendarSummaryCache = CalendarManager.eventsSummary(tomorrow: false)

        var apiContent = userText
        if let instruction = session.instruction {
            apiContent += "\n\n[\(instruction)]"
        }

        provider.start(systemPrompt: systemPrompt(),
                       tools: Self.toolDefinitions,
                       history: buildHistory(),
                       userText: apiContent,
                       model: store.state.ai.activeModel,
                       effort: session.effort)

        do {
            var rounds = 0
            while rounds < 8 {
                rounds += 1
                let round = try await provider.runRound { [weak self] text in
                    self?.streamingText += text
                }
                guard round.stopReason == "tool_use", !round.toolCalls.isEmpty else { break }

                var results: [AgentToolResult] = []
                for call in round.toolCalls {
                    let output = await handleTool(name: call.name, input: call.input)
                    results.append(AgentToolResult(id: call.id, name: call.name, output: output))
                }
                provider.appendToolResults(results)
                if pendingInputRequest != nil { break }
                if !streamingText.isEmpty, !streamingText.hasSuffix("\n") {
                    streamingText += "\n\n"
                }
            }
        } catch {
            lastError = (error as? CoachError)?.message ?? error.localizedDescription
        }

        let finalText = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty || pendingInputRequest != nil {
            store.appendChat(role: "assistant", text: finalText, inputRequest: pendingInputRequest)
        }
        streamingText = ""
        pendingInputRequest = nil
    }

    // MARK: - History

    private func buildHistory() -> [ChatTurn] {
        store.state.chat.suffix(40).map { ChatTurn(role: $0.role, text: $0.text) }
    }

    // MARK: - Tool belt

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "timebox_day",
            "description": "Replace today's timeboxed schedule. This is your primary instrument of control: every morning brief and every midday replan goes through it. Build the schedule around the client's real calendar events (use read_calendar first). 3-7 blocks; each block is one concrete commitment with a start time and duration. With schedule_checkins true (default), every block gets a pre-start reminder and an interactive end-of-block check-in the client answers from the lock screen.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "blocks": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string", "description": "Concrete commitment, e.g. 'Strength training - push day' or 'Deep work: ship onboarding flow'."],
                                "category": ["type": "string", "enum": ["fitness", "professional", "recovery", "other"]],
                                "start": ["type": "string", "description": "24h start time 'HH:MM' in the client's local time."],
                                "duration_minutes": ["type": "integer"],
                            ],
                            "required": ["title", "category", "start", "duration_minutes"],
                        ],
                    ],
                    "schedule_checkins": ["type": "boolean", "description": "Default true. Schedules block notifications."],
                    "write_to_calendar": ["type": "boolean", "description": "Also write the blocks into the client's calendar as events (only if they enabled calendar write)."],
                ],
                "required": ["blocks"],
            ],
        ],
        [
            "name": "update_block",
            "description": "Update the status of one of today's blocks (matched loosely by title). Use when the client reports an outcome in chat, or when you negotiate a skip.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "status": ["type": "string", "enum": ["done", "missed", "skipped", "planned"]],
                ],
                "required": ["title", "status"],
            ],
        ],
        [
            "name": "set_habits",
            "description": "Replace the client's recurring habit list (adherence history is preserved for habits whose titles you keep). Habits are standing daily/weekly commitments separate from timeboxed blocks - e.g. '10k steps', 'No screens after 22:30'. Keep the list short: 2-5 habits.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "habits": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string"],
                                "category": ["type": "string", "enum": ["fitness", "professional", "recovery", "other"]],
                                "weekdays": [
                                    "type": "array",
                                    "items": ["type": "integer"],
                                    "description": "Calendar weekdays 1=Sunday ... 7=Saturday. Omit or empty for every day.",
                                ],
                            ],
                            "required": ["title", "category"],
                        ],
                    ],
                ],
                "required": ["habits"],
            ],
        ],
        [
            "name": "update_goal",
            "description": "Update a goal: log a progress note or setback, set overall percent complete, set next week's target, add milestones with deadlines, or mark a milestone complete. Milestone deadlines are commitments - renegotiate them out loud with the client, never silently.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "goal_title": ["type": "string", "description": "Matched loosely against the client's goals."],
                    "note": ["type": "string"],
                    "percent_complete": ["type": "number"],
                    "weekly_target": ["type": "string", "description": "This week's concrete target for the goal."],
                    "add_milestones": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string"],
                                "deadline": ["type": "string", "description": "'YYYY-MM-DD', optional."],
                            ],
                            "required": ["title"],
                        ],
                    ],
                    "complete_milestone": ["type": "string", "description": "Title of a milestone to mark done."],
                ],
                "required": ["goal_title"],
            ],
        ],
        [
            "name": "log_metric",
            "description": "Record a measurement the client reports or that you verify: bodyweight, 5K time, deep work hours, pages written. Builds the trend charts on their Progress screen.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Metric name, e.g. 'Bodyweight', '5K time (min)'."],
                    "unit": ["type": "string"],
                    "value": ["type": "number"],
                ],
                "required": ["name", "unit", "value"],
            ],
        ],
        [
            "name": "update_dossier",
            "description": "Maintain your private client file. Your chat window only shows recent messages - anything important that isn't in the dossier WILL be forgotten. Write/overwrite a named section (e.g. 'Schedule & constraints', 'Fitness baseline', 'History & failure patterns', 'Motivation profile', 'Patterns & risks', 'Wins'). Pass empty content to delete a section. Keep sections current: rewrite them as you learn more.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "section": ["type": "string"],
                    "content": ["type": "string"],
                ],
                "required": ["section", "content"],
            ],
        ],
        [
            "name": "schedule_nudge",
            "description": "Schedule a one-off push notification at a specific local time - a reminder, a pre-commitment, or a pointed check-in. Block check-ins are scheduled automatically by timebox_day; use this for everything in between.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "message": ["type": "string", "description": "Notification text, max ~120 characters, in your voice."],
                    "hour": ["type": "integer", "description": "0-23 local time."],
                    "minute": ["type": "integer"],
                    "day": ["type": "string", "enum": ["today", "tomorrow"]],
                ],
                "required": ["message", "hour", "minute", "day"],
            ],
        ],
        [
            "name": "read_calendar",
            "description": "Read the client's real calendar events for today or tomorrow. Always check before timeboxing so blocks don't collide with meetings.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "day": ["type": "string", "enum": ["today", "tomorrow"]],
                ],
                "required": ["day"],
            ],
        ],
        [
            "name": "read_health",
            "description": "Read verified HealthKit data: workouts in the last 7 days, steps today, and last night's sleep. Use it to fact-check fitness claims and to calibrate today's training load.",
            "input_schema": [
                "type": "object",
                "properties": [String: Any](),
            ],
        ],
        [
            "name": "save_weekly_report",
            "description": "Save the weekly report card to the client's Progress screen. Use only during a weekly review. Content should be structured markdown: grade, wins, failures, patterns, next week's focus.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "e.g. 'Week of Jun 8: B-'."],
                    "content": ["type": "string"],
                ],
                "required": ["title", "content"],
            ],
        ],
        [
            "name": "mark_intake_complete",
            "description": "Call once, when the intake interview is finished and the dossier is populated.",
            "input_schema": [
                "type": "object",
                "properties": [String: Any](),
            ],
        ],
        [
            "name": "request_user_input",
            "description": "Render tap-friendly input controls for the client to answer your question, instead of making them type a freeform reply. This is your DEFAULT way to interact - prefer it for almost every turn. Write a short question as text in the SAME turn first (one or two sentences, no walls of text), then call this tool. Use it whenever the answer is naturally structured - choosing one option, choosing several, rating on a scale, a number/time/date, or yes/no. To check in on today's blocks, add a single field with type 'block_status': it lists every block of today with Done/Missed/Skipped controls and writes the outcome straight into the record - use this instead of asking them to type a report. Keep it to ONE focused question (1-3 fields). The client always also has a free-text box, so set allow_custom true (or add a 'text' field) whenever the answer might not fit your options. After you call this, the turn ends and the client's selection arrives as their next message - do not keep talking or call other tools alongside it.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "Optional one-line restatement of what you're asking, shown above the controls."],
                    "fields": [
                        "type": "array",
                        "description": "1-3 input fields.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string", "description": "Short identifier, also used as the field's label if no label is given."],
                                "label": ["type": "string", "description": "Human-readable label for this field."],
                                "type": ["type": "string", "enum": ["single_select", "multi_select", "scale", "number", "time", "date", "boolean", "text", "block_status"]],
                                "options": ["type": "array", "items": ["type": "string"], "description": "Choices for single_select / multi_select."],
                                "min": ["type": "number", "description": "Lower bound for scale."],
                                "max": ["type": "number", "description": "Upper bound for scale."],
                                "step": ["type": "number", "description": "Step for scale (default 1)."],
                                "unit": ["type": "string", "description": "Unit shown with number/scale, e.g. 'hours', 'kg'."],
                                "placeholder": ["type": "string", "description": "Placeholder for number/text fields."],
                                "allow_custom": ["type": "boolean", "description": "Add an 'Other…' free-text entry to a select. Default false."],
                            ],
                            "required": ["label", "type"],
                        ],
                    ],
                    "submit_label": ["type": "string", "description": "Optional label for the submit button (default 'Send')."],
                ],
                "required": ["fields"],
            ],
        ],
    ]

    private func handleTool(name: String, input: [String: Any]) async -> String {
        switch name {
        case "timebox_day":
            guard let rawBlocks = input["blocks"] as? [[String: Any]], !rawBlocks.isEmpty else {
                return "Error: no blocks provided."
            }
            let blocks = rawBlocks.compactMap { raw -> TimeBlock? in
                guard let title = raw["title"] as? String, !title.isEmpty,
                      let start = raw["start"] as? String,
                      let startMinutes = Self.parseClock(start),
                      let duration = raw["duration_minutes"] as? Int, duration > 0 else { return nil }
                let category = GoalCategory(rawValue: raw["category"] as? String ?? "other") ?? .other
                return TimeBlock(title: title, category: category,
                                 startMinutes: startMinutes, durationMinutes: duration)
            }
            guard !blocks.isEmpty else { return "Error: blocks were malformed. Use start 'HH:MM' and integer duration_minutes." }
            store.setTodayBlocks(blocks)
            var result = "Schedule saved: \(blocks.count) blocks on the client's Today screen."
            if (input["schedule_checkins"] as? Bool) ?? true {
                NotificationManager.scheduleBlockCheckins(for: store.today.blocks,
                                                          dateKey: store.todayKey)
                result += " Lock-screen check-ins scheduled for each block."
            }
            if (input["write_to_calendar"] as? Bool) == true {
                if store.state.profile?.calendarWriteEnabled == true, CalendarManager.isAuthorized {
                    result += CalendarManager.writeBlocks(store.today.blocks)
                        ? " Blocks written to their calendar."
                        : " Calendar write failed."
                } else {
                    result += " Calendar write is not enabled by the client."
                }
            }
            return result

        case "update_block":
            guard let title = input["title"] as? String,
                  let statusRaw = input["status"] as? String,
                  let status = BlockStatus(rawValue: statusRaw) else {
                return "Error: title and a valid status are required."
            }
            return store.setBlockStatus(titled: title, status: status)
                ? "Block '\(title)' marked \(status.label.lowercased())."
                : "Error: no block today matches '\(title)'. Today's blocks: \(store.today.blocks.map { $0.title }.joined(separator: "; "))."

        case "set_habits":
            guard let rawHabits = input["habits"] as? [[String: Any]] else {
                return "Error: habits array required."
            }
            let habits = rawHabits.compactMap { raw -> Habit? in
                guard let title = raw["title"] as? String, !title.isEmpty else { return nil }
                let category = GoalCategory(rawValue: raw["category"] as? String ?? "other") ?? .other
                let weekdays = (raw["weekdays"] as? [Int]) ?? []
                return Habit(title: title, category: category,
                             weekdays: weekdays.filter { (1...7).contains($0) })
            }
            store.setHabits(habits)
            return "Habit list set: \(habits.map { $0.title }.joined(separator: "; "))."

        case "update_goal":
            guard let goalTitle = input["goal_title"] as? String,
                  let index = store.goalIndex(matching: goalTitle) else {
                return "Error: no goal matched '\(input["goal_title"] as? String ?? "")'. Goals: \(store.state.goals.map { $0.title }.joined(separator: "; "))."
            }
            var changes: [String] = []
            if let note = input["note"] as? String, !note.isEmpty {
                store.state.goals[index].progressNotes.append(ProgressNote(note: note))
                changes.append("note logged")
            }
            if let percent = input["percent_complete"] as? Double {
                store.state.goals[index].progressPercent = min(100, max(0, percent))
                changes.append("progress set to \(Int(percent))%")
            }
            if let target = input["weekly_target"] as? String, !target.isEmpty {
                store.state.goals[index].weeklyTarget = target
                changes.append("weekly target set")
            }
            if let rawMilestones = input["add_milestones"] as? [[String: Any]] {
                for raw in rawMilestones {
                    guard let title = raw["title"] as? String, !title.isEmpty else { continue }
                    let deadline = (raw["deadline"] as? String).flatMap(Self.parseDate)
                    store.state.goals[index].milestones.append(
                        Milestone(title: title, deadline: deadline)
                    )
                }
                changes.append("milestones added")
            }
            if let completed = input["complete_milestone"] as? String {
                let needle = completed.lowercased()
                if let milestoneIndex = store.state.goals[index].milestones.firstIndex(where: {
                    $0.title.lowercased().contains(needle) || needle.contains($0.title.lowercased())
                }) {
                    store.state.goals[index].milestones[milestoneIndex].isDone = true
                    changes.append("milestone '\(completed)' completed")
                } else {
                    changes.append("WARNING: no milestone matched '\(completed)'")
                }
            }
            return changes.isEmpty ? "No changes specified." : "Goal updated: \(changes.joined(separator: ", "))."

        case "log_metric":
            guard let name = input["name"] as? String,
                  let value = input["value"] as? Double else {
                return "Error: name and numeric value are required."
            }
            store.logMetric(name: name, unit: input["unit"] as? String ?? "", value: value)
            return "Logged \(name) = \(value). It appears on the Progress charts."

        case "update_dossier":
            guard let section = input["section"] as? String,
                  let content = input["content"] as? String else {
                return "Error: section and content are required."
            }
            store.upsertMemory(section: section, content: content)
            return content.isEmpty
                ? "Dossier section '\(section)' deleted."
                : "Dossier section '\(section)' saved."

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

        case "read_calendar":
            let tomorrow = (input["day"] as? String) == "tomorrow"
            if let summary = CalendarManager.eventsSummary(tomorrow: tomorrow) {
                return summary
            }
            return "Calendar access is not granted. Ask the client to enable it in Settings, and plan from what they tell you."

        case "read_health":
            if let summary = await HealthManager.summary() {
                return summary
            }
            return "Health data is not available (no permission or no data). Rely on the client's reports."

        case "save_weekly_report":
            guard let title = input["title"] as? String,
                  let content = input["content"] as? String else {
                return "Error: title and content are required."
            }
            store.state.weeklyReports.append(WeeklyReport(title: title, content: content))
            return "Weekly report saved to the client's Progress screen."

        case "mark_intake_complete":
            store.state.profile?.intakeComplete = true
            return "Intake marked complete. You are now in full coaching mode."

        case "request_user_input":
            guard let request = Self.parseInputRequest(input) else {
                return "Error: request_user_input needs a non-empty 'fields' array with valid types."
            }
            pendingInputRequest = request
            return "Controls are now displayed to the client. Their answer arrives as your next user message. Do not call request_user_input again or keep talking until they respond."

        default:
            return "Error: unknown tool '\(name)'."
        }
    }

    private static func parseInputRequest(_ input: [String: Any]) -> InputRequest? {
        guard let rawFields = input["fields"] as? [[String: Any]] else { return nil }
        let fields = rawFields.compactMap { parseInputField($0) }
        guard !fields.isEmpty else { return nil }
        return InputRequest(prompt: input["prompt"] as? String,
                            fields: fields,
                            submitLabel: input["submit_label"] as? String)
    }

    private static func parseInputField(_ raw: [String: Any]) -> InputField? {
        guard let typeRaw = raw["type"] as? String,
              let type = InputFieldType(rawValue: typeRaw) else { return nil }
        let label = (raw["label"] as? String) ?? (raw["id"] as? String) ?? ""
        guard !label.isEmpty else { return nil }
        let key = (raw["id"] as? String) ?? label
        let options = (raw["options"] as? [String]) ?? []
        return InputField(key: key,
                          label: label,
                          type: type,
                          options: options,
                          min: asDouble(raw["min"]),
                          max: asDouble(raw["max"]),
                          step: asDouble(raw["step"]),
                          unit: raw["unit"] as? String,
                          placeholder: raw["placeholder"] as? String,
                          allowCustom: (raw["allow_custom"] as? Bool) ?? false)
    }

    private static func asDouble(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func parseClock(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: value)
    }

    // MARK: - System prompt

    private func systemPrompt() -> String {
        let profile = store.state.profile
        let name = profile?.name ?? "the client"
        let intensity = profile?.intensity ?? .balanced

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let now = dateFormatter.string(from: Date())

        let deadlineFormatter = DateFormatter()
        deadlineFormatter.dateFormat = "MMM d"

        // Goals with milestones and weekly targets.
        var goalLines: [String] = []
        for goal in store.state.goals {
            var line = "- [\(goal.category.label)] \(goal.title) - \(Int(goal.progressPercent))% complete. Why it matters: \(goal.why)"
            if let target = goal.weeklyTarget, !target.isEmpty {
                line += "\n  This week's target: \(target)"
            }
            for milestone in goal.milestones {
                let deadline = milestone.deadline.map { " (by \(deadlineFormatter.string(from: $0)))" } ?? ""
                line += "\n  - [\(milestone.isDone ? "DONE" : "OPEN")] \(milestone.title)\(deadline)"
            }
            if let lastNote = goal.progressNotes.last {
                line += "\n  Latest note: \(lastNote.note)"
            }
            goalLines.append(line)
        }
        let goalsSection = goalLines.isEmpty ? "No goals defined yet." : goalLines.joined(separator: "\n")

        // Dossier.
        let dossierSection: String
        if store.state.coachMemory.isEmpty {
            dossierSection = "Empty. You have not recorded anything yet."
        } else {
            dossierSection = store.state.coachMemory.map {
                "### \($0.title)\n\($0.content)"
            }.joined(separator: "\n")
        }

        // Habits with adherence.
        let habitsSection: String
        if store.state.habits.isEmpty {
            habitsSection = "No habits defined yet."
        } else {
            habitsSection = store.state.habits.map { habit in
                let adherence = store.habitAdherence(habit)
                let doneToday = store.habitDoneToday(habit.id) ? "done today" : "not yet today"
                return "- \(habit.title) (\(habit.scheduleLabel)) - \(adherence.done)/\(adherence.scheduled) over 14 days, \(doneToday)"
            }.joined(separator: "\n")
        }

        // Metrics.
        let metricsSection: String
        if store.state.metrics.isEmpty {
            metricsSection = "No metrics logged yet."
        } else {
            metricsSection = store.state.metrics.map { series in
                guard let latest = series.samples.last else { return "- \(series.name): no samples" }
                var line = "- \(series.name): \(latest.value) \(series.unit) (latest)"
                if series.samples.count >= 2, let first = series.samples.first {
                    let change = latest.value - first.value
                    line += String(format: ", change %+.1f over %d samples", change, series.samples.count)
                }
                return line
            }.joined(separator: "\n")
        }

        // Today's schedule.
        let nowMinutes = Calendar.current.component(.hour, from: Date()) * 60
            + Calendar.current.component(.minute, from: Date())
        let scheduleSection: String
        if store.today.blocks.isEmpty {
            scheduleSection = "No schedule set for today yet. Set one with timebox_day."
        } else {
            scheduleSection = store.today.blocks.map { block in
                var line = "- \(block.timeRangeLabel) [\(block.status.label.uppercased())] \(block.title) (\(block.category.label))"
                if block.status == .planned && block.endMinutes <= nowMinutes {
                    line += " <- OVERDUE, unresolved"
                }
                return line
            }.joined(separator: "\n")
        }

        // 14-day record.
        let recordSection = recentRecord(days: 14)

        // Recent reflections.
        let reflections = recentReflections(days: 7)

        // Live context.
        var liveContext: [String] = []
        if let calendar = calendarSummaryCache {
            liveContext.append("CALENDAR TODAY (live):\n\(calendar)")
        }
        if let health = healthSummaryCache {
            liveContext.append("HEALTH DATA (live, verified):\n\(health)")
        }
        let liveSection = liveContext.isEmpty
            ? "No live calendar/health data. Use read_calendar and read_health tools, or rely on the client's reports."
            : liveContext.joined(separator: "\n\n")

        let intakeLine = (profile?.intakeComplete ?? false)
            ? ""
            : "\nINTAKE NOT COMPLETE: you have not finished interviewing this client. Until the intake is done, prioritize discovery over directives.\n"

        return """
        You are \(name)'s full-time life coach and personal assistant, living inside their iOS app. They hired you because they were moving too slowly on their fitness and professional goals and taking things for granted. You own their schedule. You assign, you verify, you confront, you adjust. You are not a passive chatbot waiting for questions.

        \(intensity.promptDescription)
        \(intakeLine)
        Current local time: \(now).

        ## CLIENT DOSSIER (your private file, maintained via update_dossier)
        \(dossierSection)

        ## GOALS, MILESTONES, WEEKLY TARGETS
        \(goalsSection)

        ## STANDING HABITS
        \(habitsSection)

        ## METRICS
        \(metricsSection)

        ## TODAY'S TIMEBOXED SCHEDULE
        \(scheduleSection)

        ## 14-DAY RECORD
        Current streak (days fully executed): \(store.streak).
        \(recordSection)

        ## RECENT EVENING REFLECTIONS
        \(reflections)

        ## LIVE CONTEXT
        \(liveSection)

        ## HOW YOU OPERATE
        - You hold real levers: timebox_day writes their actual schedule and arms lock-screen check-ins; schedule_nudge sends real notifications; update_goal moves real milestones. A coach who only talks is not doing the job - act through tools, then summarize what you did.
        - Time-box everything. Commitments get a start time and a duration, scheduled around their real calendar. Vague intentions are not allowed to survive a conversation with you.
        - Verify before you praise. Cross-check fitness claims against HealthKit data. If the record says 2 of 5 blocks done, the conversation starts there.
        - Critique with receipts. Cite specific blocks, dates, adherence numbers, and patterns from the record above. Never scold from vibes; never invent data.
        - Own the structure: every goal needs milestones with deadlines and a weekly target. If a deadline slips, renegotiate it explicitly in conversation - nothing drifts silently.
        - Memory discipline: your visible chat history is only the recent messages. Anything durable - constraints, patterns, promises, excuses, wins - goes in the dossier via update_dossier, or it is lost.
        - Coaching methodology: GROW (goal, reality, options, will) for decisions; implementation intentions ("after X, I do Y") for habits; progressive overload for training; timeboxing for focus. Use them, don't lecture about them.
        - This is a phone app, not a chat thread. The client wants to TAP, not read. Aim for 90%+ of your turns to end in a request_user_input control. Lead with at most one or two short sentences - a verdict, or the single thing that matters - then the control. Never restate the schedule, goals, metrics, or your reasoning back as prose; those have their own screens. No walls of text, no markdown headers, no emoji lists, no recaps.
        - Checking in on the day: send ONE request_user_input with a single 'block_status' field - it shows every block with Done/Missed/Skipped and writes the result into the record directly. Do NOT ask the client to type out what happened, and do NOT list the blocks as text yourself. After they submit, the blocks and progress are already updated; acknowledge in one line and move on (replan with timebox_day only if something needs saving).
        - Logging specifics: use a number or scale field for measurements (weight, sleep hours, deep-work hours), single_select/multi_select for choices, boolean for yes/no. Reserve free text (a text field, or allow_custom) for genuinely open-ended things. Persist whatever you learn with your other tools (update_goal, log_metric, update_dossier) in the same turn.

        ## RESPONSIBILITIES AND LIMITS
        - Sustainable pace is your responsibility: program rest and recovery, watch sleep data, and intervene against overtraining or burnout even if the client wants to push. Pushing hard and pushing stupid are different things.
        - Pain, injury, or health symptoms: stop the relevant training and tell them to see a medical professional. You are not a doctor.
        - Signs of crisis or serious mental-health struggle: drop the coaching posture, be human, and direct them to professional help immediately.
        - No medical, financial, or legal advice. Refer out.
        - Hard discipline is welcome; humiliation is not. You are tough on behavior, never on the person.
        """
    }

    private func recentRecord(days: Int) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        var lines: [String] = []
        for offset in 1...days {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let label = formatter.string(from: date)
            guard let log = store.state.days[AppStore.key(for: date)], !log.blocks.isEmpty else {
                lines.append("- \(label): no schedule set")
                continue
            }
            let done = log.blocks.filter { $0.status == .done }.count
            let missedTitles = log.blocks.filter { $0.status == .missed || $0.status == .planned }
                .map { $0.title }
            var line = "- \(label): \(done)/\(log.blocks.count) blocks done"
            if !missedTitles.isEmpty {
                line += " - missed: \(missedTitles.joined(separator: ", "))"
            }
            lines.append(line)
        }
        return lines.isEmpty ? "No history yet." : lines.joined(separator: "\n")
    }

    private func recentReflections(days: Int) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        var lines: [String] = []
        for offset in 0...days {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()),
                  let log = store.state.days[AppStore.key(for: date)],
                  let reflection = log.eveningReflection,
                  !reflection.isEmpty else { continue }
            lines.append("- \(formatter.string(from: date)): \"\(reflection)\"")
        }
        return lines.isEmpty ? "None recorded." : lines.joined(separator: "\n")
    }
}
