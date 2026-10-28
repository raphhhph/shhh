import Foundation

/// The welcome's "Your IB" step, without the view: the exam session, the EE, the IAs (an IO for
/// Language A) and TOK the student said are in progress, and the project notes made from them.
/// The choices are kept in UserDefaults, so the notes can be made later when the notes folder only
/// comes after this step. Notes already there are kept as they are.
@MainActor
enum IBSetup {
    private static let defaults = UserDefaults.standard

    /// The Diploma (and anything not MYP): MYP students have no EE, IAs or TOK.
    static var applies: Bool { !Profile.programme.uppercased().contains("MYP") }

    // MARK: - Choices (the step's @AppStorage keys)

    static var trackEE: Bool {
        get { defaults.object(forKey: "ibTrackEE") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ibTrackEE") }
    }
    static var eeSubject: String {
        get { defaults.string(forKey: "ibEESubject") ?? "" }
        set { defaults.set(newValue, forKey: "ibEESubject") }
    }
    static var eeSupervisor: String {
        get { defaults.string(forKey: "ibEESupervisor") ?? "" }
        set { defaults.set(newValue, forKey: "ibEESupervisor") }
    }
    /// Subjects whose IA (or IO) is in progress, "|"-separated ("Sports, Exercise & Health" has a comma).
    static var iaSubjects: [String] {
        get { (defaults.string(forKey: "ibIASubjects") ?? "").split(separator: "|").map(String.init) }
        set { defaults.set(newValue.joined(separator: "|"), forKey: "ibIASubjects") }
    }
    static var tokEssay: Bool {
        get { defaults.object(forKey: "ibTOKEssay") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ibTOKEssay") }
    }
    static var tokExhibition: Bool {
        get { defaults.object(forKey: "ibTOKExhibition") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ibTOKExhibition") }
    }
    /// Chosen but not made yet (no notes folder when the step was left).
    static var pending: Bool {
        get { defaults.bool(forKey: "ibProjectsPending") }
        set { defaults.set(newValue, forKey: "ibProjectsPending") }
    }

    // MARK: - Subjects

    /// "Math AI HL, ESS SL" → [("Math AI", "HL"), ("ESS", "SL")], as the School step reads it.
    static func levels(_ text: String) -> [(subject: String, level: String)] {
        text.split(separator: ",").compactMap { part -> (subject: String, level: String)? in
            let words = part.trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty else { return nil }
            for level in ["HL", "SL"] where words.hasSuffix(" " + level) {
                return (String(words.dropLast(3)), level)
            }
            return (words, "SL")
        }
    }

    static func joined(_ list: [(subject: String, level: String)]) -> String {
        list.map { "\($0.subject) \($0.level)" }.joined(separator: ", ")
    }

    /// Language A's internal assessment is the Individual Oral.
    static func isLanguageA(_ subject: String) -> Bool {
        subject.contains(" A ") || subject.hasSuffix(" A") || subject.hasPrefix("Literature & Performance")
    }

    static func courseworkKind(_ subject: String) -> IBProjects.Kind { isLanguageA(subject) ? .io : .ia }

    /// Subjects with an IA (or IO) deadline on ManageBac: on to start with.
    static func suggestedIAs(_ subjects: [String], now: Date = Date()) -> [String] {
        let items = CalendarFeed.linkItems().filter { $0.kind == .deadline && $0.start > now }
        return subjects.filter { subject in
            guard let pattern = courseworkKind(subject).titlePattern else { return false }
            let word = subject.lowercased().components(separatedBy: .whitespaces).first ?? ""
            guard !word.isEmpty else { return false }
            return items.contains { item in
                item.title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                    && (item.title.lowercased().contains(word) || (item.subject ?? "").lowercased().contains(word))
            }
        }
    }

    // MARK: - Exam session

    /// "Nov 2026", "May 2027"… from now, about two and a half years ahead.
    static func sessions(_ now: Date = Date()) -> [String] {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        var list: [String] = []
        for y in year...(year + 2) {
            if y > year || month < 5 { list.append("May \(y)") }
            if y > year || month < 11 { list.append("Nov \(y)") }
        }
        return list
    }

    /// DP2: the next May. DP1 (or not said): the May after that.
    static func defaultSession(_ now: Date = Date()) -> String {
        let mays = sessions(now).filter { $0.hasPrefix("May") }
        let programme = Profile.programme.lowercased()
        let secondYear = programme.contains("dp2") || programme.contains("year 2")
        return (secondYear ? mays.first : mays.dropFirst().first) ?? mays.first ?? "May \(Calendar.current.component(.year, from: now) + 2)"
    }

    /// When the session's exams start, roughly: 1 May or 1 November.
    static func sessionStart(_ session: String) -> Date? {
        let parts = session.split(separator: " ")
        guard parts.count == 2, let year = Int(parts[1]) else { return nil }
        let month = parts[0].lowercased().hasPrefix("nov") ? 11 : 5
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))
    }

    /// How long before the exams a school usually wants each one finished.
    static func daysBeforeExams(_ kind: IBProjects.Kind) -> Int {
        switch kind {
        case .ee: 90
        case .ia: 75
        case .tokEssay: 110
        case .tokExhibition: 330
        case .io: 150
        case .cas: 30
        // Kinds added later (uni applications): a deadline months before the exams.
        default: 120
        }
    }

    /// A final date from the exam session, when ManageBac has none. Nil when that's already close
    /// (the template then squeezes the milestones in from today).
    static func defaultFinal(_ kind: IBProjects.Kind, now: Date = Date()) -> Date? {
        guard let start = sessionStart(Profile.examSession),
              let date = Calendar.current.date(byAdding: .day, value: -daysBeforeExams(kind), to: start),
              date > now.addingTimeInterval(14 * 86_400) else { return nil }
        return date
    }

    // MARK: - Making the notes

    /// What was chosen, as (kind, subject, supervisor).
    static func wanted() -> [(kind: IBProjects.Kind, subject: String, supervisor: String)] {
        var list: [(kind: IBProjects.Kind, subject: String, supervisor: String)] = []
        if trackEE { list.append((.ee, eeSubject, eeSupervisor.trimmingCharacters(in: .whitespaces))) }
        for subject in iaSubjects { list.append((courseworkKind(subject), subject, "")) }
        if tokEssay { list.append((.tokEssay, "", "")) }
        if tokExhibition { list.append((.tokExhibition, "", "")) }
        return list
    }

    /// An existing note for it: the same kind (and subject, for an IA). One IO note covers both
    /// Language A subjects, as `IBProjects.create` names it.
    static func tracked(_ kind: IBProjects.Kind, subject: String, in projects: [IBProjects.Project]) -> Bool {
        projects.contains { project in
            project.kind == kind && (kind != .ia || project.subject.caseInsensitiveCompare(subject) == .orderedSame)
        }
    }

    /// Makes a note for each choice not already tracked, once there's a notes folder. The final
    /// date is a matching ManageBac deadline, else one from the exam session (marked as a guess).
    /// Returns the labels made.
    @discardableResult
    static func createPendingProjects(_ now: Date = Date()) -> [String] {
        guard pending, applies, IBProjects.folder != nil else { return [] }
        var projects = IBProjects.all()
        var made: [String] = []
        var failed = false
        for choice in wanted() where !tracked(choice.kind, subject: choice.subject, in: projects) {
            let deadline = IBProjects.matchingDeadline(choice.kind, subject: choice.subject, now: now)
            let fallback = deadline == nil ? defaultFinal(choice.kind, now: now) : nil
            let before = Set(projects.map(\.url.path))
            guard let url = IBProjects.create(choice.kind, subject: choice.subject, finalDate: deadline ?? fallback,
                                              supervisor: choice.supervisor, now: now) else { failed = true; continue }
            if fallback != nil, !before.contains(url.path) { markSessionGuess(url) }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let project = IBProjects.parse(text, url: url)
                projects.append(project)
                made.append(project.label)
            }
        }
        if !failed { pending = false }
        return made
    }

    /// "final: 2028-02-01" → "… # from your exam session: change it to the real date".
    private static func markSessionGuess(_ url: URL) {
        guard var text = try? String(contentsOf: url, encoding: .utf8),
              let range = text.range(of: #"(?m)^final: \d{4}-\d{2}-\d{2}$"#, options: .regularExpression) else { return }
        text.replaceSubrange(range, with: String(text[range]) + " # from your exam session: change it to the real date")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
