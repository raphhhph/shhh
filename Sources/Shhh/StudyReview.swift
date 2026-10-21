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
        /// A test in this subject coming up, from their calendar ("Econ Unit 3 test, Thu 23 Oct").
        var test: Test? = nil

        /// Due now, or due by a test in the subject: revise it before the test, not after.
        var isDue: Bool {
            let today = Calendar.current.startOfDay(for: Date())
            return due <= today || (test.map { due <= $0.date } ?? false)
        }
        /// Whole days past due (0 when due today, negative when not due yet).
        var daysOverdue: Int {
            Calendar.current.dateComponents([.day], from: due, to: Calendar.current.startOfDay(for: Date())).day ?? 0
        }

        /// "due today", "3 days overdue", "in 4 days".
        var when: String {
            if let test, due > Calendar.current.startOfDay(for: Date()) {
                return "before \(test.title), \(test.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
            }
            let days = daysOverdue
            if days == 0 { return "due today" }
            if days > 0 { return days == 1 ? "1 day overdue" : "\(days) days overdue" }
            return -days == 1 ? "tomorrow" : "in \(-days) days"
        }
    }

    struct Test: Hashable {
        let pack: String?
        let subject: String
        let title: String
        let date: Date
    }

    private static var testsCache: (at: Date, tests: [Test])?

    /// Tests, exams and assessments in the next two weeks (ManageBac, Google and Mac calendars), each
    /// matched to one of their subjects by the subject's name or its syllabus map's aliases.
    static func tests() -> [Test] {
        if let cache = testsCache, Date().timeIntervalSince(cache.at) < 600 { return cache.tests }
        let subjects = Profile.subjects.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let found = CalendarFeed.items(from: Date(), days: 14).compactMap { item -> Test? in
            guard item.kind == .deadline || item.kind == .event,
                  item.title.range(of: #"\b(test|exam|exams|quiz|assessment|summative|mock|mocks|paper [1-3])\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            else { return nil }
            let pack = StudyBuddy.pack(for: item.title)
            let named = subjects.first { item.title.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
            guard let subject = named ?? subjects.first(where: { pack != nil && StudyBuddy.pack(for: $0) == pack }) else { return nil }
            return Test(pack: StudyBuddy.pack(for: subject), subject: subject, title: item.title, date: Calendar.current.startOfDay(for: item.start))
        }
        testsCache = (Date(), found)
        return found
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
            // "AHL 1.12" in the map is "1.12" in the log.
            return String(trimmed[number]).uppercased().replacingOccurrences(of: #"^AHL\s+"#, with: "", options: .regularExpression)
        }
        return trimmed.lowercased()
    }

    /// Every topic in the log with when it's next due.
    static func topics(_ results: [StudyBuddy.Result] = StudyBuddy.results()) -> [Topic] {
        let coming = tests()
        // Topics show under the subject as it is in their profile ("Economics HL"), even when older
        // log lines say "Economics".
        let profile = Profile.subjects.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
            let pack = StudyBuddy.pack(for: latest.subject)
            let subject = pack.flatMap { pack in profile.first { StudyBuddy.pack(for: $0) == pack } } ?? latest.subject
            let test = coming.first { (pack != nil && $0.pack == pack) || $0.subject == subject }
            return Topic(subject: subject, pack: pack, topic: latest.topic,
                         attempts: attempts.count, lastScore: lastScore, last: lastDay, due: due, test: test)
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

    /// What to revise now, most urgent first: the soonest test, then the longest overdue, then the lowest marks.
    /// `pack` limits it to one subject's map; `subject` to topics logged under that exact name.
    static func due(pack: String? = nil, subject: String? = nil, from all: [Topic]? = nil) -> [Topic] {
        let subjectPack = subject.flatMap(StudyBuddy.pack(for:))
        return (all ?? topics()).filter { topic in
            guard topic.isDue, pack == nil || topic.pack == pack else { return false }
            guard let subject else { return true }
            return topic.subject == subject || (subjectPack != nil && topic.pack == subjectPack)
        }
        .sorted { a, b in
            let testA = a.test?.date ?? .distantFuture, testB = b.test?.date ?? .distantFuture
            if testA != testB { return testA < testB }
            return (a.daysOverdue, -a.lastScore) > (b.daysOverdue, -b.lastScore)
        }
    }

    /// The next topic to come up, when nothing is due.
    static func upcoming(from all: [Topic]? = nil) -> Topic? {
        (all ?? topics()).filter { !$0.isDue }.min { $0.due < $1.due }
    }

    /// How much of a subject's syllabus map they've been marked on: the numbered subtopics, and those
    /// with no quiz answer yet (in syllabus order).
    static func coverage(subject: String, from all: [Topic]? = nil) -> (total: Int, done: Int, untouched: [String]) {
        guard let pack = StudyBuddy.pack(for: subject) else { return (0, 0, []) }
        let sections = PastPapers.sections(pack)
        let practised = Set((all ?? topics()).filter { $0.pack == pack }.map { key($0.topic) })
        let untouched = sections.filter { !practised.contains(key($0.label)) }.map(\.label)
        return (sections.count, sections.count - untouched.count, untouched)
    }

    /// For a tutor's or Claude's instructions: what's due, one line each.
    static func lines(_ topics: [Topic], limit: Int = 8) -> String {
        topics.prefix(limit).map {
            "- \($0.subject) · \($0.topic): last \(Int(($0.lastScore * 100).rounded()))%, \($0.when)"
        }.joined(separator: "\n")
    }
}
