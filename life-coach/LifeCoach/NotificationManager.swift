import Foundation
import UserNotifications

enum NotificationManager {
    static let blockCheckinCategory = "BLOCK_CHECKIN"
    static let actionDone = "BLOCK_DONE"
    static let actionMissed = "BLOCK_MISSED"
    static let actionSnooze = "BLOCK_SNOOZE"

    static func registerCategories() {
        let done = UNNotificationAction(identifier: actionDone, title: "Done ✓")
        let missed = UNNotificationAction(identifier: actionMissed, title: "Missed ✗",
                                          options: [.destructive])
        let snooze = UNNotificationAction(identifier: actionSnooze, title: "Ask me in 15 min")
        let category = UNNotificationCategory(
            identifier: blockCheckinCategory,
            actions: [done, missed, snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: - Daily rituals

    static func scheduleDailyCheckIns(morningHour: Int, eveningHour: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [
            "morning-checkin", "evening-checkin", "weekly-review",
        ])

        let morning = UNMutableNotificationContent()
        morning.title = "Morning brief"
        morning.body = "Your coach is ready to timebox your day. Report in."
        morning.sound = .default
        var morningComponents = DateComponents()
        morningComponents.hour = morningHour
        morningComponents.minute = 0
        center.add(UNNotificationRequest(
            identifier: "morning-checkin",
            content: morning,
            trigger: UNCalendarNotificationTrigger(dateMatching: morningComponents, repeats: true)
        ))

        let evening = UNMutableNotificationContent()
        evening.title = "Evening debrief"
        evening.body = "Time to report in. The coach already knows what was on the schedule."
        evening.sound = .default
        var eveningComponents = DateComponents()
        eveningComponents.hour = eveningHour
        eveningComponents.minute = 0
        center.add(UNNotificationRequest(
            identifier: "evening-checkin",
            content: evening,
            trigger: UNCalendarNotificationTrigger(dateMatching: eveningComponents, repeats: true)
        ))

        let weekly = UNMutableNotificationContent()
        weekly.title = "Weekly review"
        weekly.body = "Sit down with your coach: full audit of the week, report card, next week's targets."
        weekly.sound = .default
        var weeklyComponents = DateComponents()
        weeklyComponents.weekday = 1 // Sunday
        weeklyComponents.hour = max(eveningHour - 1, 12)
        weeklyComponents.minute = 0
        center.add(UNNotificationRequest(
            identifier: "weekly-review",
            content: weekly,
            trigger: UNCalendarNotificationTrigger(dateMatching: weeklyComponents, repeats: true)
        ))
    }

    // MARK: - Block pings

    /// Clears previously scheduled block pings for the day, then schedules a
    /// pre-start reminder and an interactive end-of-block check-in for every
    /// block that is still in the future.
    static func scheduleBlockCheckins(for blocks: [TimeBlock], dateKey: String) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let stale = requests
                .map { $0.identifier }
                .filter { $0.hasPrefix("block-") }
            center.removePendingNotificationRequests(withIdentifiers: stale)

            let calendar = Calendar.current
            let now = Date()
            let nowMinutes = calendar.component(.hour, from: now) * 60
                + calendar.component(.minute, from: now)

            for block in blocks where block.status == .planned {
                // Pre-start reminder, 5 minutes before.
                let warnMinutes = block.startMinutes - 5
                if warnMinutes > nowMinutes {
                    let content = UNMutableNotificationContent()
                    content.title = "Up next: \(block.title)"
                    content.body = "Starts at \(TimeBlock.clock(block.startMinutes)). Set up now."
                    content.sound = .default
                    var components = calendar.dateComponents([.year, .month, .day], from: now)
                    components.hour = warnMinutes / 60
                    components.minute = warnMinutes % 60
                    center.add(UNNotificationRequest(
                        identifier: "block-warn-\(block.id.uuidString)",
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    ))
                }

                // Interactive end-of-block check-in.
                if block.endMinutes > nowMinutes, block.endMinutes < 24 * 60 {
                    let content = UNMutableNotificationContent()
                    content.title = "Block ended: \(block.title)"
                    content.body = "Did it happen? Answer honestly — the record is the record."
                    content.sound = .default
                    content.categoryIdentifier = blockCheckinCategory
                    content.userInfo = ["blockID": block.id.uuidString, "dateKey": dateKey]
                    var components = calendar.dateComponents([.year, .month, .day], from: now)
                    components.hour = block.endMinutes / 60
                    components.minute = block.endMinutes % 60
                    center.add(UNNotificationRequest(
                        identifier: "block-end-\(block.id.uuidString)",
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    ))
                }
            }
        }
    }

    static func snoozeBlockCheckin(blockID: String, dateKey: String, title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Still waiting: \(title)"
        content.body = "You asked for 15 minutes. Did it happen?"
        content.sound = .default
        content.categoryIdentifier = blockCheckinCategory
        content.userInfo = ["blockID": blockID, "dateKey": dateKey]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 15 * 60, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "block-snooze-\(blockID)-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        ))
    }

