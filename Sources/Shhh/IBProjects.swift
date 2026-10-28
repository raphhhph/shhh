import Foundation

/// The IB's long projects (Extended Essay, IAs, TOK essay and exhibition, IO, CAS) as notes in the
/// vault, one per project in `School/Projects/`, so the student can read and edit them in Obsidian
/// and Claude can with its file tools:
///
///     ---
///     kind: ee
///     subject: Economics
///     supervisor: Ms Li
///     final: 2027-02-15
///     doc: _files/School/EE draft.docx
///     words: 4000
///     ---
///     ## Milestones
///     - [ ] 2026-11-10 · Full first draft to supervisor
///     ## Meetings
///     - 2026-10-26 · Ms Li · Approval panel, D308: narrow the question
///     ## Next action
///     Rewrite the research question.
///
/// Joe makes them from a template with the IB's usual milestones spaced back from the final date,
/// reads progress from them, puts each project's next milestone in the Daybook when it's this week
/// or overdue, and gives the nearest one a study block.
enum IBProjects {
    enum Kind: String, CaseIterable, Identifiable {
        case ee
        case ia
        case tokEssay = "tok-essay"
        case tokExhibition = "tok-exhibition"
        case io
        case cas
        /// University applications (UCAS, Common App or both): not an IB component, but tracked the same way.
        case uni

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ee: "Extended Essay"
            case .ia: "Internal Assessment"
            case .tokEssay: "TOK Essay"
            case .tokExhibition: "TOK Exhibition"
            case .io: "Individual Oral"
            case .cas: "CAS"
            case .uni: "Applications"
            }
        }

        /// How tasks name it: "EE: Outline".
        var short: String {
            switch self {
            case .ee: "EE"
            case .ia: "IA"
            case .tokEssay: "TOK essay"
            case .tokExhibition: "TOK exhibition"
            case .io: "IO"
            case .cas: "CAS"
            case .uni: "Applications"
            }
        }

        /// The word limit, where the IB sets one for every student.
        var wordLimit: Int? {
            switch self {
            case .ee: 4000
            case .tokEssay: 1600
            case .tokExhibition: 950
            default: nil
            }
        }

        /// The IB's usual steps, each with how many days before the final date it's due.
        var milestones: [(title: String, daysBefore: Int)] {
            switch self {
            case .ee: [
                ("Topic and research question", 300),
                ("Proposal to supervisor", 270),
                ("First reflection (RPPF)", 240),
                ("Research and notes", 180),
                ("Outline", 150),
                ("Full first draft to supervisor", 100),
                ("Interim reflection (RPPF)", 90),
                ("Final draft", 14),
                ("Viva voce and final reflection (RPPF)", 7),
                ("Submit the EE", 0),
            ]
            case .ia: [
                ("Proposal and research question", 90),
                ("Data or research done", 70),
                ("Full draft", 45),
                ("Teacher feedback on the draft", 30),
                ("Final IA submitted", 0),
            ]
            case .tokEssay: [
                ("Choose the prescribed title", 60),
                ("Plan: knowledge questions and examples", 45),
                ("Draft to teacher", 28),
                ("Final essay submitted", 0),
            ]
            case .tokExhibition: [
                ("Choose the IA prompt", 42),
                ("Pick the 3 objects", 35),
                ("Commentary draft", 14),
                ("Final exhibition submitted", 0),
            ]
            case .io: [
                ("Choose the global issue", 42),
                ("Pick the two extracts", 28),
                ("Outline (10 bullet points)", 14),
                ("Practice run", 5),
                ("The oral", 0),
            ]
            case .cas: [
                ("Plan CAS experiences", 540),
                ("CAS project started", 360),
                ("All 7 learning outcomes covered", 120),
                ("Reflections up to date", 30),
                ("Final CAS interview and portfolio", 0),
            ]
            case .uni: Kind.uniSteps(ucas: true, commonApp: true)
            }
        }

        /// The steps for `subject`: an application's system ("UCAS", "Common App", or both), else `milestones`.
        func steps(subject: String) -> [(title: String, daysBefore: Int)] {
            guard self == .uni else { return milestones }
            let systems = Kind.uniSystems(subject)
            return Kind.uniSteps(ucas: systems.ucas, commonApp: systems.commonApp)
        }

        /// Which systems an application's subject names; neither named means both.
        static func uniSystems(_ subject: String) -> (ucas: Bool, commonApp: Bool) {
            let lower = subject.lowercased()
            let ucas = lower.contains("ucas"), common = lower.contains("common")
            return ucas || common ? (ucas, common) : (true, true)
        }

        /// UCAS steps counted back from its main deadline (29 Jan: Oxbridge and medicine 15 Oct is 106
        /// days before); Common App's from its Regular deadline (1 Jan: Early 1 Nov is 61 days before).
        /// With both, the final date is UCAS's and Common App's sit 28 days earlier (1 Jan).
        static func uniSteps(ucas: Bool, commonApp: Bool) -> [(title: String, daysBefore: Int)] {
            let ucasSteps: [(title: String, daysBefore: Int)] = [
                ("Shortlist UCAS courses and universities", 240),
                ("UCAS personal statement first draft", 150),
                ("Ask for the UCAS teacher reference", 140),
                ("UCAS personal statement final", 115),
                ("UCAS Oxbridge and medicine deadline (15 Oct, only if applying)", 106),
                ("UCAS reference in and application checked by the school", 21),
                ("UCAS main deadline (29 Jan)", 0),
            ]
            let commonSteps: [(title: String, daysBefore: Int)] = [
                ("Common App college list and account", 180),
                ("Common App essay first draft", 120),
                ("Ask two teachers and the counsellor for Common App recommendations", 100),
                ("Common App essay final", 70),
                ("Common App Early deadline (1 Nov, ED/EA)", 61),
                ("Common App supplemental essays done", 21),
                ("Common App Regular deadline (1 Jan)", 0),
            ]
            let shift = ucas ? 28 : 0
            var steps: [(title: String, daysBefore: Int)] = ucas ? ucasSteps : []
            if commonApp {
                steps += commonSteps.map { (title: $0.title, daysBefore: $0.daysBefore + shift) }
            }
            return steps.sorted { $0.daysBefore > $1.daysBefore }
        }

        /// What a ManageBac deadline for it is called.
        var titlePattern: String? {
            switch self {
            case .ee: #"\b(ee|extended essay)\b"#
            case .ia: #"\b(ia|internal assessment)\b"#
            case .tokEssay: #"\btok\b.*\bessay\b|\bessay\b.*\btok\b|theory of knowledge essay"#
            case .tokExhibition: #"exhibition"#
            case .io: #"\b(io|individual oral)\b"#
            case .cas: nil
            case .uni: #"\b(ucas|common app)\b"#
            }
        }

        /// "ee", "EE", "extended essay", "Maths IA", "TOK Essay.md" → the kind.
        init?(loose text: String) {
            let words = text.lowercased().replacingOccurrences(of: ".md", with: "")
            if let exact = Kind(rawValue: words.trimmingCharacters(in: .whitespaces)) { self = exact; return }
            let found: [(Kind, String)] = [
                (.tokExhibition, #"exhibition"#), (.tokEssay, #"tok.*essay|essay.*tok|theory of knowledge"#),
                (.ee, #"\bee\b|extended essay"#), (.io, #"\bio\b|individual oral"#),
                (.ia, #"\bia\b|internal assessment"#), (.cas, #"\bcas\b"#),
                (.uni, #"\buni\b|\buniversit(y|ies)\b|\bucas\b|common app|\b(college|university|uni)\s+app(lication)?s?\b|\bmy applications?\b|^applications?$"#),
            ]
            guard let match = found.first(where: { words.range(of: $0.1, options: .regularExpression) != nil }) else { return nil }
            self = match.0
        }
    }

    struct Milestone: Hashable {
        var date: Date?
        var title: String
        var done: Bool
    }

    struct Project: Identifiable, Hashable {
        var url: URL
        var kind: Kind?
        var subject = ""
        var supervisor = ""
        var finalDate: Date?
        var doc = ""
        var words: Int?
        var milestones: [Milestone] = []
        var meetings: [String] = []
        var nextAction = ""

        var id: String { url.path }
        var name: String { url.deletingPathExtension().lastPathComponent }

        /// "EE", "Maths AI IA", "TOK essay": how tasks and the Study page name it.
        var label: String {
            guard let kind else { return name }
            if kind == .ia { return subject.isEmpty ? name : "\(subject) IA" }
            return kind.short
        }

        var done: Int { milestones.filter(\.done).count }
        var progress: Double { milestones.isEmpty ? 0 : Double(done) / Double(milestones.count) }

        /// The first milestone not ticked, by date.
        var next: Milestone? {
            milestones.filter { !$0.done }.min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        }

        /// ## Next action, or the next open milestone when that's empty or still names one now ticked.
        var nextStep: String {
            let action = nextAction.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))).lowercased()
            let stale = action.isEmpty || milestones.contains { $0.done && $0.title.lowercased() == action }
            guard stale else { return nextAction }
            return next.map { "\($0.title)." } ?? ""
        }
    }

    // MARK: - Reading

    /// Another folder, given on the command line (`--projects <folder>`).
    static var folderOverride: URL?

    /// `School/Projects` in their notes.
    static var folder: URL? {
        if let folderOverride { return folderOverride }
        return (StudyBuddy.schoolFolder ?? Daybook.root?.appendingPathComponent("School", isDirectory: true))?
            .appendingPathComponent("Projects", isDirectory: true)
    }

    static func all() -> [Project] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
            let url = folder.appendingPathComponent(name)
            return (try? String(contentsOf: url, encoding: .utf8)).map { parse($0, url: url) }
        }
    }

    static func parse(_ text: String, url: URL) -> Project {
        var project = Project(url: url)
        var lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<close] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                var value = String(line[line.index(after: colon)...])
                if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
                value = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                switch key {
                case "kind": project.kind = Kind(loose: value)
                case "subject": project.subject = value
                case "supervisor": project.supervisor = value
                case "final": project.finalDate = isoDate(value)
                case "doc": project.doc = value
                case "words": project.words = Int(value.filter(\.isNumber))
                default: break
                }
            }
            lines = Array(lines[(close + 1)...])
        }
        var section = ""
        for line in lines {
            if line.hasPrefix("## ") { section = line.dropFirst(3).lowercased().trimmingCharacters(in: .whitespaces); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if section.hasPrefix("milestone") {
                if let item = milestone(trimmed) { project.milestones.append(item) }
            } else if section.hasPrefix("meeting") {
                if trimmed.hasPrefix("- ") { project.meetings.append(String(trimmed.dropFirst(2))) }
            } else if section.hasPrefix("next"), project.nextAction.isEmpty {
                project.nextAction = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            }
        }
        if project.kind == nil { project.kind = Kind(loose: project.name) }
        if project.words == nil { project.words = project.kind?.wordLimit }
        return project
    }

    /// "- [ ] 2026-11-10 · Full first draft" → a milestone.
    static func milestone(_ line: String) -> Milestone? {
        let lower = line.lowercased()
        guard lower.hasPrefix("- [ ] ") || lower.hasPrefix("- [x] ") else { return nil }
        var rest = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        var date: Date?
        if rest.count >= 10, let parsed = isoDate(String(rest.prefix(10))) {
            date = parsed
            rest = String(rest.dropFirst(10)).trimmingCharacters(in: CharacterSet(charactersIn: " ·-—:"))
        }
        return Milestone(date: date, title: rest, done: lower.hasPrefix("- [x]"))
    }

    /// "2026-11-10" at midnight, on the Mac's clock.
    static func isoDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    static func daysLeft(_ date: Date, _ now: Date = Date()) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// "today", "tomorrow", "Mon 10 Nov".
    static func dayName(_ date: Date, _ now: Date = Date()) -> String {
        switch daysLeft(date, now) {
        case 0: "today"
        case 1: "tomorrow"
        default: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    // MARK: - Into the Daybook

    /// Each project's next milestone when it's overdue or due within a week, as a Daybook task:
    /// "- [ ] EE: Full first draft to supervisor — due Mon 10 Nov · project".
    static func dailyTasks(_ now: Date = Date()) -> [String] {
        all().compactMap { project -> String? in
            guard let next = project.next, let date = next.date else { return nil }
            let left = daysLeft(date, now)
            guard left <= 7 else { return nil }
            let when = left < 0 ? "overdue since \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))" : "due \(dayName(date, now))"
            return "- [ ] \(project.label): \(next.title) — \(when) · project"
        }
    }

    /// Every milestone not yet ticked, as "EE: Outline", so a Daybook task can tell it's still open.
    static func openLabels() -> [String] {
        all().flatMap { project in project.milestones.filter { !$0.done }.map { "\(project.label): \($0.title)" } }
    }

    /// What an overdue milestone's item carries in `detail`, so the plans can tell it apart.
    static let overdueMark = "overdue"

    /// A milestone as a deadline for the study plans, at the end of its day. An overdue one is
    /// due at the end of today, so it still gets study blocks, and is marked (see `isOverdue`):
    /// the plans give it at most one block a day, after anything really due by tomorrow.
    static func milestoneItem(_ project: Project, _ milestone: Milestone, date: Date, _ now: Date) -> CalendarFeed.Item {
        let late = daysLeft(date, now) < 0
        let day = late ? now : date
        let due = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: day) ?? day
        return CalendarFeed.Item(title: "\(project.label): \(milestone.title)", detail: late ? overdueMark : "",
                                 start: due, allDay: true, kind: .deadline, subject: "project")
    }

    /// Whether a study-plan item is an overdue project milestone (its "due today" isn't real).
    static func isOverdue(_ item: CalendarFeed.Item) -> Bool {
        item.subject == "project" && item.detail == overdueMark
    }

    /// Whether a study-plan item is a project milestone due soon or overdue. Its date is the
    /// student's own (or a template's), so a real deadline due by `horizon` comes before it, and
    /// it gets one block a day at most.
    static func yields(_ item: CalendarFeed.Item, before horizon: Date) -> Bool {
        isOverdue(item) || (item.subject == "project" && item.start < horizon)
    }

    /// Each project's next dated milestone (an overdue one as due today), as a deadline for the study plans.
    static func milestoneItems(_ now: Date = Date()) -> [CalendarFeed.Item] {
        all().compactMap { project -> CalendarFeed.Item? in
            guard let next = project.next, let date = next.date else { return nil }
            return milestoneItem(project, next, date: date, now)
        }
    }

    /// Every open dated milestone due by `end` (overdue ones as due today), for the week's plan.
    static func openMilestoneItems(_ now: Date = Date(), through end: Date? = nil) -> [CalendarFeed.Item] {
        all().flatMap { project -> [CalendarFeed.Item] in
            project.milestones.filter { !$0.done }.compactMap { milestone -> CalendarFeed.Item? in
                guard let date = milestone.date, end.map({ date <= $0 }) ?? true else { return nil }
                return milestoneItem(project, milestone, date: date, now)
            }
        }
    }

    /// The project milestone due soonest, for a block in today's Plan.
    static func nearestMilestone(_ now: Date = Date()) -> CalendarFeed.Item? {
        milestoneItems(now).min { $0.start < $1.start }
    }

    // MARK: - Making one

    /// Makes a project's note from its template (or returns the one already there).
    @discardableResult
    static func create(_ kind: Kind, subject: String = "", finalDate: Date? = nil, supervisor: String = "", now: Date = Date()) -> URL? {
        guard let folder else { return nil }
        let base = kind == .ia ? (subject.isEmpty ? kind.title : "\(subject) IA") : kind.title
        let name = base.replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression)
        let url = folder.appendingPathComponent(name + ".md")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = template(kind, name: name, subject: subject, finalDate: finalDate, supervisor: supervisor, now: now)
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    /// The note: frontmatter, the IB's milestones dated back from the final date (squeezed in
    /// when there's less time than usual), an empty meeting log and the first step as next action.
    /// With no final date given, a matching ManageBac deadline is used, or a guess marked as one.
    static func template(_ kind: Kind, name: String, subject: String, finalDate: Date?, supervisor: String, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let steps = kind.steps(subject: subject)
        let span = steps.map { $0.daysBefore }.max() ?? 0
        let known = finalDate ?? matchingDeadline(kind, subject: subject, now: now)
        let guess = kind == .uni ? uniDeadline(subject: subject, now: now) : calendar.date(byAdding: .day, value: span, to: today)
        let finalDay = calendar.startOfDay(for: known ?? guess ?? today)
        let left = max(0, daysLeft(finalDay, today))
        // Applications keep their real dates (a deadline doesn't squeeze): a step already past is
        // due today, and a deadline already past is left out.
        let scale = kind != .uni && span > left && span > 0 ? Double(left) / Double(span) : 1
        let milestones = steps.compactMap { step -> String? in
            let back = Int((Double(step.daysBefore) * scale).rounded())
            var date = calendar.date(byAdding: .day, value: -back, to: finalDay) ?? finalDay
            if kind == .uni, date < today {
                guard !step.title.lowercased().contains("deadline") else { return nil }
                date = today
            }
            return "- [ ] \(date.formatted(.localDay)) · \(step.title)"
        }
        let log: [String] = kind == .cas ? [""] + CASLog.logHeader : []
        let finalLine = "final: \(finalDay.formatted(.localDay))" + (known == nil ? " # a guess: change it to the real date" : "")
        return ([
            "---",
            "summary: \"\(name) tracker: milestones, supervisor meetings and the next action.\"",
            "kind: \(kind.rawValue)",
            "subject: \(subject)",
            "supervisor: \(supervisor)",
            finalLine,
            "doc: ",
            "words: \(kind.wordLimit.map { String($0) } ?? "")",
            "---",
            "# \(name)",
            "",
            "## Milestones",
        ] + milestones + [
            "",
            "## Meetings",
            "",
            "## Next action",
            "\(steps.first?.title ?? "Plan the first step").",
        ] + log).joined(separator: "\n") + "\n"
    }

    /// The next main deadline for an application: UCAS's 29 Jan (Common App's 1 Jan when it's the
    /// only one), a year later for a first-year student (DP1, grade 11), who applies next autumn.
    static func uniDeadline(subject: String, now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        let systems = Kind.uniSystems(subject)
        let day = DateComponents(month: 1, day: systems.ucas ? 29 : 1)
        guard var date = calendar.nextDate(after: now, matching: day, matchingPolicy: .nextTime) else { return nil }
        let programme = Profile.programme.lowercased()
        if programme.range(of: #"\bdp ?1\b|year 1\b|first year|grade 11|year 12"#, options: .regularExpression) != nil {
            date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
        return date
    }

    /// The date of a ManageBac deadline that looks like this project's final one.
    static func matchingDeadline(_ kind: Kind, subject: String, now: Date = Date()) -> Date? {
        guard let pattern = kind.titlePattern else { return nil }
        let subjectWord = subject.lowercased().components(separatedBy: .whitespaces).first ?? ""
        let found = CalendarFeed.linkItems().filter { item in
            guard item.kind == .deadline, item.start > now,
                  item.title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
            guard kind == .ia, !subjectWord.isEmpty else { return true }
            return item.title.lowercased().contains(subjectWord) || (item.subject ?? "").lowercased().contains(subjectWord)
        }
        return (found.last(where: { $0.title.lowercased().contains("final") }) ?? found.max { $0.start < $1.start })?.start
    }

    // MARK: - Word count

    /// The words in the project's own document, when it's a file on this Mac (.docx, .pages, .rtf
    /// through textutil; .md, .txt read directly). A Google Doc is left to Claude.
    static func wordCount(doc: String) -> Int? {
        guard let file = docFile(doc) else { return nil }
        let text: String?
        switch file.pathExtension.lowercased() {
        case "md", "markdown", "txt": text = try? String(contentsOf: file, encoding: .utf8)
        case "docx", "doc", "pages", "rtf", "odt": text = textutil(file)
        default: text = nil
        }
        return text.map { $0.split(whereSeparator: { $0.isWhitespace }).count }
    }

    /// The doc's file: an absolute path, ~/…, or a path in their notes.
    static func docFile(_ doc: String) -> URL? {
        var path = doc.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.lowercased().hasPrefix("http") else { return nil }
        if path.hasPrefix("[["), path.hasSuffix("]]") { path = String(path.dropFirst(2).dropLast(2)) }
        if path.hasPrefix("file://") { path = URL(string: path)?.path ?? path }
        path = (path as NSString).expandingTildeInPath
        let candidates = path.hasPrefix("/") ? [URL(fileURLWithPath: path)]
            : [Assistant.vaultURL, Daybook.root, folder].compactMap { $0?.appendingPathComponent(path) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func textutil(_ file: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    // MARK: - For the CLI and the assistant

    /// Each project's progress, next milestone and words, and the tasks it adds to today's Daybook.
    static func report(_ now: Date = Date()) -> String {
        guard let folder else { return "No notes vault set." }
        let projects = all()
        if projects.isEmpty {
            return "No projects in \(folder.path) yet. Make one with: Joe --project-new ee \"Economics\" 2027-02-15"
        }
        var lines = projects.map { project -> String in
            var line = "\(project.label) (\(project.name).md): \(project.done)/\(project.milestones.count) milestones done"
            if let next = project.next {
                line += " · next: \(next.title)"
                if let date = next.date {
                    let left = daysLeft(date, now)
                    line += left < 0 ? " (overdue by \(-left) days)" : " (\(dayName(date, now)), \(left) days)"
                }
            } else if !project.milestones.isEmpty {
                line += " · all done"
            }
            if let finalDate = project.finalDate { line += " · final \(finalDate.formatted(.localDay))" }
            if let words = wordCount(doc: project.doc) { line += " · \(words)" + (project.words.map { "/\($0)" } ?? "") + " words" }
            if !project.nextStep.isEmpty { line += "\n    next action: \(project.nextStep)" }
            if let meeting = project.meetings.last { line += "\n    last meeting: \(meeting)" }
            return line
        }
        let tasks = dailyTasks(now)
        lines += ["", "Tasks for today's Daybook:"] + (tasks.isEmpty ? ["(none: no milestone overdue or due within 7 days)"] : tasks)
        if let block = nearestMilestone(now) {
            lines.append(isOverdue(block)
                ? "Study block in today's Plan goes to: \(block.title), overdue (one block a day, after anything due by tomorrow)"
                : "Study block in today's Plan goes to: \(block.title), due \(dayName(block.start, now))")
        }
        return lines.joined(separator: "\n")
    }

    /// For the assistant's instructions.
    static var instructions: String {
        guard let folder else { return "" }
        let exe = Bundle.main.executablePath ?? "Joe"
        let names = all().map(\.name)
        return """


            IB projects (EE, IAs, TOK essay and exhibition, IO, CAS, and uni applications): one note each in \(Daybook.relative(folder))/ \
            (now: \(names.isEmpty ? "none yet" : names.joined(separator: ", "))). Each has frontmatter (kind, subject, \
            supervisor, final, doc, words), ## Milestones as "- [ ] yyyy-mm-dd · step", ## Meetings and ## Next action. \
            Their next milestone shows up in the Daybook by itself.
            - "Start my EE / Maths IA / TOK essay / uni applications…": run "\(exe)" --project-new \
            <ee|ia|tok-essay|tok-exhibition|io|cas|uni> "<subject>" [yyyy-mm-dd final date] ["<supervisor>"] (for uni the \
            subject is "UCAS", "Common App" or "UCAS and Common App"). It makes the note from the IB template with dated \
            milestones and prints them. Say the first two in one line, and ask for the final date if it says it guessed.
            - "I met Ms X about my EE…": add "- yyyy-mm-dd · who · what was agreed" under ## Meetings, and rewrite \
            ## Next action as one line. "Done with my EE outline": tick that milestone ([x]) and the matching Daybook task.
            - CAS: "log CAS: …" and "how's my CAS" are done by Joe himself (a row under ## Log in CAS.md: date, \
            experience, strand, hours, learning outcomes LO1–LO7, evidence). To fix a row, edit the table.
            - "How's my EE going", "how many words": run "\(exe)" --projects and answer from it (milestones done, the next \
            one and days left, words against the limit). For a Google Doc in doc:, read it and count yourself.
            """
    }
}
