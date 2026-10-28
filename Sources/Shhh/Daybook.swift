import Foundation

/// The Daybook: the user's day as a note in the vault (`Daybook.md`), in place of the old Daybook
/// page. The assistant builds it each morning (focus, five tasks, classes, deadlines, emails that
/// need a reply, the rest of the day, backlog) and keeps it current as tasks get done, so "what
/// do I have to do?" is answered from it. Yesterday's moves to `Daybook/History`, which with the
/// conversation log there is the assistant's memory of past days. Classes come from the saved
/// timetable, worked out here rather than by Claude, so they're never misread.
enum Daybook {
    /// The folder the Daybook lives in: the vault's `Brain` (see `NoteSaver.root`), or another one
    /// given on the command line (`--daybook-preview <vault>`), for testing against a copy.
    static var root: URL? { rootOverride ?? NoteSaver.root }
    static var rootOverride: URL?
    static var url: URL? { root?.appendingPathComponent("Daybook.md") }
    static var history: URL? { root?.appendingPathComponent("Daybook/History", isDirectory: true) }
    static var patterns: URL? { root?.appendingPathComponent("Daybook/Patterns.md") }
    static var timetableURL: URL? { root?.appendingPathComponent("_files/School/timetable.json") }
    /// The Google calendar ManageBac's feed is in (from the timetable's config).
    static var managebacCalendarID: String? { timetable?.config?.managebacCalendarId }
    static var routinesURL: URL? { root?.appendingPathComponent("Daybook/Routines.md") }
    /// What they've said is done ("- 2026-10-27 · Taxes upload"), so a past deadline doesn't come back as overdue.
    static var doneURL: URL? { root?.appendingPathComponent("Daybook/Done.md") }

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

    /// Today's or, before 04:00, still yesterday's: a student up past midnight is still in
    /// yesterday's day, so its Daybook stays until the morning instead of a new one at 00:30.
    static var isCurrent: Bool { date == day(Date()) || date == bookDay }

    /// The day the Daybook belongs to now: yesterday until 04:00.
    private static var bookDay: String { day(Date().addingTimeInterval(-4 * 3600)) }

    /// Between midnight and 04:00, when no new Daybook is started.
    static var isLateNight: Bool { Calendar.current.component(.hour, from: Date()) < 4 }

    /// A Daybook from an earlier day goes to History, so today's starts fresh.
    static func archiveIfOld() {
        guard let url, let history, let date, date < bookDay else { return }
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
        guard let entry = schoolDay(on: date, in: timetable) else { return nil }
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
        return (dayLabel(rotation, cycle).map { "\($0): " } ?? "") + periods.joined(separator: ", ")
    }

