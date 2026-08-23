import Foundation

/// Live Gmail WRITE actions — the companion to the read-only `GmailService`. Every
/// authenticated call reuses the same `GoogleAuth` token and the same 401/403
/// handling the read path uses, but raised as the typed
/// `InboxToolError.needsReconnect` so the capability layer and UI can turn it into
/// a "Reconnect Gmail to enable actions" prompt instead of silently failing.
///
/// These calls require the `gmail.modify` scope (a superset of `gmail.readonly`).
/// An existing read-only token 403s here until the user re-consents. Unsubscribe
/// is the exception: it talks to the SENDER's endpoint, needs no Google scope, and
/// carries no Authorization header.
///
/// Mirrors `GmailService`: a plain value type whose async methods only hop to the
/// main actor to read the access token. The read paths are untouched.
struct GmailWriteService {
    let auth: GoogleAuth

    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    // MARK: - Read / unread / archive

    /// Remove the `UNREAD` label → the message reads as read in Gmail.
    func markRead(id: String) async throws {
        try await modify(id: id, addLabelIds: [], removeLabelIds: ["UNREAD"])
    }

    /// Re-add the `UNREAD` label (the undo of `markRead`).
    func markUnread(id: String) async throws {
        try await modify(id: id, addLabelIds: ["UNREAD"], removeLabelIds: [])
    }

    /// Remove the `INBOX` label → the message is archived out of the inbox.
    func archive(id: String) async throws {
        try await modify(id: id, addLabelIds: [], removeLabelIds: ["INBOX"])
    }

    /// Re-add the `INBOX` label (the undo of `archive`).
    func unarchive(id: String) async throws {
        try await modify(id: id, addLabelIds: ["INBOX"], removeLabelIds: [])
    }

    // MARK: - Labels

    /// Ensure a user label named `labelName` exists (creating it if missing), then
    /// add it to the given message. Reserved for the mute / auto-file flows landing
    /// in M4 — it is wired and correct but not yet invoked by a tool this
    /// milestone (snooze is purely local, see `InboxStore`).
    func apply(labelName: String, toID id: String) async throws {
        let labelId = try await ensureLabel(named: labelName)
        try await modify(id: id, addLabelIds: [labelId], removeLabelIds: [])
    }

    /// The id of the user label named `name`, creating the label if it doesn't
    /// already exist. The match against existing labels is case-insensitive on the
    /// display name.
    func ensureLabel(named name: String) async throws -> String {
        guard let listURL = URL(string: "\(Self.base)/labels") else {
            throw InboxToolError.gmail("Couldn't build the labels URL.")
        }
        let data = try await send(listURL, method: "GET", jsonBody: nil)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let labels = object["labels"] as? [[String: Any]],
           let match = labels.first(where: {
               ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
           }),
           let id = match["id"] as? String {
            return id
        }
        // Not found — create it.
        let created = try await send(listURL, method: "POST", jsonBody: [
            "name": name,
            "labelListVisibility": "labelShow",
            "messageListVisibility": "show",
        ])
        guard let object = try? JSONSerialization.jsonObject(with: created) as? [String: Any],
              let id = object["id"] as? String else {
            throw InboxToolError.gmail("Couldn't create the \"\(name)\" label.")
        }
        return id
    }

    // MARK: - Unsubscribe

    /// What an unsubscribe attempt produced.
    enum UnsubscribeResult {
        /// RFC 8058 one-click POST succeeded — fully done, nothing for the UI to do.
        case oneClickDone
        /// No one-click path; the UI should OPEN this link (https page or mailto:).
        case openURL(URL)
        /// The message carried no usable unsubscribe target.
        case none
    }

    /// Unsubscribe from a bulk sender. Needs NO Google scope — it talks to the
    /// sender's own endpoint. When the message advertises one-click
    /// (`List-Unsubscribe-Post: List-Unsubscribe=One-Click`) AND exposes an https
    /// target, perform the RFC 8058 POST directly. Otherwise hand the best link
    /// back (https preferred, else mailto:) for the UI to open.
    func unsubscribe(message: EmailMessage) async throws -> UnsubscribeResult {
        let targets = Self.parseListUnsubscribe(message.listUnsubscribe ?? "")
        let web = targets.first { $0.scheme == "https" || $0.scheme == "http" }
        let mailto = targets.first { $0.scheme == "mailto" }

        if message.listUnsubscribePostOneClick, let web {
            try await postOneClick(web.url)
            return .oneClickDone
        }
        if let web { return .openURL(web.url) }
        if let mailto { return .openURL(mailto.url) }
        return .none
    }

    /// Parse a raw `List-Unsubscribe` header into its angle-bracketed targets, in
    /// header order — e.g. `<https://x/u?z>, <mailto:u@x?subject=...>`.
    static func parseListUnsubscribe(_ raw: String) -> [(scheme: String, url: URL)] {
        guard !raw.isEmpty,
              let regex = try? NSRegularExpression(pattern: "<([^>]+)>") else { return [] }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        var result: [(scheme: String, url: URL)] = []
        for match in matches {
            let inner = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: inner) else { continue }
            result.append((scheme: (url.scheme ?? "").lowercased(), url: url))
        }
        return result
    }

    /// RFC 8058 one-click POST to the sender's https endpoint. Deliberately sends
    /// NO Authorization header — this is the sender's server, not Google's.
    private func postOneClick(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "List-Unsubscribe=One-Click".data(using: .utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw InboxToolError.gmail("The unsubscribe request was rejected by the sender.")
        }
    }

    // MARK: - REST plumbing

    /// `users.messages.modify` — add and/or remove label ids on a message.
    private func modify(id: String, addLabelIds: [String], removeLabelIds: [String]) async throws {
        var body: [String: Any] = [:]
        if !addLabelIds.isEmpty { body["addLabelIds"] = addLabelIds }
        if !removeLabelIds.isEmpty { body["removeLabelIds"] = removeLabelIds }
        guard let url = URL(string: "\(Self.base)/messages/\(id)/modify") else {
            throw InboxToolError.gmail("Couldn't build the modify URL.")
        }
        _ = try await send(url, method: "POST", jsonBody: body)
    }

    /// Shared authenticated request to the Gmail REST API. Attaches a fresh Bearer
    /// token (plus a JSON content type when there's a body) and maps 401/403 to the
    /// reconnect-required error, exactly like the read path's `GmailService.get`.
    @discardableResult
    private func send(_ url: URL, method: String, jsonBody: [String: Any]?) async throws -> Data {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw InboxToolError.gmail("No response from Gmail.")
        }
        switch http.statusCode {
        case 200, 201, 204: return data
        case 401, 403: throw InboxToolError.needsReconnect
        default: throw InboxToolError.gmail("Gmail request failed (HTTP \(http.statusCode)).")
        }
    }
}
