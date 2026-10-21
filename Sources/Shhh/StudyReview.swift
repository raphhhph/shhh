import Foundation

/// Spaced repetition from the quiz log: every topic they've been marked on comes back for review
/// after a gap that grows each time they do well (3 days, then about a week, two weeks, a month)
/// and drops back to a day when they don't. Nothing new is stored: the schedule is worked out from
/// "Quiz log.md" each time, so it stays right when they edit the log by hand.
enum StudyReview {
    struct Topic: Hashable {
        /// The subject as they wrote it in the log ("Economics HL"), and its syllabus map.
        let subject: String
        let pack: String?
        /// The topic's latest name ("2.8 Market failure: externalities").
        let topic: String
        let attempts: Int
        /// Their marks the last day they did it, as a fraction.
        let lastScore: Double
        let last: Date
        let due: Date

        var isDue: Bool { due <= Calendar.current.startOfDay(for: Date()) }
        /// Whole days past due (0 when due today, negative when not due yet).
        var daysOverdue: Int {
            Calendar.current.dateComponents([.day], from: due, to: Calendar.current.startOfDay(for: Date())).day ?? 0
        }

        /// "due today", "3 days overdue", "in 4 days".
        var when: String {
            let days = daysOverdue
            if days == 0 { return "due today" }
            if days > 0 { return days == 1 ? "1 day overdue" : "\(days) days overdue" }
            return -days == 1 ? "tomorrow" : "in \(-days) days"
        }
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// "2.8 Externalities" and "2.8 Market failure: externalities" are the same topic: its number
    /// ("2.8", "AHL 1.12", "S1.4", "C3.2", "WH10") when it has one, else its name.
    static func key(_ topic: String) -> String {
        let trimmed = topic.trimmingCharacters(in: .whitespaces)
        if let number = trimmed.range(of: #"^(AHL\s+)?([A-Z]{1,3}\.?)?\d+(\.\d+)*\b"#, options: .regularExpression) {
            return String(trimmed[number]).uppercased()
        }
        return trimmed.lowercased()
    }

    /// Every topic in the log with when it's next due.
    static func topics(_ results: [StudyBuddy.Result] = StudyBuddy.results()) -> [Topic] {
        let groups = Dictionary(grouping: results.filter { !$0.topic.isEmpty && day.date(from: $0.date) != nil }) {
            (StudyBuddy.pack(for: $0.subject) ?? $0.subject.lowercased()) + "|" + key($0.topic)
        }
        return groups.values.compactMap { attempts -> Topic? in
            // One score per day: two answers on a topic in one session count once.
            let days = Dictionary(grouping: attempts, by: \.date).sorted { $0.key < $1.key }
            var interval = 0
            var lastScore = 0.0
            for (_, answers) in days {
                let score = Double(answers.reduce(0) { $0 + $1.score }) / Double(max(1, answers.reduce(0) { $0 + $1.total }))
                interval = next(interval, score)
                lastScore = score
            }
            guard let latest = attempts.last, let lastDay = days.last.flatMap({ day.date(from: $0.key) }),
                  let due = Calendar.current.date(byAdding: .day, value: interval, to: lastDay) else { return nil }
            return Topic(subject: latest.subject, pack: StudyBuddy.pack(for: latest.subject), topic: latest.topic,
                         attempts: attempts.count, lastScore: lastScore, last: lastDay, due: due)
        }
    }

    /// The gap in days before the next review, from the last gap and how they just did.
    static func next(_ interval: Int, _ score: Double) -> Int {
        switch score {
        case 0.8...: return min(60, interval == 0 ? 3 : max(interval + 2, Int((Double(interval) * 2.5).rounded())))
        case 0.5..<0.8: return min(30, interval == 0 ? 2 : max(interval + 1, Int((Double(interval) * 1.3).rounded())))
        default: return 1
        }
    }

    /// What to revise now, most urgent first: the longest overdue, then the lowest marks.
    /// `pack` limits it to one subject's map; `subject` to topics logged under that exact name.
    static func due(pack: String? = nil, subject: String? = nil, from all: [Topic]? = nil) -> [Topic] {
        let subjectPack = subject.flatMap(StudyBuddy.pack(for:))
        return (all ?? topics()).filter { topic in
            guard topic.isDue, pack == nil || topic.pack == pack else { return false }
            guard let subject else { return true }
            return topic.subject == subject || (subjectPack != nil && topic.pack == subjectPack)
        }
        .sorted { ($0.daysOverdue, -$0.lastScore) > ($1.daysOverdue, -$1.lastScore) }
    }

    /// The next topic to come up, when nothing is due.
    static func upcoming(from all: [Topic]? = nil) -> Topic? {
        (all ?? topics()).filter { !$0.isDue }.min { $0.due < $1.due }
    }

    /// For a tutor's or Claude's instructions: what's due, one line each.
    static func lines(_ topics: [Topic], limit: Int = 8) -> String {
        topics.prefix(limit).map {
            "- \($0.subject) · \($0.topic): last \(Int(($0.lastScore * 100).rounded()))%, \($0.when)"
        }.joined(separator: "\n")
    }
}
