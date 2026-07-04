import Foundation

/// Which LLM backend powers the coach. Adding a third provider is a matter of
/// adding a case here, a catalog entry, and one `ChatProvider` conformer - the
/// agent loop, tools, and UI stay provider-agnostic.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case ollama
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .claude: return "Claude"
        }
    }

    var keyLabel: String {
        switch self {
        case .ollama: return "Ollama Cloud API key"
        case .claude: return "Anthropic API key"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .ollama: return "Ollama API key"
        case .claude: return "sk-ant-..."
        }
    }

    var keyFooter: String {
        switch self {
        case .ollama:
            return "Powers your coach via Ollama Cloud. Create one at ollama.com -> Settings -> Keys. Stored only in this device's Keychain."
        case .claude:
            return "Powers your coach via Claude. Create one at console.anthropic.com -> API Keys. Stored only in this device's Keychain."
        }
    }
}

/// A selectable model within a provider.
struct ModelOption: Identifiable, Hashable {
    let tag: String     // exact wire model id
    let label: String   // friendly name
    var id: String { tag }
}

/// Curated, tool-capable models. Only models that reliably support tool calling
/// belong here - the whole app is tool-driven (structured input + state writes).
enum AIModels {
    static let ollama: [ModelOption] = [
        ModelOption(tag: "kimi-k2.6:cloud", label: "Kimi K2.6"),
        ModelOption(tag: "minimax-m3:cloud", label: "MiniMax M3"),
    ]

    static let claude: [ModelOption] = [
        ModelOption(tag: "claude-opus-4-8", label: "Claude Opus 4.8"),
        ModelOption(tag: "claude-sonnet-4-6", label: "Claude Sonnet 4.6"),
        ModelOption(tag: "claude-haiku-4-5", label: "Claude Haiku 4.5"),
    ]

    static func list(for provider: AIProvider) -> [ModelOption] {
        switch provider {
        case .ollama: return ollama
        case .claude: return claude
        }
    }

    static func label(for tag: String) -> String {
        (ollama + claude).first { $0.tag == tag }?.label ?? tag
    }
}

/// Persisted provider/model selection. Defaults to Ollama per the product
/// decision; Claude is a manual fallback (no automatic switching).
struct AIConfig: Codable {
    var provider: AIProvider = .ollama
    var ollamaModel: String = AIModels.ollama.first!.tag
    var claudeModel: String = "claude-opus-4-8"

    init() {}

    func model(for provider: AIProvider) -> String {
        switch provider {
        case .ollama: return ollamaModel
        case .claude: return claudeModel
        }
    }

    var activeModel: String { model(for: provider) }

    // Tolerant decoding so adding fields later never wipes saved state.
    enum CodingKeys: String, CodingKey { case provider, ollamaModel, claudeModel }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(AIProvider.self, forKey: .provider) ?? .ollama
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? AIModels.ollama.first!.tag
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? "claude-opus-4-8"
    }
}

// MARK: - Provider-agnostic agent transport

/// One prior chat turn, as stored in the transcript.
struct ChatTurn {
    let role: String   // "user" or "assistant"
    let text: String
}

/// A normalised tool call the model requested.
struct AgentToolCall {
    let id: String
    let name: String
    let input: [String: Any]
}

/// The result of executing a tool, fed back to the model.
struct AgentToolResult {
    let id: String
    let name: String
    let output: String
}

/// The outcome of one streamed assistant turn.
struct LLMRound {
    let stopReason: String          // "end_turn" | "tool_use" | "refusal"
    let toolCalls: [AgentToolCall]
}

/// The transport + wire-format contract. Each provider owns ALL of its own
/// request building, streaming, parsing, and message bookkeeping; the engine
/// only drives the loop (run round -> execute tools -> hand back results).
@MainActor
protocol ChatProvider: AnyObject {
    var provider: AIProvider { get }
    func hasKey() -> Bool

    /// Begin a fresh send. `tools` are the shared Anthropic-style definitions;
    /// each provider adapts them to its own format.
    func start(systemPrompt: String,
               tools: [[String: Any]],
               history: [ChatTurn],
               userText: String,
               model: String,
               effort: String)

    /// Stream one assistant turn, forwarding visible text via `onText`.
    func runRound(onText: @escaping (String) -> Void) async throws -> LLMRound

    /// Append executed tool results for the next round.
    func appendToolResults(_ results: [AgentToolResult])

    /// One-shot, non-streaming request/response - no tools, no transcript
    /// bookkeeping. The general-purpose primitive every AI feature (Inbox
    /// classifier, News, Factscroll) uses for a simple prompt -> text call. This
    /// is independent of the streaming agent loop above and does not touch its
    /// internal message state.
    func complete(systemPrompt: String, userText: String, model: String) async throws -> String
}

/// Shared error surfaced to the UI.
struct CoachError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
