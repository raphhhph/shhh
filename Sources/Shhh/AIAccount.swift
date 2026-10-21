import Foundation

/// How Joe pays for Claude: the Claude plan Claude Code is signed in to (the default), or an
/// Anthropic API key, billed per request, which is how Joe runs for other people. The key is kept
/// in a file only this user can read (API.json in Joe's folder), not the Keychain, which asked for
/// the Mac's password after every update.
enum AIAccount {
    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/API.json")

    static var usesAPIKey: Bool {
        get { UserDefaults.standard.bool(forKey: "useAPIKey") }
        set { UserDefaults.standard.set(newValue, forKey: "useAPIKey") }
    }

    /// The key, when "API key" mode is on and one is saved.
    static var apiKey: String? {
        guard usesAPIKey else { return nil }
        return storedKey
    }

    static var storedKey: String? { stored("anthropicKey") }

    private static func stored(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return json[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func save(_ key: String, as name: String = "anthropicKey") {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var json = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) ?? [:]
        json[name] = trimmed
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: OpenRouter

    /// Settings → Advanced → Other models: GPT, DeepSeek, Qwen, Gemini… through OpenRouter, which
    /// speaks Claude Code's protocol. Cheaper for simple things; Claude stays the best at using the Mac.
    static var usesOpenRouter: Bool {
        get { UserDefaults.standard.bool(forKey: "useOpenRouter") && stored("openRouterKey") != nil }
        set { UserDefaults.standard.set(newValue, forKey: "useOpenRouter") }
    }

    /// Any Anthropic-compatible API: OpenRouter by default, or a gateway such as LiteLLM, a company
    /// proxy or a local model server. (OpenAI-only APIs go through one of these.)
    static var endpoint: String {
        get { UserDefaults.standard.string(forKey: "customEndpoint").flatMap { $0.isEmpty ? nil : $0 } ?? "https://openrouter.ai/api" }
        set { UserDefaults.standard.set(newValue, forKey: "customEndpoint") }
    }

    static var openRouterModel: String {
        get { UserDefaults.standard.string(forKey: "openRouterModel").flatMap { $0.isEmpty ? nil : $0 } ?? "openrouter/auto" }
        set { UserDefaults.standard.set(newValue, forKey: "openRouterModel") }
    }

    static var maskedOpenRouterKey: String? {
        stored("openRouterKey").map { $0.count > 12 ? String($0.prefix(8)) + "…" + String($0.suffix(4)) : "saved" }
    }

    /// The model to ask for: the OpenRouter one in that mode, else Claude's.
    static func model(_ claude: String) -> String { usesOpenRouter ? openRouterModel : claude }

    /// What Claude Code needs to talk to OpenRouter. Its own settings folder, so the Claude plan's
    /// sign-in (kept in the usual one) isn't used, and isn't signed out either.
    static var openRouterEnvironment: [String: String]? {
        guard usesOpenRouter, let key = stored("openRouterKey") else { return nil }
        let folder = url.deletingLastPathComponent().appendingPathComponent("OpenRouter Claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ["ANTHROPIC_BASE_URL": endpoint, "ANTHROPIC_AUTH_TOKEN": key,
                "ANTHROPIC_API_KEY": "", "CLAUDE_CONFIG_DIR": folder.path]
    }

    // MARK: ChatGPT

    /// Settings → Advanced → AI: "ChatGPT" runs Joe on OpenAI's Codex CLI signed in to the user's
    /// ChatGPT plan (`CodexSession`), for students who pay for ChatGPT instead of Claude.
    static var usesChatGPT: Bool {
        get { UserDefaults.standard.string(forKey: "aiProvider") == "chatgpt" }
        set { UserDefaults.standard.set(newValue ? "chatgpt" : "claude", forKey: "aiProvider") }
    }

    /// Never chosen, and only Codex is on this Mac: ChatGPT, so a student who set up Codex
    /// elsewhere has nothing to switch.
    static func chooseProviderIfUnset() {
        guard UserDefaults.standard.string(forKey: "aiProvider") == nil,
              Assistant.executable == nil, CodexSession.executable != nil else { return }
        usesChatGPT = true
    }

    /// A Codex model ID, or nil for the plan's default (which follows OpenAI's newest).
    static var chatGPTModel: String? {
        UserDefaults.standard.string(forKey: "chatGPTModel").flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Whose AI answers, for messages: "Claude" or "ChatGPT".
    static var brainName: String { usesChatGPT ? "ChatGPT" : "Claude" }

    /// "sk-ant-…a1b2", for showing which key is saved without showing it.
    static var maskedKey: String? {
        storedKey.map { $0.count > 12 ? String($0.prefix(7)) + "…" + String($0.suffix(4)) : "saved" }
    }
}
