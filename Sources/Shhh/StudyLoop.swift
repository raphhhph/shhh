import Foundation

/// The study loop, worked out on the Mac so Claude only has to say it: the morning brief's study
/// lines (one overdue item with its action, today's study blocks, this week's project milestone),
/// the night shutdown's steps (tick what got done, re-plan what slipped, tomorrow's first block,
/// one loop to close), the Sunday week plan's summary, and ticking a task everywhere.
enum StudyLoop {
    /// A local answer for the card: its title, the text, and the one line read aloud.
    struct Reply {
        var subject: String
        var card: String
        var spoken: String
    }

    private static var exe: String { Bundle.main.executablePath ?? "Joe" }

    private static var daybookText: String {
        Daybook.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private static var weekText: String {
        WeekPlan.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    // MARK: - Morning brief

    /// The first open "overdue since" task in the Daybook (Today's five, then Backlog).
    private static func overdueLine(in text: String, projects: Bool = true) -> String? {
        (Daybook.section("Today's five", of: text) + Daybook.section("Backlog", of: text)).first { line in
            line.hasPrefix("- [ ]") && line.contains("overdue since") && (projects || !line.contains("· project"))
        }
    }

    /// "Taxes is overdue since Wed 24 Sep: upload it, email the teacher or mark it done."
    static func overdue(in text: String) -> String? {
        guard let line = overdueLine(in: text) else { return nil }
        let title = Daybook.taskTitle(line)
        var since = ""
        if let range = line.range(of: #"overdue since [^·—/(]+"#, options: .regularExpression) {
            since = String(line[range]).replacingOccurrences(of: "overdue since", with: "").trimmingCharacters(in: .whitespaces)
        }
        let action = line.contains("· project") ? "do it today, or move its date in the project note"
            : "upload it, email the teacher or mark it done"
        return "\(title) is overdue" + (since.isEmpty ? "" : " since \(since)") + ": \(action)."
    }

    /// Today's study blocks from the Daybook's Plan: "16:10–17:40 after school: Taxes · Economics".
    static func blocks(in text: String) -> [String] {
        Daybook.section("Plan", of: text).filter { $0.hasPrefix("- ") }.map { line -> String in
            var body = String(line.dropFirst(2))
            if let due = body.range(of: " — ") { body = String(body[..<due.lowerBound]) }
            return body.replacingOccurrences(of: #"^(\S+) \(([^)]*)\): "#, with: "$1 $2: ", options: .regularExpression)
        }
    }

    /// The open project milestone due soonest this week: "EE: Outline, due Thu 30 Oct (3 days)".
    static func weekMilestone(_ now: Date = Date()) -> String? {
        let soonest = IBProjects.all().compactMap { project -> (label: String, date: Date)? in
            guard let next = project.next, let date = next.date, (0...7).contains(IBProjects.daysLeft(date, now)) else { return nil }
            return (label: "\(project.label): \(next.title)", date: date)
        }.min { $0.date < $1.date }
        guard let soonest else { return nil }
        let left = IBProjects.daysLeft(soonest.date, now)
        return "\(soonest.label), due \(IBProjects.dayName(soonest.date, now))" + (left > 1 ? " (\(left) days)" : "")
    }

    /// The study lines for the morning brief, from today's Daybook (built just before) and the projects.
    static func briefFacts(_ now: Date = Date()) -> String {
        let text = daybookText
        var facts: [String] = []
        if let overdue = overdue(in: text) { facts.append("- Overdue: \(overdue)") }
        let today = blocks(in: text)
        if !today.isEmpty { facts.append("- Study blocks today: " + today.prefix(3).joined(separator: "; ")) }
        if let milestone = weekMilestone(now) { facts.append("- Project milestone this week: \(milestone)") }
        guard !facts.isEmpty else { return "" }
        return """

            Also say these, already worked out from my Daybook and projects, one short sentence each, after what's due \
            (on a day off too):
            """ + "\n" + facts.joined(separator: "\n")
    }

    // MARK: - Night shutdown

    /// A study block's task: "- [ ] 16:10–17:40 (after school): get ahead on Taxes · Economics — due Fri" → "Taxes".
    static func blockTitle(_ line: String) -> String {
        guard let colon = line.range(of: "): ") else { return "" }
        return String(line[colon.upperBound...]).replacingOccurrences(of: "get ahead on ", with: "")
            .components(separatedBy: " — ")[0].components(separatedBy: " · ")[0].trimmingCharacters(in: .whitespaces)
    }

    /// What's still open today: Today's five unticked, then the Plan's blocks, each once.
    static func openToday(in text: String) -> [String] {
        let five = Daybook.section("Today's five", of: text).filter { $0.hasPrefix("- [ ]") }.map { Daybook.taskTitle($0) }
        let planned = Daybook.section("Plan", of: text).filter { $0.hasPrefix("- ") }.map { blockTitle($0) }
        var titles: [String] = []
        for title in five + planned where !title.isEmpty && !titles.contains(where: { $0 == title || Daybook.sameTask($0, title) }) {
            titles.append(title)
        }
        return titles
    }

    /// The first study block on a day in a Week.md text: "16:10 (after school): Taxes, due Fri 31 Oct".
    /// Nil when the plan doesn't cover that day; "" when it does, with nothing planned.
    static func firstBlock(on day: Date, in text: String) -> String? {
        let key = day.formatted(.localDay)
        var inside = false, covered = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                inside = line.hasSuffix(key)
                if inside { covered = true }
                continue
            }
            guard inside, line.hasPrefix("- [ ] "), let open = line.firstIndex(of: "("), let close = line.range(of: "): ") else { continue }
            let time = String(line.dropFirst(6).prefix(5))
            let label = String(line[line.index(after: open)..<close.lowerBound])
            let rest = String(line[close.upperBound...])
            let due = rest.components(separatedBy: " — ").dropFirst().first?
                .replacingOccurrences(of: #" · moved from .*$"#, with: "", options: .regularExpression)
            return "\(time) (\(label)): \(blockTitle(line))" + (due.map { ", \($0)" } ?? "")
        }
        return covered ? "" : nil
    }

    /// Tomorrow's (or any day's) first block: from Week.md, or a plan worked out now when it doesn't cover the day.
    static func firstBlock(on day: Date, now: Date = Date()) -> String? {
        let found = firstBlock(on: day, in: weekText) ?? firstBlock(on: day, in: WeekPlan.text(from: day, now: now))
        return found?.isEmpty == false ? found : nil
    }

    /// "Taxes is still overdue: shall I draft the email to the teacher?" (not a project milestone).
    static func loopClose(in text: String) -> String? {
        overdueLine(in: text, projects: false).map { "\(Daybook.taskTitle($0)) is still overdue: shall I draft the email to the teacher?" }
    }

    /// The study steps added to the night shutdown.
    static func shutdownSteps(_ now: Date = Date()) -> String {
        guard Daybook.url != nil else { return "" }
        let text = daybookText
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let open = openToday(in: text).prefix(6)
        let first = firstBlock(on: tomorrow, now: now)
        var steps: [String] = [
            "1. Ask what I got done today" + (open.isEmpty ? "" : " (still open: \(open.joined(separator: "; ")))")
                + ", and wait for my answer.",
            """
            2. When I answer (even "nothing"): for each thing I did, run "\(exe)" --mark-done "<its title>" (it ticks it in \
            the Daybook, Week.md, Done.md and its project milestone). Then run "\(exe)" --week-replan: today's unticked \
            study blocks move to free slots later this week, and it prints what moved and tomorrow's first block. Say \
            what moved in one line (skip it if nothing did).
            """,
            "3. Say tomorrow's first block: " + (first ?? "nothing planned yet") + " (or the one --week-replan printed, if it changed).",
        ]
        if let offer = loopClose(in: text) {
            steps.append("4. Then offer: \"\(offer)\" If I say yes, write it and save it as a draft: never send it.")
        }
        return "\n\nThen close the day's study loop, one short sentence each:\n" + steps.joined(separator: "\n")
    }

    /// The night's re-plan (`--week-replan`): what moved, and tomorrow's first block.
    static func replanTonight(_ now: Date = Date()) -> String {
        let moves = WeekPlan.replan(now, tonight: true)
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return (moves.isEmpty ? "Nothing moved." : "Moved:\n" + moves.joined(separator: "\n"))
            + "\nTomorrow's first block: " + (firstBlock(on: tomorrow, now: now) ?? "nothing planned")
    }

    // MARK: - The week

    struct WeekSummary {
        var range = ""
        var days: [(day: String, titles: [String])] = []
        var first: String?
        var questions: [String] = []
        var blocks = 0
    }

    /// Week.md in brief: the days' blocks by title, the first block and the Needs you questions.
    static func summary(of text: String) -> WeekSummary {
        var week = WeekSummary()
        var section = ""
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("# Week — ") { week.range = String(line.dropFirst("# Week — ".count)); continue }
            if line.hasPrefix("## ") {
                section = String(line.dropFirst(3))
                if section.contains(" · ") { week.days.append((day: section.components(separatedBy: " · ")[0], titles: [])) }
                continue
            }
            if section == "Needs you", line.hasPrefix("- ") { week.questions.append(String(line.dropFirst(2))); continue }
            guard section.contains(" · "), line.hasPrefix("- [ ] "), !week.days.isEmpty else { continue }
            let title = blockTitle(line)
            guard !title.isEmpty else { continue }
            let last = week.days.count - 1
            week.blocks += 1
            if week.first == nil { week.first = "\(week.days[last].day) \(line.dropFirst(6).prefix(5)), \(title)" }
            if !week.days[last].titles.contains(title) { week.days[last].titles.append(title) }
        }
        return week
    }

    /// The card for a week plan just written ("plan my week", or Sunday evening's).
    static func weekReply(_ text: String, sunday: Bool) -> Reply {
        let week = summary(of: text)
        let header = "**Week.md**" + (week.range.isEmpty ? "" : ", \(week.range)")
            + ": \(week.blocks) study block\(week.blocks == 1 ? "" : "s"), done by 23:00."
        let days = week.days.map { "- \($0.day): " + ($0.titles.isEmpty ? "nothing planned" : $0.titles.joined(separator: ", ")) }
        var parts = [header, days.joined(separator: "\n")]
        if let first = week.first { parts.append("First block: \(first).") }
        if !week.questions.isEmpty { parts.append("To settle: " + week.questions.joined(separator: " ")) }
        var spoken = (sunday ? "Next week's plan is ready" : "Your week is planned") + ": \(week.blocks) study blocks"
            + (week.first.map { ", the first \($0)" } ?? "") + "."
        if let question = week.questions.first { spoken += " " + question }
        return Reply(subject: sunday ? "Next week planned" : "Week planned", card: parts.joined(separator: "\n\n"), spoken: spoken)
    }

    // MARK: - Done

    /// Words that don't tell tasks apart ("the taxes upload" is "Taxes").
    private static let filler: Set<String> = ["the", "my", "a", "an", "our", "task", "upload", "homework", "assignment",
                                              "thing", "one", "it", "that", "all", "of", "on", "for", "to", "and", "s"]

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !filler.contains($0) })
    }

    /// Everything open that could be marked done: Daybook tasks and deadlines, Week.md blocks, project milestones.
    static func openTitles() -> [String] {
        let text = daybookText
        let done = Daybook.doneTitles(text)
        let tasks = text.components(separatedBy: "\n").filter { $0.hasPrefix("- [ ] ") }.map { Daybook.taskTitle($0) }
        let deadlines = Daybook.section("Deadlines", of: text).filter { $0.hasPrefix("- ") && $0.contains(" — ") }.map { line -> String in
            line.components(separatedBy: " — ").dropFirst().joined(separator: " — ")
                .components(separatedBy: " · ")[0].trimmingCharacters(in: .whitespaces)
        }
        let blocks = weekText.components(separatedBy: "\n").filter { $0.hasPrefix("- [ ] ") }.map { blockTitle($0) }
        return (tasks + deadlines + blocks + IBProjects.openLabels()).filter { title in
            !title.isEmpty && !done.contains { Daybook.sameTask($0, title) }
        }
    }

    /// The one open thing `query` names ("the taxes upload", "ee outline"); nil when nothing or
    /// several different things fit.
    static func resolve(_ query: String) -> String? {
        let wanted = words(query)
        guard !wanted.isEmpty else { return nil }
        var found: [String] = []
        for title in openTitles() where wanted.isSubset(of: words(title)) || Daybook.sameTask(title, query) {
            if !found.contains(where: { $0.lowercased() == title.lowercased() || Daybook.sameTask($0, title) }) { found.append(title) }
        }
        if found.count > 1, let exact = found.first(where: { words($0) == wanted }) { return exact }
        return found.count == 1 ? found[0] : nil
    }

    /// Ticks a task everywhere it's open (the Daybook, Week.md, its project milestone) and adds it
    /// to Done.md. Returns where it was ticked.
    @discardableResult
    static func markDone(_ title: String, now: Date = Date()) -> [String] {
        func same(_ other: String) -> Bool { other.lowercased() == title.lowercased() || Daybook.sameTask(other, title) }
        func tick(_ url: URL?, _ matches: (String) -> Bool) -> Bool {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            var lines = text.components(separatedBy: "\n")
            var changed = false
            for index in lines.indices where lines[index].hasPrefix("- [ ] ") && matches(lines[index]) {
                lines[index] = "- [x] " + String(lines[index].dropFirst(6))
                changed = true
            }
            return changed && (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil
        }
        var places: [String] = []
        if tick(Daybook.url, { same(Daybook.taskTitle($0)) }) { places.append("the Daybook") }
        if tick(WeekPlan.url, { same(blockTitle($0)) }) { places.append("the week plan") }
        for project in IBProjects.all() {
            let ticked = tick(project.url) { line in
                guard let milestone = IBProjects.milestone(line), !milestone.done else { return false }
                return same("\(project.label): \(milestone.title)")
            }
            if ticked { places.append(project.name) }
        }
        Daybook.addDone([title], date: now.formatted(.localDay))
        places.append("Done.md")
        return places
    }
}

