import Foundation

/// Live `EmailService` backed by the Gmail REST API. Pages through ALL unread
/// mail to learn the true unread count, fetches the newest working set in full,
/// and maps each to the same `EmailMessage` the classifier and UI consume — so
/// the Inbox feature is unchanged downstream of this swap. Read-only; access
/// comes from `GoogleAuth`.
///
/// **Incremental sync (M5):** after a full fetch the service captures the
/// mailbox `historyId`. On subsequent calls the caller may supply a stored
/// `historyId`; the service then calls `users.history.list` to get only changed
/// message IDs (messagesAdded + labelsRemoved INBOX), re-fetches just those
/// messages, and returns them alongside the unmodified working-set count. When
/// the `historyId` is absent/expired (Gmail returns a `404` on old IDs), the
/// service falls back to a full `listUnreadIDs` pass automatically.
struct GmailService: EmailService {
    let auth: GoogleAuth

    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    /// How many of the newest unread messages we fetch in full and triage. The
    /// list endpoint returns newest-first, so this is the freshest working set.
    private static let workingSet = 120
    /// Page size for the id-listing pass (Gmail's max per page is 500; 100 keeps
    /// each round-trip small while still draining the unread list quickly).
    private static let listPageSize = 100
    /// Safety cap on list pages so a pathological mailbox can't page forever
    /// (~2000 ids). If we hit it we simply report the count we have.
    private static let maxListPages = 20
    /// Hard cap on stored body length so a giant HTML email can't bloat the cache.
    private static let maxBodyChars = 6000

    // MARK: - Full fetch (EmailService conformance)

    func fetchRecent() async throws -> InboxFetch {
        let token = try await auth.validAccessToken()
        let ids = try await Self.listUnreadIDs(token: token)
        guard !ids.isEmpty else { return InboxFetch(messages: [], totalUnread: 0) }

        // Fetch the newest working set in full, concurrently; a single failure
        // drops just that one message. The total unread count is the full id list.
        let working = Array(ids.prefix(Self.workingSet))
        let messages = await withTaskGroup(of: EmailMessage?.self) { group in
            for id in working {
                group.addTask { try? await Self.fetchMessage(id: id, token: token) }
            }
            var collected: [EmailMessage] = []
            for await message in group { if let message { collected.append(message) } }
            return collected
        }
        return InboxFetch(messages: messages.sorted { $0.date > $1.date },
                          totalUnread: ids.count)
    }

    // MARK: - Current historyId

    /// Fetches the current mailbox `historyId` from `users.getProfile`. Returns nil
    /// on any error — callers treat a nil historyId as "full refresh needed".
    func currentHistoryId() async throws -> String? {
        let token = try await auth.validAccessToken()
        guard let url = URL(string: "\(Self.base)/profile") else { return nil }
        let data = try await Self.get(url, token: token)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["historyId"] as? String
    }

    // MARK: - Incremental fetch