    /// "Day 9 · Cycle B", "Day 3" for a rotation without cycles, nil for a weekly timetable.
    private static func dayLabel(_ rotation: String, _ cycle: String) -> String? {
        guard Int(rotation) != nil else { return nil }
        return cycle.isEmpty ? "Day \(rotation)" : "Day \(rotation) · Cycle \(cycle)"
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
        if let timetable, let entry = schoolDay(on: date, in: timetable) {
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

    /// Every class in the timetable ("Economics HL", "Chinese B"), for naming a deadline's subject.
    static var classNames: [String] {
        guard let timetable else { return [] }
        let names = timetable.grids.values.joined().filter { $0 != "—" }
            .compactMap { $0.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces) }
        return Array(Set(names.filter { !$0.isEmpty && $0.lowercased() != "advisory" })).sorted()
    }

    /// A day's timetable entry (date, rotation day, cycle), or nil when there's no school: not in
    /// the timetable, or a holiday on their school calendar (see `CalendarFeed.holidays`).
    private static func schoolDay(on date: Date, in timetable: Timetable) -> [Timetable.Value]? {
        let iso = day(date)
        guard !CalendarFeed.holidays.contains(iso),
              let entry = timetable.days.first(where: { $0.first?.text == iso }), entry.count >= 3 else { return nil }
        return entry
    }

    /// Whether there's school on a day (in the saved timetable).
    static func isSchoolDay(_ date: Date) -> Bool {
        guard let timetable else { return !Calendar.current.isDateInWeekend(date) }
        return schoolDay(on: date, in: timetable) != nil
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

    // MARK: - Built here, each morning

    /// Marks the parts of a locally built Daybook that are still Claude's to fill.
    static let pendingMark = "_Joe is still checking this._"

    /// Builds today's Daybook without Claude when there's none yet, and says whether it did.
    @discardableResult
    static func buildLocally(_ now: Date = Date()) -> Bool {
        guard let url, !isCurrent, !isLateNight, let text = localText(now) else { return false }
        recordDone(from: lastNote(now))
        archiveIfOld()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let written = (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
        if written { WeekPlan.replan(now) } // yesterday's unticked study blocks move on
        return written
    }

    /// The last day's note: still today's file if it hasn't been archived yet.
    private static func lastNote(_ now: Date) -> String {
        let lastURL = (date.map { $0 < day(now) } ?? false) ? url : lastArchived
        return lastURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// Today's Daybook from what Joe already has: classes from the timetable; today's events and
    /// the next three weeks' deadlines from the calendar links and the Mac's Calendar; Today's
    /// five, Backlog and Inbox carried over from the last day, with what's due today or tomorrow
    /// added. It takes a moment, where Claude took a minute and a lot of tokens every morning.
    /// What needs their mail or judgement (Needs you, acting on Inbox) is left to Claude, marked
    /// with `pendingMark` (see `finishRules`); so are the calendar parts when Joe can't read one.
    static func localText(_ now: Date = Date()) -> String? {
        guard root != nil else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let today = day(now)
        let tomorrowEnd = calendar.date(byAdding: .day, value: 2, to: start) ?? now
        let ownCalendar = CalendarFeed.readsCalendarItself
        // From two weeks back, for what's overdue.
        let pastStart = calendar.date(byAdding: .day, value: -14, to: start) ?? start
        let all = CalendarFeed.items(from: pastStart, days: 35)
        let items = all.filter { $0.start >= start }
        let deadlines = items.filter { $0.kind == .deadline }
        let events = items.filter { $0.kind == .event && calendar.isDate($0.start, inSameDayAs: now) }

        let last = lastNote(now)
        let done = doneTitles(last)
        func isDone(_ title: String) -> Bool { done.contains { sameTask($0, title) } }

        // A past deadline that isn't done: one task, with the one thing to do about it.
        let manageBac = CalendarFeed.manageBacHome
        let overdue = all.filter { $0.kind == .deadline && $0.start < start && !isDone($0.title) }.map { item -> (title: String, line: String) in
            let since = item.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            let link = (item.url ?? manageBac).map { " ([Open ManageBac](\($0)))" } ?? ""
            return (item.title, "- [ ] \(item.title) — overdue since \(since) · upload it\(link) / email the teacher / mark done"
                + (item.subject.map { " · \($0)" } ?? ""))
        }
        func isOverdue(_ line: String) -> Bool { overdue.contains { sameTask($0.title, taskTitle(line)) } }

        // Yesterday's unticked tasks; a project task goes once its milestone is ticked in the project note.
        let openMilestones = IBProjects.openLabels()
        let carried = section("Today's five", of: last).filter { $0.hasPrefix("- [ ]") && !isOverdue($0) }
            .filter { line in !line.contains("· project") || openMilestones.contains { sameTask($0, taskTitle(line)) } }
            .map(carriedAgain)
            .map { line -> String in
                // "due tomorrow" from yesterday is "due today" now: re-read it from the calendar.
                guard let item = all.first(where: { $0.kind == .deadline && sameTask($0.title, taskTitle(line)) }),
                      let range = line.range(of: #"— due [^·—]+"#, options: .regularExpression) else { return line }
                return line.replacingCharacters(in: range, with: "— due \(when(item, now)) ")
            }
        let inbox = section("Inbox", of: last).filter { $0.hasPrefix("- ") }

        // Backlog, aged: stamped the first day it's seen, raised at a week with a decision to make,
        // moved to Dropped (not deleted) at three weeks.
        var backlog: [String] = []
        var stale: [String] = []
        var dropped = section("Dropped", of: last).filter { $0.hasPrefix("- ") }
        for line in section("Backlog", of: last) where line.hasPrefix("- ") && !line.lowercased().hasPrefix("- [x]") && !isOverdue(line) {
            let entry = stamped(line, today)
            let age = daysOld(entry, now)
            if age >= 21 {
                dropped.append(entry + " · dropped \(today)")
            } else if age >= 7, !entry.contains("decide:"), stale.count < 2 {
                stale.append(checkbox(entry) + " — decide: do, schedule or drop")
            } else {
                backlog.append(entry)
            }
        }

        // Each project's next milestone when it's this week or overdue (see IBProjects).
        let projectTasks = IBProjects.dailyTasks(now).filter { task in !carried.contains { sameTask(taskTitle($0), taskTitle(task)) } }
        backlog.removeAll { line in projectTasks.contains { sameTask(taskTitle($0), taskTitle(line)) } }

        // Due today or tomorrow, unless it's already a task: those come first.
        let urgent = deadlines.filter { $0.start < tomorrowEnd && !isDone($0.title) }
            .filter { item in !carried.contains { CalendarFeed.sameThing($0, item.title) } }
            .map { "- [ ] \($0.title) — due \(when($0, now))" + ($0.subject.map { " · \($0)" } ?? "") }
        var tasks = urgent + overdue.prefix(3).map { $0.line } + projectTasks + carried + stale
        let lateRest = overdue.dropFirst(3).map { $0.line }
        // Never an empty list while the backlog has things in it: at least three, project lines and the oldest first.
        if tasks.count < 3, !backlog.isEmpty {
            let order = backlog.indices.sorted { a, b in
                let projectA = backlog[a].contains("· project"), projectB = backlog[b].contains("· project")
                if projectA != projectB { return projectA }
                let ageA = daysOld(backlog[a], now), ageB = daysOld(backlog[b], now)
                return ageA != ageB ? ageA > ageB : a < b
            }
            let picked = Array(order.prefix(3 - tasks.count))
            tasks += picked.map { checkbox(backlog[$0]) }
            backlog = backlog.indices.filter { !picked.contains($0) }.map { backlog[$0] }
        }
        let five = Array(tasks.prefix(5)), overflow = tasks.dropFirst(5).map { stamped($0, today) }
        // A week-old backlog item that didn't make the five is asked about, not buried in Backlog.
        let staleAsks = stale.filter { !five.contains($0) }.map { line in
            "- \(taskTitle(line)) has waited \(daysOld(line, now)) days: do, schedule or drop?"
        }

        let focus: String
        if let first = five.first {
            focus = "Get \(taskTitle(first)) done."
        } else if let next = deadlines.first {
            focus = "Nothing urgent: get ahead on \(next.title), due \(when(next, now))."
        } else {
            focus = "A clear day: nothing due in the next three weeks."
        }

        let rest: [String] = ownCalendar ? (events.isEmpty ? ["Nothing else on the calendar."] : events.map { event -> String in
            let place = event.detail.isEmpty ? "" : " · \(event.detail)"
            if event.allDay { return "- All day: \(event.title)\(place)" }
            let time = hhmm(event.start) + (event.end.map { "–" + hhmm($0) } ?? "")
            return "- \(time) \(event.title)\(place)"
        }) : [pendingMark]
        let due: [String] = ownCalendar || !deadlines.isEmpty ? (deadlines.isEmpty ? ["Nothing due in the next three weeks."] : deadlines.map { item -> String in
            "- \(when(item, now)) — \(item.title)" + (item.subject.map { " · \($0)" } ?? "")
        }) : [pendingMark]

        let title = now.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let owns = last.components(separatedBy: "\n").prefix(12).first { $0.hasPrefix("owns:") }
            ?? "owns: today's focus, tasks, classes, deadlines and inbox"
        var lines = [
            "---",
            "summary: \"Their day on \(title): focus, five tasks, classes, deadlines, what needs a reply.\"",
            owns,
            "date: \(today)",
            "updated: \(today) \(hhmm(now))",
            "---",
            "# Daybook — \(title)",
            "",
            "**Focus:** \(focus)",
            "",
            "## Today's five",
        ]
        lines += five.isEmpty ? ["Nothing carried over and nothing due today or tomorrow."] : five
        let busy = events.filter { !$0.allDay }.map { ($0.start, $0.end ?? $0.start.addingTimeInterval(3600)) }
        // The project with the nearest milestone gets a block too.
        let work = deadlines.filter { !isDone($0.title) } + (IBProjects.nearestMilestone(now).map { [$0] } ?? [])
        let plan = studyPlan(work, now, busy: busy)
        if !plan.isEmpty { lines += ["", "## Plan"] + plan }
        lines += ["", "## Classes", classTable(on: now), "", "## Rest of today"] + rest
        lines += ["", "## Deadlines"] + due
        // Two things at once today (MUN and Volleyball): one question, unless Patterns has the answer.
        let known = patterns.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        lines += ["", "## Needs you"] + WeekPlan.clashes(events, known: known) + staleAsks + [pendingMark]
        lines += ["", "## Backlog"] + (overflow + lateRest + backlog).prefix(30)
        lines += ["", "## Inbox"] + inbox
        if !dropped.isEmpty {
            lines += ["", "## Dropped", "_Three weeks untouched. Not deleted: move a line back to Backlog to bring it back._"] + dropped.suffix(30)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Closing loops

    /// A task line's title: "- [ ] Taxes upload — due today · Economics" → "Taxes upload".
    static func taskTitle(_ line: String) -> String {
        let text = line.replacingOccurrences(of: #"^\s*- (\[[ xX]\] )?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "~~", with: "")
        return text.components(separatedBy: " — ")[0].components(separatedBy: " · ")[0].trimmingCharacters(in: .whitespaces)
    }

    /// Whether two titles name the same task: (nearly) the same words, numbers included, so
    /// "Quiz: Markets 2" isn't "Quiz: Markets 1".
    static func sameTask(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.8
    }

    /// A backlog line as a task: "- foo" → "- [ ] foo".
    private static func checkbox(_ line: String) -> String {
        line.hasPrefix("- [") ? line : "- [ ] " + String(line.dropFirst(2))
    }

    private static let addedPattern = #"added \d{4}-\d{2}-\d{2}"#

    /// A backlog line with the day it was first seen ("· added 2026-10-27"), for ageing it.
    private static func stamped(_ line: String, _ today: String) -> String {
        line.range(of: addedPattern, options: .regularExpression) != nil ? line : line + " · added \(today)"
    }

    /// Days since a line's "added" stamp (0 without one).
    private static func daysOld(_ line: String, _ now: Date) -> Int {
        guard let range = line.range(of: addedPattern, options: .regularExpression),
              let added = IBProjects.isoDate(String(line[range].dropFirst(6))) else { return 0 }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: added), to: calendar.startOfDay(for: now)).day ?? 0
    }

    /// What's been done: Done.md's titles, and the last day's ticked lines.
    static func doneTitles(_ last: String) -> [String] {
        let log = doneURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let logged = log.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.map { line -> String in
            let parts = line.dropFirst(2).components(separatedBy: " · ")
            return (parts.count > 1 ? parts[1] : parts[0]).trimmingCharacters(in: .whitespaces)
        }
        let ticked = last.components(separatedBy: "\n").filter { $0.lowercased().hasPrefix("- [x]") }.map(taskTitle)
        return (logged + ticked).filter { !$0.isEmpty }
    }

    /// The last day's ticked tasks go in Done.md, which outlasts the day, so a deadline that was
    /// handed in isn't raised as overdue tomorrow.
    private static func recordDone(from last: String) {
        guard let doneURL else { return }
        let ticked = last.components(separatedBy: "\n").filter { $0.lowercased().hasPrefix("- [x]") }.map(taskTitle).filter { !$0.isEmpty }
        guard !ticked.isEmpty else { return }
        var log = (try? String(contentsOf: doneURL, encoding: .utf8))
            ?? "---\nsummary: \"What they've finished, one line each, so it isn't raised as overdue again.\"\n---\n# Done\n\n"
        let known = log.components(separatedBy: "\n")
        let date = last.components(separatedBy: "\n").prefix(12).first { $0.hasPrefix("date:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) } ?? day(Date())
        var changed = false
        for title in Set(ticked) where !known.contains(where: { $0.hasSuffix(" · " + title) }) {
            if !log.hasSuffix("\n") { log += "\n" }
            log += "- \(date) · \(title)\n"
            changed = true
        }
        guard changed else { return }
        try? FileManager.default.createDirectory(at: doneURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? log.write(to: doneURL, atomically: true, encoding: .utf8)
    }

    /// Deadlines that just appeared on the calendar, into today's Daybook: under Deadlines, and as
    /// a task (in Today's five when it's due today or tomorrow and there's room, else Backlog).
    /// Nothing happens before today's Daybook exists: its build picks them up.
    static func addNewDeadlines(_ items: [CalendarFeed.Item], now: Date = Date()) {
        guard let url, isCurrent, var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let calendar = Calendar.current
        let soon = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now
        var lines = text.components(separatedBy: "\n")
        for item in items where !text.contains(item.title) {
            let subject = item.subject.map { " · \($0)" } ?? ""
            insert("- \(when(item, now)) — \(item.title)\(subject)", under: "Deadlines", in: &lines)
            let task = "- [ ] \(item.title) — due \(when(item, now))\(subject) · new"
            let five = section("Today's five", of: lines.joined(separator: "\n")).filter { $0.hasPrefix("- [") }.count
            insert(task, under: item.start < soon && five < 5 ? "Today's five" : "Backlog", in: &lines)
            text = lines.joined(separator: "\n")
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds a line at the end of a `## ` section, replacing a "Nothing …" line there.
    static func insert(_ line: String, under heading: String, in lines: inout [String]) {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## ") && $0.lowercased().contains(heading.lowercased()) }) else { return }
        var end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        if let filler = lines[(start + 1)..<end].firstIndex(where: { $0.hasPrefix("Nothing") }) {
            lines.remove(at: filler)
            end -= 1
        }
        // After the section's last line, before the blank line that ends it.
        var at = end
        while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
        lines.insert(line, at: at)
    }

    /// When to work on what's due: today's free periods, after school and the evening, each given
    /// to the most pressing deadline of the next two weeks (tests and summatives first on the same
    /// day), so the student sees a plan, not just a list. Suggestions, written at the morning build.
    private static func studyPlan(_ deadlines: [CalendarFeed.Item], _ now: Date, busy: [(Date, Date)] = []) -> [String] {
        let calendar = Calendar.current
        guard let fortnight = calendar.date(byAdding: .day, value: 14, to: now) else { return [] }
        let sorted = deadlines.filter { $0.start > now && $0.start < fortnight }.sorted { a, b in
            let dayA = calendar.startOfDay(for: a.start), dayB = calendar.startOfDay(for: b.start)
            if dayA != dayB { return dayA < dayB }
            return isWeighty(a) && !isWeighty(b)
        }
        // What's really due by the end of tomorrow comes first, then a project milestone that's
        // overdue or due by then (its date is the student's own), then the rest.
        let horizon = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? fortnight
        let soft = { (item: CalendarFeed.Item) in IBProjects.yields(item, before: horizon) }
        let soon = sorted.filter { !soft($0) && $0.start < horizon }
        let late = sorted.filter { soft($0) }
        let later = sorted.filter { !soft($0) && $0.start >= horizon }
        let work = soon + late + later
        guard !work.isEmpty else { return [] }
        // Two blocks for the most pressing one still due after the block, then one each; what's
        // due before a block is skipped, not given it. A milestone from `late` gets one at most.
        var given: [String: Int] = [:]
        return freeBlocks(on: now, busy: busy).filter { $0.end > now }.compactMap { block -> String? in
            let upcoming = work.filter { $0.start > block.end }
            guard let first = upcoming.first(where: { !soft($0) }) ?? upcoming.first,
                  let item = upcoming.first(where: { candidate in
                      let cap = soft(candidate) ? 1 : (candidate.id == first.id ? 2 : 1)
                      return (given[candidate.id] ?? 0) < cap
                  }) else { return nil }
            given[item.id, default: 0] += 1
            let due: String = IBProjects.isOverdue(item) ? "overdue" : "due \(when(item, now))"
            return "- \(hhmm(block.start))–\(hhmm(block.end)) (\(block.label)): \(item.title)"
                + (item.subject.map { " · \($0)" } ?? "") + " — \(due)"
        }
    }

    /// A test, summative, IA, essay or project milestone: worth more study time.
    static func isWeighty(_ item: CalendarFeed.Item) -> Bool {
        item.subject == "project"
            || item.title.range(of: #"\b(test|exam|summative|paper|ia|assessment|essay|quiz)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The study blocks on a day: its free periods (a "—" in the grid), 90 minutes from 30 minutes
    /// after the last class, and 19:30–21:00 (10:00–12:00 instead on a day off). They work around
    /// timed events (gym 15:45–16:45 moves after-school work to 16:45, or cuts a block short), end
    /// by 23:00 (the done-by goal), and any left under 30 minutes is dropped.
    static func freeBlocks(on day: Date, busy: [(Date, Date)] = []) -> [(label: String, start: Date, end: Date)] {
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int = 0) -> Date? { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) }
        var blocks: [(label: String, start: Date, end: Date)] = []
        let lessons = timeline(day).filter { $0.kind == .lesson }
        if let timetable, let entry = schoolDay(on: day, in: timetable) {
            let grid = timetable.grids[entry[1].text + entry[2].text] ?? []
            for row in timetable.rows where row.kind == "class" {
                guard let index = row.idx, index < grid.count, grid[index] == "—",
                      let start = time(row.start, on: day), let end = time(row.end, on: day) else { continue }
                blocks.append(("free P\(row.p ?? "?")", start, end))
            }
            if let last = lessons.map({ $0.end ?? $0.start }).max() {
                let start = last.addingTimeInterval(30 * 60)
                blocks.append(("after school", start, start.addingTimeInterval(90 * 60)))
            }
        } else if let start = at(10), let end = at(12) {
            blocks.append(("morning", start, end))
        }
        if let start = at(19, 30), let end = at(21) { blocks.append(("evening", start, end)) }
        let edge = at(23)
        // In time order, and never overlapping: a free last period and "after school" can meet
        // (free P5 14:25–15:25, after school from 14:55), so a later block starts when the one before ends.
        var previousEnd = Date.distantPast
        return blocks.sorted { $0.start < $1.start }.compactMap { block in
            var block = block
            for (start, end) in busy.sorted(by: { $0.0 < $1.0 }) where start < block.end && end > block.start {
                if start > block.start, start.timeIntervalSince(block.start) >= 30 * 60 { block.end = start } else { block.start = end }
            }
            if block.start < previousEnd { block.start = previousEnd }
            if let edge, block.end > edge { block.end = edge }
            guard block.end.timeIntervalSince(block.start) >= 30 * 60 else { return nil }
            previousEnd = block.end
            return block
        }
    }

    /// "08:30" on a day.
    private static func time(_ text: String, on date: Date) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date)
    }

    /// What's left for Claude in a locally built Daybook, or nil when it's all done.
    static var finishRules: String? {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8), text.contains(pendingMark) else { return nil }
        let config = timetable?.config
        let calendarToo = section("Deadlines", of: text).contains(pendingMark) || section("Rest of today", of: text).contains(pendingMark)
        let manageBac = config?.managebacCalendarId ?? "ManageBac"
        let sync = CalendarFeed.syncInstructions.replacingOccurrences(of: " Reply in one line.", with: "")
        let calendarRules = !calendarToo ? "" : """
              - Rest of today: today's Google Calendar events that aren't classes (classes carry #class), as \
            "- 15:00–16:00 Title". Deadlines: the ManageBac calendar (\(manageBac)) for the next three weeks, as \
            "- <day> — Title · Subject". Then, for the dashboard's calendar: \(sync)
            """
        return """
            Today's Daybook (\(relative(url))) was built from their timetable and calendar. Fill in only the parts \
            that say "\(pendingMark)", before you answer anything about their day, and leave the rest as it is:
              - Needs you: keep the lines already there (a clash to settle), then at most three emails or invites from the \
            last day that really need their reply (Gmail inbox, not promotions or social; \(config?.swisLabelId.map { "school mail has label \($0)" } ?? "school mail first")), each with who, \
            what to do and an [Open](link); then "_N others, all noise._". If you can't reach their mail, write "Mail isn't connected."
            \(calendarRules)
              - Inbox: act on its items, then leave it empty. Patterns: read \(relative(patterns)) and add this \
            weekday's regular meetings to Rest of today. On a posting day add ## Post today.
              - Change Focus only if something in Needs you matters more.
            """
    }

    /// The lines under a `## ` heading (matched loosely), up to the next one.
    static func section(_ name: String, of text: String) -> [String] {
        var inside = false
        var found: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inside = line.lowercased().contains(name.lowercased()); continue }
            if inside, !line.trimmingCharacters(in: .whitespaces).isEmpty { found.append(line) }
        }
        return found
    }

    /// A task carried to another day: "carried N×" goes up by one, and from three days it asks for a decision.
    private static func carriedAgain(_ line: String) -> String {
        var text = line.replacingOccurrences(of: " · new", with: "")
        var times = 1
        if let range = text.range(of: #"carried (\d+)×"#, options: .regularExpression) {
            times = (Int(text[range].filter(\.isNumber)) ?? 0) + 1
            text.replaceSubrange(range, with: "carried \(times)×")
        } else {
            text += " · carried 1×"
        }
        if times >= 3, !text.contains("decide:") { text += " — decide: do it today, hand off or drop" }
        return text
    }

    /// "today 15:00", "tomorrow", "Fri 24 Oct 23:59", for a deadline.
    static func when(_ item: CalendarFeed.Item, _ now: Date) -> String {
        let calendar = Calendar.current
        let time = item.allDay ? "" : " " + hhmm(item.start)
        if calendar.isDate(item.start, inSameDayAs: now) { return "today" + time }
        if let next = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(item.start, inSameDayAs: next) { return "tomorrow" + time }
        return item.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + time
    }

    /// "07:05", whatever the Mac's clock style, as the timeline reads it.
    static func hhmm(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The Classes table: Period, Time, Class, Room.
    private static func classTable(on date: Date) -> String {
        guard let timetable, let entry = schoolDay(on: date, in: timetable) else {
            return "No school today."
        }
        let grid = timetable.grids[entry[1].text + entry[2].text] ?? []
        var rows = (dayLabel(entry[1].text, entry[2].text).map { [$0, ""] } ?? []) + ["| Period | Time | Class | Room |", "|---|---|---|---|"]
        for row in timetable.rows {
            switch row.kind {
            case "class":
                guard let index = row.idx, index < grid.count else { continue }
                let parts = grid[index].components(separatedBy: " · ")
                let name = grid[index] == "—" ? "Free" : parts[0]
                rows.append("| P\(row.p ?? "?") | \(row.start)–\(row.end) | \(name) | \(parts.count > 1 ? parts[1] : "") |")
            case "advisory":
                rows.append("| Advisory | \(row.start)–\(row.end) | Advisory | |")
            default: continue
            }
        }
        return rows.joined(separator: "\n")
    }

    /// Forgets the timetable read, so a new one is read at once.
    static func timetableChanged() { cachedTimetable = nil }

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
            \(CalendarFeed.links.isEmpty ? "  - Then, for the dashboard's calendar: " + CalendarFeed.syncInstructions.replacingOccurrences(of: " Reply in one line.", with: "") : "")
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
        text += loopRules
        if !isCurrent { buildLocally() }
        if !isCurrent, !isLateNight {
            text += "\nThere's no Daybook for today yet: build it before you answer anything about their day.\n" + buildRules
        } else if let finish = finishRules {
            text += "\n" + finish
        }
        return text
    }

    /// Closing loops and the week: what overdue, ageing and week lines mean, and what to do with them.
    static var loopRules: String {
        let exe = Bundle.main.executablePath ?? "Joe"
        return """

            Loose ends in the Daybook:
            - "overdue since …" lines have one action each. "Email the teacher": find the class's teacher (their notes, \
            past school mail), write a short, polite email in their voice saying it's late and when they'll hand it in, \
            and save it as a draft (Gmail draft, or a Mail draft): never send it. "Upload it": open the line's ManageBac link.
            - "Mark it done" / "I handed in X": tick it ([x]) everywhere it appears (Today's five, Backlog, \(relative(weekURL)), a \
            project's milestone) and add "- yyyy-mm-dd · <title>" to \(relative(doneURL)), so it isn't raised as overdue again.
            - "decide: do, schedule or drop": do → keep it in Today's five; schedule → give it a day (a date in the line, or a \
            block in \(relative(weekURL))); drop → move the line under ## Dropped (never delete it).
            Week: for "plan my week", run "\(exe)" --week-plan (it writes \(relative(weekURL)): study blocks around classes and \
            events, done by 23:00), then read it and say the plan in two or three lines, and ask its Needs you question if \
            there is one. When they settle a clash ("volleyball, not MUN"), add "- Clash: <one> vs <other> → <choice>" to \
            \(relative(patterns)) and take the question out of the Week note's and Daybook's Needs you.
            """
    }

    /// The week's study plan (see `WeekPlan`).
    static var weekURL: URL? { root?.appendingPathComponent("Daybook/Week.md") }

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

// MARK: - Timetable from a photo or PDF

extension Daybook {
    /// Reads a timetable from a photo, screenshot or PDF and saves it as timetable.json, so a new
    /// student has classes, Now/Next and the Daybook's Classes from the first day. Claude (Sonnet,
    /// with only the Read tool) reads the file; the dates are worked out here. A weekly timetable
    /// repeats Monday to Friday; a rotation ("Day 1" to "Day 8") moves on one day per weekday, from
    /// `dayToday` ("Day 3", or "3") or else Day 1 today. School holidays aren't known, so they
    /// show as school days. An earlier timetable goes to the Trash. Returns a line to show: what
    /// was saved, or what went wrong.
    @MainActor
    static func importTimetable(from file: URL, dayToday: String? = nil) async -> String {
        guard let target = timetableURL else { return "Choose your notes folder first: the timetable is saved there." }
        guard let executable = Assistant.executable else { return "Joe needs Claude set up to read a timetable." }
        let prompt = """
            Read the file \(file.lastPathComponent) in this folder with the Read tool. It's a student's school timetable.
            Reply with JSON only, no other text:
            {"periods": [{"label": "1", "start": "08:30", "end": "09:20"}, …],
             "days": [{"day": "Monday", "classes": ["Economics HL · D304", "—", …]}, …]}
            - periods: the timetable's lessons in order, with 24-hour times. Leave out breaks and lunch. Advisory, \
            homeroom or tutor time is a period labelled "Advisory".
            - days: each column or day as printed ("Monday", or "Day 1" for a rotation), in order. classes has one \
            entry per period, in the same order: the class name as printed with its level (HL/SL) when shown, then \
            " · " and the room when shown, or "—" for a free period. Spell out short names only when the timetable \
            itself does.
            If it isn't a timetable, reply {"error": "<what it is>"}.
            """
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "--model", Assistant.Model.sonnet.rawValue, "--tools", "Read", "--allowedTools", "Read",
                             "--strict-mcp-config", "--setting-sources", "user", "--disable-slash-commands",
                             "--no-session-persistence", "--output-format", "text"]
        process.environment = Assistant.environment()
        process.currentDirectoryURL = file.deletingLastPathComponent()
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let reply: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard (try? process.run()) != nil else { return continuation.resume(returning: nil) }
                let timeout = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timeout)
                input.fileHandleForWriting.write(Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
        guard let reply, let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(reply[open...close].utf8)) as? [String: Any] else {
            return "Joe couldn't read that timetable. Try a clearer photo or the PDF."
        }
        if let error = json["error"] as? String { return "That doesn't look like a timetable (\(error))." }
        let periods = (json["periods"] as? [[String: String]] ?? []).filter { $0["start"] != nil && $0["end"] != nil }
        let days = (json["days"] as? [[String: Any]] ?? []).compactMap { entry -> (label: String, classes: [String])? in
            guard let label = entry["day"] as? String, let classes = entry["classes"] as? [String], !classes.isEmpty else { return nil }
            return (label, classes)
        }
        guard !periods.isEmpty, !days.isEmpty else { return "Joe couldn't find the periods and days in that timetable." }
        guard let saved = timetableJSON(periods: periods, days: days, dayToday: dayToday) else {
            return "Joe couldn't work out the days of that timetable."
        }
        let manager = FileManager.default
        try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: target.path) { try? manager.trashItem(at: target, resultingItemURL: nil) }
        guard (try? saved.write(to: target)) != nil else { return "Joe couldn't save the timetable." }
        timetableChanged()
        let classes = Set(days.flatMap(\.classes).filter { $0 != "—" }.map { $0.components(separatedBy: " · ")[0] })
        return "Saved your timetable: \(days.count) days, \(periods.count) periods, \(classes.count) classes."
    }

    /// timetable.json in the shape `Timetable` reads: dates for the next half year, each with its
    /// timetable day; a grid of classes per day; the periods as rows.
    static func timetableJSON(periods: [[String: String]], days: [(label: String, classes: [String])], dayToday: String?,
                              from now: Date = Date()) -> Data? {
        let weekdays = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        func weekday(_ label: String) -> Int? { weekdays[String(label.lowercased().trimmingCharacters(in: .whitespaces).prefix(3))] }
        let weekly = days.allSatisfy { weekday($0.label) != nil }
        // Grid keys are rotation + cycle; the cycle is left empty here.
        let keys = days.enumerated().map { weekly ? String($0.element.label.prefix(3)) : String($0.offset + 1) }
        var grids: [String: [String]] = [:]
        for (key, day) in zip(keys, days) { grids[key] = day.classes }
        let rows: [[String: Any]] = periods.enumerated().map { index, period -> [String: Any] in
            let label = period["label"] ?? String(index + 1)
            if label.lowercased().range(of: #"advisory|homeroom|tutor"#, options: .regularExpression) != nil {
                return ["kind": "advisory", "start": period["start"] ?? "", "end": period["end"] ?? ""]
            }
            return ["kind": "class", "start": period["start"] ?? "", "end": period["end"] ?? "", "idx": index,
                    "p": label.replacingOccurrences(of: #"^(P|Period)\s*"#, with: "", options: [.regularExpression, .caseInsensitive])]
        }
        let calendar = Calendar.current
        var position = 0
        if !weekly, let dayToday, let number = Int(dayToday.filter(\.isNumber)), number >= 1 { position = (number - 1) % days.count }
        var dated: [[String]] = []
        for offset in 0..<183 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            let number = calendar.component(.weekday, from: date)
            if weekly {
                if let index = days.firstIndex(where: { weekday($0.label) == number }) { dated.append([date.formatted(.localDay), keys[index], ""]) }
            } else if (2...6).contains(number) {
                dated.append([date.formatted(.localDay), keys[position], ""])
                position = (position + 1) % days.count
            }
        }
        guard !dated.isEmpty else { return nil }
        let timetable: [String: Any] = ["days": dated, "grids": grids, "rows": rows, "config": [String: String]()]
        return try? JSONSerialization.data(withJSONObject: timetable, options: [.prettyPrinted, .sortedKeys])
    }
}

extension FormatStyle where Self == Date.ISO8601FormatStyle {
    /// "2026-10-19" in the Mac's time zone (plain `.iso8601` is UTC: before 08:00 in Shenzhen it
    /// would still be yesterday).
    static var localDay: Date.ISO8601FormatStyle { Date.ISO8601FormatStyle(timeZone: .current).year().month().day() }
}
