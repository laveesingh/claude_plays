import SwiftUI

/// A single email pulled from the user's inbox. Carries the FULL plain-text body
/// so the reading drawer can show the real message - the classifier only ever
/// sees a truncated copy, but the body is preserved here. The bulk-mail headers
/// (`List-Unsubscribe`, recipients, reply-to) are kept so the classifier can tell
/// a real person from a mailing list without guessing.
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

    /// Raw `List-Unsubscribe` header, if present - a strong "this is bulk" signal.
    let listUnsubscribe: String?
    /// True when `List-Unsubscribe-Post` advertises `List-Unsubscribe=One-Click`.
    let listUnsubscribePostOneClick: Bool
    /// Raw `To` header (recipients) - helps tell direct mail from a blast.
    let toRecipients: String
    /// Raw `Cc` header.
    let cc: String
    /// Raw `Reply-To` header.
    let replyTo: String

    /// Whether this looks like bulk mail (carries an unsubscribe affordance).
    var hasUnsubscribe: Bool {
        !(listUnsubscribe ?? "").isEmpty || listUnsubscribePostOneClick
    }

    init(id: String,
         threadId: String,
         senderName: String,
         senderEmail: String,
         subject: String,
         snippet: String,
         body: String,
         date: Date,
         isUnread: Bool,
         listUnsubscribe: String? = nil,
         listUnsubscribePostOneClick: Bool = false,
         toRecipients: String = "",
         cc: String = "",
         replyTo: String = "") {
        self.id = id
        self.threadId = threadId
        self.senderName = senderName
        self.senderEmail = senderEmail
        self.subject = subject
        self.snippet = snippet
        self.body = body
        self.date = date
        self.isUnread = isUnread
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePostOneClick = listUnsubscribePostOneClick
        self.toRecipients = toRecipients
        self.cc = cc
        self.replyTo = replyTo
    }

    enum CodingKeys: String, CodingKey {
        case id, threadId, senderName, senderEmail, subject, snippet, body, date, isUnread
        case listUnsubscribe, listUnsubscribePostOneClick, toRecipients, cc, replyTo
    }

    /// Tolerant decode: the bulk-mail fields were added after the first caches
    /// shipped, so an older `inbox-cache.json` lacks them - default rather than
    /// throw, which would wipe the whole cache.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        threadId = try c.decode(String.self, forKey: .threadId)
        senderName = try c.decode(String.self, forKey: .senderName)
        senderEmail = try c.decode(String.self, forKey: .senderEmail)
        subject = try c.decode(String.self, forKey: .subject)
        snippet = try c.decode(String.self, forKey: .snippet)
        body = try c.decode(String.self, forKey: .body)
        date = try c.decode(Date.self, forKey: .date)
        isUnread = try c.decode(Bool.self, forKey: .isUnread)
        listUnsubscribe = try c.decodeIfPresent(String.self, forKey: .listUnsubscribe)
        listUnsubscribePostOneClick = try c.decodeIfPresent(Bool.self, forKey: .listUnsubscribePostOneClick) ?? false
        toRecipients = try c.decodeIfPresent(String.self, forKey: .toRecipients) ?? ""
        cc = try c.decodeIfPresent(String.self, forKey: .cc) ?? ""
        replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo) ?? ""
    }
}

// MARK: - Lanes

/// The eight triage lanes the Inbox sorts mail into. A lane is the coarse "where
/// does this belong" bucket; `EmailCategory` is the fine reason inside it. Each
/// lane owns its display identity (title / color / icon) and a `sortPriority`
/// that fixes its position in the list and the filter chip row - lower is higher,
/// `noise` always last.
enum InboxLane: String, Codable, CaseIterable, Identifiable {
    case needsYou
    case waiting
    case people
    case money
    case security
    case calendar
    case orders
    case noise

    var id: String { rawValue }

