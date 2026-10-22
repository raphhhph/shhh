import Foundation

/// Flashcards for definitions: after a whiteboard quiz the tutor lists the terms it asked them to
/// define (and the ones its model answers relied on) with the exact wording, and they're kept per
/// subject beside their school notes ("School/Flashcards/Economics HL.md"), one "term::definition"
/// per line: the Obsidian Spaced Repetition plugin's format, so they work there too. The whiteboard
/// reviews them as a deck ("review my econ flashcards", or Flashcards on the Study page).
enum Flashcards {
    struct Card: Hashable, Identifiable {
        var term: String
        var definition: String
        var id: String { term.lowercased() }
    }

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

    /// "term::definition" (the file), or "term :: definition" / "term | definition" (the tutor).
    static func parse(_ line: String) -> Card? {
        let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
        let separator = trimmed.range(of: "::") ?? trimmed.range(of: " | ")
        guard let separator else { return nil }
        let term = trimmed[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let definition = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !definition.isEmpty, term.count <= 80 else { return nil }
        return Card(term: term, definition: definition)
    }

    /// Adds new cards and updates the definition of ones they already have (same term).
    static func save(_ new: [Card], subject: String) {
        guard !new.isEmpty else { return }
        var all = cards(subject)
        for card in new {
            if let i = all.firstIndex(where: { $0.id == card.id }) { all[i].definition = card.definition } else { all.append(card) }
        }
        let tag = subject.replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let text = "#flashcards/\(tag)\n\nDefinitions from Joe's whiteboard quizzes. Edit freely: one card per line, the term and its definition separated by a double colon.\n\n"
            + all.map { "\($0.term)::\($0.definition.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.write(to: url(for: subject), atomically: true, encoding: .utf8)
    }

    /// The cards they pressed "Again" on in their last review, to come first next time.
    static func missed(_ subject: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: "flashcardsMissed." + subject) ?? []
    }

    static func setMissed(_ ids: [String], subject: String) {
        UserDefaults.standard.set(ids, forKey: "flashcardsMissed." + subject)
    }
}
