import SwiftUI

/// A single email pulled from the user's inbox (last ~2 days). Carries the FULL
/// plain-text body so the reading drawer can show the real message later - the
/// classifier only ever sees a truncated copy, but the body is preserved here.
struct EmailMessage: Codable, Identifiable, Hashable {
    let id: String
    let threadId: String
    let senderName: String      // display name, e.g. "Jordan Reyes"
    let senderEmail: String     // e.g. "jordan@acme.com"
    let subject: String
    let snippet: String         // short preview line
    let body: String            // full plain-text body
    let date: Date
    var isUnread: Bool

    init(id: String,
         threadId: String,
         senderName: String,
         senderEmail: String,
         subject: String,
         snippet: String,
         body: String,
         date: Date,
         isUnread: Bool) {
        self.id = id
        self.threadId = threadId
        self.senderName = senderName
        self.senderEmail = senderEmail
        self.subject = subject
        self.snippet = snippet
        self.body = body
        self.date = date
        self.isUnread = isUnread
    }
}

/// The four (and only four) reasons an email is "important". Each carries its
/// display label and the badge color the spec assigns it.
enum EmailCategory: String, Codable, CaseIterable, Identifiable {
    case action     // user must DO something          -> red
    case human      // written personally by a person   -> blue
    case money      // actual money moved               -> green
    case security   // login/password/suspicious access -> amber

    var id: String { rawValue }

    var label: String {
        switch self {
        case .action: return "Action"
        case .human: return "Human"
        case .money: return "Money"
        case .security: return "Security"
        }
    }

    /// The SwiftUI badge color, per spec: red / blue / green / amber.
    var badgeColor: Color {
        switch self {
        case .action: return .red
        case .human: return .blue
        case .money: return .green
        case .security: return Color(red: 1.0, green: 0.75, blue: 0.0) // amber
        }
    }
}

/// An `EmailMessage` paired with the classifier's verdict. Non-important emails
/// have `category == nil` and an empty `reason`; their `summary` is one line.
/// Important emails carry a category, a one-line `reason`, and a 2-3 line `summary`.
struct ClassifiedEmail: Codable, Identifiable, Hashable {
    let email: EmailMessage
    let important: Bool
    let category: EmailCategory?
    let reason: String      // one line, only meaningful when important
    let summary: String     // 2-3 lines if important, 1 line otherwise

    var id: String { email.id }

    init(email: EmailMessage,
         important: Bool,
         category: EmailCategory?,
         reason: String,
         summary: String) {
        self.email = email
        self.important = important
        self.category = category
        self.reason = reason
        self.summary = summary
    }
}
