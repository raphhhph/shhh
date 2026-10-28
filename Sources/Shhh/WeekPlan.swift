import Foundation

/// The week's study plan, `Daybook/Week.md`: each day's study blocks (the same free periods,
/// after-school and evening blocks as the Daybook's Plan, worked around calendar events and done
/// by 23:00), given to what's due soonest, with tests, IAs and project milestones getting more
/// blocks. Built on "plan my week" (`--week-plan`) or on Sunday evening for the week ahead.
/// Each morning a block left unticked moves to the next free slot this week, and the note says
/// what moved. Two events at once become one question in Needs you.
enum WeekPlan {
    static var url: URL? { Daybook.weekURL }

    /// "Mon 27 Oct".
    private static func short(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Mon 27 Oct · 2026-10-27": the date at the end is how a re-plan finds the day.
    private static func heading(_ day: Date) -> String {
        "\(short(day)) · \(day.formatted(.localDay))"
    }

    // MARK: - Building

    /// The plan for the seven days from `first`.
    static func text(from first: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: first)
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let items = CalendarFeed.items(from: start, days: 21)
        let done = Daybook.doneTitles(Daybook.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
        let deadlines = items.filter { item in item.kind == .deadline && !done.contains { Daybook.sameTask($0, item.title) } }
        // Every open project milestone due this week or soon after (an overdue one as due today).
        let milestonesEnd = calendar.date(byAdding: .day, value: 14, to: start) ?? start
        let milestones = IBProjects.openMilestoneItems(now, through: milestonesEnd)
        let work = (deadlines + milestones).filter { $0.start > now || IBProjects.isOverdue($0) }.sorted { a, b in
            let dayA = calendar.startOfDay(for: a.start), dayB = calendar.startOfDay(for: b.start)
            if dayA != dayB { return dayA < dayB }
            return Daybook.isWeighty(a) && !Daybook.isWeighty(b)
        }
        // Blocks each piece of work wants: three for a test, IA, essay or milestone, one otherwise.
        var wanted: [String: Int] = [:]
        for item in work { wanted[item.id] = Daybook.isWeighty(item) ? 3 : 1 }
        let events = items.filter { $0.kind == .event && !$0.allDay }
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let known = Daybook.patterns.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let questions = clashes(events.filter { $0.start < weekEnd }, known: known)
        let range = "\(short(start)) to \(short(days.last ?? start))"
        var lines: [String] = [
            "---",
            "summary: \"Their study plan for \(range): blocks around classes and events, done by 23:00.\"",
            "from: \(start.formatted(.localDay))",
            "updated: \(now.formatted(.localDay)) \(Daybook.hhmm(now))",
            "---",
            "# Week — \(range)",
            "",
            "Study blocks around classes and events, for what's due soonest (tests, IAs and project milestones get more). Tick a block when it's done; one left unticked moves to the next free slot.",
            "",
            "## Needs you",
        ]
        lines += questions.isEmpty ? ["Nothing to settle."] : questions
        lines += ["", "## Moved", "Nothing moved yet."]
        for day in days {
            let dayEvents = events.filter { calendar.isDate($0.start, inSameDayAs: day) }
            let busy = dayEvents.map { ($0.start, $0.end ?? $0.start.addingTimeInterval(3600)) }
            lines += ["", "## \(heading(day))"]
            if !dayEvents.isEmpty {
                lines.append("Busy: " + dayEvents.map { event in
                    "\(Daybook.hhmm(event.start))–\(Daybook.hhmm(event.end ?? event.start.addingTimeInterval(3600))) \(event.title)"
                }.joined(separator: ", "))
            }
            var planned = 0
            var today: [String: Int] = [:]
            // What's really due by the end of the next day comes before a milestone that's overdue
            // or due by then (its date is the student's own).
            let horizon = calendar.date(byAdding: .day, value: 2, to: day) ?? day
            let soft = { (item: CalendarFeed.Item) in IBProjects.yields(item, before: horizon) }
            for block in Daybook.freeBlocks(on: day, busy: busy) where block.end > now {
                // At most two blocks a day for one thing, so a test gets spread over the days before it;
                // a milestone due by tomorrow gets one a day at most, an overdue one on any day (it's already late).
                let eligible = work.filter { item in
                    (IBProjects.isOverdue(item) || item.start > block.end) && (today[item.id] ?? 0) < (soft(item) ? 1 : 2)
                }
                let soon: [CalendarFeed.Item] = eligible.filter { !soft($0) && $0.start < horizon }
                let late: [CalendarFeed.Item] = eligible.filter { soft($0) }
                let rest: [CalendarFeed.Item] = eligible.filter { !soft($0) && $0.start >= horizon }
                let candidates = soon + late + rest
                var ahead = false
                // As in the Daybook's plan: what's due today (after this block) or tomorrow gets the
                // day's blocks first, whether or not it already had its share earlier in the week
                // (two for the most pressing one, then one each). Then a milestone, then
                // what's due later, in due order, until each has the blocks it wants.
                let pressing = work.first { !soft($0) && $0.start > block.end && $0.start < horizon }
                var pick: CalendarFeed.Item? = soon.first { item in
                    (today[item.id] ?? 0) < (item.id == pressing?.id ? 2 : 1)
                }
                if pick == nil { pick = (late + rest).first { (wanted[$0.id] ?? 0) > 0 } }
                // Everything has its blocks: a free day's first block gets ahead on the nearest one.
                if pick == nil, planned == 0, let next = candidates.first(where: { !IBProjects.isOverdue($0) }) { pick = next; ahead = true }
                guard let item = pick else { continue }
                if !ahead { wanted[item.id] = max(0, (wanted[item.id] ?? 0) - 1) }
                today[item.id, default: 0] += 1
                let subject = item.subject.map { $0 == "project" ? "" : " · \($0)" } ?? ""
                // "Get ahead" only before the due day; on the day it's just due today.
                let dueDay = calendar.isDate(item.start, inSameDayAs: day)
                let label = ahead && !dueDay ? "get ahead on " : ""
                let due: String
                if IBProjects.isOverdue(item) {
                    due = "overdue"
                } else if dueDay {
                    due = "due today" + (item.allDay ? "" : " " + Daybook.hhmm(item.start))
                } else {
                    due = "due " + short(item.start)
                }
                lines.append("- [ ] \(Daybook.hhmm(block.start))–\(Daybook.hhmm(block.end)) (\(block.label)): \(label)\(item.title)\(subject) — \(due)")
                planned += 1
            }
            if planned == 0 { lines.append("Nothing planned.") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes Week.md for the seven days from `first` (today by default).
    @discardableResult
    static func build(from first: Date? = nil, now: Date = Date()) -> URL? {
        guard let url else { return nil }
        let plan = text(from: first ?? now, now: now)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? plan.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    /// On Sunday evening, next week's plan, once.
    static func buildIfSundayEvening(_ now: Date = Date()) {
        let calendar = Calendar.current
        guard calendar.component(.weekday, from: now) == 1, calendar.component(.hour, from: now) >= 17, let url,
              let monday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return }
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !existing.contains("from: \(monday.formatted(.localDay))") else { return }
        build(from: monday, now: now)
    }

    // MARK: - Clashes

    /// Two events at once: one question each ("MUN and Volleyball both Thu 30 Oct 15:30: which
    /// one?"), unless Patterns already has the answer ("- Clash: MUN vs Volleyball → Volleyball").
    static func clashes(_ events: [CalendarFeed.Item], known: String) -> [String] {
        let timed = events.filter { $0.kind == .event && !$0.allDay }.sorted { $0.start < $1.start }
        let answered = known.lowercased().components(separatedBy: "\n")
        var found: [String] = []
        for (index, first) in timed.enumerated() {
            let firstEnd = first.end ?? first.start.addingTimeInterval(3600)
            for second in timed[(index + 1)...] {
                guard second.start < firstEnd else { break }
                guard !CalendarFeed.sameThing(first.title, second.title) else { continue }
                let pair = [first.title.lowercased(), second.title.lowercased()]
                if answered.contains(where: { line in pair.allSatisfy { line.contains($0) } }) { continue }
                found.append("- \(first.title) and \(second.title) both \(short(second.start)) \(Daybook.hhmm(second.start)): which one?")
            }
        }
        return found
    }

    // MARK: - Re-planning

    /// "16:10" from an open or ticked block line ("- [ ] 16:10–17:40 (after school): …").
    private static func blockTime(_ line: String) -> String? {
        guard let range = line.range(of: #"^- \[[ xX]\] \d{2}:\d{2}–"#, options: .regularExpression) else { return nil }
        return String(line[range].dropFirst(6).prefix(5))
    }

    /// A block line's task title, however the line was written: "- [ ] 15:55–17:25 (after school):
    /// get ahead on Paper 1 Writing · Chinese B — due Thu 29 Oct · moved from Tue 27 Oct 15:55" →
    /// "Paper 1 Writing". Nil when it isn't a block line.
    static func blockTitle(_ line: String) -> String? {
        let plain = line.replacingOccurrences(of: "~~", with: "")
        guard let colon = plain.range(of: "): ") else { return nil }
        return title(String(plain[colon.upperBound...]))
    }

    /// A task title without what a block line adds around it: "get ahead on ", " · moved from …",
    /// " — due …" and the " · Chinese B" subject. Used on both sides of a match.
    static func title(_ text: String) -> String {
        var rest = text.trimmingCharacters(in: .whitespaces)
        let ahead = "get ahead on "
        if rest.hasPrefix(ahead) { rest = String(rest.dropFirst(ahead.count)) }
        rest = rest.replacingOccurrences(of: #" · moved from .*$"#, with: "", options: .regularExpression)
        let first = rest.components(separatedBy: " — ").first ?? rest
        return (first.components(separatedBy: " · ").first ?? first).trimmingCharacters(in: .whitespaces)
    }

    /// Re-plans `text` (a Week.md): a block left unticked on a day before today is struck through
    /// and moves to the next free slot this week (before its deadline); "## Moved" says what moved,
    /// and one that fits nowhere becomes a question in Needs you. A block whose task was marked done
    /// elsewhere is ticked instead. Nil when there's nothing to change.
    static func replanned(_ text: String, now: Date = Date()) -> (text: String, moves: [String])? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var lines = text.components(separatedBy: "\n")
        var dayOf: [Int: Date] = [:]
        var days: [Date] = []
        var current: Date?
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("## ") {
                current = line.components(separatedBy: " · ").last.flatMap { IBProjects.isoDate($0) }
                if let current { days.append(current) }
                continue
            }
            if let current { dayOf[index] = current }
        }
        // A plan for a week that's over isn't re-planned: the next one is built instead.
        guard days.contains(where: { $0 >= today }) else { return nil }

        let items = CalendarFeed.items(from: today, days: 21)
        let pending = items.filter { $0.kind == .deadline } + IBProjects.openMilestoneItems(now)
        let events = items.filter { $0.kind == .event && !$0.allDay }
        let done = Daybook.doneTitles(Daybook.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
        var taken = Set(lines.indices.compactMap { index -> String? in
            guard let day = dayOf[index], let time = blockTime(lines[index]) else { return nil }
            return "\(day.formatted(.localDay)) \(time)"
        })
        // The slots left this week, in order.
        var slots: [(day: Date, label: String, start: Date, end: Date)] = []
        for day in days where day >= today {
            let busy = events.filter { calendar.isDate($0.start, inSameDayAs: day) }
                .map { ($0.start, $0.end ?? $0.start.addingTimeInterval(3600)) }
            for block in Daybook.freeBlocks(on: day, busy: busy) where block.start > now {
                slots.append((day: day, label: block.label, start: block.start, end: block.end))
            }
        }

        var changed = false
        var moves: [String] = []
        var additions: [(heading: String, line: String)] = []
        var questions: [String] = []
        // Titles already reported, so two missed blocks for one thing make one line.
        var reported: [String] = []
        for index in lines.indices {
            let line = lines[index]
            guard let day = dayOf[index], day < today, line.hasPrefix("- [ ] "), let time = blockTime(line),
                  let colon = line.range(of: "): ") else { continue }
            changed = true
            let body = String(line.dropFirst(6)) // after "- [ ] "
            let rest = String(line[colon.upperBound...]).replacingOccurrences(of: #" · moved from .*$"#, with: "", options: .regularExpression)
            let title = WeekPlan.title(rest)
            if done.contains(where: { Daybook.sameTask($0, title) }) {
                lines[index] = "- [x] " + body
                continue
            }
            // An overdue milestone's "due today" is made up: it can move to any slot left this week.
            // The closest title first, so "Paper 1 Writing" doesn't take "Paper 2 Reading"'s date.
            let due = (pending.first(where: { WeekPlan.title($0.title) == title })
                ?? pending.first(where: { Daybook.sameTask(WeekPlan.title($0.title), title) })
                ?? pending.first(where: { CalendarFeed.sameThing(WeekPlan.title($0.title), title) }))
                .flatMap { IBProjects.isOverdue($0) ? nil : $0.start }
            let was = "\(short(day)) \(time)"
            guard let slot = slots.first(where: { slot in
                !taken.contains("\(slot.day.formatted(.localDay)) \(Daybook.hhmm(slot.start))") && (due.map { slot.end < $0 } ?? true)
            }) else {
                // Still open in a block from today on: say so instead of asking. Matched on the title
                // alone (an overdue milestone's due date is made up, so dates can't be compared).
                let planned = (lines.indices.compactMap { other -> (day: Date, line: String)? in
                    guard let otherDay = dayOf[other], otherDay >= today else { return nil }
                    return (day: otherDay, line: lines[other])
                } + additions.compactMap { addition -> (day: Date, line: String)? in
                    IBProjects.isoDate(addition.heading).map { (day: $0, line: addition.line) }
                }).compactMap { block -> (day: Date, time: String)? in
                    guard block.line.hasPrefix("- [ ] "), let otherTime = blockTime(block.line),
                          let otherTitle = blockTitle(block.line) else { return nil }
                    guard otherTitle.lowercased() == title.lowercased() || Daybook.sameTask(otherTitle, title) else { return nil }
                    return (day: block.day, time: otherTime)
                }
                let first = !reported.contains { CalendarFeed.sameThing($0, title) }
                reported.append(title)
                if planned.isEmpty {
                    lines[index] = "- ~~\(body)~~ didn't fit anywhere else"
                    if first { questions.append("- \(title) (was \(was)) didn't fit anywhere else this week: drop it, or ask for more time?") }
                } else {
                    let byDay = Dictionary(grouping: planned, by: { $0.day })
                    let times = byDay.keys.sorted().map { plannedDay -> String in
                        "\(short(plannedDay)) " + (byDay[plannedDay] ?? []).map { $0.time }.sorted().joined(separator: " and ")
                    }.joined(separator: "; ")
                    lines[index] = "- ~~\(body)~~ already planned \(times)"
                    if first { moves.append("- \(title) (was \(was)): already planned \(times)") }
                }
                continue
            }
            taken.insert("\(slot.day.formatted(.localDay)) \(Daybook.hhmm(slot.start))")
            let to = "\(short(slot.day)) \(Daybook.hhmm(slot.start))"
            lines[index] = "- ~~\(body)~~ moved to \(to)"
            additions.append((heading: slot.day.formatted(.localDay),
                              line: "- [ ] \(Daybook.hhmm(slot.start))–\(Daybook.hhmm(slot.end)) (\(slot.label)): \(rest) · moved from \(was)"))
            moves.append("- \(title): \(was) → \(to)")
        }
        guard changed else { return nil }
        for addition in additions { Daybook.insert(addition.line, under: addition.heading, in: &lines) }
        for move in moves { Daybook.insert(move, under: "Moved", in: &lines) }
        for question in questions { Daybook.insert(question, under: "Needs you", in: &lines) }
        if let stamp = lines.firstIndex(where: { $0.hasPrefix("updated:") }) {
            lines[stamp] = "updated: \(now.formatted(.localDay)) \(Daybook.hhmm(now))"
        }
        return (lines.joined(separator: "\n"), moves + questions)
    }

    /// Re-plans Week.md (at the morning build). Returns what moved.
    @discardableResult
    static func replan(_ now: Date = Date()) -> [String] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8),
              let result = replanned(text, now: now) else { return [] }
        try? result.text.write(to: url, atomically: true, encoding: .utf8)
        return result.moves
    }
}
