import Foundation

/// What the study plan says for now, read for the screen: the next study block (from Week.md, or
/// today's Daybook Plan), the overdue lines in Today's five, and the week's blocks per day. The
/// plans themselves are written by `Daybook` and `WeekPlan`; this only reads them.
enum StudyToday {
    /// Settings → School → Week plan: when study ends each night, how long the after-school block
    /// is, and whether Sunday evening plans the next week.
    enum Settings {
        static var doneByHour: Int {
            let hour = UserDefaults.standard.integer(forKey: "studyDoneBy")
            return (20...24).contains(hour) ? hour : 23
        }
        static var blockMinutes: Int {
            let minutes = UserDefaults.standard.integer(forKey: "studyBlockMinutes")
            return (30...180).contains(minutes) ? minutes : 90
        }
        static var sundayPlan: Bool { UserDefaults.standard.object(forKey: "sundayPlan") as? Bool ?? true }
    }

    struct Block: Hashable {
        var start: Date
        var end: Date
        /// "after school", "free period"…
        var label: String
        var title: String
        var subject: String?
        /// "due Fri 31 Oct", "due today", "overdue", or "exam tomorrow" for revision before an in-class exam.
        var due: String
        var done = false
        /// Revision for an exam sat in class, not work towards an assignment: the line says
        /// "revise for …" or "— exam tomorrow" (the planners' `Assessment` wording).
        var exam = false

        var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
        /// "Paper 2 · 40m", for the notch chip.
        var chip: String { "\(title.count > 22 ? String(title.prefix(21)) + "…" : title) · \(minutes)m" }
        /// What Start asks Joe for.
        var startRequest: String {
            "Start my study block now: \(title)\(subject.map { " (\($0))" } ?? ""), until \(Daybook.hhmm(end)). Set a timer for it and help me get going on the first step."
        }
    }

    struct Overdue: Hashable {
        /// The whole Daybook line, so Done can tick it.
        var line: String
        var title: String
        /// "Mon 20 Oct".
        var since: String
        /// Where to hand it in: the line's ManageBac link.
        var link: URL?
        var emailRequest: String { "Draft a short email to my teacher about \(title), which was due \(since) and is overdue: say when I'll hand it in." }
    }

    // MARK: Reading

    /// "- [ ] 16:10–17:40 (after school): get ahead on BM IA · Business — due Fri 31 Oct", with or
    /// without the box.
    static func block(_ line: String, on day: Date) -> Block? {
        let pattern = #"^- (\[( |x|X)\] )?(\d{1,2}:\d{2})–(\d{1,2}:\d{2}) \(([^)]*)\): (.+?) — (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: line).map { String(line[$0]) }
        }
        guard let from = group(3), let to = group(4), let label = group(5), var title = group(6), let due = group(7),
              let start = time(from, on: day), let end = time(to, on: day) else { return nil }
        var subject: String?
        if let dot = title.range(of: " · ", options: .backwards) {
            subject = String(title[dot.upperBound...])
            title = String(title[..<dot.lowerBound])
        }
        let revise = title.lowercased().hasPrefix("revise for ")
        for prefix in ["get ahead on ", "revise for "] where title.lowercased().hasPrefix(prefix) { title = String(title.dropFirst(prefix.count)) }
        let exam = revise || due.lowercased().hasPrefix("exam")
        return Block(start: start, end: end, label: label, title: title, subject: subject, due: due,
                     done: (group(2) ?? " ").lowercased() == "x", exam: exam)
    }

    private static func time(_ text: String, on day: Date) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    /// Week.md, day by day: "## Mon 27 Oct · 2026-10-27" headings and their block lines.
    static func week(_ text: String? = WeekPlan.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) -> [(day: Date, blocks: [Block])] {
        guard let text else { return [] }
        var days: [(day: Date, blocks: [Block])] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## "), let iso = line.components(separatedBy: " · ").last,
               let day = IBProjects.isoDate(iso.trimmingCharacters(in: .whitespaces)) {
                days.append((day, []))
            } else if let current = days.last, let block = block(line, on: current.day) {
                days[days.count - 1].blocks.append(block)
            }
        }
        return days
    }

    /// Today's blocks: Week.md's day when it has one, else the Daybook's Plan.
    static func blocks(_ now: Date = Date()) -> [Block] {
        if let today = week().first(where: { Calendar.current.isDate($0.day, inSameDayAs: now) }), !today.blocks.isEmpty {
            return today.blocks
        }
        guard Daybook.isCurrent, let url = Daybook.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Daybook.section("Plan", of: text).compactMap { block($0, on: now) }
    }

    /// The block on now, or the next one still to come today.
    static func next(_ now: Date = Date()) -> Block? {
        blocks(now).first { !$0.done && $0.end > now }
    }

    /// Overdue lines anywhere in today's Daybook (Today's five, and Backlog when the five were full),
    /// boxed or plain, not ticked yet.
    static func overdue() -> [Overdue] {
        guard Daybook.isCurrent, let url = Daybook.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").compactMap { line -> Overdue? in
            guard line.hasPrefix("- "), !line.lowercased().hasPrefix("- [x]"),
                  let mark = line.range(of: #"\s[—–-]\s*overdue since "#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            var title = String(line[line.index(line.startIndex, offsetBy: 2)..<mark.lowerBound])
            if title.hasPrefix("[ ] ") { title = String(title.dropFirst(4)) }
            let rest = line[mark.upperBound...]
            let since = rest.components(separatedBy: " · ").first ?? ""
            var link: URL?
            if let open = rest.range(of: "]("), let close = rest[open.upperBound...].firstIndex(of: ")") {
                link = URL(string: String(rest[open.upperBound..<close]))
            }
            return Overdue(line: line, title: title, since: since, link: link)
        }
        .reduce(into: [Overdue]()) { found, item in
            if !found.contains(where: { Daybook.sameTask($0.title, item.title) }) { found.append(item) } // in the five and Backlog once
        }
    }

    /// "May 2028": the exam session onboarding suggests (IBSetup, PR #27): the next May for DP2,
    /// the May after for DP1. A copy of that rule until the two branches meet.
    static func suggestedExamSession(programme: String, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: now), month = calendar.component(.month, from: now)
        let nextMay = month < 5 ? year : year + 1 // as IBSetup.sessions: this May only before May
        let lower = programme.lowercased()
        let second = lower.contains("dp2") || lower.contains("year 2")
        return "May \(second ? nextMay : nextMay + 1)"
    }
}
