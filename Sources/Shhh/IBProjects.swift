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

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ee: "Extended Essay"
            case .ia: "Internal Assessment"
            case .tokEssay: "TOK Essay"
            case .tokExhibition: "TOK Exhibition"
            case .io: "Individual Oral"
            case .cas: "CAS"
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
            }
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

    /// Each project's next dated milestone from today, as a deadline for the study plans.
    static func milestoneItems(_ now: Date = Date()) -> [CalendarFeed.Item] {
        all().compactMap { project -> CalendarFeed.Item? in
            guard let next = project.next, let date = next.date, daysLeft(date, now) >= 0 else { return nil }
            let due = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date
            return CalendarFeed.Item(title: "\(project.label): \(next.title)", start: due, allDay: true, kind: .deadline, subject: "project")
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
        let steps = kind.milestones
        let span = steps.map { $0.daysBefore }.max() ?? 0
        let known = finalDate ?? matchingDeadline(kind, subject: subject, now: now)
        let finalDay = calendar.startOfDay(for: known ?? calendar.date(byAdding: .day, value: span, to: today) ?? today)
        let left = max(0, daysLeft(finalDay, today))
        let scale = span > left && span > 0 ? Double(left) / Double(span) : 1
        let milestones = steps.map { step -> String in
            let back = Int((Double(step.daysBefore) * scale).rounded())
            let date = calendar.date(byAdding: .day, value: -back, to: finalDay) ?? finalDay
            return "- [ ] \(date.formatted(.localDay)) · \(step.title)"
        }
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
        ]).joined(separator: "\n") + "\n"
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
            if !project.nextAction.isEmpty { line += "\n    next action: \(project.nextAction)" }
            if let meeting = project.meetings.last { line += "\n    last meeting: \(meeting)" }
            return line
        }
        let tasks = dailyTasks(now)
        lines += ["", "Tasks for today's Daybook:"] + (tasks.isEmpty ? ["(none: no milestone overdue or due within 7 days)"] : tasks)
        if let block = nearestMilestone(now) { lines.append("Study block in today's Plan goes to: \(block.title), due \(dayName(block.start, now))") }
        return lines.joined(separator: "\n")
    }

    /// For the assistant's instructions.
    static var instructions: String {
        guard let folder else { return "" }
        let exe = Bundle.main.executablePath ?? "Joe"
        let names = all().map(\.name)
        return """


            IB projects (EE, IAs, TOK essay and exhibition, IO, CAS): one note each in \(Daybook.relative(folder))/ \
            (now: \(names.isEmpty ? "none yet" : names.joined(separator: ", "))). Each has frontmatter (kind, subject, \
            supervisor, final, doc, words), ## Milestones as "- [ ] yyyy-mm-dd · step", ## Meetings and ## Next action. \
            Their next milestone shows up in the Daybook by itself.
            - "Start my EE / Maths IA / TOK essay…": run "\(exe)" --project-new <ee|ia|tok-essay|tok-exhibition|io|cas> \
            "<subject>" [yyyy-mm-dd final date] ["<supervisor>"]. It makes the note from the IB template with dated \
            milestones and prints them. Say the first two in one line, and ask for the final date if it says it guessed.
            - "I met Ms X about my EE…": add "- yyyy-mm-dd · who · what was agreed" under ## Meetings, and rewrite \
            ## Next action as one line. "Done with my EE outline": tick that milestone ([x]) and the matching Daybook task.
            - "How's my EE going", "how many words": run "\(exe)" --projects and answer from it (milestones done, the next \
            one and days left, words against the limit). For a Google Doc in doc:, read it and count yourself.
            """
    }
}
