import AppKit
import ImageIO
import PDFKit

/// Returned marks and draft feedback, kept as Markdown beside their school notes:
/// - "School/Marks.md": every returned mark logged during a mark review (date, subject, assessment,
///   mark, boundary), for predicted grades later.
/// - Draft feedback against the IB criteria: under "## Feedback" in the project's note
///   ("School/Projects/Extended Essay.md") when there is one, else "School/Feedback/<name>.md".
/// - The text of a draft or a marked paper they drop on the whiteboard (Word, Pages, PDF, text).
enum Marks {
    private static var school: URL { StudyBuddy.schoolFolder ?? PastPapers.folder }

    static var logURL: URL { school.appendingPathComponent("Marks.md") }

    private static func today() -> String { Date().formatted(.iso8601.year().month().day()) }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Adds a returned mark to the log, as a table row.
    static func log(subject: String, assessment: String, mark: String, boundary: String) {
        guard !mark.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var text = (try? String(contentsOf: logURL, encoding: .utf8))
            ?? "# Marks\n\nReturned marks, newest at the bottom. Joe adds a row in each mark review; edit freely.\n\n| Date | Subject | Assessment | Mark | Boundary |\n|---|---|---|---|---|\n"
        if !text.hasSuffix("\n") { text += "\n" }
        text += "| \(today()) | \(cell(subject)) | \(cell(assessment)) | \(cell(mark)) | \(cell(boundary)) |\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// The latest rows of the log: (date, subject, assessment, mark, boundary).
    static func recent(limit: Int = 4) -> [[String]] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        let rows = text.components(separatedBy: "\n").filter { $0.hasPrefix("| 2") }.map { line in
            line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
        }.filter { $0.count >= 4 }
        return Array(rows.suffix(limit).reversed())
    }

    // MARK: Draft feedback

    /// The project's note in "School/Projects/": named for it, or the one of its kind ("Maths AI IA.md"
    /// for "Mathematics AI IA", "EE.md" for "Extended Essay").
    static func projectNote(for project: String) -> URL? {
        guard let folder = StudyBuddy.schoolFolder?.appendingPathComponent("Projects", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let notes = files.filter { $0.pathExtension.lowercased() == "md" }
        func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        if let exact = notes.first(where: { name($0) == project.lowercased() }) { return exact }
        let kind: String
        switch project {
        case "Extended Essay": kind = #"extended essay|\bee\b"#
        case "TOK Exhibition": kind = #"exhibition"#
        case "TOK Essay": kind = #"tok essay|theory of knowledge essay"#
        case _ where project.hasSuffix("IO"): kind = #"\bio\b|individual oral"#
        case _ where project.hasSuffix("IA"): kind = #"\bia\b|internal assessment|exploration|investigation"#
        default: return nil
        }
        let matches = notes.filter { name($0).range(of: kind, options: .regularExpression) != nil }
        if matches.count <= 1 { return matches.first }
        // Several IAs: the one whose name shares the subject's first word ("math" in "Maths AI IA").
        let word = String(project.lowercased().prefix { $0.isLetter }.prefix(4))
        return word.isEmpty ? nil : matches.first { name($0).contains(word) }
    }

    /// Where feedback on a draft goes: the project's note when it has one, else its own note.
    static func feedbackURL(for project: String) -> URL {
        projectNote(for: project) ?? school.appendingPathComponent("Feedback", isDirectory: true)
            .appendingPathComponent(project.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".md")
    }

    /// Saves one round of feedback, dated, under "## Feedback" (the section is added when missing),
    /// so the next check can show progress.
    static func saveFeedback(_ body: String, project: String) {
        let file = feedbackURL(for: project)
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? "# \(project) · feedback\n\nJoe's feedback on each draft against the IB criteria, newest at the bottom.\n"
        let entry = "### \(today()) · draft check\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        if let section = text.range(of: "\n## Feedback\n") ?? (text.hasPrefix("## Feedback\n") ? text.range(of: "## Feedback\n") : nil) {
            // At the end of the section: before the next "## " heading, or at the end of the note.
            let after = text[section.upperBound...]
            let end = after.range(of: "\n## ")?.lowerBound ?? text.endIndex
            var before = String(text[..<end])
            if !before.hasSuffix("\n") { before += "\n" }
            text = before + "\n" + entry + String(text[end...])
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n## Feedback\n\n" + entry
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// The draft named by the project note's `doc:` line, when it's a file on this Mac.
    static func projectDraft(for project: String) -> URL? {
        guard let note = projectNote(for: project), let text = try? String(contentsOf: note, encoding: .utf8),
              let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("doc:") }) else { return nil }
        var path = line.dropFirst(4).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !path.isEmpty, !path.hasPrefix("http") else { return nil }
        path = (path as NSString).expandingTildeInPath
        // Relative paths are in their notes.
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : (Daybook.root ?? note.deletingLastPathComponent()).appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Reading a dropped file

    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp"]

    /// The words in a text, as a word processor counts them.
    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { word in word.contains { $0.isLetter || $0.isNumber } }.count
    }

    /// The text of a draft or paper: Word, Pages, RTF and OpenDocument through `textutil`, PDFs by
    /// their text (scanned pages read with text recognition), Markdown and plain text as they are.
    /// Slow for big scanned PDFs: call it off the main thread.
    static func text(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let document = PDFDocument(url: url) else { return nil }
            var pages: [String] = []
            for i in 0..<min(document.pageCount, 60) {
                guard let page = document.page(at: i) else { continue }
                var text = page.string ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 25 {
                    let recognized = Textbook.recognize(page).text
                    if recognized.count > text.count { text = recognized }
                }
                pages.append("=== page \(i + 1) ===\n" + text)
            }
            return pages.joined(separator: "\n\n")
        case "docx", "doc", "pages", "rtf", "rtfd", "odt", "html", "htm", "webarchive":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "txt", "-stdout", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        default:
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// A photo of a page, as a JPEG no bigger than 2000 px, to send to Claude.
    static func jpeg(of url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2000,
              ] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