/// Study requests Joe does himself, without Claude, when the action is clear: "start my Econ IA"
/// (a project note), "plan my week" (Week.md), "done with Paper 2" (ticked everywhere) and "how's
/// my EE going" (its progress). Anything unclear goes to Claude as before.
enum StudyIntent {
    case projectNew(IBProjects.Kind, subject: String, due: Date?)
    case weekPlan(nextWeek: Bool)
    case markDone(String)
    case projectStatus(String)

    /// What `--route` prints.
    var route: String {
        switch self {
        case .projectNew: "local (project new)"
        case .weekPlan: "local (week plan)"
        case .markDone: "local (mark done)"
        case .projectStatus: "local (project status)"
        }
    }

    // MARK: - Understanding

    static func parse(_ said: String) -> StudyIntent? {
        let text = said.replacingOccurrences(of: "’", with: "'").lowercased()
            .replacingOccurrences(of: #"^\W*((hey|ok|okay|yo),?\s+)?(joe,?\s+)?((can|could|would) you\s+|please\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(,?\s*(please|for me|thanks|thank you))+\W*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s.!?]+$"#, with: "", options: .regularExpression)
        guard !text.isEmpty, text.count <= 120 else { return nil }
        return parseWeekPlan(text) ?? parseMarkDone(text) ?? parseProjectStatus(text) ?? parseProjectNew(text)
    }

    /// The `item` group of a pattern's match in `text`.
    private static func item(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(withName: "item"), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    private static func parseWeekPlan(_ text: String) -> StudyIntent? {
        let pattern = #"^(let's\s+)?(plan|make|build|write|sort out|set up|work out)\s+(out\s+)?(me\s+)?(my|the|a|this|next)\s+(next\s+)?(study\s+)?week('s)?(\s+(plan|study plan|schedule))?$|^(make|build|write)\s+(me\s+)?(a|my|the)\s+(weekly|week)\s+(study\s+)?(plan|schedule)$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return .weekPlan(nextWeek: text.contains("next week"))
    }

    private static func parseMarkDone(_ text: String) -> StudyIntent? {
        let patterns = [
            #"^(mark|tick|check)\s+(off\s+)?(?<item>.+?)\s+(as\s+)?(done|finished|complete|completed|handed in|submitted)$"#,
            #"^(tick|check)\s+off\s+(?<item>.+)$"#,
            #"^((i'm|i am|we're)\s+)?(all\s+)?(done|finished)\s+with\s+(?<item>.+)$"#,
            #"^i\s+(just\s+|have\s+|already\s+)?(finished|handed in|submitted|completed)\s+(?<item>.+)$"#,
        ]
        guard let found = patterns.lazy.compactMap({ item($0, text) }).first else { return nil }
        let thing = found.replacingOccurrences(of: #"^(the|my|our)\s+"#, with: "", options: .regularExpression)
        guard !thing.isEmpty, !thing.contains(","), thing.split(separator: " ").count <= 8,
              !["it", "that", "this", "everything", "all", "today"].contains(thing) else { return nil }
        return .markDone(thing)
    }

    private static func parseProjectStatus(_ text: String) -> StudyIntent? {
        let patterns = [
            #"^(how's|hows|how is|how are)\s+(my|the)\s+(?<item>.+?)\s+(going|coming along|looking|doing)$"#,
            #"^(where am i|how far am i|how far along am i)\s+(with|on|in)\s+(my|the)\s+(?<item>.+)$"#,
            #"^how many words\b.*\b(my|the)\s+(?<item>.+)$"#,
            #"^(progress|status)\s+(on|of)\s+(my|the)\s+(?<item>.+)$"#,
        ]
        guard let found = patterns.lazy.compactMap({ item($0, text) }).first else { return nil }
        guard IBProjects.Kind(loose: found) != nil || found.range(of: #"^(ib\s+)?projects?$"#, options: .regularExpression) != nil else { return nil }
        return .projectStatus(found)
    }

    /// Subjects as said, and the name they get (matched to the profile's own spelling when it has one).
    private static let subjects: [(pattern: String, name: String, key: String)] = [
        (#"\b(econ|economics)\b"#, "Economics", "econ"), (#"\b(business management|business|bm)\b"#, "Business Management", "business"),
        (#"\b(maths?|mathematics)( (aa|ai))?\b"#, "Maths", "math"), (#"\bphysics\b"#, "Physics", "physics"),
        (#"\b(chem|chemistry)\b"#, "Chemistry", "chem"), (#"\b(bio|biology)\b"#, "Biology", "bio"), (#"\bess\b"#, "ESS", "ess"),
        (#"\bhistory\b"#, "History", "history"), (#"\b(geo|geography)\b"#, "Geography", "geo"),
        (#"\b(psych|psychology)\b"#, "Psychology", "psych"), (#"\benglish\b"#, "English", "english"),
        (#"\bchinese\b"#, "Chinese", "chinese"), (#"\bspanish\b"#, "Spanish", "spanish"), (#"\bfrench\b"#, "French", "french"),
        (#"\b(computer science|cs)\b"#, "Computer Science", "computer"), (#"\b(visual arts|art)\b"#, "Visual Arts", "art"),
        (#"\bfilm\b"#, "Film", "film"), (#"\b(sehs|sports science)\b"#, "SEHS", "sehs"), (#"\bmusic\b"#, "Music", "music"),
        (#"\btheatre\b"#, "Theatre", "theatre"),
    ]

    /// The subject named in `text` (its name, and the short key that matches its spellings), and the text without it.
    static func subject(in text: String) -> (name: String, key: String, rest: String)? {
        for subject in subjects {
            guard let range = text.range(of: subject.pattern, options: .regularExpression) else { continue }
            let own = Profile.subjects.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.lowercased().contains(subject.key) }
                .map { $0.replacingOccurrences(of: #"\s+(HL|SL)$"#, with: "", options: [.regularExpression, .caseInsensitive]) }
            return (own ?? subject.name, subject.key, text.replacingCharacters(in: range, with: " "))
        }
        return nil
    }

    /// "2027-02-15", "15 feb", "february 15th 2027" in `text` (next year when the day has passed
    /// this year), and the text without it.
    static func date(in text: String, now: Date = Date()) -> (date: Date, rest: String)? {
        if let range = text.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression), let date = IBProjects.isoDate(String(text[range])) {
            return (date, text.replacingCharacters(in: range, with: " "))
        }
        let month = #"(?<m>jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?"#
        let day = #"(?<d>\d{1,2})(st|nd|rd|th)?"#
        let year = #"(,?\s+(?<y>\d{4}))?"#
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        for pattern in [#"\b"# + day + #"\s+(of\s+)?"# + month + year + #"\b"#, #"\b"# + month + #"\s+"# + day + year + #"\b"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range, in: text),
                  let dayRange = Range(match.range(withName: "d"), in: text), let dayNumber = Int(text[dayRange]),
                  let monthRange = Range(match.range(withName: "m"), in: text),
                  let monthIndex = months.firstIndex(of: String(text[monthRange])) else { continue }
            let calendar = Calendar.current
            let yearNumber = Range(match.range(withName: "y"), in: text).flatMap { Int(text[$0]) }
            var parts = DateComponents(year: yearNumber ?? calendar.component(.year, from: now), month: monthIndex + 1, day: dayNumber)
            guard (1...31).contains(dayNumber), var date = calendar.date(from: parts) else { continue }
            if yearNumber == nil, date < calendar.startOfDay(for: now) {
                parts.year = (parts.year ?? 0) + 1
                date = calendar.date(from: parts) ?? date
            }
            return (date, text.replacingCharacters(in: whole, with: " "))
        }
        return nil
    }

    /// Words a project request may have besides its kind, subject and date.
    private static let projectWords: Set<String> = [
        "ee", "extended", "essay", "ia", "internal", "assessment", "tok", "theory", "of", "knowledge", "exhibition", "io",
        "individual", "oral", "cas", "project", "note", "tracker", "for", "in", "on", "with", "due", "by", "final", "deadline",
        "date", "is", "the", "my", "a", "an", "and", "new", "s",
    ]

    private static func parseProjectNew(_ text: String) -> StudyIntent? {
        guard let found = item(#"^(let's\s+)?(start|begin|set up|create|make)\s+(?<item>.+)$"#, text),
              let kind = IBProjects.Kind(loose: found) else { return nil }
        var rest = found
        var due: Date?
        if let dated = date(in: rest) { due = dated.date; rest = dated.rest }
        var subject = ""
        if let named = self.subject(in: rest) { subject = named.name; rest = named.rest }
        // Anything else said ("start writing my TOK essay intro") is more than making the note: Claude's.
        let left = rest.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !projectWords.contains($0) }
        guard left.isEmpty else { return nil }
        // An IA needs its subject to be named; which one is a question for Claude.
        if kind == .ia, subject.isEmpty { return nil }
        return .projectNew(kind, subject: subject, due: due)
    }

    // MARK: - Doing

    /// Does it and says what was done; nil when it can't be settled here (Claude takes it).
    func run(now: Date = Date()) -> StudyLoop.Reply? {
        switch self {
        case let .projectNew(kind, subject, due):
            let before = Set(IBProjects.all().map(\.url))
            guard let url = IBProjects.create(kind, subject: subject, finalDate: due, now: now),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let project = IBProjects.parse(text, url: url)
            guard !before.contains(url) else {
                let status = Self.status(project, now)
                return StudyLoop.Reply(subject: "\(project.label) already started", card: status, spoken: Self.firstSentences(status, 2))
            }
            let steps = project.milestones.filter { !$0.done }.prefix(2).map { milestone -> String in
                milestone.title + (milestone.date.map { " by \(IBProjects.dayName($0, now))" } ?? "")
            }
            let guessed = text.contains("# a guess")
            var card = "Made **\(project.name)** in \(Daybook.relative(url)) from the IB template: \(project.milestones.count) milestones"
                + (project.finalDate.map { ", final \(IBProjects.dayName($0, now))" } ?? "") + (guessed ? " (a guess)" : "") + "."
            if let first = steps.first { card += "\n\nFirst: \(first)." + (steps.count > 1 ? " Then: \(steps[1])." : "") }
            if guessed { card += "\n\nThe final date is a guess: tell me the real one, or change final: in the note." }
            return StudyLoop.Reply(subject: "\(project.label) started", card: card,
                                   spoken: "Started your \(project.label)." + (steps.first.map { " First step: \($0)." } ?? ""))
        case let .weekPlan(nextWeek):
            let calendar = Calendar.current
            let start = nextWeek ? calendar.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? now : now
            guard let url = WeekPlan.build(from: start, now: now), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return StudyLoop.weekReply(text, sunday: false)
        case let .markDone(query):
            guard let title = StudyLoop.resolve(query) else { return nil }
            let places = StudyLoop.markDone(title, now: now)
            return StudyLoop.Reply(subject: "Done: \(title)", card: "Ticked **\(title)**: \(places.joined(separator: ", ")).",
                                   spoken: "Done: \(title), ticked off.")
        case let .projectStatus(query):
            let projects = IBProjects.all()
            let kind = IBProjects.Kind(loose: query)
            let named = StudyIntent.subject(in: query)?.key
            let matching = kind == nil ? projects : projects.filter { project in
                project.kind == kind && (named.map { project.subject.lowercased().contains($0) || project.name.lowercased().contains($0) } ?? true)
            }
            guard !matching.isEmpty else {
                guard let kind else { return StudyLoop.Reply(subject: "No projects yet", card: "No project notes yet: say \"start my EE\" to make one.", spoken: "No project notes yet.") }
                return StudyLoop.Reply(subject: "No \(kind.short) note yet", card: "There's no \(kind.short) note yet: say \"start my \(kind.short)\" and I'll make one.",
                                       spoken: "There's no \(kind.short) note yet.")
            }
            let lines = matching.map { Self.status($0, now) }
            let subject = matching.count == 1 ? "\(matching[0].label): \(matching[0].done)/\(matching[0].milestones.count) milestones" : "Projects"
            return StudyLoop.Reply(subject: subject, card: lines.joined(separator: "\n\n"), spoken: Self.firstSentences(lines[0], 2))
        }
    }

    /// "EE: 3 of 10 milestones done. Next: Outline, due Thu 30 Oct (3 days). 1250 of 4000 words."
    static func status(_ project: IBProjects.Project, _ now: Date) -> String {
        var text = "**\(project.label)**: \(project.done) of \(project.milestones.count) milestones done."
        if let next = project.next {
            text += " Next: \(next.title)"
            if let date = next.date {
                let left = IBProjects.daysLeft(date, now)
                text += left < 0 ? ", overdue by \(-left) day\(left == -1 ? "" : "s")" : left == 0 ? ", due today" : ", due \(IBProjects.dayName(date, now)) (\(left) day\(left == 1 ? "" : "s"))"
            }
            text += "."
        } else if !project.milestones.isEmpty {
            text += " All done."
        }
        if let words = IBProjects.wordCount(doc: project.doc) { text += " \(words)" + (project.words.map { " of \($0)" } ?? "") + " words." }
        let step = project.nextStep
        if !step.isEmpty, project.next.map({ !step.hasPrefix($0.title) }) ?? true { text += "\nNext action: \(step)" }
        return text
    }

    /// The first `count` sentences, without Markdown, to read aloud.
    static func firstSentences(_ text: String, _ count: Int) -> String {
        let plain = text.replacingOccurrences(of: "**", with: "").components(separatedBy: "\n")[0]
        let sentences = plain.components(separatedBy: ". ")
        return sentences.prefix(count).joined(separator: ". ") + (sentences.count > count ? "." : "")
    }
}
