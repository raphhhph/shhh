import Foundation

/// What finally worked, after Joe got a task wrong a few times (a CAS reflection that took five
/// tries, say), so the next time a task like it goes right the first time.
///
/// Two ways in: Claude writes one itself with `Joe --learn "<task>" "<what worked>"` once it gets
/// there after failed tries, and if it doesn't, the session saves the steps that worked after the
/// last failure (`Trail`). Lessons go in the system prompt, newest first, and a lesson for the same
/// task replaces the old one. Lessons.json in Joe's folder.
enum Lessons {
    struct Lesson: Codable {
        var task: String
        var lesson: String
        /// How many tries it took, when Joe knows.
        var tries: Int?
        var date: Date
        /// Saved from the session's own record of the steps, not written by Claude.
        var automatic: Bool?
    }

    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/Lessons.json")
    /// The most the system prompt carries, so it stays small.
    static let shown = 15

    static var all: [Lesson] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Lesson].self, from: data)) ?? []
    }

    private static func write(_ lessons: [Lesson]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(lessons) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Saves a lesson, replacing one for the same task. A lesson Claude wrote isn't replaced by an
    /// automatic one.
    @discardableResult
    static func save(task: String, lesson: String, tries: Int? = nil, automatic: Bool = false) -> String {
        let task = clip(task, 120), lesson = clip(lesson, 600)
        guard !task.isEmpty, !lesson.isEmpty else { return "Use: --learn \"<task>\" \"<what worked>\"" }
        var lessons = all
        if let old = lessons.firstIndex(where: { same($0.task, task) }) {
            if automatic, lessons[old].automatic != true { return "Kept the lesson already saved for that." }
            lessons.remove(at: old)
        }
        lessons.insert(Lesson(task: task, lesson: lesson, tries: tries, date: Date(), automatic: automatic ? true : nil), at: 0)
        write(Array(lessons.prefix(60)))
        return "Saved. Next time: \(lesson)"
    }

    /// `Joe --learn "<task>" "<what worked>"`, `--learn list`, `--learn forget "<task>"`.
    static func run(_ args: [String]) -> String {
        switch (args.first ?? "", args.count) {
        case ("list", 1):
            let lessons = all
            return lessons.isEmpty ? "No lessons yet." : lessons.map(line).joined(separator: "\n")
        case ("forget", 2):
            var lessons = all
            guard let old = lessons.firstIndex(where: { same($0.task, args[1]) }) else { return "No lesson for that." }
            lessons.remove(at: old)
            write(lessons)
            return "Forgot it."
        case (_, 2):
            return save(task: args[0], lesson: args[1])
        default:
            return "Use: --learn \"<task>\" \"<what worked>\" | list | forget \"<task>\""
        }
    }

    /// For the system prompt.
    static var instructions: String {
        let lessons = all.prefix(shown)
        let saved = lessons.isEmpty ? "" : """

            Lessons from tasks that took you several tries before (follow the one that matches before \
            trying anything else):
            \(lessons.map { "- " + line($0) }.joined(separator: "\n"))
            """
        return """


            Learning from mistakes: when a task took you more than one try (a step failed, a click or \
            save didn't stick, you had to go back and redo it, or they said it was wrong) and you then \
            got it right, save what finally worked before your reply, without asking: \
            "\(Bundle.main.executablePath ?? "Joe")" --learn "<the task, in a few words, with the site>" \
            "<what worked: the page, the fields and buttons by their labels, the order, and what not to do>". \
            Keep it to one or two sentences, with no uids (they change) and nothing private. Don't mention \
            it unless they ask.\(saved)
            """
    }

    private static func line(_ lesson: Lesson) -> String {
        "\(lesson.task): \(lesson.lesson)\(lesson.tries.map { " (took \($0) tries)" } ?? "")"
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let text = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// The same task, give or take case and punctuation.
    private static func same(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " } }
        return words(a) == words(b)
    }

    /// The steps of one task as the session saw them, across follow-ups, until it's done.
    struct Trail {
        private(set) var task = ""
        private struct Step {
            var text: String
            /// Nil until its result comes.
            var failed: Bool?
        }
        private var steps: [Step] = []
        private var ids: [String: Int] = [:]
        private var failures = 0
        private var learned = false
        /// The task of a turn that went fine, in case they come back to say it didn't.
        private var previous = ""

        /// A new request. A follow-up saying it went wrong counts as a failure of the same task.
        mutating func request(_ text: String) {
            if Self.saysWrong(text), !(task.isEmpty && previous.isEmpty) {
                if task.isEmpty { task = previous }
                failures += 1
                steps.append(Step(text: "(they said it was wrong)", failed: true))
            } else if task.isEmpty {
                task = text
            }
        }

        mutating func call(id: String, tool: String, input: [String: Any]) {
            if tool == "Bash", let words = ToolPolicy.shellWords(input["command"] as? String ?? ""),
               words.count >= 2, words[0] == Bundle.main.executablePath, words[1] == "--learn" {
                learned = true
                return
            }
            guard let text = Self.step(tool, input) else { return }
            // The same call again is a retry.
            if steps.last?.text == text { failures += 1 }
            ids[id] = steps.count
            steps.append(Step(text: text))
        }

        mutating func result(id: String, text: String, isError: Bool) {
            guard let index = ids.removeValue(forKey: id) else { return }
            let failed = isError || Self.looksFailed(text)
            steps[index].failed = failed
            if failed { failures += 1 }
        }

        /// At the end of a turn: once it took two or more failures, the steps after the last one are
        /// what worked. Saved unless Claude saved its own lesson; then the trail starts over.
        mutating func finished() {
            // Right the first time: the next request is a new task.
            if failures == 0 { let done = task; self = Trail(); previous = done; return }
            guard failures >= 2 else { return }
            defer { self = Trail() }
            guard !learned, let last = steps.lastIndex(where: { $0.failed == true }) else { return }
            let worked = steps[(last + 1)...].filter { $0.failed == false }.map { $0.text }
            guard !worked.isEmpty else { return }
            Lessons.save(task: task, lesson: "What worked: " + worked.suffix(8).joined(separator: ", then "),
                         tries: failures + 1, automatic: true)
        }

        /// One step, short: Joe's own commands and the joe-browser tools, which is where tasks
        /// go wrong. Long text (a whole reflection) is cut.
        private static func step(_ tool: String, _ input: [String: Any]) -> String? {
            func short(_ s: String) -> String { s.count > 40 ? String(s.prefix(37)) + "…" : s }
            if tool == "Bash" {
                guard let words = ToolPolicy.shellWords(input["command"] as? String ?? ""),
                      words.count >= 2, words[0] == Bundle.main.executablePath, words[1] != "--plan",
                      !(words[1] == "--tab" && words.count >= 3 && ["read", "list", "find"].contains(words[2])) else { return nil }
                // uids change from page to page, so they're left out.
                let rest = words.dropFirst().filter { $0.firstMatch(of: #/^t?\d+(_\d+)?$/#) == nil }
                return "Joe " + rest.map { $0.contains(" ") ? "\"\(short($0))\"" : short($0) }.joined(separator: " ")
            }
            let prefix = "mcp__\(JoeBrowser.server)__"
            guard tool.hasPrefix(prefix) else { return nil }
            let name = String(tool.dropFirst(prefix.count))
            guard !["take_snapshot", "take_screenshot", "list_pages", "wait_for"].contains(name) else { return nil }
            let detail = [input["url"], input["value"], input["text"], input["key"]].compactMap { $0 as? String }.first
            return name + (detail.map { " \"\(short($0))\"" } ?? "")
        }

        private static func looksFailed(_ text: String) -> Bool {
            let start = text.prefix(160).lowercased()
            return ["couldn't", "could not", "didn't", "no option", "not found", "no element", "error", "failed",
                    "timed out", "no tab", "isn't", "can't"].contains { start.contains($0) }
        }

        private static func saysWrong(_ text: String) -> Bool {
            let text = text.lowercased()
            return ["that's wrong", "thats wrong", "didn't work", "didnt work", "not right", "try again",
                    "still wrong", "it's not saved", "didn't save", "you didn't", "that's not"].contains { text.contains($0) }
        }
    }
}
