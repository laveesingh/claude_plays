import Foundation

/// One web search hit: the title, the source URL, and the extracted page text
/// the model is allowed to reason from. This is the only ground truth a
/// web-grounded feature (News today, others later) ever cites - never the
/// model's own memory.
struct WebResult: Codable, Hashable {
    let title: String
    let url: String
    let content: String

    init(title: String, url: String, content: String) {
        self.title = title
        self.url = url
        self.content = content
    }
}

/// The platform's web-search/-fetch abstraction. Kept protocol-first so an
/// Anthropic-native grounding (server-side web search / fetch tools) can drop in
/// later without touching News. The Ollama implementation is the default today.
protocol Grounding {
    /// Run a live web search. `maxResults` is clamped to the provider ceiling.
    func search(_ query: String, maxResults: Int) async throws -> [WebResult]

    /// Best-effort full-page fetch for a single URL. Optional to call.
    func fetch(_ url: String) async throws -> String
}

extension Grounding {
    /// Convenience default so callers can omit `maxResults`.
    func search(_ query: String) async throws -> [WebResult] {
        try await search(query, maxResults: 5)
    }
}

/// Errors surfaced by the grounding layer, mapped to clear user-facing copy.
struct GroundingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Ollama-Cloud-backed grounding: POSTs the `/api/web_search` and
/// `/api/web_fetch` endpoints with the same Bearer auth the chat provider uses,
/// reading the Ollama key from the Keychain. Stateless and `Sendable` - safe to
/// share across tasks.
final class OllamaGrounding: Grounding {
    private let searchEndpoint = URL(string: "https://ollama.com/api/web_search")!
    private let fetchEndpoint = URL(string: "https://ollama.com/api/web_fetch")!

    /// The provider's hard ceiling on results per call.
    private static let maxResultsCeiling = 10

    func search(_ query: String, maxResults: Int = 5) async throws -> [WebResult] {
        let key = try requireKey()
        let clamped = min(max(1, maxResults), Self.maxResultsCeiling)

        var request = URLRequest(url: searchEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "max_results": clamped,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawResults = object["results"] as? [[String: Any]] else {
            throw GroundingError(message: "Web search returned an unreadable response.")
        }

        return rawResults.compactMap { raw in
            guard let url = raw["url"] as? String, !url.isEmpty else { return nil }
            let title = (raw["title"] as? String) ?? url
            let content = (raw["content"] as? String) ?? ""
            return WebResult(title: title, url: url, content: content)
        }
    }

    func fetch(_ url: String) async throws -> String {
        let key = try requireKey()

        var request = URLRequest(url: fetchEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": url])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GroundingError(message: "Web fetch returned an unreadable response.")
        }
        // The fetch endpoint returns the page's extracted content; tolerate a few
        // shapes rather than hard-failing - this call is best-effort.
        if let content = object["content"] as? String { return content }
        if let results = object["results"] as? [[String: Any]],
           let first = results.first,
           let content = first["content"] as? String {
            return content
        }
        return ""
    }

    // MARK: - Helpers

    private func requireKey() throws -> String {
        guard let key = KeychainHelper.load(provider: .ollama), !key.isEmpty else {
            throw GroundingError(
                message: "Add your Ollama Cloud API key in Settings so News can search the web."
            )
        }
        return key
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GroundingError(message: "Invalid response from the web search service.")
        }
        guard http.statusCode == 200 else {
            throw GroundingError(message: errorMessage(from: data, status: http.statusCode))
        }
    }

    private static func errorMessage(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String {
            return message
        }
        switch status {
        case 401, 403: return "Invalid Ollama API key. Check it in Settings."
        case 429: return "Web search is rate limited - wait a moment and try again."
        default: return "Web search error (HTTP \(status))."
        }
    }
}

/// Convenience facade so feature code can say `GroundingService.shared.search(...)`
/// without naming the concrete backend. Swap the backing `Grounding` here when an
/// Anthropic-native grounding ships.
enum GroundingService {
    static let shared: Grounding = OllamaGrounding()
}
