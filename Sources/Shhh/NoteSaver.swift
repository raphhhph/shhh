import AppKit
import Foundation

/// Notes from the notepad, saved into the vault as a note of their own when the notepad closes,
/// so the assistant has them later ("what did we cover in Econ on Thursday?"). Lectures go in
/// `School/Lecture Notes`, meetings in `Meetings`, anything else in `Notes`. Claude (Haiku, no
/// tools) titles each one from the notes and what was said while taking them.
@MainActor
final class NoteSaver {
    enum Kind: String, CaseIterable {
        case lecture, meeting, notes

        var label: String {
            switch self {
            case .lecture: "Lecture notes"
            case .meeting: "Meeting notes"
            case .notes: "Notes"
            }
        }

        var folder: String {
            switch self {
            case .lecture: "School/Lecture Notes"
            case .meeting: "Meetings"
            case .notes: "Notes"
            }
        }
    }

    nonisolated static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "saveNotesToVault") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "saveNotesToVault") }
    }

    /// Where the notes go: the vault's `Brain` folder when it has one (the assistant's memory),
    /// otherwise the vault itself.
    nonisolated static var root: URL? {
        guard let vault = Assistant.vaultURL else { return nil }
        let brain = vault.appendingPathComponent("Brain", isDirectory: true)
        return FileManager.default.fileExists(atPath: brain.path) ? brain : vault
    }

    /// A kind's folder relative to the vault ("Brain/Meetings"), for the assistant's instructions.
    static func folderPath(_ kind: Kind) -> String {
        guard let vault = Assistant.vaultURL, let root else { return kind.folder }
        let prefix = String(root.path.dropFirst(vault.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (prefix.isEmpty ? "" : prefix + "/") + kind.folder + "/"
    }

    /// One sitting of notes: from "help me take notes" to the notepad closing (and any reopening
    /// before the next "take notes"). Kept across launches.
    private struct Sitting: Codable {
        var kind: String?
        var requests: [String] = []
        /// The note it's saved as, relative to `root`, with its title and summary.
        var file: String?
        var title: String?
        var summary: String?
        var savedAt: Date?
    }

    private var session: Sitting {
        didSet { if let data = try? JSONEncoder().encode(session) { UserDefaults.standard.set(data, forKey: "notepadSession") } }
    }
    private var titling = false
    /// A note saved and titled: its file, kind and text (the app has lectures and meetings structured).
    var onTitled: (URL, Kind, String) -> Void = { _, _, _ in }

    init() {
        session = UserDefaults.standard.data(forKey: "notepadSession")
            .flatMap { try? JSONDecoder().decode(Sitting.self, from: $0) } ?? Sitting()
    }

    var kind: Kind? {
        get { session.kind.flatMap(Kind.init) }
        set { session.kind = newValue?.rawValue }
    }

    /// These notes are in the vault already: new notes should start a new sitting, not replace them.
    var isSaved: Bool { session.file != nil }

    /// A new sitting, from what the user asked ("help me take notes for this Econ lecture").
    func begin(_ request: String?) {
        session = Sitting()
        if let request { heard(request) }
    }

    /// Something the user said about these notes: it helps title them, and may say what they are.
    func heard(_ request: String) {
        session.requests = Array((session.requests + [request]).suffix(8))
        if let kind = Self.kind(in: request) { session.kind = kind.rawValue }
    }

    /// "Notes for my Econ lecture" → lecture, "the call with Ana" → meeting.
    static func kind(in text: String) -> Kind? {
        let lecture = #"\b(lectures?|class(es)?|lessons?|seminars?|tutorials?|workshops?|revision)\b"#
        let meeting = #"\b(meetings?|calls? with|(phone|zoom|video|team|sales|creator|onboarding) calls?|interviews?|one[- ]on[- ]ones?|1:1|stand-?ups?)\b"#
        if text.range(of: meeting, options: [.regularExpression, .caseInsensitive]) != nil { return .meeting }
        if text.range(of: lecture, options: [.regularExpression, .caseInsensitive]) != nil { return .lecture }
        return nil
    }

    /// "This is a meeting", "it's a lecture": a request that only says what the notes are.
    static func isKindStatement(_ text: String) -> Bool {
        text.range(of: #"^\W*(hey\W+)?(this|these|it|that)('?s| is| are)( (a|an|my|the))? \w*\s*(lecture|class|lesson|seminar|meeting|call|notes)( notes)?\W*$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Saving

    /// Saves the notes into the vault: as a new note the first time (titled by Claude a few
    /// seconds later), then over the same note, unless it was changed in Obsidian since.
    func save(_ text: String, announce: @escaping (String) -> Void) {
        let notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isEnabled, let root = Self.root, !notes.isEmpty else { return }
        let manager = FileManager.default
        if let file = session.file, let title = session.title {
            let url = root.appendingPathComponent(file)
            let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { $0.timeIntervalSince(session.savedAt ?? .distantPast) > 2 } ?? true
            if !changed || !manager.fileExists(atPath: url.path) {
                write(notes, to: url, title: title, summary: session.summary)
                return
            }
            // Edited in Obsidian since: those edits stay, and this goes in a note of its own.
            session.file = nil
        }
        let kind = self.kind ?? .notes
        let date = Date()
        let title = "\(kind.label) \(date.formatted(.dateTime.day().month(.abbreviated))) \(date.formatted(date: .omitted, time: .shortened))"
        let url = Self.unique(root.appendingPathComponent(kind.folder, isDirectory: true), name: "\(Self.day(date)) \(title)")
        write(notes, to: url, title: title, summary: "\(kind.label) taken \(Self.day(date)).")
        announce("Notes saved to Obsidian")
        guard !titling else { return }
        titling = true
        Task {
            defer { titling = false }
            if let found = await Self.describe(notes: notes, kind: self.kind, requests: session.requests),
               let file = session.file {
                let current = root.appendingPathComponent(file)
                let kind = self.kind ?? found.kind
                let folder = root.appendingPathComponent(kind.folder, isDirectory: true)
                let renamed = Self.unique(folder, name: "\(Self.day(date)) \(Self.fileName(found.title))", except: current)
                let body = (try? String(contentsOf: current, encoding: .utf8)).map(Self.body(of:)) ?? notes
                try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
                if renamed != current { try? manager.moveItem(at: current, to: renamed) }
                session.kind = kind.rawValue
                write(body, to: renamed, title: found.title, summary: found.summary)
                announce("Saved to Obsidian: \(found.title)")
                onTitled(renamed, kind, body)
            }
            Self.rebuildIndex(root)
        }
    }

    private func write(_ notes: String, to url: URL, title: String, summary: String?) {
        let kind = self.kind ?? .notes
        let summary = (summary ?? "").replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
        let text = """
            ---
            summary: "\(summary)"
            type: \(kind.label.lowercased())
            date: \(Self.day(Date()))
            source: Joe notepad
            ---
            # \(title)

            \(notes)

            """
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil, let root = Self.root else { return }
        session.file = String(url.path.dropFirst(root.path.count + 1))
        session.title = title
        session.summary = summary
        session.savedAt = Date()
    }

    /// A saved note without its frontmatter and title: the notes themselves.
    private static func body(of text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeFirst(end + 1) }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty || first.hasPrefix("# ") {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.localDay)
    }

    /// Obsidian can't link to names with these in them.
    private static func fileName(_ title: String) -> String {
        title.replacingOccurrences(of: ":", with: " —")
            .components(separatedBy: CharacterSet(charactersIn: "/\\*\"<>|?#^[]")).joined()
            .trimmingCharacters(in: .whitespaces)
    }

    private static func unique(_ folder: URL, name: String, except: URL? = nil) -> URL {
        var url = folder.appendingPathComponent(name + ".md")
        var number = 2
        while url != except, FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) (\(number)).md")
            number += 1
        }
        return url
    }

    /// The vault's own index script, if it has one (it lists every note with its summary).
    private static func rebuildIndex(_ root: URL) {
        let script = root.appendingPathComponent("_tools/build_router.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Titling

    /// A title, a one-line summary and what kind of notes these are, from Claude (Haiku, no tools,
    /// about five seconds) or Codex in ChatGPT mode, or nil if it couldn't.
    private static func describe(notes: String, kind: Kind?, requests: [String]) async -> (kind: Kind, title: String, summary: String)? {
        let excerpt = notes.count > 7000 ? notes.prefix(5500) + "\n…\n" + notes.suffix(1500) : Substring(notes)
        let prompt = """
            Title these notes the user took in a notepad, for their Obsidian vault.
            \(kind.map { "They're \($0.label.lowercased())." } ?? "Decide whether they're a lecture (a class, lesson or talk), a meeting (a call or meeting with people) or other notes.")
            What the user said while taking them: \(requests.isEmpty ? "(nothing)" : requests.map { "\"\($0)\"" }.joined(separator: "; "))
            Today is \(Date().formatted(date: .complete, time: .omitted)).

            Reply with JSON only: {"kind": "lecture" | "meeting" | "notes", "title": "…", "summary": "…"}
            - title: at most 8 words. For a lecture, the subject then the topic ("Economics — Price Elasticity of Demand"). \
            For a meeting, who or what then the topic ("WellPrepped — Creator Call with Ana"). No date, no quotes.
            - summary: one line, under 25 words, saying what's in the notes and when to open them.

            <notes>
            \(excerpt)
            </notes>
            """
        let text: String?
        if AIAccount.usesChatGPT || Assistant.executable == nil {
            // ChatGPT mode (or no Claude Code): the same through Codex.
            text = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: CodexAccount.quickAnswer(prompt, timeout: 60)) }
            }
        } else {
            text = await claudeText(prompt)
        }
        guard let text, let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        return (Kind(rawValue: json["kind"] as? String ?? "") ?? .notes, String(title.prefix(80)), json["summary"] as? String ?? "")
    }

    /// Claude Code's answer to a prompt (Haiku, no tools), or nil.
    private static func claudeText(_ prompt: String) async -> String? {
        guard let executable = Assistant.executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "--model", Assistant.Model.haiku.rawValue, "--tools", "", "--strict-mcp-config",
                             "--setting-sources", "user", "--disable-slash-commands", "--no-session-persistence",
                             "--output-format", "text"]
        process.environment = Assistant.environment()
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard (try? process.run()) != nil else { return continuation.resume(returning: nil) }
                let timeout = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
                input.fileHandleForWriting.write(Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
