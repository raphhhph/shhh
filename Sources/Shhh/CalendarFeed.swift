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
        items += linkItems().filter { $0.start >= first && $0.start < last } // ManageBac and Google links
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

// MARK: - Calendar links (ManageBac, Google), read directly

/// ManageBac and Google Calendar both give a private calendar link (iCal). Pasted once, Joe reads
/// it himself every half hour: no syncing through Claude, nothing to set up in Terminal.
extension CalendarFeed {
    /// The links they've added, "webcal://…" or "https://…".
    static var links: [String] {
        get { UserDefaults.standard.stringArray(forKey: "calendarLinks") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "calendarLinks") }
    }

    static let feedCache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/Calendar links.json")

    /// When the links were last read.
    static var linksReadAt: Date? {
        (try? feedCache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Reads every link and saves what's on them. Returns how many items, or an error to show.
    @discardableResult
    static func refreshLinks() async -> String {
        var all: [[String: String]] = []
        var problems: [String] = []
        for link in links {
            guard let url = URL(string: link.replacingOccurrences(of: "webcal://", with: "https://")) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let text = String(decoding: data, as: UTF8.self)
                guard text.contains("BEGIN:VCALENDAR") else { problems.append("\(url.host ?? link) didn't send a calendar"); continue }
                let manageBac = (url.host ?? "").contains("managebac")
                all += parseICS(text, deadlines: manageBac)
            } catch {
                problems.append("\(url.host ?? link): \(error.localizedDescription)")
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: all) {
            try? FileManager.default.createDirectory(at: feedCache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: feedCache)
        }
        return problems.isEmpty ? "\(all.count) items" : problems.joined(separator: "; ")
    }

    /// The saved items, in the same shape as calendar.json.
    static func linkItems() -> [Item] {
        guard let data = try? Data(contentsOf: feedCache),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return list.compactMap { entry in
            guard let title = entry["title"], let startText = entry["start"], let start = icsDate(startText) else { return nil }
            return Item(title: title, detail: entry["detail"] ?? "", start: start, end: entry["end"].flatMap(icsDate),
                        allDay: startText.count == 8, kind: entry["kind"] == "deadline" ? .deadline : .event)
        }
    }

    /// VEVENTs from an iCal file: title, start, end, where; ManageBac's are deadlines.
    static func parseICS(_ text: String, deadlines: Bool) -> [[String: String]] {
        // Lines that start with a space continue the one before.
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
        var items: [[String: String]] = []
        var current: [String: String]?
        let horizon = Date().addingTimeInterval(-14 * 86_400)
        for line in unfolded.components(separatedBy: "\n") {
            if line == "BEGIN:VEVENT" { current = [:]; continue }
            if line == "END:VEVENT" {
                if var event = current, event["title"] != nil, let start = event["start"], let date = icsDate(start), date > horizon {
                    let title = event["title"] ?? ""
                    event["kind"] = deadlines || title.range(of: #"\b(due|deadline|summative|formative|test|quiz|exam)\b"#,
                                                             options: [.regularExpression, .caseInsensitive]) != nil && deadlines ? "deadline" : "event"
                    items.append(event)
                }
                current = nil
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].split(separator: ";").first.map(String.init) ?? ""
            let value = String(line[line.index(after: colon)...])
                .replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
            switch key {
            case "SUMMARY": current?["title"] = value
            case "DTSTART": current?["start"] = value
            case "DTEND": current?["end"] = value
            case "LOCATION": if !value.isEmpty { current?["detail"] = value }
            default: break
            }
        }
        return items
    }

    /// "20261021", "20261021T153000" (local) or "20261021T073000Z" (UTC).
    static func icsDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if text.hasSuffix("Z") {
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else {
            formatter.timeZone = .current
            formatter.dateFormat = text.count == 8 ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
        }
        return formatter.date(from: text)
    }
}
