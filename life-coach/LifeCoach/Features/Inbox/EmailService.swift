import Foundation

/// The result of one inbox fetch: the working set of fully-fetched messages plus
/// the TRUE count of everything unread (which can be far larger than the working
/// set). The store leads with the brief over `totalUnread`, but only triages and
/// renders the messages it actually pulled down.
struct InboxFetch {
    let messages: [EmailMessage]
    let totalUnread: Int
}

/// Source of inbox email. The classifier and store depend on this abstraction;
/// `MockEmailService` backs development and the disconnected state, while the
/// live `GmailService` conforms to the same protocol once Gmail is connected.
protocol EmailService {
    /// The user's unread mail (newest-first working set) plus the total unread
    /// count across the mailbox.
    func fetchRecent() async throws -> InboxFetch
}

/// Deterministic, varied inbox covering every classification path: genuine
/// Action emails, real Human notes, actual Money movements, a Security alert,
/// and a clear majority of non-important promotions/newsletters/statements.
struct MockEmailService: EmailService {
    func fetchRecent() async throws -> InboxFetch {
        let now = Date()
        let cal = Calendar.current

        // Helper: a date `hours` ago (kept within the last 2 days).
        func ago(hours: Int) -> Date {
            cal.date(byAdding: .hour, value: -hours, to: now) ?? now
        }

        var messages: [EmailMessage] = []

        // MARK: Action (must DO something) - 3

        messages.append(EmailMessage(
            id: "m-action-payment",
            threadId: "t-action-payment",
            senderName: "Netflix",
            senderEmail: "info@account.netflix.com",
            subject: "Your payment didn't go through",
            snippet: "We couldn't process the payment for your subscription. Update your details to avoid interruption.",
            body: """
            Hi there,

            We were unable to process the payment for your Netflix subscription \
            using the card ending in 4291. Your membership will be paused on June \
            17 unless you update your payment method.

            To keep watching without interruption, please sign in and add a valid \
            payment method.

            If you've already updated your details, you can ignore this email.

            - The Netflix Team
            """,
            date: ago(hours: 3),
            isUnread: true
        ))

        messages.append(EmailMessage(
            id: "m-action-kyc",
            threadId: "t-action-kyc",
            senderName: "Wise",
            senderEmail: "noreply@wise.com",
            subject: "Action required: verify your identity to keep your account active",
            snippet: "We need a few documents to comply with regulations. Your account is limited until you verify.",
            body: """
            Hello,

            To comply with financial regulations, we need to verify your identity. \
            Until you complete verification, your account is limited and you won't \
            be able to send or receive money.

            Please upload a government-issued ID and a proof of address within 7 \
            days. It takes about 5 minutes.

            Thanks for helping us keep Wise safe,
            The Wise Team
            """,
            date: ago(hours: 9),
            isUnread: true
        ))

        messages.append(EmailMessage(
            id: "m-action-refund",
            threadId: "t-action-refund",
            senderName: "Amazon",
            senderEmail: "return@amazon.com",
            subject: "Confirm your refund method for order #112-7789",
            snippet: "Your return was received. Please confirm how you'd like to be refunded within 48 hours.",
            body: """
            Hi,

            We've received the item you returned from order #112-7789 (Anker USB-C \
            Charger). Before we issue your refund of $39.99, please confirm whether \
            you'd like it back to your original payment method or as Amazon credit.

            This choice expires in 48 hours; after that we'll default to your \
            original payment method.

            Confirm your refund method here.

            Thank you,
            Amazon Returns
            """,
            date: ago(hours: 14),
            isUnread: false
        ))

        // MARK: Human (personally written) - 2

        messages.append(EmailMessage(
            id: "m-human-friend",
            threadId: "t-human-friend",
            senderName: "Priya Nair",
            senderEmail: "priya.nair@gmail.com",
            subject: "are you around this weekend?",
            snippet: "hey! it's been ages. was thinking of doing a small dinner saturday, would love for you to come.",
            body: """
            hey you,

            it's honestly been way too long. I was just telling Sam how we keep \
            saying we'll catch up and never do, so I'm forcing the issue: I'm \
            doing a small dinner at mine this Saturday, nothing fancy, maybe 6 \
            people.

            would genuinely love for you to come. let me know if you're free and \
            I'll send the address. no pressure if not, but I'm holding a seat for \
            you until thursday :)

            miss you,
            Priya
            """,
            date: ago(hours: 5),
            isUnread: true
        ))

        messages.append(EmailMessage(
            id: "m-human-colleague",
            threadId: "t-human-colleague",
            senderName: "Marcus Lindqvist",
            senderEmail: "marcus@northwind.io",
            subject: "quick thought on the proposal",
            snippet: "Read the draft last night - really strong. One thing on the pricing section I wanted to flag before you send.",
            body: """
            Hey,

            I finally read the proposal draft last night and honestly it's really \
            strong - the framing of the problem is much tighter than the last \
            version.

            One thing before you send it: I think the pricing section undersells \
            us. We're anchoring too low and it makes the whole thing feel less \
            serious. Can we grab 15 minutes tomorrow to talk it through? I have \
            some numbers that might help.

            Either way, nice work pulling this together.

            Marcus
            """,
            date: ago(hours: 20),
            isUnread: false
        ))

        // MARK: Money (actual money moved) - 2

        messages.append(EmailMessage(
            id: "m-money-charge",
            threadId: "t-money-charge",
            senderName: "Chase",
            senderEmail: "no.reply.alerts@chase.com",
            subject: "Your card was charged $84.20",
            snippet: "A transaction of $84.20 at WHOLE FOODS MARKET was charged to your card ending 7782.",
            body: """
            Account alert

            A charge of $84.20 was made on your Chase Freedom card ending in 7782.

            Merchant: WHOLE FOODS MARKET #1042
            Date: today
            Amount: $84.20

            If you don't recognize this transaction, contact us immediately. \
            Otherwise, no action is needed.

            Chase Alerts
            """,
            date: ago(hours: 7),
            isUnread: false
        ))

        messages.append(EmailMessage(
            id: "m-money-autopay",
            threadId: "t-money-autopay",
            senderName: "PG&E",
            senderEmail: "billing@pge.com",
            subject: "Reminder: $142.66 autopay scheduled for June 16",
            snippet: "Your automatic payment of $142.66 for your June statement is scheduled in 2 days.",
            body: """
            Hello,

            This is a reminder that your scheduled automatic payment will be \
            processed soon.

            Amount: $142.66
            Payment date: June 16
            Account ending: 0098
            Funding source: Bank account ending 4410

            No action is needed - the payment will be made automatically. If you'd \
            like to change or cancel it, you can do so up to one day before the \
            payment date.

            PG&E Billing
            """,
            date: ago(hours: 11),
            isUnread: false
        ))

        // MARK: Security (login/password/suspicious) - 1

        messages.append(EmailMessage(
            id: "m-security-login",
            threadId: "t-security-login",
            senderName: "Google",
            senderEmail: "no-reply@accounts.google.com",
            subject: "Security alert: new sign-in on Windows",
            snippet: "Your Google Account was just signed in to from a new Windows device. If this was you, you can ignore this.",
            body: """
            New sign-in to your Google Account

            Your Google Account was just used to sign in from a new Windows device.

            Device: Windows
            Location: Frankfurt, Germany
            Time: today, a few minutes ago

            If this was you, you don't need to do anything. If you don't recognize \
            this activity, secure your account now - someone may have your password.

            The Google Accounts team
            """,
            date: ago(hours: 1),
            isUnread: true
        ))

        // MARK: Non-important (the majority) - 6

        messages.append(EmailMessage(
            id: "m-promo-sale",
            threadId: "t-promo-sale",
            senderName: "Nike",
            senderEmail: "news@notifications.nike.com",
            subject: "Up to 40% off — Summer styles are here ☀️",
            snippet: "Members get early access to the summer sale. Shop new arrivals and last-chance favorites.",
            body: """
            The summer sale is on.

            Members get early access to up to 40% off select styles. From running \
            essentials to everyday comfort, refresh your rotation before they're \
            gone.

            Shop the sale now. Free shipping on orders over $50.

            Unsubscribe anytime.
            """,
            date: ago(hours: 2),
            isUnread: true
        ))

        messages.append(EmailMessage(
            id: "m-newsletter-stratechery",
            threadId: "t-newsletter-stratechery",
            senderName: "Morning Brew",
            senderEmail: "crew@morningbrew.com",
            subject: "☕ The chip wars heat up",
            snippet: "Markets, tech, and business news to start your day. Plus: why everyone is suddenly talking about robotaxis.",
            body: """
            Good morning. Today we're looking at the latest twist in the \
            semiconductor race, a surprisingly strong jobs report, and why \
            robotaxis are suddenly everywhere in the headlines.

            MARKETS: Indexes closed mixed yesterday as investors weighed earnings.

            TECH: A new round of export rules is reshaping where chips get made.

            Plus the usual recommendations, a brain teaser, and today's meme.

            Read on.
            """,
            date: ago(hours: 6),
            isUnread: false
        ))

        messages.append(EmailMessage(
            id: "m-receipt-spotify",
            threadId: "t-receipt-spotify",
            senderName: "Spotify",
            senderEmail: "no-reply@spotify.com",
            subject: "Your Spotify Premium receipt",
            snippet: "Thanks for your payment. Here's your receipt for Spotify Premium Individual.",
            body: """
            Receipt

            Thanks for being a Premium member. This is your receipt - no action is \
            needed.

            Plan: Premium Individual
            Amount: $11.99
            Billing period: Jun 12 - Jul 11
            Payment method: Visa ending 4291

            You can view your full billing history anytime in your account.

            The Spotify Team
            """,
            date: ago(hours: 16),
            isUnread: false
        ))

        messages.append(EmailMessage(
            id: "m-statement-amex",
            threadId: "t-statement-amex",
            senderName: "American Express",
            senderEmail: "AmericanExpress@welcome.americanexpress.com",
            subject: "Your June statement is ready",
            snippet: "Your monthly statement is now available to view online. No payment is due yet.",
            body: """
            Your statement is ready

            Your American Express statement for the period ending June 10 is now \
            available to view online.

            New balance: $1,204.33
            Minimum due: $35.00
            Payment due date: July 5

            This is a routine notification - you can view the full statement in \
            your online account whenever you're ready.

            American Express
            """,
            date: ago(hours: 22),
            isUnread: false
        ))

        messages.append(EmailMessage(
            id: "m-social-linkedin",
            threadId: "t-social-linkedin",
            senderName: "LinkedIn",
            senderEmail: "notifications-noreply@linkedin.com",
            subject: "You appeared in 9 searches this week",
            snippet: "See who's been looking at your profile and who's searching for people like you.",
            body: """
            You're getting noticed.

            You appeared in 9 searches this week, including recruiters in your \
            industry. People are finding you - see what's drawing them in.

            See your search appearances. Upgrade to Premium to see exactly who \
            searched for you.

            LinkedIn
            """,
            date: ago(hours: 28),
            isUnread: false
        ))

        messages.append(EmailMessage(
            id: "m-promo-doordash",
            threadId: "t-promo-doordash",
            senderName: "DoorDash",
            senderEmail: "no-reply@doordash.com",
            subject: "🍔 $0 delivery fees this weekend only",
            snippet: "Your favorites, delivered for less. Enjoy $0 delivery fees on orders over $15 all weekend.",
            body: """
            The weekend just got tastier.

            Enjoy $0 delivery fees on orders over $15 from thousands of local \
            restaurants, all weekend long. No promo code needed - the discount is \
            applied automatically at checkout.

            Order now before the weekend ends.

            Manage your email preferences.
            """,
            date: ago(hours: 30),
            isUnread: true
        ))

        let sorted = messages.sorted { $0.date > $1.date }
        return InboxFetch(messages: sorted, totalUnread: sorted.count)
    }
}