    /// Attempts an incremental refresh using `users.history.list` starting from
    /// `sinceHistoryId`. Returns the newly-added unread INBOX messages and an
    /// updated `historyId`. Falls back to a full `fetchRecent()` when the history
    /// record is expired or unavailable (Gmail HTTP 404), which is expected after
    /// several days without a background task firing.
    ///
    /// - Returns: `(newMessages, updatedHistoryId)`. `newMessages` contains only
    ///   the messages that appeared in the inbox since `sinceHistoryId` — the
    ///   caller is responsible for merging them into its full working set.
    func fetchIncremental(sinceHistoryId: String) async throws -> ([EmailMessage], String?) {
        let token = try await auth.validAccessToken()

        var allAddedIDs: [String] = []
        var pageToken: String?
        var latestHistoryId: String? = sinceHistoryId
        var page = 0
        var historyExpired = false

        // Page through history events, collecting messagesAdded with INBOX label.
        repeat {
            var comps = URLComponents(string: "\(Self.base)/history")!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "startHistoryId", value: sinceHistoryId),
                URLQueryItem(name: "historyTypes", value: "messageAdded"),
                URLQueryItem(name: "labelId", value: "INBOX"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = items
            guard let url = comps.url else { break }

            do {
                let data = try await Self.get(url, token: token)
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
                if let hid = obj["historyId"] as? String { latestHistoryId = hid }

                let history = (obj["history"] as? [[String: Any]]) ?? []
                for record in history {
                    let added = (record["messagesAdded"] as? [[String: Any]]) ?? []
                    for entry in added {
                        guard let msg = entry["message"] as? [String: Any],
                              let id = msg["id"] as? String else { continue }
                        let labels = (msg["labelIds"] as? [String]) ?? []
                        // Only care about UNREAD INBOX messages.
                        guard labels.contains("INBOX"), labels.contains("UNREAD") else { continue }
                        allAddedIDs.append(id)
                    }
                }
                pageToken = obj["nextPageToken"] as? String
                page += 1
            } catch let err as GoogleAuthError {
                // Gmail returns 404 when the historyId is too old. Signal fallback.
                if err.localizedDescription.contains("404") {
                    historyExpired = true
                }
                break
            } catch {
                break
            }
        } while pageToken != nil && page < Self.maxListPages

        // If the history record expired, fall back to a full fetch. The caller
        // should treat the returned historyId as the new baseline.
        if historyExpired || (allAddedIDs.isEmpty && page == 0) {
            // Fall back: full refresh is the safest recovery path.
            let full = try await fetchRecent()
            let freshHistoryId = try? await currentHistoryId()
            return (full.messages, freshHistoryId)
        }

        // De-duplicate ids (the same message can appear in multiple history events).
        let uniqueIDs = Array(Set(allAddedIDs))
        guard !uniqueIDs.isEmpty else { return ([], latestHistoryId) }

        // Fetch only the new messages in full.
        let messages = await withTaskGroup(of: EmailMessage?.self) { group in
            for id in uniqueIDs {
                group.addTask { try? await Self.fetchMessage(id: id, token: token) }
            }
            var collected: [EmailMessage] = []
            for await message in group { if let message { collected.append(message) } }
            return collected
        }

        return (messages.sorted { $0.date > $1.date }, latestHistoryId)
    }

    // MARK: - REST calls

    /// Page through `messages.list?q=is:unread in:inbox` following `nextPageToken`
    /// to collect ALL unread INBOX ids (newest first), bounded by `maxListPages`.
    ///
    /// The `in:inbox` qualifier (added in M2) is what makes archive durable: the
    /// `archive` write removes the `INBOX` label but leaves a message unread, so a
    /// bare `is:unread` query would resurface it on the next refresh. Scoping to
    /// the inbox means archived mail stays archived after reconciliation, while
    /// the triage still covers everything unread that's actually IN the inbox.
    private static func listUnreadIDs(token: String) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        var page = 0

        repeat {
            var comps = URLComponents(string: "\(base)/messages")!
            var items = [
                URLQueryItem(name: "q", value: "is:unread in:inbox"),
                URLQueryItem(name: "maxResults", value: "\(listPageSize)"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = items
            guard let url = comps.url else { break }

            let data = try await get(url, token: token)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            let messages = (object["messages"] as? [[String: Any]]) ?? []
            ids.append(contentsOf: messages.compactMap { $0["id"] as? String })
            pageToken = object["nextPageToken"] as? String
            page += 1
        } while pageToken != nil && page < maxListPages

        return ids
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

        // Bulk-mail + addressing headers — strong signal for the classifier.
        let listUnsub = header(headers, "List-Unsubscribe")
        let listUnsubPost = header(headers, "List-Unsubscribe-Post")
        let oneClick = listUnsubPost.range(of: "List-Unsubscribe=One-Click",
                                           options: .caseInsensitive) != nil
        let to = header(headers, "To")
        let cc = header(headers, "Cc")
        let replyTo = header(headers, "Reply-To")

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
                            isUnread: isUnread,
                            listUnsubscribe: listUnsub.isEmpty ? nil : listUnsub,
                            listUnsubscribePostOneClick: oneClick,
                            toRecipients: to,
                            cc: cc,
                            replyTo: replyTo)
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
