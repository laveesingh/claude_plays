import Foundation

/// Claude backend: streams the Messages API (SSE) and runs the tool-use loop with
/// Anthropic content blocks. Adaptive thinking + effort are gated to the models
/// that accept them (Opus 4.8 / Sonnet 4.6); Haiku 4.5 gets a plain request.
@MainActor
final class AnthropicProvider: ChatProvider {
    let provider: AIProvider = .claude
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private var apiKey = ""
    private var model = "claude-opus-4-8"
    private var effort = "high"
    private var systemPrompt = ""
    private var tools: [[String: Any]] = []
    private var messages: [[String: Any]] = []

    func hasKey() -> Bool {
        guard let key = KeychainHelper.load(provider: .claude) else { return false }
        return !key.isEmpty
    }

    private var supportsThinkingEffort: Bool {
        model == "claude-opus-4-8" || model == "claude-sonnet-4-6"
    }

    func start(systemPrompt: String,
               tools: [[String: Any]],
               history: [ChatTurn],
               userText: String,
               model: String,
               effort: String) {
        self.apiKey = KeychainHelper.load(provider: .claude) ?? ""
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.model = model
        self.effort = effort

        var built: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }
        // The API requires the first message to be a user turn; hidden session
        // triggers can leave the transcript starting with the assistant.
        if let first = built.first, (first["role"] as? String) == "assistant" {
            built.insert(["role": "user", "content": "(Session resumed.)"], at: 0)
        }
        built.append(["role": "user", "content": userText])
        messages = built
    }

    func appendToolResults(_ results: [AgentToolResult]) {
        let blocks = results.map { result -> [String: Any] in
            [
                "type": "tool_result",
                "tool_use_id": result.id,
                "content": result.output,
            ]
        }
        messages.append(["role": "user", "content": blocks])
    }

    func runRound(onText: @escaping (String) -> Void) async throws -> LLMRound {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "system": systemPrompt,
            "tools": tools,
            "messages": messages,
        ]
        if supportsThinkingEffort {
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": effort]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoachError(message: "Invalid response from the API.")
        }
        guard http.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
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
                        onText(text)
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

        var contentBlocks: [[String: Any]] = []
        var toolCalls: [AgentToolCall] = []
        for index in order {
            switch blockTypes[index] {
            case "text":
                let text = textBlocks[index] ?? ""
                if !text.isEmpty { contentBlocks.append(["type": "text", "text": text]) }
            case "thinking":
                contentBlocks.append([
                    "type": "thinking",
                    "thinking": thinkingBlocks[index] ?? "",
                    "signature": thinkingSignatures[index] ?? "",
                ])
            case "redacted_thinking":
                contentBlocks.append(["type": "redacted_thinking", "data": redactedData[index] ?? ""])
            case "tool_use":
                guard let meta = toolMeta[index] else { continue }
                var input: [String: Any] = [:]
                let json = toolJSON[index] ?? ""
                if let data = json.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    input = parsed
                }
                contentBlocks.append(["type": "tool_use", "id": meta.id, "name": meta.name, "input": input])
                toolCalls.append(AgentToolCall(id: meta.id, name: meta.name, input: input))
            default:
                break
            }
        }

        if stopReason == "refusal" {
            throw CoachError(message: "The coach declined to respond to that request.")
        }
        messages.append(["role": "assistant", "content": contentBlocks])
        let resolved = (stopReason == "tool_use" && !toolCalls.isEmpty) ? "tool_use" : (stopReason ?? "end_turn")
        return LLMRound(stopReason: resolved, toolCalls: toolCalls)
    }

    // MARK: - One-shot completion

    /// Non-streaming request/response over the same /v1/messages endpoint and
    /// auth, with no tools. Joins the text content blocks. Thinking/effort are
    /// gated to the models that accept them, exactly as `runRound` does.
    /// Independent of the streaming `start`/`runRound` state above.
    func complete(systemPrompt: String, userText: String, model: String) async throws -> String {
        let key = KeychainHelper.load(provider: .claude) ?? ""

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // No extended thinking on one-shot completions: these are fast structured
        // tasks (classify / cluster / generate), so we skip the thinking+effort
        // params the streaming agent loop uses for deep reasoning.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "stream": false,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userText]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoachError(message: "Invalid response from the API.")
        }
        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw CoachError(message: Self.apiErrorMessage(from: errorBody, status: http.statusCode))
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoachError(message: "The API returned an unreadable response.")
        }
        if let error = object["error"] as? [String: Any] {
            throw CoachError(message: (error["message"] as? String) ?? "The API returned an error.")
        }
        let blocks = (object["content"] as? [[String: Any]]) ?? []
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text
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
        case 429: return "Rate limited - wait a moment and try again."
        case 529: return "The API is overloaded. Try again shortly."
        default: return "API error (HTTP \(status))."
        }
    }
}
