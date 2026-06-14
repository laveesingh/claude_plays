import Foundation

/// Ollama Cloud backend: streams the native /api/chat endpoint (newline-delimited
/// JSON) and runs the tool-use loop with OpenAI-style function tools. Bearer auth.
/// `think` is enabled only on high-effort sessions to keep routine turns cheap.
@MainActor
final class OllamaProvider: ChatProvider {
    let provider: AIProvider = .ollama
    private let endpoint = URL(string: "https://ollama.com/api/chat")!

    private var apiKey = ""
    private var model = ""
    private var think = false
    private var tools: [[String: Any]] = []
    private var messages: [[String: Any]] = []

    func hasKey() -> Bool {
        guard let key = KeychainHelper.load(provider: .ollama) else { return false }
        return !key.isEmpty
    }

    func start(systemPrompt: String,
               tools: [[String: Any]],
               history: [ChatTurn],
               userText: String,
               model: String,
               effort: String) {
        self.apiKey = KeychainHelper.load(provider: .ollama) ?? ""
        self.model = model
        self.think = (effort == "high")
        self.tools = tools.map(Self.functionTool)

        var built: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        built += history.map { ["role": $0.role, "content": $0.text] }
        built.append(["role": "user", "content": userText])
        messages = built
    }

    func appendToolResults(_ results: [AgentToolResult]) {
        for result in results {
            messages.append(["role": "tool", "content": result.output, "tool_name": result.name])
        }
    }

    func runRound(onText: @escaping (String) -> Void) async throws -> LLMRound {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": tools,
            "stream": true,
        ]
        if think { body["think"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoachError(message: "Invalid response from Ollama.")
        }
        guard http.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw CoachError(message: Self.errorMessage(from: errorBody, status: http.statusCode))
        }

        var fullContent = ""
        var toolCalls: [AgentToolCall] = []

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let error = object["error"] as? String {
                throw CoachError(message: error)
            }
            if let message = object["message"] as? [String: Any] {
                if let content = message["content"] as? String, !content.isEmpty {
                    fullContent += content
                    onText(content)
                }
                if let calls = message["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        guard let function = call["function"] as? [String: Any],
                              let name = function["name"] as? String else { continue }
                        toolCalls.append(AgentToolCall(id: UUID().uuidString,
                                                       name: name,
                                                       input: Self.arguments(function["arguments"])))
                    }
                }
            }
        }

        // Echo the assistant turn (including any tool calls) before the results.
        var assistant: [String: Any] = ["role": "assistant", "content": fullContent]
        if !toolCalls.isEmpty {
            assistant["tool_calls"] = toolCalls.map { call in
                ["function": ["name": call.name, "arguments": call.input]]
            }
        }
        messages.append(assistant)

        let stopReason = toolCalls.isEmpty ? "end_turn" : "tool_use"
        return LLMRound(stopReason: stopReason, toolCalls: toolCalls)
    }

    // MARK: - One-shot completion

    /// Non-streaming request/response over the same /api/chat endpoint and Bearer
    /// auth, with no tools. Reads `message.content` from the single JSON object.
    /// Independent of the streaming `start`/`runRound` state above.
    func complete(systemPrompt: String, userText: String, model: String) async throws -> String {
        let key = KeychainHelper.load(provider: .ollama) ?? ""

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoachError(message: "Invalid response from Ollama.")
        }
        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw CoachError(message: Self.errorMessage(from: errorBody, status: http.statusCode))
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoachError(message: "Ollama returned an unreadable response.")
        }
        if let error = object["error"] as? String {
            throw CoachError(message: error)
        }
        let content = (object["message"] as? [String: Any])?["content"] as? String
        return content ?? ""
    }

    // MARK: - Helpers

    /// Anthropic-style tool def -> OpenAI/Ollama function tool.
    private static func functionTool(_ def: [String: Any]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": def["name"] as? String ?? "",
                "description": def["description"] as? String ?? "",
                "parameters": def["input_schema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()],
            ],
        ]
    }

    private static func arguments(_ any: Any?) -> [String: Any] {
        if let dict = any as? [String: Any] { return dict }
        if let string = any as? String,
           let data = string.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return [:]
    }

    private static func errorMessage(from body: String, status: Int) -> String {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String {
            return message
        }
        switch status {
        case 401, 403: return "Invalid Ollama API key. Check it in Settings."
        case 404: return "That Ollama model isn't available on your account."
        case 429: return "Rate limited by Ollama - wait a moment and try again."
        default: return "Ollama error (HTTP \(status))."
        }
    }
}
