import Foundation

/// The CAS log: one row per experience under `## Log` in `School/Projects/CAS.md`, so the
/// portfolio builds up as the student goes ("log CAS: beach clean-up, 2 hours, service"):
///
///     ## Log
///     | Date | Experience | Strand | Hours | Learning outcomes | Evidence |
///     |---|---|---|---|---|---|
///     | 2026-10-25 | Beach clean-up | Service | 2 | LO6? | photos/beach.jpg |
///
/// The strand is the one said, or guessed from the words; learning outcomes said ("LO2") are kept
/// as they are, a light guess gets a "?" for the student to confirm. "How's my CAS" adds it up.
enum CASLog {
    struct Entry {
        var date: String
        var experience: String
        var strands: [String]
        var hours: Double?
        var outcomes: [Int]
        var evidence: String
    }

    static let logHeader = [
        "## Log",
        "| Date | Experience | Strand | Hours | Learning outcomes | Evidence |",
        "|---|---|---|---|---|---|",
    ]

    /// The IB's seven CAS learning outcomes, in short.
    static let outcomeNames = [
        "strengths and growth", "challenge and new skills", "initiative and planning", "commitment and perseverance",
        "collaboration", "global engagement", "ethics of choices",
    ]

    static var url: URL? { IBProjects.folder?.appendingPathComponent("CAS.md") }

    // MARK: - Understanding "log CAS: …"

