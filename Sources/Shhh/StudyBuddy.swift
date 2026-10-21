import Foundation

/// Joe as a study buddy: the IB syllabus maps he quizzes from (written by us, in the app), the
/// student's own notes and textbooks, and the quiz log he keeps to find their weak topics.
enum StudyBuddy {
    /// The syllabus packs, one Markdown file per subject, plus "Command terms.md".
    static var syllabus: URL {
        Bundle.main.resourceURL?.appendingPathComponent("Syllabus", isDirectory: true)
            ?? URL(fileURLWithPath: "Resources/Syllabus", isDirectory: true)
    }

    static var packs: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: syllabus.path)) ?? [])
            .filter { $0.hasSuffix(".md") && $0 != "Command terms.md" }
            .map { String($0.dropLast(3)) }
            .sorted()
    }

    /// The School folder in their notes, when they have one.
    static var schoolFolder: URL? {
        guard let root = Daybook.root else { return nil }
        let school = root.appendingPathComponent("School", isDirectory: true)
        return FileManager.default.fileExists(atPath: school.path) ? school : nil
    }

    /// Where the quiz scores go: beside their school notes, or in Joe's own folder.
    static var logURL: URL {
        if let school = schoolFolder { return school.appendingPathComponent("Quiz log.md") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shhh/Quiz log.md")
    }

    /// One marked question: "- 2026-10-20 · Economics · 2.8 Externalities · 3/4 · missed the welfare loss".
    struct Result: Hashable {
        let date: String
        let subject: String
        let topic: String
        let score: Int
        let total: Int
        let note: String
    }

    static func results() -> [Result] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("- ") else { return nil }
            let parts = line.dropFirst(2).components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 4 else { return nil }
            let marks = parts[3].components(separatedBy: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard marks.count == 2, marks[1] > 0 else { return nil }
            return Result(date: parts[0], subject: parts[1], topic: parts[2], score: marks[0], total: marks[1],
                          note: parts.count > 4 ? parts[4...].joined(separator: " · ") : "")
        }
    }

    /// The pack for a subject as the student wrote it ("Math AI HL" → "Mathematics AI").
    static func pack(for subject: String) -> String? {
        let words = subject.lowercased()
        let keys: [(String, [String])] = [
            ("Mathematics AI", ["math ai", "maths ai", "applications and interpretation", "a&i"]),
            ("Economics", ["econ"]),
            ("Business Management", ["business"]),
            ("Environmental Systems and Societies", ["ess", "environmental"]),
            ("English A Language and Literature", ["english a", "lang and lit", "lang & lit", "l&l", "language and literature"]),
            ("Chinese B", ["chinese b", "mandarin b", "中文"]),
            ("Theory of Knowledge", ["tok", "theory of knowledge"]),
            ("Mathematics AA", ["math aa", "maths aa", "math a&a", "maths a&a", "analysis and approaches"]),
            ("Physics", ["physic"]),
            ("Chemistry", ["chem"]),
            ("Biology", ["bio"]),
            ("History", ["histor"]),
            ("Psychology", ["psych"]),
            ("English B", ["english b", "eng b"]),
            ("Spanish", ["spanish", "español", "espanol"]),
            ("Geography", ["geog"]),
            ("Computer Science", ["computer science", "comp sci", "compsci", "cs hl", "cs sl"]),
            ("Global Politics", ["global politics", "glopo", "gp hl", "gp sl"]),
        ]
        // An alias counts at the start of a word: "ess" is ESS, but not the end of "business" or "assessment".
        func starts(_ alias: String) -> Bool {
            var search = words.startIndex..<words.endIndex
            while let found = words.range(of: alias, range: search) {
                if found.lowerBound == words.startIndex || !words[words.index(before: found.lowerBound)].isLetter { return true }
                search = words.index(after: found.lowerBound)..<words.endIndex
            }
            return false
        }
        return keys.first { entry in entry.1.contains(where: starts) }?.0
    }

    private static let markPattern = #"<mark\s[^>]*/?>"#

    /// A reply as it streams in, without its quiz marks (or a half-written one at the end).
    static func withoutMarks(_ text: String) -> String {
        var clean = text.replacingOccurrences(of: markPattern, with: "", options: .regularExpression)
        if let open = clean.range(of: "<mark", options: .backwards), !clean[open.lowerBound...].contains(">") {
            clean = String(clean[..<open.lowerBound])
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The finished reply: its quiz marks saved to the log, and the reply without them.
    static func record(_ text: String) -> String {
        var lines: [String] = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: markPattern, options: .regularExpression, range: search) {
            let tag = String(text[range])
            func value(_ name: String) -> String {
                guard let match = tag.range(of: name + #"="([^"]*)""#, options: .regularExpression) else { return "" }
                return String(tag[match].dropFirst(name.count + 2).dropLast()).replacingOccurrences(of: " · ", with: ", ")
            }
            if let score = Int(value("score")), let total = Int(value("total")), total > 0 {
                let date = Date().formatted(.iso8601.year().month().day())
                lines.append("- \(date) · \(value("subject")) · \(value("topic")) · \(score)/\(total) · \(value("note"))")
            }
            search = range.upperBound..<text.endIndex
        }
        if !lines.isEmpty {
            var log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "# Quiz log\n"
            if !log.hasSuffix("\n") { log += "\n" }
            log += lines.joined(separator: "\n") + "\n"
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? log.write(to: logURL, atomically: true, encoding: .utf8)
        }
        return withoutMarks(text)
    }

    /// For Claude's instructions: how to run a quiz.
    static var instructions: String {
        let exe = Bundle.main.executablePath ?? "Joe"
        let files = schoolFolder == nil ? nil : Daybook.root?.appendingPathComponent("_files/School", isDirectory: true)
        let due = StudyReview.lines(StudyReview.due(), limit: 5)
        return """


            Study buddy ("quiz me on…", "test me", "help me revise…", "ask me questions about…"): you quiz them \
            like an IB teacher. "Whiteboard" always means Joe's own study whiteboard, never Freeform or another \
            app: if they ask for it, tell them to say "open the whiteboard" (Joe opens it himself).
            - Syllabus maps, written for Joe, are in \(syllabus.path): \(packs.joined(separator: ", ")) (aliases \
            at the top of each), and "Command terms.md" for what each command term demands and how IB marks. \
            Read the subject's map and the command terms once at the start of a quiz.
            - Their own material comes first when it exists: Grep their notes\(schoolFolder.map { " (\($0.path))" } ?? "") \
            for the topic, and for PDFs\(files.map { " in \($0.path)/<subject>" } ?? "") such as textbooks, \
            glossaries and exam guidance, find pages with "\(exe)" --pdf-find "<pdf>" "<topic>" and read them \
            with --pdf-text "<pdf>" "<pages>". Ask about what they were taught, in its terms.
            - No topic given: \(due.isEmpty ? "" : "start with a topic due for review (spaced repetition from their quiz log):\n\(due)\n  Otherwise ")read \(logURL.path) and pick one they scored low on or haven't done yet, preferring \
            a subject with a test or deadline coming up. "What should I revise?": the due topics first.
            - One question at a time, in IB style: a command term and the marks, e.g. "Explain how a subsidy on \
            solar panels affects producers. [4]". Mix definitions, application to a short made-up context, \
            calculations and exam-style questions. Never give the answer with the question. Read aloud, say \
            just the question.
            - When they answer (by voice, as a follow-up): mark it as an IB examiner would: the mark out of the \
            total, what earned marks, what was missing, then a short model answer (2 to 4 lines, exact \
            definitions), then the next question. Strict but encouraging; give partial marks.
            - After marking, put the mark on the reply's last line, exactly: <mark subject="<subject>" \
            topic="<topic number and name>" score="<marks>" total="<total>" note="<what was missing, a few \
            words>"/>. Joe saves it to their quiz log and hides it; don't write the log yourself.
            - Diagrams: they're talking, not drawing, so ask them to describe the diagram (axes, curves, the \
            shift, the area) and mark that.
            - After five questions, or when they stop: their score, the weakest topic and the one thing to \
            revise next.
            - Maths: numbers that work on a GDC, method and accuracy marks. Chinese B: questions in Chinese, \
            corrections shown as 原句 → 改正, explanations in English.
            """
    }
}
