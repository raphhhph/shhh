import Foundation

/// Everything the assistant has created through a connector (a Gmail draft, a calendar event, a
/// Drive file), by ID, so it can delete its own work without asking. Kept on disk for 60 days, so
/// "delete the draft you wrote yesterday" works too.
@MainActor
final class CreatedItems {
    static let shared = CreatedItems()

    private struct Item: Codable {
        let id: String
        let tool: String
        let date: Date
    }

    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/Created by assistant.json")
    private var items: [Item]

    private init() {
        let saved = (try? Data(contentsOf: Self.url)).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        let cutoff = Date().addingTimeInterval(-60 * 24 * 3600)
        items = saved.filter { $0.date > cutoff }
    }

    /// Tools that make something new, whose results carry the new item's ID.
    static func isCreation(_ tool: String) -> Bool {
        !words(tool).isDisjoint(with: ["create", "copy", "duplicate", "insert", "add", "new", "upload", "import"])
    }

    /// Tools that delete or trash something.
    static func isDeletion(_ tool: String) -> Bool {
        !words(tool).isDisjoint(with: ["delete", "trash", "remove"])
    }

    /// Remembers the IDs in a creation tool's result.
    func record(result: String, tool: String) {
        let ids = Self.ids(in: result)
        guard !ids.isEmpty else { return }
        let known = Set(items.map(\.id))
        items += ids.subtracting(known).map { Item(id: $0, tool: tool, date: Date()) }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: Self.url, options: .atomic)
    }

    /// Whether everything a deletion targets was created by the assistant.
    func owns(_ input: [String: Any]) -> Bool {
        var targets: [String] = []
        for (key, value) in input {
            let key = key.lowercased()
            // The item's ID, not the calendar or label it sits in.
            guard key.hasSuffix("id") || key.hasSuffix("ids"), !["calendarid", "labelid", "labelids"].contains(key) else { continue }
            if let id = value as? String { targets.append(id) }
            if let ids = value as? [String] { targets += ids }
        }
        let known = Set(items.map(\.id))
        return !targets.isEmpty && targets.allSatisfy(known.contains)
    }

    /// IDs in a tool result: JSON fields like "id" or "draftId", or text like "ID: abc123".
    private static func ids(in text: String) -> Set<String> {
        let patterns = [#""(?:[A-Za-z_]*[iI]d)"\s*:\s*"([^"]{6,})""#, #"\b[iI][dD]\s*[:=]\s*([A-Za-z0-9_\-]{6,})"#]
        var found = Set<String>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) { found.insert(String(text[r])) }
            }
        }
        return found
    }

    /// "mcp__claude_ai_Gmail__delete_draft" → ["delete", "draft"]
    private static func words(_ tool: String) -> Set<String> {
        let parts = tool.components(separatedBy: "__")
        guard parts.count == 3, parts[0] == "mcp", parts[1] != "claude-in-chrome" else { return [] }
        return Set(parts[2].lowercased().split(separator: "_").map(String.init))
    }
}
