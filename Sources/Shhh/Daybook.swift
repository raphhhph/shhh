import Foundation

/// The Daybook: the user's day as a note in the vault (`Daybook.md`), in place of the old Daybook
/// page. The assistant builds it each morning (focus, five tasks, classes, deadlines, emails that
/// need a reply, the rest of the day, backlog) and keeps it current as tasks get done, so "what
/// do I have to do?" is answered from it. Yesterday's moves to `Daybook/History`, which with the
/// conversation log there is the assistant's memory of past days. Classes come from the saved
/// timetable, worked out here rather than by Claude, so they're never misread.
enum Daybook {
    /// The folder the Daybook lives in: the vault's `Brain` (see `NoteSaver.root`).
    static var root: URL? { NoteSaver.root }
    static var url: URL? { root?.appendingPathComponent("Daybook.md") }
    static var history: URL? { root?.appendingPathComponent("Daybook/History", isDirectory: true) }
    static var patterns: URL? { root?.appendingPathComponent("Daybook/Patterns.md") }
    static var timetableURL: URL? { root?.appendingPathComponent("_files/School/timetable.json") }
    /// The Google calendar ManageBac's feed is in (from the timetable's config).
    static var managebacCalendarID: String? { timetable?.config?.managebacCalendarId }
    static var routinesURL: URL? { root?.appendingPathComponent("Daybook/Routines.md") }

    /// The routines in Routines.md: each `##` heading with the line under it (when to say it).
    static var routines: [String] {
        guard let url = routinesURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")
        return lines.indices.filter { lines[$0].hasPrefix("## ") }.map { i in
            let name = String(lines[i].dropFirst(3))
            let trigger = lines[(i + 1)...].prefix(3).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            return trigger.map { "\(name) (\($0.trimmingCharacters(in: .whitespaces)))" } ?? name
        }
    }

