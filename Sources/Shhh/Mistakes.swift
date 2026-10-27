import AppKit

/// The mistake book: every whiteboard answer that lost marks, kept per subject as a Markdown note
/// beside their school notes ("School/Mistakes/Economics HL.md"): the question, what was missing
/// and the model answer. It's revision material they can read in Obsidian before a test, and the
/// tutor reads the latest ones to re-test exactly what they got wrong.
enum Mistakes {
    struct Entry {
        let date: String
        let topic: String
        let score: Int
        let total: Int
        let question: String
        let missing: [String]
        let model: String
        /// Why the marks went, from a mark review: "didn't know", "command term" or "careless".
        /// Older entries have none.
        var cause: String = ""
        /// When a fresh redo question on it is due ("2026-10-28"), from a mark review.
        var redo: [String] = []
    }

    static var folder: URL {
        if let school = StudyBuddy.schoolFolder { return school.appendingPathComponent("Mistakes", isDirectory: true) }
        return PastPapers.folder.appendingPathComponent("Mistakes", isDirectory: true)
    }

    static func url(for subject: String) -> URL {
        let name = subject.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent(name + ".md")
    }

    /// Adds the answers that lost marks to the subject's mistake book.
    static func record(_ entries: [Entry], subject: String) {
        let lost = entries.filter { $0.score < $0.total }
        guard !lost.isEmpty else { return }
        let file = url(for: subject)
        var text = (try? String(contentsOf: file, encoding: .utf8))
            ?? "# Mistakes · \(subject)\n\nEvery whiteboard answer that lost marks, newest at the bottom. Joe re-tests these.\n"
        if !text.hasSuffix("\n") { text += "\n" }
        for entry in lost {
            text += "\n## \(entry.date) · \(entry.topic.isEmpty ? "Question" : entry.topic) · \(entry.score)/\(entry.total)\n"
            text += "**Question:** \(entry.question.replacingOccurrences(of: "\n", with: " "))\n"
            if !entry.missing.isEmpty { text += "**Missing:**\n" + entry.missing.map { "- \($0)" }.joined(separator: "\n") + "\n" }
            if !entry.model.isEmpty { text += "**Model answer:** \(entry.model.replacingOccurrences(of: "\n", with: " "))\n" }
            if !entry.cause.isEmpty { text += "**Cause:** \(entry.cause)\n" }
            if !entry.redo.isEmpty { text += "**Redo:** \(entry.redo.joined(separator: ", "))\n" }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// The latest mistakes in a subject, as written in the book (for the tutor).
    static func recent(_ subject: String, limit: Int = 8) -> [String] {
        guard let text = try? String(contentsOf: url(for: subject), encoding: .utf8) else { return [] }
        let sections = text.components(separatedBy: "\n## ").dropFirst()
        return sections.suffix(limit).map { "## " + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Each entry's heading ("2026-10-27 · 2.5 Normal distribution · 2/6"), cause and redo dates,
    /// for the ones with a redo schedule (from a mark review). Older entries have no "**Redo:**" line.
    static func scheduled(_ subject: String) -> [(heading: String, topic: String, cause: String, redo: [String])] {
        guard let text = try? String(contentsOf: url(for: subject), encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n## ").dropFirst().compactMap { section -> (heading: String, topic: String, cause: String, redo: [String])? in
            let lines = section.components(separatedBy: "\n")
            func field(_ name: String) -> String {
                lines.first { $0.hasPrefix("**\(name):** ") }.map { String($0.dropFirst(name.count + 6)).trimmingCharacters(in: .whitespaces) } ?? ""
            }
            let redo = field("Redo").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !redo.isEmpty, let heading = lines.first else { return nil }
            let parts = heading.components(separatedBy: " · ")
            return (heading, parts.count >= 3 ? parts[1] : "", field("Cause"), redo)
        }
    }

    static func count(_ subject: String) -> Int {
        guard let text = try? String(contentsOf: url(for: subject), encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "\n## ").count - 1
    }

    /// Opens the book in their Markdown app (Obsidian when it owns .md files).
    @MainActor
    static func open(_ subject: String) {
        let file = url(for: subject)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        NSWorkspace.shared.open(file)
    }

    /// The "✗ missing: …" lines of a feedback, without the marker. A tutor's caveat that slipped in
    /// ("my inference…, tell me if…") isn't a lost mark point, so it's left out.
    static func missing(in feedback: String) -> [String] {
        let meta = ["my inference", "tell me", "if you", "let me know", "i'm assuming", "i assumed", "my guess", "i'll correct"]
        return feedback.components(separatedBy: "\n")
            .filter { $0.contains("✗") || $0.lowercased().contains("missing") }
            .map { $0.replacingOccurrences(of: #"^[-•*✗\s]+(missing:?\s*)?"#, with: "", options: [.regularExpression, .caseInsensitive]) }
            .filter { line in !line.isEmpty && !meta.contains { line.lowercased().contains($0) } }
    }
}