    /// The section / chip title shown to the user.
    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .waiting: return "Waiting on you"
        case .people: return "People"
        case .money: return "Money"
        case .security: return "Security"
        case .calendar: return "Calendar & travel"
        case .orders: return "Orders"
        case .noise: return "Everything else"
        }
    }

    /// The lane's accent color, used for chips, section headers, and badges.
    var color: Color {
        switch self {
        case .needsYou: return .red
        case .waiting: return .orange
        case .people: return .blue
        case .money: return .green
        case .security: return Color(red: 1.0, green: 0.75, blue: 0.0) // amber
        case .calendar: return .purple
        case .orders: return .teal
        case .noise: return .gray
        }
    }

    var systemImage: String {
        switch self {
        case .needsYou: return "exclamationmark.circle.fill"
        case .waiting: return "arrowshape.turn.up.left.fill"
        case .people: return "person.fill"
        case .money: return "dollarsign.circle.fill"
        case .security: return "lock.shield.fill"
        case .calendar: return "calendar"
        case .orders: return "shippingbox.fill"
        case .noise: return "tray.full.fill"
        }
    }

    /// List ordering - lower surfaces higher; `noise` is pinned last.
    var sortPriority: Int {
        switch self {
        case .needsYou: return 0
        case .waiting: return 1
        case .security: return 2
        case .money: return 3
        case .people: return 4
        case .calendar: return 5
        case .orders: return 6
        case .noise: return 7
        }
    }

    /// Non-noise lanes render as rich attention cards; noise renders as compact
    /// rows. Centralized here so the view and section logic agree.
    var usesCard: Bool { self != .noise }
}

// MARK: - Categories

/// The fine-grained reason an email landed where it did. Every category maps to
/// exactly one `InboxLane`. The classifier emits these exact rawValues; the lane
/// (and therefore importance) is derived from the category.
///
/// The four `legacy*` cases preserve the original taxonomy's rawValues
/// (`action`/`human`/`money`/`security`) so an older `inbox-cache.json` still
/// decodes; they map onto the closest new lane.
enum EmailCategory: String, Codable, CaseIterable, Identifiable {
    // needsYou
    case failedPayment
    case duePayment
    case kyc
    case deadline
    case accountIssue
    case rsvp
    // waiting
    case replyRequested
    case questionPending
    // people
    case personal
    case work
    case recruiter
    case coldOutreach
    // money
    case charge
    case statement
    case receipt
    case refund
    case invoice
    case renewal
    case fraud
    // security
    case loginAlert
    case passwordChange
    case suspiciousAccess
    case twoFactor
    // calendar & travel
    case calendarInvite
    case reschedule
    case itinerary
    case booking
    // orders
    case shipping
    case orderConfirm
    case returnUpdate
    // noise
    case newsletter
    case promotion
    case socialNotification
    case productUpdate
    case digest

    // Legacy rawValues from the original four-category taxonomy.
    case legacyAction = "action"
    case legacyHuman = "human"
    case legacyMoney = "money"
    case legacySecurity = "security"

    var id: String { rawValue }

    /// The lane this category belongs to.
    var lane: InboxLane {
        switch self {
        case .failedPayment, .duePayment, .kyc, .deadline, .accountIssue, .rsvp:
            return .needsYou
        case .replyRequested, .questionPending:
            return .waiting
        case .personal, .work, .recruiter, .coldOutreach:
            return .people
        case .charge, .statement, .receipt, .refund, .invoice, .renewal, .fraud:
            return .money
        case .loginAlert, .passwordChange, .suspiciousAccess, .twoFactor:
            return .security
        case .calendarInvite, .reschedule, .itinerary, .booking:
            return .calendar
        case .shipping, .orderConfirm, .returnUpdate:
            return .orders
        case .newsletter, .promotion, .socialNotification, .productUpdate, .digest:
            return .noise
        // Legacy mappings.
        case .legacyAction: return .needsYou
        case .legacyHuman: return .people
        case .legacyMoney: return .money
        case .legacySecurity: return .security
        }
    }

    /// A short human label for the badge.
    var label: String {
        switch self {
        case .failedPayment: return "Failed payment"
        case .duePayment: return "Payment due"
        case .kyc: return "Verify identity"
        case .deadline: return "Deadline"
        case .accountIssue: return "Account issue"
        case .rsvp: return "RSVP"
        case .replyRequested: return "Reply requested"
        case .questionPending: return "Question"
        case .personal: return "Personal"
        case .work: return "Work"
        case .recruiter: return "Recruiter"
        case .coldOutreach: return "Outreach"
        case .charge: return "Charge"
        case .statement: return "Statement"
        case .receipt: return "Receipt"
        case .refund: return "Refund"
        case .invoice: return "Invoice"
        case .renewal: return "Renewal"
        case .fraud: return "Fraud alert"
        case .loginAlert: return "New sign-in"
        case .passwordChange: return "Password"
        case .suspiciousAccess: return "Suspicious access"
        case .twoFactor: return "2FA"
        case .calendarInvite: return "Invite"
        case .reschedule: return "Reschedule"
        case .itinerary: return "Itinerary"
        case .booking: return "Booking"
        case .shipping: return "Shipping"
        case .orderConfirm: return "Order"
        case .returnUpdate: return "Return"
        case .newsletter: return "Newsletter"
        case .promotion: return "Promotion"
        case .socialNotification: return "Notification"
        case .productUpdate: return "Update"
        case .digest: return "Digest"
        case .legacyAction: return "Action"
        case .legacyHuman: return "Human"
        case .legacyMoney: return "Money"
        case .legacySecurity: return "Security"
        }
    }

