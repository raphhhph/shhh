import AppKit

/// Flashcards for definitions: after a whiteboard quiz the tutor lists the terms it asked them to
/// define (and the ones its model answers relied on) with the exact wording, and they're kept per
/// subject beside their school notes ("School/Flashcards/Economics HL.md"), one "term::definition"
/// per line. Each card is on a spaced-repetition schedule: graded Again, Hard, Good or Easy, it
/// comes back after a day, then days, weeks and months as they keep knowing it. The schedule is
/// kept on the card's line in the Obsidian Spaced Repetition plugin's format
/// ("term::definition <!--SR:!2026-11-02,3,250-->"), so the deck works the same in Obsidian.
enum Flashcards {
    struct Card: Hashable, Identifiable {
        var term: String
        var definition: String
        /// When it's next due; nil for a card never reviewed.
        var due: Date? = nil
        /// Days between the last review and `due`.
        var interval = 0
        /// How much the gap grows on Good, in percent (250 = 2.5×). Lower for cards they find hard.
        var ease = 250
        var id: String { term.lowercased() }

        var isNew: Bool { due == nil }
        var isDue: Bool { due.map { $0 <= Calendar.current.startOfDay(for: Date()) } ?? false }
    }

    enum Grade: Int, CaseIterable {
        case again = 1, hard, good, easy

        var title: String {
            switch self {
            case .again: "Again"
            case .hard: "Hard"
            case .good: "Good"
            case .easy: "Easy"
            }
        }
    }

    /// The deck's numbers for the Study page.
    struct Stats {
        var total = 0
        var due = 0
        var new = 0
        /// Cards they know well: three weeks or more between reviews.
        var learned = 0
        /// The soonest review when nothing is due.
        var next: Date?
    }

    /// New cards a day, so a big deck after a long quiz doesn't arrive all at once.
    static let newPerDay = 20

    static var folder: URL {
        if let school = StudyBuddy.schoolFolder { return school.appendingPathComponent("Flashcards", isDirectory: true) }
        return PastPapers.folder.appendingPathComponent("Flashcards", isDirectory: true)
    }

    static func url(for subject: String) -> URL {
        folder.appendingPathComponent(subject.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".md")
    }

    static func cards(_ subject: String) -> [Card] {
        guard let text = try? String(contentsOf: url(for: subject), encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").compactMap(parse)
    }

    static func stats(_ subject: String) -> Stats {
        let all = cards(subject)
        return Stats(total: all.count, due: all.filter(\.isDue).count, new: min(newPerDay, all.filter(\.isNew).count),
                     learned: all.filter { $0.interval >= 21 }.count, next: all.compactMap(\.due).min())
    }

    /// Today's reviews: the cards due (longest overdue first), then up to `newPerDay` new ones.
    static func session(_ subject: String) -> [Card] {
        let all = cards(subject)
        let due = all.filter(\.isDue).sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
        return due + all.filter(\.isNew).prefix(newPerDay)
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// "term::definition" (the file, maybe with its schedule), or "term :: definition" /
    /// "term | definition" (the tutor).
    static func parse(_ line: String) -> Card? {
        var trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
        var schedule: (Date, Int, Int)?
        if let comment = trimmed.range(of: #"\s*<!--SR:!\d{4}-\d{2}-\d{2},\d+,\d+-->\s*$"#, options: .regularExpression) {
            // "<!--SR:!2026-11-02,3,250-->": the date, the gap in days, the ease.
            let parts = trimmed[comment].trimmingCharacters(in: .whitespaces).dropFirst(8).dropLast(3).split(separator: ",")
            if parts.count == 3, let date = day.date(from: String(parts[0])), let interval = Int(parts[1]), let ease = Int(parts[2]) {
                schedule = (date, interval, ease)
            }
            trimmed = String(trimmed[..<comment.lowerBound])
        }
        let separator = trimmed.range(of: "::") ?? trimmed.range(of: " | ")
        guard let separator else { return nil }
        // The tutor sometimes bolds the term: "**Tax incidence** :: …".
        let term = trimmed[..<separator.lowerBound].replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        let definition = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !definition.isEmpty, term.count <= 80 else { return nil }
        var card = Card(term: term, definition: definition)
        if let (due, interval, ease) = schedule { card.due = due; card.interval = interval; card.ease = ease }
        return card
    }

    /// Adds new cards and updates the definition of ones they already have (same term), keeping
    /// their schedule.
    static func save(_ new: [Card], subject: String) {
        guard !new.isEmpty else { return }
        var all = cards(subject)
        for card in new {
            if let i = all.firstIndex(where: { $0.id == card.id }) { all[i].definition = card.definition } else { all.append(card) }
        }
        write(all, subject: subject)
    }

    /// A reviewed card's new schedule, written to its line.
    static func update(_ card: Card, subject: String) {
        var all = cards(subject)
        guard let i = all.firstIndex(where: { $0.id == card.id }) else { return }
        all[i].due = card.due
        all[i].interval = card.interval
        all[i].ease = card.ease
        write(all, subject: subject)
    }

    private static func write(_ all: [Card], subject: String) {
        let tag = subject.replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let text = "#flashcards/\(tag)\n\nDefinitions from Joe's whiteboard quizzes. Edit freely: one card per line, the term and its definition separated by a double colon.\n\n"
            + all.map { card in
                let line = "\(card.term)::\(card.definition.replacingOccurrences(of: "\n", with: " "))"
                return card.due.map { line + " <!--SR:!\(day.string(from: $0)),\(card.interval),\(card.ease)-->" } ?? line
            }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.write(to: url(for: subject), atomically: true, encoding: .utf8)
    }

    // MARK: Scheduling

    /// The gap in days a grade would give (the buttons show it: "1d", "4d", "3w").
    static func interval(after grade: Grade, for card: Card) -> Int {
        let last = card.interval
        switch grade {
        case .again: return 0
        case .hard: return card.isNew ? 1 : max(1, Int((Double(last) * 1.2).rounded()))
        case .good: return card.isNew || last == 0 ? 1 : max(last + 1, Int((Double(last) * Double(card.ease) / 100).rounded()))
        case .easy: return card.isNew || last == 0 ? 4 : max(last + 2, Int((Double(last) * Double(card.ease) / 100 * 1.3).rounded()))
        }
    }

    /// The card after a grade: Again brings it back today (it comes round again this session) and
    /// makes it grow more slowly; Easy makes it grow faster.
    static func schedule(_ card: Card, _ grade: Grade) -> Card {
        var card = card
        let days = min(365, interval(after: grade, for: card))
        switch grade {
        case .again: card.ease = max(130, card.ease - 20)
        case .hard: card.ease = max(130, card.ease - 15)
        case .good: break
        case .easy: card.ease = min(350, card.ease + 15)
        }
        card.interval = days
        card.due = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date()))
        return card
    }

    /// "now", "1d", "12d", "3w", "2mo".
    static func short(_ days: Int) -> String {
        switch days {
        case ..<1: "now"
        case ..<14: "\(days)d"
        case ..<60: "\(Int((Double(days) / 7).rounded()))w"
        default: "\(Int((Double(days) / 30).rounded()))mo"
        }
    }

    /// Opens the deck in their Markdown app (Obsidian when it owns .md files).
    @MainActor
    static func open(_ subject: String) {
        let file = url(for: subject)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        NSWorkspace.shared.open(file)
    }
}
