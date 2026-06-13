import Foundation
import EventKit

/// EventKit access: the coach reads your real calendar to plan around it, and
/// (optionally) writes its timeboxes into the calendar as events.
enum CalendarManager {
    private static let eventStore = EKEventStore()
    private static let coachMarker = "Scheduled by Coach app"

    static func requestPermission() async -> Bool {
        (try? await eventStore.requestFullAccessToEvents()) ?? false
    }

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Prompt-ready list of events for today or tomorrow, excluding the coach's
    /// own blocks.
    static func eventsSummary(tomorrow: Bool) -> String? {
        guard isAuthorized else { return nil }
        let calendar = Calendar.current
        var dayStart = calendar.startOfDay(for: Date())
        if tomorrow {
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            dayStart = next
        }
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }

        let predicate = eventStore.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { !($0.notes?.contains(coachMarker) ?? false) }
            .sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else { return "No calendar events." }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let lines = events.prefix(20).map { event -> String in
            if event.isAllDay {
                return "- All day: \(event.title ?? "Untitled")"
            }
            let start = formatter.string(from: event.startDate)
            let end = formatter.string(from: event.endDate)
            return "- \(start)-\(end): \(event.title ?? "Untitled")"
        }
        return lines.joined(separator: "\n")
    }

    /// Writes today's blocks as calendar events, replacing any blocks the coach
    /// wrote earlier today.
    static func writeBlocks(_ blocks: [TimeBlock]) -> Bool {
        guard isAuthorized else { return false }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }

        // Remove the coach's previous events for today.
        let predicate = eventStore.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        for event in eventStore.events(matching: predicate)
        where event.notes?.contains(coachMarker) ?? false {
            try? eventStore.remove(event, span: .thisEvent, commit: false)
        }

        for block in blocks {
            guard let start = calendar.date(byAdding: .minute, value: block.startMinutes, to: dayStart),
                  let end = calendar.date(byAdding: .minute, value: block.endMinutes, to: dayStart)
            else { continue }
            let event = EKEvent(eventStore: eventStore)
            event.title = block.title
            event.startDate = start
            event.endDate = end
            event.notes = coachMarker
            event.calendar = eventStore.defaultCalendarForNewEvents
            try? eventStore.save(event, span: .thisEvent, commit: false)
        }

        do {
            try eventStore.commit()
            return true
        } catch {
            return false
        }
    }
}
