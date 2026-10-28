import Foundation

/// The weekly wellbeing check-in, `Daybook/Wellbeing.md`: last week's average sleep and stress
/// from 1 to 5, asked with Sunday's week plan (or on "how am I doing"), answered in one line
/// ("stress 4, slept 6 hours"). A hard week (stress 4 or more, or under 6.5 hours of sleep) makes
/// the next week plan lighter: one block at most on weekday evenings, none after 21:00 on school nights.
///
///     | Date | Sleep (avg h) | Stress (1–5) | Note |
///     |---|---|---|---|
///     | 2026-10-26 | 6 | 4 | mocks week |
enum Wellbeing {
    struct Entry {
        var date: Date
        var sleep: Double?
        var stress: Int?
        var note: String
    }

    static var url: URL? { Daybook.root?.appendingPathComponent("Daybook/Wellbeing.md") }

    /// The one question, on Sunday's card and for "how am I doing".
    static let question = "Quick check-in: how many hours did you sleep a night last week, and your stress from 1 to 5? Say it like \"stress 3, slept 7 hours\"."

    /// How long a check-in counts for the week plan.
    static let freshDays = 14

    // MARK: - Understanding

    /// "stress 4, slept 6 hours", "wellbeing: 3, 7h", "slept about 6.5 hours, stress is 2" → an entry.
    /// Nil when it isn't an answer to the check-in.
    static func parse(_ text: String, now: Date = Date()) -> Entry? {
        var rest = text.lowercased()
        let prefixed = rest.range(of: #"^(wellbeing|well-being|check[- ]?in)\s*[:,\-–—]?\s*"#, options: .regularExpression)
        // Said as an answer: it starts with the stress or the sleep ("stress 4…", "I slept 6 hours…").
        let answer = rest.range(of: #"^((my|the)\s+)?(stress(ed)?|sleep)\b|^(i\s+)?(slept|sleep|sleeping|got)\b"#, options: .regularExpression) != nil
        guard prefixed != nil || answer else { return nil }
        if let prefixed { rest.replaceSubrange(prefixed, with: "") }

        var sleep: Double?
        if let found = capture(#"(?<n>\d+(\.\d+)?)\s*(h|hrs?|hours?)\b(\s+(of\s+)?sleep)?"#, in: &rest) { sleep = Double(found) }
        var stress: Int?
        if let found = capture(#"\bstress(ed)?\s*(level\s*)?(is\s*|was\s*|of\s*|at\s*|about\s*|around\s*|:\s*)?(?<n>[1-5])(\s*(/|out of)\s*5)?(?=\s*($|[,;.]|and\b|but\b|slept\b|sleep\b|i\b|\d))"#, in: &rest) {
            stress = Int(found)
        }
        // "wellbeing: 3, 7h": a bare 1–5 is the stress, a bare number above that the sleep.
        if prefixed != nil, stress == nil || sleep == nil {
            while let found = capture(#"(^|[\s,])(?<n>\d+(\.\d+)?)(?=$|[\s,])"#, in: &rest), let value = Double(found) {
                if stress == nil, value == value.rounded(), (1...5).contains(value) { stress = Int(value) }
                else if sleep == nil, (3...12).contains(value) { sleep = value }
                else { break }
                if stress != nil, sleep != nil { break }
            }
        }
        guard stress != nil || sleep != nil else { return nil }
        // Sleep alone only as a past week's ("slept 6 hours"), not "sleep for 2 hours" (a nap timer).
        if stress == nil, prefixed == nil, text.lowercased().range(of: #"\b(slept|got)\b"#, options: .regularExpression) == nil { return nil }
        if let hours = sleep, !(2...14).contains(hours) { return nil }
        let note = rest.replacingOccurrences(of: #"\b(i\s+)?(slept|sleep|sleeping|about|around|roughly|like|a night|per night|each night|on average|average|and|my|is|was|of|stress(ed)?)\b"#,
                                             with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\s,;.]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // An answer is short; anything longer is a conversation for Claude.
        guard note.split(separator: " ").count <= 8 else { return nil }
        return Entry(date: Calendar.current.startOfDay(for: now), sleep: sleep, stress: stress, note: note)
    }

    /// The `n` group of the first match, taken out of `text`.
    private static func capture(_ pattern: String, in text: inout String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text), let number = Range(match.range(withName: "n"), in: text) else { return nil }
        let found = String(text[number])
        text.replaceSubrange(whole, with: " ")
        return found
    }

    // MARK: - The note

    static func hoursText(_ hours: Double) -> String {
        hours == hours.rounded() ? String(Int(hours)) : String(format: "%g", hours)
    }

    static func entries() -> [Entry] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").compactMap { line -> Entry? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return nil }
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4, let date = IBProjects.isoDate(cells[1]) else { return nil }
            let sleep = Double(cells[2].filter { $0.isNumber || $0 == "." })
            let stress = Int(cells[3].filter(\.isNumber).prefix(1))
            return Entry(date: date, sleep: sleep, stress: stress, note: cells.count > 4 ? cells[4] : "")
        }
    }

    static var latest: Entry? { entries().max { $0.date < $1.date } }

    /// Writes the check-in (today's replaces an earlier one from today).
    @discardableResult
    static func record(_ entry: Entry) -> URL? {
        guard let url else { return nil }
        let day = entry.date.formatted(.localDay)
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? """
            ---
            summary: "Weekly wellbeing check-ins: average sleep and stress 1–5. A hard week makes the next week plan lighter."
            ---
            # Wellbeing

            | Date | Sleep (avg h) | Stress (1–5) | Note |
            |---|---|---|---|
            """).components(separatedBy: "\n")
        let row = "| \(day) | \(entry.sleep.map { hoursText($0) } ?? "") | \(entry.stress.map { String($0) } ?? "") | "
            + entry.note.replacingOccurrences(of: "|", with: "/") + " |"
        if let index = lines.firstIndex(where: { $0.hasPrefix("| \(day) |") }) {
            lines[index] = row
        } else if let last = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }) {
            lines.insert(row, at: last + 1)
        } else {
            lines += ["| Date | Sleep (avg h) | Stress (1–5) | Note |", "|---|---|---|---|", row]
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        guard (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }

    // MARK: - The week plan

    /// Whether a check-in says the week was hard.
    static func isHard(_ entry: Entry) -> Bool {
        (entry.stress ?? 0) >= 4 || (entry.sleep.map { $0 < 6.5 } ?? false)
    }

    /// When the latest check-in (in the last two weeks) was hard: the line for Week.md's header.
    static func lighter(_ now: Date = Date()) -> String? {
        guard let entry = latest, IBProjects.daysLeft(entry.date, now) >= -freshDays, isHard(entry) else { return nil }
        var said: [String] = []
        if let stress = entry.stress { said.append("stress \(stress)/5") }
        if let sleep = entry.sleep { said.append("\(hoursText(sleep))h sleep") }
        let day = entry.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "Lighter week: your check-in on \(day) said \(said.joined(separator: ", ")), so at most one block on weekday evenings and none after 21:00 on school nights."
    }

    // MARK: - Cards

    /// The card after an answer.
    static func recorded(_ entry: Entry, now: Date = Date()) -> StudyLoop.Reply {
        var said: [String] = []
        if let stress = entry.stress { said.append("stress \(stress)/5") }
        if let sleep = entry.sleep { said.append("\(hoursText(sleep)) hours of sleep") }
        var card = "Noted in **Wellbeing.md**: " + said.joined(separator: ", ") + (entry.note.isEmpty ? "." : " (\(entry.note)).")
        let spoken: String
        if isHard(entry) {
            card += "\nThat's a hard week. Your next week plan will be lighter: one block at most on weekday evenings, none after 21:00 on school nights."
            if entry.sleep.map({ $0 < 6.5 }) ?? false { card += " Sleep comes first: aim to be in bed by 23:00." }
            if (entry.stress ?? 0) >= 5 { card += "\nIf it stays this high, talk to your advisor or the school counsellor; you don't have to carry it alone." }
            spoken = "Got it. Next week's plan will be lighter."
        } else {
            card += "\nSounds manageable: the plan stays as it is."
            spoken = "Got it, thanks."
        }
        if entry.stress == nil { card += "\nAnd your stress, 1 to 5?" }
        if entry.sleep == nil { card += "\nAnd how many hours did you sleep a night?" }
        return StudyLoop.Reply(subject: "Wellbeing check-in", card: card, spoken: spoken)
    }

    /// "How am I doing": the last check-in, and the question.
    static func checkIn(now: Date = Date()) -> StudyLoop.Reply {
        var card = question
        if let entry = latest {
            var said: [String] = []
            if let stress = entry.stress { said.append("stress \(stress)/5") }
            if let sleep = entry.sleep { said.append("\(hoursText(sleep))h sleep") }
            let day = entry.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            card = "Last check-in, \(day): \(said.joined(separator: ", "))" + (entry.note.isEmpty ? "." : " (\(entry.note)).") + "\n\n" + question
        }
        return StudyLoop.Reply(subject: "Wellbeing check-in", card: card,
                               spoken: "How many hours did you sleep a night last week, and your stress from 1 to 5?")
    }
}
