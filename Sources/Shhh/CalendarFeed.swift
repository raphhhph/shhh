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
        /// For a deadline: the class it's for ("Economics HL"), when Joe can tell.
        var subject: String?
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
        for index in items.indices where items[index].kind == .deadline && items[index].subject == nil {
            items[index].subject = subject(of: items[index].title, notes: items[index].detail,
                                           at: items[index].allDay ? nil : items[index].start)
        }
        var seen = Set<String>()
        var kept: [Item] = []
        for item in items.sorted(by: { $0.start < $1.start }) {
            let key = "\(item.title.lowercased()) \(Int(item.start.timeIntervalSince1970 / 60))"
            guard seen.insert(key).inserted else { continue }
            // The same deadline from two places (a calendar link and Joe's sync), named a little
            // differently: "BM Unit 1 Summative Assessment" and "Unit 1 Summative Assessment 2".
            if item.kind == .deadline, kept.contains(where: { $0.kind == .deadline && calendar.isDate($0.start, inSameDayAs: item.start)
                                                              && Self.sameThing($0.title, item.title) }) { continue }
            kept.append(item)
        }
        return kept
    }

    /// Titles that are mostly the same words.
    static func sameThing(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 })
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.6
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

    /// Whether Joe reads a calendar himself (a link, or the Mac's Calendar), so the Daybook's
    /// classes, events and deadlines don't need Claude.
    static var readsCalendarItself: Bool {
        !links.isEmpty || EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Reads every link and saves what's on them. Returns how many items, or an error to show.
    /// A link that can't be read this time keeps what it had last time, so a dropped connection
    /// doesn't empty Due soon for half an hour.
    @discardableResult
    static func refreshLinks() async -> String {
        let previous = (try? Data(contentsOf: feedCache))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: String]] } ?? []
        var all: [[String: String]] = []
        var problems: [String] = []
        for link in links {
            guard let url = URL(string: link.replacingOccurrences(of: "webcal://", with: "https://")) else { continue }
            let kept = previous.filter { $0["source"] == link }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
                    problems.append("\(url.host ?? link) answered \(status) (the link may have been reset: copy it again)")
                    all += kept
                    continue
                }
                let text = String(decoding: data, as: UTF8.self)
                guard text.contains("BEGIN:VCALENDAR") else {
                    problems.append("\(url.host ?? link) didn't send a calendar")
                    all += kept
                    continue
                }
                let manageBac = (url.host ?? "").contains("managebac")
                all += parseICS(text, deadlines: manageBac, source: link)
            } catch {
                problems.append("\(url.host ?? link): \(error.localizedDescription)")
                all += kept
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: all) {
            try? FileManager.default.createDirectory(at: feedCache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: feedCache)
        }
        // A task set on ManageBac since the last read goes straight into today's Daybook.
        if !previous.isEmpty {
            let known = Set(previous.filter { $0["kind"] == "deadline" }.compactMap { $0["title"] })
            let added = linkItems().filter { $0.kind == .deadline && !known.contains($0.title) && $0.start > Date() }
            if !added.isEmpty { Daybook.addNewDeadlines(added) }
        }
        return problems.isEmpty ? "\(all.count) items" : problems.joined(separator: "; ")
    }

    /// The saved items, in the same shape as calendar.json.
    static func linkItems(subjects: Bool = true) -> [Item] {
        guard let data = try? Data(contentsOf: feedCache),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return list.compactMap { entry in
            guard let title = entry["title"], let startText = entry["start"], let start = icsDate(startText) else { return nil }
            let deadline = entry["kind"] == "deadline"
            return Item(title: title, detail: entry["detail"] ?? "", start: start, end: entry["end"].flatMap(icsDate),
                        allDay: startText.count == 8, kind: deadline ? .deadline : .event,
                        subject: deadline && subjects ? subject(of: title, notes: entry["notes"] ?? "", category: entry["category"] ?? "",
                                                                at: startText.count == 8 ? nil : start) : nil)
        }
    }

    /// VEVENTs from an iCal file: title, start, end, where, notes; ManageBac's are deadlines, and so
    /// is anything called a test, quiz or due on another calendar. Repeating events are expanded
    /// for the next three months, times in another time zone are saved in UTC, cancelled ones are
    /// left out.
    static func parseICS(_ text: String, deadlines: Bool, source: String = "") -> [[String: String]] {
        // Lines that start with a space continue the one before.
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
        var events: [[String: String]] = []
        var current: [String: String]?
        var nested = 0 // inside a VALARM, whose DESCRIPTION isn't the event's
        for line in unfolded.components(separatedBy: "\n") {
            if line == "BEGIN:VEVENT" { current = [:]; nested = 0; continue }
            if line == "END:VEVENT" {
                if let event = current { events.append(event) }
                current = nil
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("BEGIN:") { nested += 1; continue }
            if line.hasPrefix("END:") { nested = max(0, nested - 1); continue }
            guard nested == 0, let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon].split(separator: ";").map(String.init)
            let key = head.first ?? ""
            let zone = head.dropFirst().first { $0.hasPrefix("TZID=") }.map { String($0.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            let raw = String(line[line.index(after: colon)...])
            let value = raw.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\N", with: " ")
                .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "SUMMARY": current?["title"] = value
            case "DTSTART": current?["start"] = normalized(raw, zone: zone)
            case "DTEND": current?["end"] = normalized(raw, zone: zone)
            case "LOCATION": if !value.isEmpty { current?["detail"] = value }
            case "DESCRIPTION": if !value.isEmpty { current?["notes"] = String(value.prefix(300)) }
            case "CATEGORIES": if !value.isEmpty { current?["category"] = value }
            case "UID": current?["uid"] = value
            case "STATUS": current?["status"] = value.uppercased()
            case "RRULE": current?["rrule"] = value
            case "RECURRENCE-ID": current?["recurrence"] = normalized(raw, zone: zone)
            case "EXDATE":
                let dates = raw.split(separator: ",").map { normalized(String($0), zone: zone) }
                current?["exdate"] = ((current?["exdate"].map { [$0] } ?? []) + dates).joined(separator: ",")
            default: break
            }
        }
        // A changed occurrence of a repeating event comes as its own VEVENT (with RECURRENCE-ID):
        // it replaces that occurrence.
        let moved = Set(events.compactMap { event in event["recurrence"].map { "\(event["uid"] ?? "") \($0)" } })
        let horizon = Date().addingTimeInterval(-14 * 86_400)
        let until = Date().addingTimeInterval(90 * 86_400)
        let due = #"\b(due|deadline|summative|formative|test|quiz|exam)\b"#
        var items: [[String: String]] = []
        for event in events {
            guard event["status"] != "CANCELLED", let title = event["title"], let start = event["start"], let first = icsDate(start) else { continue }
            let allDay = start.count == 8
            let length = event["end"].flatMap(icsDate).map { $0.timeIntervalSince(first) }
            var item = event.filter { ["title", "detail", "notes", "category"].contains($0.key) }
            item["kind"] = deadlines || title.range(of: due, options: [.regularExpression, .caseInsensitive]) != nil ? "deadline" : "event"
            if !source.isEmpty { item["source"] = source }
            guard let rule = event["rrule"] else {
                if first > horizon { items.append(item.merging(["start": start, "end": event["end"]].compactMapValues { $0 }) { $1 }) }
                continue
            }
            let skipped = Set((event["exdate"] ?? "").split(separator: ",").map(String.init))
            for date in occurrences(of: first, rule: rule, from: horizon, to: until) {
                let stamp = icsStamp(date, allDay: allDay)
                guard !skipped.contains(stamp), !moved.contains("\(event["uid"] ?? "") \(stamp)") else { continue }
                var occurrence = item
                occurrence["start"] = stamp
                if let length { occurrence["end"] = icsStamp(date.addingTimeInterval(length), allDay: allDay) }
                items.append(occurrence)
            }
        }
        return items
    }

    /// When a repeating event happens between two dates: FREQ DAILY, WEEKLY (with BYDAY), MONTHLY
    /// or YEARLY, with INTERVAL, COUNT and UNTIL. Rarer rules ("the second Tuesday") give the first
    /// date only.
    static func occurrences(of first: Date, rule: String, from: Date, to: Date) -> [Date] {
        var parts: [String: String] = [:]
        for pair in rule.split(separator: ";") {
            let halves = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if halves.count == 2 { parts[halves[0].uppercased()] = halves[1] }
        }
        let unit: Calendar.Component
        switch parts["FREQ"]?.uppercased() {
        case "DAILY": unit = .day
        case "WEEKLY": unit = .weekOfYear
        case "MONTHLY": unit = .month
        case "YEARLY": unit = .year
        default: return [first]
        }
        if unit != .weekOfYear, parts["BYDAY"] != nil || parts["BYMONTHDAY"] != nil || parts["BYSETPOS"] != nil { return [first] }
        let calendar = Calendar.current
        let interval = max(1, Int(parts["INTERVAL"] ?? "") ?? 1)
        let count = parts["COUNT"].flatMap { Int($0) } ?? .max
        // UNTIL is inclusive; a date-only one means the whole of that day.
        let last = min(to, parts["UNTIL"].flatMap { text in icsDate(text).map { text.count == 8 ? $0.addingTimeInterval(86_399) : $0 } } ?? to)
        let codes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        let weekdays = unit == .weekOfYear
            ? Set((parts["BYDAY"] ?? "").split(separator: ",").compactMap { codes[String($0.suffix(2)).uppercased()] }) : []
        let firstWeekday = calendar.component(.weekday, from: first)
        let days = weekdays.isEmpty ? [firstWeekday] : weekdays.sorted()
        // Jump close to `from` instead of walking years of old repeats.
        var period = 0
        var made = 0
        if first < from, let gap = calendar.dateComponents([unit], from: first, to: from).value(for: unit), gap > interval {
            period = (gap / interval - 1) * interval
            made = period / interval * days.count
        }
        var dates: [Date] = []
        walk: while made < count, dates.count < 500, let base = calendar.date(byAdding: unit, value: period, to: first) {
            for weekday in days {
                // In a week, each of its days at the same time; otherwise just `base`.
                guard let date = unit == .weekOfYear ? calendar.date(byAdding: .day, value: weekday - firstWeekday, to: base) : base else { continue }
                if date < first { continue }
                if date > last || made >= count { break walk }
                made += 1
                if date >= from { dates.append(date) }
            }
            period += interval
        }
        return dates
    }

    /// A DTSTART-style value as Joe saves it: "20261021" for a whole day, UTC ("…Z") for a time.
    private static func normalized(_ raw: String, zone: String?) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.count > 8, !text.hasSuffix("Z") else { return text }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        guard let date = formatter.date(from: text) else { return text }
        return icsStamp(date, allDay: false)
    }

    private static func icsStamp(_ date: Date, allDay: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = allDay ? .current : TimeZone(identifier: "UTC")
        formatter.dateFormat = allDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
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

// MARK: - Holidays

extension CalendarFeed {
    /// Days off on their school calendar ("2026-10-01"): whole-day events from the calendar links
    /// or calendar.json named a holiday, break, vacation and the like, every day they cover. So an
    /// imported timetable, which repeats every week, has no classes on them. Read again when the
    /// saved items change.
    static var holidays: Set<String> {
        let stamp = [linksReadAt, syncedAt].compactMap { $0 }.max() ?? .distantPast
        if let cachedHolidays, cachedHolidays.stamp == stamp { return cachedHolidays.days }
        let name = #"holiday|vacation|no school|school closed|half[ -]term|recess|\bbreak\b|golden week|national day|mid-autumn|spring festival|lunar new year|day off"#
        let calendar = Calendar.current
        var days = Set<String>()
        // Without subjects: those look at the timetable, which looks at the holidays.
        for item in linkItems(subjects: false) + cached() where item.allDay && item.kind == .event
            && item.title.range(of: name, options: [.regularExpression, .caseInsensitive]) != nil {
            // A whole-day event's end is the day after its last day.
            let last = item.end.map { $0.addingTimeInterval(-1) } ?? item.start
            var day = calendar.startOfDay(for: item.start)
            while day <= last, days.count < 1000 {
                days.insert(day.formatted(.localDay))
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        cachedHolidays = (stamp, days)
        return days
    }

    private static var cachedHolidays: (stamp: Date, days: Set<String>)?
}

// MARK: - Which class a deadline is for

extension CalendarFeed {
    /// The class a deadline is for, from the student's own timetable: "BM Unit 1 Summative" →
    /// "Business Mgmt HL", "Quiz: Markets 2" → "Economics HL". ManageBac's calendar has no subject
    /// field (its events carry only a title, times and a cut-off description), so in turn: a class
    /// named in the title (full name, initials such as BM or TOK, or a distinctive first word),
    /// then in the notes; a subject's typical words ("taxes", "ecosystem", "exhibition"); Chinese
    /// writing for a Chinese class; the class on the timetable at the time it's due; the category.
    static func subject(of title: String, notes: String = "", category: String = "", at time: Date? = nil) -> String? {
        let names = Daybook.classNames
        guard !names.isEmpty else { return category.isEmpty ? nil : category }
        func named(in text: Set<String>) -> String? {
            names.first { name in
                let core = coreWords(name)
                return (!core.isEmpty && core.allSatisfy(text.contains)) || initials(name).contains { text.contains($0) }
            } ?? names.first { coreWords($0).first.map { $0.count >= 5 && text.contains($0) } ?? false }
        }
        let heading = words(title + " " + category)
        if let name = named(in: heading) ?? named(in: words(notes)) { return name }
        let singular = Set(heading.map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }).union(heading)
        for (key, typical) in typicalWords where !typical.isDisjoint(with: singular) {
            if let name = names.first(where: { coreWords($0).contains(key) || initials($0).contains(key) }) { return name }
        }
        if title.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
           let name = names.first(where: { $0.lowercased().contains("chinese") || $0.lowercased().contains("mandarin") }) { return name }
        if let time, let lesson = Daybook.timeline(time).first(where: { $0.kind == .lesson && $0.start <= time && ($0.end ?? $0.start) > time }),
           names.contains(lesson.title) { return lesson.title }
        return category.isEmpty ? nil : category
    }

    /// Words a subject's tasks use without naming it, by the class's core word or initials.
    private static let typicalWords: [String: Set<String>] = [
        "economics": ["market", "tax", "taxe", "elasticity", "demand", "supply", "gdp", "inflation", "unemployment", "fiscal",
                      "monetary", "tariff", "subsidy", "externality", "macroeconomic", "microeconomic", "price"],
        "business": ["marketing", "stakeholder", "swot", "profit", "entrepreneur", "organisation", "hrm", "cashflow", "breakeven"],
        "ess": ["ecosystem", "biodiversity", "bioaccumulation", "sustainability", "pollution", "biome", "ecology", "conservation"],
        "maths": ["calculation", "calculus", "statistic", "probability", "algebra", "trigonometry", "derivative", "integration", "function"],
        "english": ["poem", "poetry", "novel", "literary", "rhetoric", "comic", "prose"],
        "tok": ["exhibition", "artifact", "artefact", "knower", "knowledge"],
        "biology": ["cell", "genetic", "enzyme", "photosynthesis"],
        "chemistry": ["mole", "stoichiometry", "titration", "bonding"],
        "physics": ["kinematic", "momentum", "circuit", "wave"],
        "history": ["war", "revolution", "historical"],
        "psychology": ["cognitive", "behaviour", "behavior"],
    ]

    /// Lowercased words, with the usual short forms spelled out.
    private static func words(_ text: String) -> Set<String> {
        let short = ["math": "maths", "mathematics": "maths", "econ": "economics", "bio": "biology", "chem": "chemistry",
                     "phys": "physics", "eng": "english", "lit": "literature", "geo": "geography", "psych": "psychology",
                     "comp": "computer", "sci": "science", "lang": "language", "tok": "tok", "mgmt": "management"]
        let list = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return Set(list.map { short[$0] ?? $0 })
    }

    /// A class name's words without the level and the little words: "Maths AI HL" → maths, ai.
    private static func coreWords(_ name: String) -> [String] {
        let skip: Set<String> = ["hl", "sl", "dp", "myp", "y1", "y2", "yr", "year", "and", "of", "the", "a", "b", "ab", "initio"]
        let list = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return list.filter { !skip.contains($0) && Int($0) == nil && $0.count > 1 }.map { words($0).first ?? $0 }
    }

    /// "Business Management HL" → "bm"; "Theory of Knowledge" → "tk", "tok". One-word names have none.
    private static func initials(_ name: String) -> [String] {
        let all = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["hl", "sl"].contains($0) && Int($0) == nil }
        let core = all.filter { !["and", "of", "the"].contains($0) }
        guard core.count >= 2 else { return [] }
        let short = String(core.compactMap(\.first)), long = String(all.compactMap(\.first))
        // "IT" or "PE" would also match "submit it" or "pe" in a link: leave out real words.
        let common: Set<String> = ["it", "is", "as", "at", "an", "in", "on", "or", "to", "be", "we", "me", "my", "so",
                                   "no", "do", "go", "up", "us", "am", "if", "by", "he", "hi", "ok", "pe", "pm", "id"]
        return Array(Set([short, long]).subtracting(common))
    }
}