    /// Words that name a strand, and the strand.
    private static let strandWords: [(pattern: String, strand: String)] = [
        (#"\b(creativity|creative)\b"#, "Creativity"), (#"\b(activity|active)\b"#, "Activity"), (#"\bservice\b"#, "Service"),
    ]

    /// Words that suggest a strand when none is said.
    private static let strandHints: [(pattern: String, strand: String)] = [
        (#"\b(volunteer\w*|clean.?up|charity|fundrais\w*|donat\w*|tutor\w*|taught|teach\w*|community|ngo|orphanage|elderly|care home|recycl\w*|food bank|mentor\w*|helped)\b"#, "Service"),
        (#"\b(play\w*|match|game|volleyball|football|soccer|basketball|badminton|tennis|swim\w*|run|ran|running|gym|hik\w*|train\w*|tournament|sport\w*|climb\w*|cycl\w*|yoga|rowing|rugby|athletics|marathon|dance\w*|danced)\b"#, "Activity"),
        (#"\b(paint\w*|draw\w*|music|piano|guitar|violin|drums?|band|sing\w*|sang|choir|compos\w*|design\w*|theatre|drama|play rehearsal|film\w*|photo\w*|wrote|writ\w*|poem|poetry|art|artwork|cod\w*|built|build\w*|bak\w*|cook\w*|craft\w*|sculpt\w*|mural)\b"#, "Creativity"),
    ]

    /// Light guesses at learning outcomes from the words.
    private static let outcomeHints: [(pattern: String, outcome: Int)] = [
        (#"\b(first time|new|learn\w*|tried|challenge\w*)\b"#, 2),
        (#"\b(organi[sz]\w*|planned|plan\w*|led|lead\w*|initiat\w*|started|set up|ran the)\b"#, 3),
        (#"\b(every week|weekly|again|season|regular\w*|ongoing|session \d+)\b"#, 4),
        (#"\b(team|match|together|group|club|with (my|the|our)|partner\w*|choir|band)\b"#, 5),
        (#"\b(clean.?up|beach|plastic|climate|environment\w*|poverty|refugee\w*|global|sustainab\w*|recycl\w*|un sdg|sdg)\b"#, 6),
        (#"\b(ethic\w*|fair|responsib\w*|consent)\b"#, 7),
    ]

    /// "log CAS: beach clean-up, 2 hours, service", "CAS: played volleyball match 1.5h" → an entry.
    /// `said` keeps its case (an evidence path or link needs it). Nil when it isn't one.
    static func parse(_ said: String, now: Date = Date()) -> Entry? {
        let patterns = [
            #"^(log|record)\s+(a\s+|my\s+|some\s+)?cas(\s+(experience|activity|entry|hours|session))?\s*[:,\-–—]?\s+(?<item>.+)$"#,
            #"^(add|note)\s+(a\s+|my\s+|some\s+)?cas(\s+(experience|activity|entry|hours|session))?\s*[:\-–—]\s*(?<item>.+)$"#,
            #"^cas\s*(log)?\s*[:\-–—]\s*(?<item>.+)$"#,
        ]
        var found: String?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: said, range: NSRange(said.startIndex..., in: said)),
                  let range = Range(match.range(withName: "item"), in: said) else { continue }
            found = String(said[range])
            break
        }
        guard var rest = found?.trimmingCharacters(in: .whitespaces), !rest.isEmpty,
              rest.range(of: #"^(how|what|when|where|which|who|show|do|did|am|is|are|can)\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }

        // Evidence: a link, or a file path or name.
        var evidence = ""
        for pattern in [#"https?://[^\s,]+"#, #"(?:^|\s)(?:~|/)[^\s,]*/[^\s,]+"#, #"[^\s,]+\.(jpe?g|png|heic|pdf|mov|mp4|docx?|pages|key|pptx?)\b"#] {
            guard let range = rest.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            evidence = String(rest[range]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;.")))
            rest.replaceSubrange(range, with: " ")
            break
        }
        rest = rest.replacingOccurrences(of: #"\b(evidence|photos?|proof|link)\s*(:|is|at|in)?\s*(?=,|$)"#, with: " ",
                                         options: [.regularExpression, .caseInsensitive])

        // Hours: "2 hours", "1.5h", "90 minutes", "an hour", "half an hour".
        var hours: Double?
        let hourPatterns: [(String, Double)] = [
            (#"\b(?<n>\d+(\.\d+)?)\s*(h|hrs?|hours?)\b"#, 1), (#"\b(?<n>\d+)\s*(m|mins?|minutes?)\b"#, 1.0 / 60),
        ]
        for (pattern, factor) in hourPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let whole = Range(match.range, in: rest), let number = Range(match.range(withName: "n"), in: rest),
                  let value = Double(rest[number]) else { continue }
            hours = (value * factor * 100).rounded() / 100
            rest.replaceSubrange(whole, with: " ")
            break
        }
        if hours == nil, let range = rest.range(of: #"\b(half an hour|an hour and a half|an hour|one hour)\b"#, options: [.regularExpression, .caseInsensitive]) {
            let phrase = rest[range].lowercased()
            hours = phrase.hasPrefix("half") ? 0.5 : phrase.contains("and a half") ? 1.5 : 1
            rest.replaceSubrange(range, with: " ")
        }
        rest = rest.replacingOccurrences(of: #"\bfor\s*(?=,|$)"#, with: " ", options: [.regularExpression, .caseInsensitive])

        // Learning outcomes said: "LO2", "LO 5", "learning outcome 3".
        var outcomes: [Int] = []
        if let regex = try? NSRegularExpression(pattern: #"\b(lo|learning outcomes?)\s*(?<n>[1-7])\b"#, options: [.caseInsensitive]) {
            for match in regex.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                if let number = Range(match.range(withName: "n"), in: rest), let value = Int(rest[number]), !outcomes.contains(value) {
                    outcomes.append(value)
                }
            }
            rest = regex.stringByReplacingMatches(in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: " ")
        }

        // The date: "yesterday", "today", or a day said ("25 oct"), never in the future.
        let calendar = Calendar.current
        var date = calendar.startOfDay(for: now)
        if let range = rest.range(of: #"\b(yesterday|today|this morning|this afternoon|tonight)\b"#, options: [.regularExpression, .caseInsensitive]) {
            if rest[range].lowercased() == "yesterday" { date = calendar.date(byAdding: .day, value: -1, to: date) ?? date }
            rest.replaceSubrange(range, with: " ")
        } else if let dated = StudyIntent.date(in: rest.lowercased(), now: now) {
            var day = dated.date
            if day > now { day = calendar.date(byAdding: .year, value: -1, to: day) ?? day }
            date = day
            rest = dated.rest
        }

        // The strand: the pieces that only name one ("…, service"), or the words after the experience.
        var strands: [String] = []
        var pieces: [String] = []
        for piece in rest.components(separatedBy: CharacterSet(charactersIn: ",;")) {
            var text = piece.trimmingCharacters(in: .whitespaces)
            // "service" alone (or "creativity and service") is the strand, and goes; "community service at
            // the shelter" is the experience, which says its strand too.
            let named = strandWords.filter { text.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil }
            var without = text
            for word in named {
                without = without.replacingOccurrences(of: word.pattern, with: " ", options: [.regularExpression, .caseInsensitive])
                if !strands.contains(word.strand) { strands.append(word.strand) }
            }
            let left = without.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && !["and", "strand", "strands", "for", "as", "it", "was", "is", "cas"].contains($0.lowercased()) }
            if !named.isEmpty, left.isEmpty { text = "" }
            let clean = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-–—:")))
                .replacingOccurrences(of: #"^(and|for|on|at)\s+|\s+(and|for|on|at)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            if !clean.isEmpty, clean.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil { pieces.append(clean) }
        }
        var experience = pieces.joined(separator: ", ")
        guard !experience.isEmpty else { return nil }
        experience = experience.prefix(1).uppercased() + String(experience.dropFirst())
        let lower = experience.lowercased()
        if strands.isEmpty {
            strands = strandHints.filter { lower.range(of: $0.pattern, options: .regularExpression) != nil }.map { $0.strand }
        }
        let guessed = outcomes.isEmpty
            ? outcomeHints.filter { lower.range(of: $0.pattern, options: .regularExpression) != nil }.map { $0.outcome }.prefix(2).map { -$0 }
            : []
        // A guessed outcome is kept as a negative number until it's written ("LO6?").
        return Entry(date: date.formatted(.localDay), experience: experience, strands: strands, hours: hours,
                     outcomes: outcomes.isEmpty ? Array(guessed) : outcomes.sorted(), evidence: evidence)
    }

    // MARK: - Writing

    static func hoursText(_ hours: Double) -> String {
        hours == hours.rounded() ? String(Int(hours)) : String(format: "%g", hours)
    }

    /// The outcomes as written: "LO2, LO5" (a guess as "LO5?").
    static func outcomesText(_ outcomes: [Int]) -> String {
        outcomes.map { $0 < 0 ? "LO\(-$0)?" : "LO\($0)" }.joined(separator: ", ")
    }

    static func row(_ entry: Entry) -> String {
        let cells = [entry.date, entry.experience, entry.strands.joined(separator: ", "),
                     entry.hours.map { hoursText($0) } ?? "", outcomesText(entry.outcomes), entry.evidence]
        return "| " + cells.map { $0.replacingOccurrences(of: "|", with: "/") }.joined(separator: " | ") + " |"
    }

    /// Adds the entry's row under ## Log in CAS.md (made from its template first when it's missing).
    /// Returns the note, or nil when there's no vault.
    @discardableResult
    static func append(_ entry: Entry, now: Date = Date()) -> URL? {
        guard let url else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) { IBProjects.create(.cas, now: now) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        if !lines.contains(where: { $0.hasPrefix("## Log") }) {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines += [""] + logHeader + [""]
        } else if let start = lines.firstIndex(where: { $0.hasPrefix("## Log") }),
                  !lines[(start + 1)...].prefix(while: { !$0.hasPrefix("## ") }).contains(where: { $0.hasPrefix("|---") || $0.hasPrefix("| ---") }) {
            // A Log written by hand without the table: put the table's head right under the heading.
            lines.insert(contentsOf: Array(logHeader.dropFirst()), at: start + 1)
        }
        Daybook.insert(row(entry), under: "Log", in: &lines)
        let written = lines.joined(separator: "\n")
        return (try? written.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    // MARK: - Reading

    /// The rows under ## Log.
    static func entries(in text: String) -> [Entry] {
        var inside = false
        var found: [Entry] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inside = line.lowercased().hasPrefix("## log"); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard inside, trimmed.hasPrefix("|"), !trimmed.hasPrefix("|---"), !trimmed.hasPrefix("| ---") else { continue }
            var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            guard cells.count >= 2, cells[0].lowercased() != "date" else { continue }
            func cell(_ index: Int) -> String { index < cells.count ? cells[index] : "" }
            let strands = cell(2).components(separatedBy: CharacterSet(charactersIn: ",/&+")).compactMap { part -> String? in
                let word = part.trimmingCharacters(in: .whitespaces).lowercased()
                if word.hasPrefix("c") { return "Creativity" }
                if word.hasPrefix("a") { return "Activity" }
                if word.hasPrefix("s") { return "Service" }
                return nil
            }
            var outcomes: [Int] = []
            if let regex = try? NSRegularExpression(pattern: #"(?i)lo\s*(?<n>[1-7])"#) {
                let tags = cell(4)
                for match in regex.matches(in: tags, range: NSRange(tags.startIndex..., in: tags)) {
                    if let range = Range(match.range(withName: "n"), in: tags), let value = Int(tags[range]), !outcomes.contains(value) {
                        outcomes.append(value)
                    }
                }
            }
            let hours = Double(cell(3).replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." })
            found.append(Entry(date: cell(0), experience: cell(1), strands: strands, hours: hours, outcomes: outcomes, evidence: cell(5)))
        }
        return found
    }

    /// The summary card: hours per strand, experiences, whether there's a CAS project, outcomes covered.
    static func summary(now: Date = Date()) -> StudyLoop.Reply {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return StudyLoop.Reply(subject: "No CAS log yet",
                                   card: "There's no CAS note yet. Log your first experience: \"log CAS: beach clean-up, 2 hours, service\".",
                                   spoken: "No CAS log yet. Say log CAS, then what you did.")
        }
        let rows = entries(in: text)
        let project = IBProjects.parse(text, url: url)
        guard !rows.isEmpty else {
            return StudyLoop.Reply(subject: "CAS: nothing logged yet",
                                   card: "**CAS.md** has no experiences under ## Log yet. Say \"log CAS: beach clean-up, 2 hours, service\".",
                                   spoken: "Nothing logged for CAS yet.")
        }
        var hours: [String: Double] = [:]
        for row in rows {
            for strand in row.strands { hours[strand, default: 0] += row.hours ?? 0 }
        }
        let total = rows.compactMap(\.hours).reduce(0, +)
        let strands = ["Creativity", "Activity", "Service"].map { "\($0) \(hoursText(hours[$0] ?? 0))h" }.joined(separator: " · ")
        let covered = Set(rows.flatMap(\.outcomes))
        let missing = (1...7).filter { !covered.contains($0) }
        let hasProject = rows.contains { $0.experience.lowercased().contains("cas project") }
            || project.milestones.contains { $0.done && $0.title.lowercased().contains("cas project") }
        let thin = ["Creativity", "Activity", "Service"].filter { strand in !rows.contains { $0.strands.contains(strand) } }
        var card = "**CAS**: \(rows.count) experience\(rows.count == 1 ? "" : "s"), \(hoursText(total)) hours. \(strands)."
        card += "\nCAS project: " + (hasProject ? "yes." : "not yet (one experience of a month or more, with others, that you plan).")
        let listed = covered.sorted().map { "LO\($0)" }.joined(separator: ", ")
        card += "\nLearning outcomes: \(covered.count) of 7" + (covered.isEmpty ? "." : " (\(listed)).")
        if !missing.isEmpty {
            card += " Still to show: " + missing.map { "LO\($0) \(outcomeNames[$0 - 1])" }.joined(separator: ", ") + "."
        }
        if !thin.isEmpty { card += "\nNothing yet for " + thin.joined(separator: " or ") + "." }
        if let next = project.next {
            card += "\nNext milestone: \(next.title)" + (next.date.map { ", \(IBProjects.dayName($0, now))" } ?? "") + "."
        }
        let spoken = "CAS: \(rows.count) experience\(rows.count == 1 ? "" : "s") and \(hoursText(total)) hours, \(covered.count) of 7 learning outcomes"
            + (hasProject ? "." : ", and no CAS project yet.")
        return StudyLoop.Reply(subject: "CAS: \(rows.count) experiences, \(covered.count)/7 outcomes", card: card, spoken: spoken)
    }

    /// The card after logging one.
    static func logged(_ entry: Entry, in url: URL, now: Date = Date()) -> StudyLoop.Reply {
        var card = "Logged in **\(url.deletingPathExtension().lastPathComponent).md**: \(entry.experience)"
        card += entry.date == now.formatted(.localDay) ? ", today" : ", \(entry.date)"
        card += entry.hours.map { ", \(hoursText($0))h" } ?? ""
        card += entry.strands.isEmpty ? "." : " (\(entry.strands.joined(separator: ", ")))."
        if !entry.outcomes.isEmpty {
            let guessed = entry.outcomes.contains { $0 < 0 }
            card += "\nLearning outcomes: \(outcomesText(entry.outcomes))" + (guessed ? " (a guess: change it in the note)." : ".")
        }
        var missing: [String] = []
        if entry.hours == nil { missing.append("the hours") }
        if entry.strands.isEmpty { missing.append("the strand (creativity, activity or service)") }
        if !missing.isEmpty { card += "\nAdd " + missing.joined(separator: " and ") + " in the note." }
        if entry.evidence.isEmpty { card += "\nA photo or file as evidence helps: add its link in the row." }
        let spoken = "Logged \(entry.experience) for CAS" + (entry.hours.map { ", \(hoursText($0)) hours" } ?? "")
            + (entry.strands.isEmpty ? "." : ", \(entry.strands.joined(separator: " and ").lowercased()).")
        return StudyLoop.Reply(subject: "CAS logged: \(entry.experience)", card: card, spoken: spoken)
    }
}
