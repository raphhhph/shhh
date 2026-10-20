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

    static var storedKey: String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return json["anthropicKey"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: ["anthropicKey": trimmed]) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// "sk-ant-…a1b2", for showing which key is saved without showing it.
    static var maskedKey: String? {
        storedKey.map { $0.count > 12 ? String($0.prefix(7)) + "…" + String($0.suffix(4)) : "saved" }
    }
}