    /// The badge color - inherited from the lane so the two never drift.
    var badgeColor: Color { lane.color }

    /// True for the four `legacy*` cases that only exist so old caches decode. They
    /// are never offered in the preferences UI (the user can't pick them).
    var isLegacy: Bool {
        switch self {
        case .legacyAction, .legacyHuman, .legacyMoney, .legacySecurity: return true
        default: return false
        }
    }

    /// The real, user-selectable categories grouped by lane in lane priority order —
    /// what the Inbox preferences sheet lists for elevate / suppress.
    static var assignable: [EmailCategory] {
        allCases
            .filter { !$0.isLegacy }
            .sorted {
                if $0.lane.sortPriority != $1.lane.sortPriority {
                    return $0.lane.sortPriority < $1.lane.sortPriority
                }
                return $0.rawValue < $1.rawValue
            }
    }
}

// MARK: - Classified email

/// An `EmailMessage` paired with the classifier's verdict. The `lane` is the
/// source of truth for where the email belongs; `important` is derived from it
/// (anything outside `noise` is important) so existing consumers - notably
/// `HomeView`'s glance - keep working unchanged.
struct ClassifiedEmail: Codable, Identifiable, Hashable {
    let email: EmailMessage
    let lane: InboxLane
    let category: EmailCategory?
    let confidence: Double      // 0...1, the classifier's certainty
    let waitingOnYou: Bool      // a real person is awaiting THIS user's reply
    let reason: String          // one line, only meaningful when non-noise
    let summary: String         // 2-3 lines if non-noise, 1 line otherwise

    var id: String { email.id }

    /// Anything that isn't pure noise is "important". Kept as a derived value so
    /// `HomeView` (which filters on `important`) needs no changes.
    var important: Bool { lane != .noise }

    init(email: EmailMessage,
         lane: InboxLane,
         category: EmailCategory?,
         confidence: Double,
         waitingOnYou: Bool,
         reason: String,
         summary: String) {
        self.email = email
        self.lane = lane
        self.category = category
        self.confidence = confidence
        self.waitingOnYou = waitingOnYou
        self.reason = reason
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case email, lane, category, confidence, waitingOnYou, reason, summary
    }

    /// A copy with a replaced underlying message, preserving the verdict. Used by
    /// the store's optimistic local edits (e.g. mark read/unread), which only flip
    /// a field on `email` without re-running the classifier.
    func withEmail(_ newEmail: EmailMessage) -> ClassifiedEmail {
        ClassifiedEmail(email: newEmail,
                        lane: lane,
                        category: category,
                        confidence: confidence,
                        waitingOnYou: waitingOnYou,
                        reason: reason,
                        summary: summary)
    }

    /// A copy re-filed into `newLane`, keeping the fine category and summary. Used by
    /// `InboxRanker` to apply the user's HARD preference overrides (mute → noise,
    /// VIP → out of noise, keyword force, category elevate/suppress) on top of the
    /// classifier's verdict. Filing into noise clears the waiting flag and reason,
    /// which only make sense on attention mail.
    func withLane(_ newLane: InboxLane) -> ClassifiedEmail {
        guard newLane != lane else { return self }
        let goingToNoise = newLane == .noise
        return ClassifiedEmail(email: email,
                               lane: newLane,
                               category: category,
                               confidence: confidence,
                               waitingOnYou: goingToNoise ? false : waitingOnYou,
                               reason: goingToNoise ? "" : reason,
                               summary: summary)
    }

    /// Tolerant decode: old caches predate `lane`/`confidence`/`waitingOnYou` and
    /// stored the legacy category rawValues. Default every new field, and recover
    /// the lane from the category when the cache has no explicit lane so an old
    /// important email upgrades cleanly instead of falling into noise. An UNKNOWN
    /// category rawValue decodes to nil rather than throwing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decode(EmailMessage.self, forKey: .email)

        if let raw = try c.decodeIfPresent(String.self, forKey: .category) {
            category = EmailCategory(rawValue: raw)
        } else {
            category = nil
        }

        if let decodedLane = try c.decodeIfPresent(InboxLane.self, forKey: .lane) {
            lane = decodedLane
        } else {
            lane = category?.lane ?? .noise
        }

        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        waitingOnYou = try c.decodeIfPresent(Bool.self, forKey: .waitingOnYou) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }
}
