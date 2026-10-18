import Foundation

/// What the user has dictated and asked, for the dashboard: its history and stats ("1,240 words
/// dictated this week, 31 minutes saved"). Kept on this Mac only (History.json in Joe's folder),
/// the last 1,000 entries, and only while "Keep history" is on.
struct Activity: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case dictation, ask }
    var id = UUID()
    var date: Date
    var kind: Kind
    var text: String
    /// For a request to Joe: the answer's subject line.
    var answer: String?
    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

enum ActivityLog {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/History.json")

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepHistory") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepHistory") }
    }

    static func load() -> [Activity] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode([Activity].self, from: $0) } ?? []
    }

    static func record(_ kind: Activity.Kind, _ text: String, answer: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !text.isEmpty else { return }
        let entries = Array((load() + [Activity(date: Date(), kind: kind, text: text, answer: answer)]).suffix(1000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(entries).write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Stats

    struct Stats {
        var wordsToday = 0
        var wordsThisWeek = 0
        var asksThisWeek = 0
        /// Days in a row (up to today) with at least one dictation or request.
        var streak = 0
        /// Typing at 40 wpm versus speaking at 150.
        var minutesSaved: Int { Int((Double(wordsThisWeek) / 40 - Double(wordsThisWeek) / 150).rounded()) }
    }

    static func stats(_ entries: [Activity]) -> Stats {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        var stats = Stats()
        for entry in entries {
            if entry.kind == .dictation {
                if calendar.isDateInToday(entry.date) { stats.wordsToday += entry.words }
                if entry.date > weekAgo { stats.wordsThisWeek += entry.words }
            } else if entry.date > weekAgo {
                stats.asksThisWeek += 1
            }
        }
        let days = Set(entries.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day } // today not started yet
        while days.contains(day) {
            stats.streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return stats
    }
}
