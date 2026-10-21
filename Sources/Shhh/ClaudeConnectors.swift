import Foundation

/// Which claude.ai connectors (Gmail, Google Calendar, Drive…) the student's Claude has, so
/// onboarding can tick them off instead of always asking. Read from the first message every
/// `claude -p` session sends (`system`/`init`, with `mcp_servers`: name and status).
enum ClaudeConnectors {
    private static let key = "claudeConnectors"

    /// The connected servers' names from the last session that started, e.g. "claude_ai_Gmail".
    static var connected: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    /// Whether one whose name contains `word` ("gmail", "calendar") is connected.
    static func has(_ word: String) -> Bool {
        connected.contains { $0.localizedCaseInsensitiveContains(word) }
    }

    static func note(_ message: [String: Any]) {
        guard message["subtype"] as? String == "init", let servers = message["mcp_servers"] as? [[String: Any]] else { return }
        let names = servers.compactMap { $0["status"] as? String == "connected" ? $0["name"] as? String : nil }
        UserDefaults.standard.set(names, forKey: key)
    }
}
