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

    /// The "✗ missing: …" lines of a feedback, without the marker.
    static func missing(in feedback: String) -> [String] {
        feedback.components(separatedBy: "\n")
            .filter { $0.contains("✗") || $0.lowercased().contains("missing") }
            .map { $0.replacingOccurrences(of: #"^[-•*✗\s]+(missing:?\s*)?"#, with: "", options: [.regularExpression, .caseInsensitive]) }
            .filter { !$0.isEmpty }
    }
}
