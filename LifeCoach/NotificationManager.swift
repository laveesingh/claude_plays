import Foundation
import UserNotifications

enum NotificationManager {
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func scheduleDailyCheckIns(morningHour: Int, eveningHour: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["morning-checkin", "evening-checkin"])

        let morning = UNMutableNotificationContent()
        morning.title = "Morning check-in"
        morning.body = "Your coach is waiting. Get today's plan and commit to it."
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
        evening.title = "Evening review"
        evening.body = "Time to report in. What got done today — and what didn't?"
        evening.sound = .default
        var eveningComponents = DateComponents()
        eveningComponents.hour = eveningHour
        eveningComponents.minute = 0
        center.add(UNNotificationRequest(
            identifier: "evening-checkin",
            content: evening,
            trigger: UNCalendarNotificationTrigger(dateMatching: eveningComponents, repeats: true)
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
        let request = UNNotificationRequest(
            identifier: "nudge-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
        return true
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}

/// Shows notifications as banners while the app is in the foreground.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