    /// One-off nudge scheduled by the coach.
    static func scheduleNudge(message: String, hour: Int, minute: Int, tomorrow: Bool) -> Bool {
        let calendar = Calendar.current
        var base = Date()
        if tomorrow {
            guard let next = calendar.date(byAdding: .day, value: 1, to: base) else { return false }
            base = next
        }
        var components = calendar.dateComponents([.year, .month, .day], from: base)
        components.hour = hour
        components.minute = minute
        guard let fireDate = calendar.date(from: components), fireDate > Date() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Your coach"
        content.body = message
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "nudge-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        ))
        return true
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // MARK: - Inbox watch (M5)

    /// Fires a local notification summarising newly-arrived important mail. De-duplication
    /// (so the same message never triggers two banners) is the caller's responsibility —
    /// `InboxStore.backgroundRefresh()` tracks notified IDs and only passes truly new items.
    ///
    /// The notification body names the top two senders / subjects so the user knows at a
    /// glance whether it's worth opening the app.
    ///
    /// - Parameters:
    ///   - items: Newly-arrived important classified emails (caller guarantees non-empty).
    static func fireImportantMailAlert(for items: [ClassifiedEmail]) {
        guard !items.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.sound = .default

        let count = items.count
        if count == 1 {
            let item = items[0]
            content.title = "New message from \(item.email.senderName)"
            content.body = item.email.subject.isEmpty ? item.email.snippet : item.email.subject
        } else {
            content.title = "\(count) things need your attention"
            // Name the top two senders.
            let top = items.prefix(2).map { $0.email.senderName }.joined(separator: " + ")
            let extra = count > 2 ? " and \(count - 2) more" : ""
            content.body = "\(top)\(extra)"
        }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "inbox-alert-\(UUID().uuidString)",
                content: content,
                trigger: nil  // deliver immediately
            )
        )
    }

    /// Schedules (or cancels) the repeating daily inbox-brief notification. Removes any
    /// previously scheduled daily-brief request so a changed hour takes effect at once.
    ///
    /// - Parameters:
    ///   - hour: The hour (0–23) to fire, or nil to cancel.
    ///   - brief: The brief line to use as the notification body.
    static func scheduleInboxDailyBrief(hour: Int?, brief: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["inbox-daily-brief"])
        guard let hour else { return }

        let content = UNMutableNotificationContent()
        content.title = "Daily inbox brief"
        content.body = brief.isEmpty ? "Your inbox summary is ready." : brief
        content.sound = .default

        var comps = DateComponents()
        comps.hour = hour
        comps.minute = 0
        center.add(UNNotificationRequest(
            identifier: "inbox-daily-brief",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        ))
    }

    /// Schedules (or re-schedules) the repeating weekly inbox-recap notification,
    /// firing every Sunday at 7 PM. The body summarises the week's sender activity
    /// drawn from `SenderMemory` — specifically how many unique senders were seen,
    /// how many opened vs archived.
    ///
    /// - Parameter senderMemory: The store's current sender stats.
    static func scheduleInboxWeeklyRecap(senderMemory: SenderMemory) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["inbox-weekly-recap"])

        let totalSenders = senderMemory.senders.count
        let opened = senderMemory.senders.values.filter { $0.opened > 0 }.count
        let ignored = senderMemory.senders.values.filter { $0.opened == 0 && $0.archived > 0 }.count

        let content = UNMutableNotificationContent()
        content.title = "Weekly inbox recap"
        if totalSenders == 0 {
            content.body = "Your inbox week in review is ready."
        } else {
            content.body = "Opened from \(opened) senders, silently filed \(ignored). Tap to review."
        }
        content.sound = .default

        var comps = DateComponents()
        comps.weekday = 1   // Sunday
        comps.hour = 19     // 7 PM
        comps.minute = 0
        center.add(UNNotificationRequest(
            identifier: "inbox-weekly-recap",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        ))
    }
}

/// Routes notification taps and lock-screen actions back into app state.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    /// Set once at app startup.
    var store: AppStore?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier

        guard let blockIDString = userInfo["blockID"] as? String,
              let blockID = UUID(uuidString: blockIDString),
              let dateKey = userInfo["dateKey"] as? String else {
            completionHandler()
            return
        }

        let title = response.notification.request.content.title

        Task { @MainActor in
            switch action {
            case NotificationManager.actionDone:
                self.store?.setBlockStatus(blockID: blockID, dateKey: dateKey, status: .done)
            case NotificationManager.actionMissed:
                self.store?.setBlockStatus(blockID: blockID, dateKey: dateKey, status: .missed)
            case NotificationManager.actionSnooze:
                NotificationManager.snoozeBlockCheckin(blockID: blockIDString,
                                                       dateKey: dateKey,
                                                       title: title)
            default:
                break // plain tap opens the app
            }
            completionHandler()
        }
    }
}
