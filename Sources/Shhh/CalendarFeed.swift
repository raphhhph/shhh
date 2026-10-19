import EventKit
import Foundation

/// What's on, day by day, for the dashboard's Calendar: classes from the timetable, Google Calendar
/// events and ManageBac deadlines (which Joe saves to calendar.json beside the timetable each
/// morning, or when asked to sync, since only he can reach those accounts), Joe's alarms, and the
/// Mac's own Calendar when it's allowed.
enum CalendarFeed {
    struct Item: Identifiable, Hashable {
        enum Kind: String { case lesson, event, deadline, alarm }
        var title: String
        var detail = ""
        var start: Date
        var end: Date?
        var allDay = false
        var kind: Kind
        var id: String { "\(kind.rawValue) \(start.timeIntervalSince1970) \(title)" }
    }

    /// Where Joe saves the Google Calendar and ManageBac items.
    static var cacheURL: URL? { Daybook.root?.appendingPathComponent("_files/School/calendar.json") }

    /// When Joe last saved them.
    static var syncedAt: Date? {
        cacheURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    }

    /// Everything from `start` for `days` days, sorted, without duplicates (the same title at the same time).
    static func items(from start: Date, days: Int) -> [Item] {
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: start)
        guard let last = calendar.date(byAdding: .day, value: days, to: first) else { return [] }
        var items: [Item] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { continue }
            items += Daybook.timeline(day).filter { $0.kind == .lesson }
                .map { Item(title: $0.title, detail: $0.detail, start: $0.start, end: $0.end, kind: .lesson) }
            items += alarms(on: day)
        }
        items += cached().filter { $0.start >= first && $0.start < last }
        items += macCalendar(from: first, to: last)
        var seen = Set<String>()
        return items.sorted { $0.start < $1.start }.filter { item in
            let key = "\(item.title.lowercased()) \(Int(item.start.timeIntervalSince1970 / 60))"
            return seen.insert(key).inserted
        }
    }

    // MARK: - Sources

    private struct Cached: Decodable {
        let title: String
        let start: String
        let end: String?
        let allDay: Bool?
        let kind: String?
        let detail: String?
    }

    /// calendar.json: [{"title", "start", "end"?, "allDay"?, "kind": "event"|"deadline", "detail"?}],
    /// times as "2026-10-20T15:00" (local) or "2026-10-20" for a whole day.
    private static func cached() -> [Item] {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Cached].self, from: data) else { return [] }
        return list.compactMap { entry in
            guard let start = date(entry.start) else { return nil }
            let allDay = entry.allDay ?? (entry.start.count <= 10)
            return Item(title: entry.title, detail: entry.detail ?? "", start: start, end: entry.end.flatMap(date),
                        allDay: allDay, kind: entry.kind == "deadline" ? .deadline : .event)
        }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Joe's alarms on a day, repeating ones included.
    private static func alarms(on day: Date) -> [Item] {
        let calendar = Calendar.current
        return AlarmStore.load().compactMap { alarm in
            if calendar.isDate(alarm.fireAt, inSameDayAs: day) {
                return Item(title: alarm.title, start: alarm.fireAt, kind: .alarm)
            }
            guard let days = alarm.repeatDays, days.contains(calendar.component(.weekday, from: day)), day > alarm.fireAt,
                  let time = calendar.date(bySettingHour: calendar.component(.hour, from: alarm.fireAt),
                                           minute: calendar.component(.minute, from: alarm.fireAt), second: 0, of: day) else { return nil }
            return Item(title: alarm.title, start: time, kind: .alarm)
        }
    }

    private static let store = EKEventStore()

    /// The Mac's Calendar (which may hold their Google account), when it's allowed.
    private static func macCalendar(from start: Date, to end: Date) -> [Item] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            let deadline = event.calendar.title.lowercased().contains("managebac")
            return Item(title: event.title ?? "Event", detail: event.location ?? "", start: event.startDate,
                        end: event.isAllDay ? nil : event.endDate, allDay: event.isAllDay, kind: deadline ? .deadline : .event)
        }
    }

    static func requestMacCalendar(_ done: @escaping () -> Void) {
        store.requestFullAccessToEvents { _, _ in DispatchQueue.main.async(execute: done) }
    }

    /// For Joe: how to save calendar.json.
    static var syncInstructions: String {
        let config = Daybook.managebacCalendarID ?? "the ManageBac one"
        return """
            Save my calendar for the dashboard: write \(Daybook.relative(cacheURL)) as a JSON array of every event \
            from today to 21 days ahead in all my Google calendars, including \(config) (its items are ManageBac \
            tasks and deadlines). Each: {"title", "start": "YYYY-MM-DDTHH:MM" local time or "YYYY-MM-DD" for a \
            whole day, "end" (same format, if it has one), "allDay": true|false, "kind": "deadline" for ManageBac \
            tasks and anything due, otherwise "event", "detail": the class or place, short}. Leave out my class \
            timetable events (tagged #class): the app has those. Reply in one line.
            """
    }
}
