import Foundation

/// What Joe already knows on the Mac, sent with a conversation's first request, so a quick
/// question ("what's on tomorrow?", "when's my chem test?") is answered straight away instead of
/// after a round trip to the Google Calendar connector: on 22 Oct that took 8 s before the first
/// word (ToolSearch, the connector's call, then a second reply).
enum QuickContext {
    nonisolated static var isEnabled: Bool { UserDefaults.standard.object(forKey: "quickContext") as? Bool ?? true }

    /// The next three days and the deadlines of the next two weeks, from the dashboard's calendar
    /// (timetable, Joe's saved Google Calendar and ManageBac items, calendar links, alarms, the Mac's
    /// Calendar). Empty when there's nothing.
    static var calendar: String {
        guard isEnabled else { return "" }
        let now = Date()
        let soon = CalendarFeed.items(from: now, days: 3).filter { $0.kind != .deadline && ($0.end ?? $0.start) >= now }
        let deadlines = CalendarFeed.items(from: now, days: 14).filter { $0.kind == .deadline }
        let items = (soon + deadlines).sorted { $0.start < $1.start }.prefix(40)
        guard !items.isEmpty else { return "" }
        let lines = items.map { item -> String in
            let day = item.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            let time = item.allDay || item.kind == .deadline && Calendar.current.component(.hour, from: item.start) == 0 ? ""
                : " " + item.start.formatted(date: .omitted, time: .shortened)
                    + (item.end.map { "–" + $0.formatted(date: .omitted, time: .shortened) } ?? "")
            let detail = item.detail.isEmpty ? "" : " (\(item.detail.prefix(60)))"
            return "- \(day)\(time) [\(item.kind.rawValue)] \(item.title)\(detail)"
        }
        let synced = CalendarFeed.syncedAt.map { " Google Calendar and ManageBac items were saved \($0.formatted(.relative(presentation: .named)))." } ?? ""
        return """
            Their calendar, from Joe (next 3 days, deadlines for 2 weeks).\(synced) For a quick question about \
            their schedule or deadlines, answer from this without calling a calendar tool; check the live \
            calendar only for something it doesn't cover, or when they ask to change something.
            \(lines.joined(separator: "\n"))
            """
    }
}

/// Connectors Joe has no use for (finance, CRM, design boards and the like) are left out of its
/// sessions. Raph's account had 19 connectors with 361 tools, and Claude Code's turn took about
/// 4.5 s to start answering on his Mac, against about 1.2 s with few (22 Oct). The ones a student
/// uses (Google, Microsoft, Notion, Canva…) and every connector set up on the Mac itself (the
/// notes vault, Joe's browser, Chrome) stay. Off: `defaults write io.github.tibophlp.shhh
/// trimConnectors -bool false`; keep more with `connectorsKept` (words in their names).
enum Connectors {
    nonisolated static var isEnabled: Bool { UserDefaults.standard.object(forKey: "trimConnectors") as? Bool ?? true }

    private static let wanted = ["gmail", "google", "calendar", "drive", "docs", "sheets", "slides", "notion", "canva",
                                 "outlook", "microsoft", "onedrive", "teams", "office", "todoist", "spotify",
                                 "managebac", "obsidian", "vault", "joe", "chrome", "apple", "icloud", "reminders"]

    /// Server names seen in earlier sessions, as they appear in tool names ("claude_ai_Miro").
    private static var seen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mcpServersSeen") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "mcpServersSeen") }
    }

    /// From a session's start ("system"/"init"): the servers it has, kept for the next sessions
    /// (the ones left out don't show up again, so nothing is ever forgotten).
    static func learn(_ message: [String: Any]) {
        var names = seen
        for tool in message["tools"] as? [String] ?? [] {
            let parts = tool.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" { names.insert(parts[1]) }
        }
        for server in message["mcp_servers"] as? [[String: Any]] ?? [] {
            if let name = server["name"] as? String { names.insert(normalized(name)) }
        }
        if names != seen { seen = names }
    }

    /// "claude.ai Gmail" → "claude_ai_Gmail", "plugin:finance:slack" → "plugin_finance_slack", as
    /// Claude Code names their tools.
    private static func normalized(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    /// For `--disallowedTools`: every tool of each unused account connector or plugin.
    static var unused: [String] {
        guard isEnabled else { return [] }
        let kept = wanted + (UserDefaults.standard.stringArray(forKey: "connectorsKept") ?? []).map { $0.lowercased() }
        return seen.filter { name in
            (name.hasPrefix("claude_ai_") || name.hasPrefix("plugin_"))
                && !kept.contains { name.lowercased().contains($0) }
        }.sorted().map { "mcp__" + $0 }
    }
}
