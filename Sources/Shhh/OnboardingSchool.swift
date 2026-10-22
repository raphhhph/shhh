import Foundation

/// What the ManageBac link tells the welcome on its own, so the student doesn't type it again:
/// their subjects (from the class names on their tasks) and what's coming up. Guesses only; the
/// School step shows them prefilled for the student to correct.
extension CalendarFeed {
    /// Subject names as the School step lists them, and words a ManageBac class name might use for
    /// each. More specific names come first ("English B" before "English A").
    private static let subjectWords: [(subject: String, words: [String])] = [
        ("English B", ["english b"]),
        ("English A Literature", ["english a literature", "english literature"]),
        ("English A Lang & Lit", ["english a", "english language and literature", "english lang"]),
        ("Mandarin ab initio", ["mandarin ab initio", "chinese ab initio"]),
        ("Chinese B", ["chinese b", "mandarin b"]),
        ("Chinese A Literature", ["chinese a literature", "chinese literature"]),
        ("Chinese A Lang & Lit", ["chinese a", "chinese language and literature", "chinese lang"]),
        ("Spanish ab initio", ["spanish ab initio"]),
        ("Spanish B", ["spanish b"]),
        ("French ab initio", ["french ab initio"]),
        ("French B", ["french b"]),
        ("Economics", ["economics"]),
        ("Business Management", ["business management", "business"]),
        ("Psychology", ["psychology"]),
        ("History", ["history"]),
        ("Geography", ["geography"]),
        ("Global Politics", ["global politics"]),
        ("Digital Society", ["digital society", "itgs"]),
        ("Philosophy", ["philosophy"]),
        ("Biology", ["biology"]),
        ("Chemistry", ["chemistry"]),
        ("Physics", ["physics"]),
        ("ESS", ["ess", "environmental systems"]),
        ("Computer Science", ["computer science"]),
        ("Sports, Exercise & Health", ["sports, exercise", "sehs"]),
        ("Design Technology", ["design technology"]),
        ("Math AA", ["math aa", "maths aa", "mathematics aa", "analysis and approaches", "analysis & approaches"]),
        ("Math AI", ["math ai", "maths ai", "mathematics ai", "applications and interpretation", "applications & interpretation"]),
        ("Visual Arts", ["visual arts"]),
        ("Music", ["music"]),
        ("Theatre", ["theatre", "theater"]),
        ("Film", ["film"]),
        ("Dance", ["dance"]),
    ]

    /// Words a subject's tasks use without naming it ("Taxes", "Accounts and Finance Summative"),
    /// tried after the class names. ManageBac's feed has no class field.
    private static let typicalWords: [(subject: String, words: [String])] = [
        ("Economics", ["tax", "taxes", "supply", "demand", "elasticity", "gdp", "inflation", "unemployment", "fiscal",
                       "monetary", "tariff", "subsidy", "externality", "market failure"]),
        ("Business Management", ["accounts and finance", "marketing", "stakeholder", "stakeholders", "swot", "cash flow",
                                 "break-even", "human resource", "human resources"]),
        ("ESS", ["ecosystem", "ecosystems", "biodiversity", "sustainability", "pollution", "biome", "biomes"]),
        ("English A Lang & Lit", ["graphic novel", "poem", "poetry", "novel", "individual oral", "io"]),
        ("Math AI", ["calculus", "derivative", "derivatives", "integration", "trigonometry", "probability", "statistics"]),
    ]

    /// "Economics", "Chinese B SL"… in the order they first appear on the student's ManageBac
    /// tasks, at most six: the class named in the title, then in the notes, then Chinese writing
    /// (their Chinese class), then a subject's typical words. HL or SL only when the task says
    /// (MYP has no levels; the School step treats a name without one as SL for the Diploma).
    static func subjectGuesses() -> [String] {
        guard let data = try? Data(contentsOf: feedCache),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        var found: [String] = []
        for entry in entries where entry["kind"] == "deadline" {
            let title = entry["title"] ?? "", notes = (entry["notes"] ?? "") + " " + (entry["detail"] ?? "")
            func named(_ text: String, in list: [(subject: String, words: [String])]) -> String? {
                list.first { item in item.words.contains { has(text, $0) } }?.subject
            }
            let chinese = (title + notes).unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } ? "Chinese B" : nil
            guard let subject = named(title, in: subjectWords) ?? named(notes, in: subjectWords) ?? chinese
                    ?? named(title, in: typicalWords) ?? named(notes, in: typicalWords),
                  !found.contains(where: { $0 == subject || $0.hasPrefix(subject + " ") }) else { continue }
            let level = has(title, "hl") ? " HL" : has(title, "sl") ? " SL" : ""
            found.append(subject + level)
            if found.count == 6 { break }
        }
        return found
    }

    /// The next few ManageBac deadlines, soonest first.
    static func upcomingDeadlines(_ count: Int = 3) -> [Item] {
        let now = Date()
        return Array(linkItems().filter { $0.kind == .deadline && $0.start >= now }.sorted { $0.start < $1.start }.prefix(count))
    }

    /// The word or phrase on its own, not inside another word ("ess" isn't in "assessment").
    private static func has(_ text: String, _ words: String) -> Bool {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: words))\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