    /// "Remember conversations": each request and the gist of its answer go in a monthly log.
    static var remembers: Bool {
        get { UserDefaults.standard.object(forKey: "rememberConversations") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "rememberConversations") }
    }

    /// A path for the assistant's instructions, relative to the vault (its working folder).
    static func relative(_ url: URL?) -> String {
        guard let url, let vault = Assistant.vaultURL else { return url?.path ?? "" }
        return url.path.hasPrefix(vault.path + "/") ? String(url.path.dropFirst(vault.path.count + 1)) : url.path
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.localDay)
    }

    // MARK: - Today's note

    /// The day the Daybook is for (its `date:`), or nil if there's none.
    static var date: String? {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n").prefix(12)
            .first { $0.hasPrefix("date:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
    }

    static var isCurrent: Bool { date == day(Date()) }

    /// A Daybook from an earlier day goes to History, so today's starts fresh.
    static func archiveIfOld() {
        guard let url, let history, let date, date < day(Date()) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: history, withIntermediateDirectories: true)
        var target = history.appendingPathComponent("\(date).md")
        var number = 2
        while manager.fileExists(atPath: target.path) {
            target = history.appendingPathComponent("\(date) (\(number)).md")
            number += 1
        }
        try? manager.moveItem(at: url, to: target)
    }

    /// The most recent day in History, for carrying tasks over.
    static var lastArchived: URL? {
        guard let history, let names = try? FileManager.default.contentsOfDirectory(atPath: history.path) else { return nil }
        return names.filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}( \(\d+\))?\.md$"#, options: .regularExpression) != nil }
            .sorted().last.map { history.appendingPathComponent($0) }
    }

    // MARK: - Classes

    private struct Timetable: Decodable {
        struct Row: Decodable {
            let kind: String
            let start: String
            let end: String
            let idx: Int?
            let p: String?
            let label: String?
        }
        struct Config: Decodable {
            let managebacCalendarId: String?
            let swisLabelId: String?
        }
        let days: [[Value]]
        let grids: [String: [String]]
        let rows: [Row]
        let config: Config?

        enum Value: Decodable {
            case text(String), number(Int)
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) { self = .number(number) } else { self = .text(try container.decode(String.self)) }
            }
            var text: String { switch self { case .text(let t): t; case .number(let n): String(n) } }
        }
    }

    /// Read once, and again only when the file changes (it's checked every few seconds).
    private static var cachedTimetable: (stamp: Date, value: Timetable?)?
    private static var timetable: Timetable? {
        guard let url = timetableURL else { return nil }
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let cachedTimetable, cachedTimetable.stamp == stamp { return cachedTimetable.value }
        let value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Timetable.self, from: $0) }
        cachedTimetable = (stamp, value)
        return value
    }

    /// "Day 9 · Cycle B: P1 08:30 Economics HL (D304), …" for a school day, or nil.
    private static func classes(on date: Date, in timetable: Timetable) -> String? {
        let iso = day(date)
        guard let entry = timetable.days.first(where: { $0.first?.text == iso }), entry.count >= 3 else { return nil }
        let rotation = entry[1].text, cycle = entry[2].text
        let grid = timetable.grids[rotation + cycle] ?? []
        let periods = timetable.rows.compactMap { row -> String? in
            switch row.kind {
            case "class":
                guard let index = row.idx, index < grid.count else { return nil }
                let parts = grid[index].components(separatedBy: " · ")
                let name = grid[index] == "—" ? "free" : parts[0] + (parts.count > 1 ? " (\(parts[1]))" : "")
                return "P\(row.p ?? "?") \(row.start)–\(row.end) \(name)"
            case "advisory": return "Advisory \(row.start)"
            default: return nil
            }
        }
        return "Day \(rotation) · Cycle \(cycle): " + periods.joined(separator: ", ")
    }

    /// One thing on today's timeline: a class, a calendar event or an alarm.
    struct Slot: Hashable, Identifiable {
        enum Kind: Hashable { case lesson, event, alarm }
        var start: Date
        var end: Date?
        var title: String
        var detail = ""
        var kind: Kind
        var id: String { "\(start.timeIntervalSince1970) \(title)" }
    }

    /// Today's classes (from the timetable) and the Daybook's "Rest of today" events, in order.
    static func timeline(_ date: Date = Date()) -> [Slot] {
        func at(_ time: String) -> Date? {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date)
        }
        var slots: [Slot] = []
        if let timetable, let entry = timetable.days.first(where: { $0.first?.text == day(date) }), entry.count >= 3 {
            let grid = timetable.grids[entry[1].text + entry[2].text] ?? []
            for row in timetable.rows {
                guard let start = at(row.start) else { continue }
                if row.kind == "class", let index = row.idx, index < grid.count, grid[index] != "—" {
                    let parts = grid[index].components(separatedBy: " · ")
                    slots.append(Slot(start: start, end: at(row.end), title: parts[0], detail: parts.count > 1 ? parts[1] : "", kind: .lesson))
                } else if row.kind == "advisory" {
                    slots.append(Slot(start: start, end: at(row.end), title: "Advisory", kind: .lesson))
                }
            }
        }
        // "- 15:00–16:00 Call with Giorgos" lines, if the Daybook is today's.
        if let url, let text = try? String(contentsOf: url, encoding: .utf8), text.contains("date: \(day(date))") {
            var inRest = false
            for line in text.components(separatedBy: .newlines) {
                if line.hasPrefix("## ") { inRest = line.lowercased().contains("rest of today"); continue }
                guard inRest, let range = line.range(of: #"\d{1,2}:\d{2}(\s*[–-]\s*\d{1,2}:\d{2})?"#, options: .regularExpression) else { continue }
                let times = line[range].components(separatedBy: CharacterSet(charactersIn: "–-")).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let start = at(times[0]) else { continue }
                let title = line.replacingCharacters(in: range, with: "")
                    .replacingOccurrences(of: #"^[\s\-*·:|]+|\[[^\]]*\]\([^)]*\)|\*\*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                slots.append(Slot(start: start, end: times.count > 1 ? at(times[1]) : nil, title: title.isEmpty ? "Event" : title, kind: .event))
            }
        }
        return slots.sorted { $0.start < $1.start }
    }

    /// Whether there's school on a day (in the saved timetable).
    static func isSchoolDay(_ date: Date) -> Bool {
        guard let timetable else { return !Calendar.current.isDateInWeekend(date) }
        return timetable.days.contains { $0.first?.text == day(date) }
    }

    /// Tomorrow's classes, for the night shutdown and "what do I have tomorrow".
    static var tomorrow: String? {
        guard let timetable, let date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else { return nil }
        let name = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return classes(on: date, in: timetable).map { "Tomorrow, \(name): \($0)." } ?? "Tomorrow, \(name): no school."
    }

    /// Today's classes, or that there's no school and the next school day's.
    static var today: String? {
        guard let timetable else { return nil }
        let now = Date()
        if let classes = classes(on: now, in: timetable) { return "Today, \(now.formatted(.dateTime.weekday(.wide).day().month(.wide))): \(classes)." }
        for offset in 1...21 {
            guard let next = Calendar.current.date(byAdding: .day, value: offset, to: now),
                  let classes = classes(on: next, in: timetable) else { continue }
            return "No school today. Next school day, \(next.formatted(.dateTime.weekday(.wide).day().month(.wide))): \(classes)."
        }
        return "No school today or in the next three weeks."
    }

    // MARK: - Instructions for the assistant

    /// How to build today's Daybook: for the morning briefing, or the first request of a day.
    static var buildRules: String {
        let config = timetable?.config
        return """
            To build today's Daybook, write \(relative(url)) in the same format as the last one in \
            \(relative(history))/ (\(lastArchived.map { relative($0) } ?? "none yet")): frontmatter (summary, owns, \
            date: \(day(Date())), updated), a "# Daybook — <weekday day month>" title, then **Focus:**, ## Today's five, \
            ## Classes, ## Rest of today, ## Deadlines, ## Needs you, ## Backlog, ## Inbox, and ## Post today on a posting day.
              - Today's five: at most five tasks, most urgent first, as "- [ ] task — due … · detail". Carry over \
            the last Daybook's unticked tasks (raise "carried N×" by one) and drop its ticked ones. A task carried 3× \
            or more ends "— decide: do it today, hand off or drop". What doesn't fit goes to Backlog. Act on its Inbox \
            items, then leave Inbox empty.
              - Classes: a table (Period, Time, Class, Room) from the "Today, …" line in your instructions, or "No school today."
              - Rest of today: today's Google Calendar events that aren't classes (classes carry #class).
              - Deadlines: the ManageBac calendar (\(config?.managebacCalendarId ?? "ManageBac")) for the next three weeks.
              - Needs you: at most three emails or invites from the last day that really need their reply (Gmail \
            inbox, not promotions or social; \(config?.swisLabelId.map { "school mail has label \($0)" } ?? "school mail first")), each with who, \
            what to do and an [Open](link); then "_N others, all noise._".
              - Patterns: read \(relative(patterns)) and use it: prepare them for this weekday's regular meetings. \
            When a meeting or call on today's calendar also happened on this weekday last week, add it there.
              - Focus: one sentence, the one thing that matters most today.
              - Then, for the dashboard's calendar: \(CalendarFeed.syncInstructions.replacingOccurrences(of: " Reply in one line.", with: ""))
            """
    }

    /// For the assistant's instructions: where the Daybook is, how to use it and today's classes.
    /// What was asked lately goes with the first request instead (`recentRequests`), so these
    /// instructions stay the same all day and Claude can reuse them from its cache.
    static var instructions: String {
        guard url != nil else { return "" }
        archiveIfOld()
        var text = """


            Their Daybook is \(relative(url)): today's focus, five tasks, classes, deadlines, emails that need \
            a reply, the rest of today, backlog and inbox. It's their to-do list. For "what's on my daybook", "what do \
            I have to do", "my five things", "my emails" and the like, read it and answer from it. Keep it current \
            without asking: tick a task ([x]) when they say it's done, add what they ask to Today's five or Backlog, \
            and put "remind me tomorrow…" in Inbox. Past days are in \(relative(history))/.
            \(today ?? "")
            \(tomorrow ?? "")
            """
        if let routinesURL {
            text += """

                Routines are in \(relative(routinesURL)): \(routines.isEmpty ? "none yet" : routines.joined(separator: "; ")).
                - When they say a routine's phrase (or clearly mean one), read that routine and do its steps, then say in \
                one line what you did.
                - When they set one up or change one ("when I say let's work on WellPrepped, do…", "from now on, get to \
                work should also…", "instead, do…"), write it in that note without asking: a "## Name" heading, a \
                "Say “…”." line with the phrases, then numbered steps, concrete enough to repeat exactly (apps, \
                sites, workspaces, notes). Change only what they changed. Then confirm in one line.
                - If they say a phrase that sounds like a routine but none matches, ask what it should do, and save it.
                - Open apps with open -a "Name". Switch Vivaldi's workspace with "\(Bundle.main.executablePath ?? "Joe")" \
                --workspace "<name>" (its workspaces: \(Workspace.names.joined(separator: ", "))).
                """
        }
        if !isCurrent {
            text += "\nThere's no Daybook for today yet: build it before you answer anything about their day.\n" + buildRules
        }
        return text
    }

    /// What they asked lately (newest last), sent with the first request of a conversation.
    static var recentRequests: String {
        guard url != nil else { return "" }
        let log = recentLog(limit: 15)
        guard !log.isEmpty else { return "" }
        return "What they asked you lately (newest last), from \(relative(logURL(for: Date())))…:\n" + log.joined(separator: "\n")
    }

    // MARK: - Memory: the conversation log

    private static func logURL(for date: Date) -> URL? {
        history?.appendingPathComponent("Log \(date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month())).md")
    }

    /// One line per request: when, what was asked, and the answer's subject.
    static func log(question: String, reply: String) {
        guard remembers, let url = logURL(for: Date()), !question.isEmpty else { return }
        let (subject, body) = Subject.split(reply)
        let gist = subject ?? String(body.prefix(100))
        let clean = { (text: String) in text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        let line = "- \(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())) — "
            + "“\(clean(String(question.prefix(200))))” → \(clean(gist))\n"
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            let header = """
                ---
                summary: "Everything he asked Joe in \(Date().formatted(.dateTime.month(.wide).year())), one line each, with the answer's gist."
                ---
                # Joe log — \(Date().formatted(.dateTime.month(.wide).year()))


                """
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    /// The last few lines of the log (this month's, and last month's if it's thin).
    static func recentLog(limit: Int) -> [String] {
        guard remembers else { return [] }
        let now = Date()
        let months = [Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now, now]
        let lines = months.compactMap { logURL(for: $0) }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { $0.components(separatedBy: "\n").filter { $0.hasPrefix("- ") } }
        return Array(lines.suffix(limit))
    }
}

extension FormatStyle where Self == Date.ISO8601FormatStyle {
    /// "2026-10-19" in the Mac's time zone (plain `.iso8601` is UTC: before 08:00 in Shenzhen it
    /// would still be yesterday).
    static var localDay: Date.ISO8601FormatStyle { Date.ISO8601FormatStyle(timeZone: .current).year().month().day() }
}
