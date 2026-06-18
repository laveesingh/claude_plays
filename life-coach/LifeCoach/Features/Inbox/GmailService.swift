import Foundation

/// Live `EmailService` backed by the Gmail REST API. Lists the user's inbox from
/// the last ~2 days, fetches each message in full, and maps it to the same
/// `EmailMessage` the classifier and UI already consume — so the Inbox feature is
/// unchanged downstream of this swap. Read-only; access comes from `GoogleAuth`.
struct GmailService: EmailService {
    let auth: GoogleAuth

    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    /// Cap on messages pulled per refresh — keeps the fetch + classify bounded.
    private static let maxMessages = 25
    /// Hard cap on stored body length so a giant HTML email can't bloat the cache.
    private static let maxBodyChars = 6000

    func fetchRecent() async throws -> [EmailMessage] {
        let token = try await auth.validAccessToken()
        let ids = try await Self.listMessageIDs(token: token)
        guard !ids.isEmpty else { return [] }

        // Fetch message details concurrently; a single failure drops just that one.
        let messages = await withTaskGroup(of: EmailMessage?.self) { group in
            for id in ids.prefix(Self.maxMessages) {
                group.addTask { try? await Self.fetchMessage(id: id, token: token) }
            }
            var collected: [EmailMessage] = []
            for await message in group { if let message { collected.append(message) } }
            return collected
        }
        return messages.sorted { $0.date > $1.date }
    }

    // MARK: - REST calls

    /// `messages.list` for inbox mail newer than 2 days.
    private static func listMessageIDs(token: String) async throws -> [String] {
        var comps = URLComponents(string: "\(base)/messages")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: "newer_than:2d in:inbox"),
            URLQueryItem(name: "maxResults", value: "\(maxMessages)"),
        ]
        guard let url = comps.url else { return [] }
        let data = try await get(url, token: token)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let messages = (object["messages"] as? [[String: Any]]) ?? []
        return messages.compactMap { $0["id"] as? String }
    }

    /// `messages.get?format=full` → a fully-populated `EmailMessage`.
    private static func fetchMessage(id: String, token: String) async throws -> EmailMessage? {
        var comps = URLComponents(string: "\(base)/messages/\(id)")!
        comps.queryItems = [URLQueryItem(name: "format", value: "full")]
        guard let url = comps.url else { return nil }
        let data = try await get(url, token: token)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let threadId = (object["threadId"] as? String) ?? id
        let snippet = htmlDecoded((object["snippet"] as? String) ?? "")
        let labelIds = (object["labelIds"] as? [String]) ?? []
        let isUnread = labelIds.contains("UNREAD")

        // internalDate is ms since epoch — reliable, no header date parsing needed.
        let internalMS = Double((object["internalDate"] as? String) ?? "") ?? 0
        let date = internalMS > 0 ? Date(timeIntervalSince1970: internalMS / 1000) : Date()

        let payload = (object["payload"] as? [String: Any]) ?? [:]
        let headers = (payload["headers"] as? [[String: Any]]) ?? []
        let subject = header(headers, "Subject")
        let (senderName, senderEmail) = parseFrom(header(headers, "From"))

        var body = extractBody(payload) ?? snippet
        if body.count > maxBodyChars { body = String(body.prefix(maxBodyChars)) }

        return EmailMessage(id: id,
                            threadId: threadId,
                            senderName: senderName.isEmpty ? senderEmail : senderName,
                            senderEmail: senderEmail,
                            subject: subject,
                            snippet: snippet,
                            body: body,
                            date: date,
                            isUnread: isUnread)
    }

    private static func get(_ url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleAuthError("No response from Gmail.")
        }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw GoogleAuthError("Gmail access was denied. Reconnect in Settings.")
        default: throw GoogleAuthError("Gmail request failed (HTTP \(http.statusCode)).")
        }
    }

    // MARK: - Parsing

    private static func header(_ headers: [[String: Any]], _ name: String) -> String {
        headers.first {
            ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
        }?["value"] as? String ?? ""
    }

    /// "Display Name <addr@x.com>" → (name, addr); a bare address → (local, addr).
    private static func parseFrom(_ from: String) -> (name: String, email: String) {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.firstIndex(of: "<"), let close = trimmed.firstIndex(of: ">"), open < close {
            let email = String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var name = String(trimmed[..<open])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if name.isEmpty { name = email.components(separatedBy: "@").first ?? email }
            return (name, email)
        }
        let name = trimmed.components(separatedBy: "@").first ?? trimmed
        return (name, trimmed)
    }

    /// Walk the MIME tree for a text/plain part; fall back to a stripped text/html.
    private static func extractBody(_ payload: [String: Any]) -> String? {
        if let plain = findPart(payload, mime: "text/plain") {
            return plain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let html = findPart(payload, mime: "text/html") {
            return stripHTML(html)
        }
        return nil
    }

    private static func findPart(_ node: [String: Any], mime: String) -> String? {
        if (node["mimeType"] as? String) == mime,
           let body = node["body"] as? [String: Any],
           let data = body["data"] as? String,
           let decoded = decodeBase64URL(data) {
            return decoded
        }
        if let parts = node["parts"] as? [[String: Any]] {
            for part in parts {
                if let found = findPart(part, mime: mime) { return found }
            }
        }
        return nil
    }

    private static func decodeBase64URL(_ string: String) -> String? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func stripHTML(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = htmlDecoded(noTags)
        return decoded
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func htmlDecoded(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
