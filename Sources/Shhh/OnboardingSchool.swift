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

    /// "Economics HL", "Math AI SL"… in the order they first appear on the student's ManageBac
    /// tasks, at most six. HL or SL when the class name says, otherwise SL.
    static func subjectGuesses() -> [String] {
        var found: [String] = []
        for item in linkItems() where item.kind == .deadline {
            let text = "\(item.title) \(item.detail)"
            // One subject per task: the first that matches.
            guard let subject = subjectWords.first(where: { entry in entry.words.contains { has(text, $0) } })?.subject,
                  !found.contains(where: { $0.hasPrefix(subject + " ") }) else { continue }
            found.append("\(subject) \(has(text, "hl") ? "HL" : "SL")")
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
