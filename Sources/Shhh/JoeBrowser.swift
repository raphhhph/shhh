import AppKit

/// Joe's own browser: a hidden Chrome with its own profile, driven by Chrome DevTools MCP, so
/// multi-step web work (finding a ManageBac task, reading a portal) happens off screen while the
/// user keeps working. They sign in to their school sites once in that profile
/// (`Joe --browser signin`); the server and Chrome start only when Claude first uses a tool.
enum JoeBrowser {
    /// The MCP server's name, as its tools are named: mcp__joe-browser__take_snapshot.
    static let server = "joe-browser"

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shhh", isDirectory: true)
    }
    /// Where `npm install` puts chrome-devtools-mcp.
    private static var prefix: URL { support.appendingPathComponent("browser", isDirectory: true) }
    /// The browser's own profile: its cookies and sign-ins, apart from the user's own browser.
    static var profile: URL { support.appendingPathComponent("Browser profile", isDirectory: true) }

    private static var node: String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first(where: FileManager.default.isExecutableFile)
    }
    private static var npm: String? {
        ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first(where: FileManager.default.isExecutableFile)
    }
    /// The server's script, with npm's .bin link resolved so node can run it directly.
    private static var script: String? {
        let link = prefix.appendingPathComponent("node_modules/.bin/chrome-devtools-mcp").path
        guard FileManager.default.fileExists(atPath: link) else { return nil }
        return URL(fileURLWithPath: link).resolvingSymlinksInPath().path
    }

    /// Chromium browsers the server can drive (Chrome first: it's what it's tested with).
    private static let browsers = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi",
    ]
    private static var chrome: String? { browsers.first(where: FileManager.default.isExecutableFile) }

    /// Off in Settings, or until `Joe --browser setup` has installed the server.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "joeBrowser") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "joeBrowser") }
    }
    static var isReady: Bool { isEnabled && node != nil && script != nil && chrome != nil }

    /// `--mcp-config` for a Session: the server, headless, in Joe's profile, with only the tools
    /// a student's errands need (no performance traces, emulation or network logs).
    static var mcpConfig: String? {
        guard isReady, let node, let script, let chrome else { return nil }
        let arguments = [
            script, "--headless", "--userDataDir", profile.path, "--executablePath", chrome,
            "--viewport", "1280x900", "--no-usage-statistics", "--no-performance-crux",
            "--categoryPerformance=false", "--categoryEmulation=false", "--categoryNetwork=false",
            "--screenshotFormat", "jpeg", "--screenshotMaxWidth", "1280",
        ]
        let config: [String: Any] = ["mcpServers": [server: ["command": node, "args": arguments]]]
        return (try? JSONSerialization.data(withJSONObject: config)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Joe --browser

    static func run(_ arguments: [String]) -> String {
        switch arguments.first {
        case "setup": return setup()
        case "signin": return signIn(Array(arguments.dropFirst()))
        case "status": return status()
        default: return "Use: --browser setup | signin [<url>…] | status"
        }
    }

    private static func status() -> String {
        if !isEnabled { return "Joe's browser is off (Settings)." }
        if node == nil { return "Joe's browser needs Node.js: brew install node, then Joe --browser setup." }
        if chrome == nil { return "Joe's browser needs Google Chrome (or Brave, Edge or Vivaldi) in Applications." }
        if script == nil { return "Not set up yet: run Joe --browser setup." }
        let signedIn = ["Default/Cookies", "Default/Network/Cookies"].contains {
            FileManager.default.fileExists(atPath: profile.appendingPathComponent($0).path)
        }
        return "Joe's browser is ready (\(URL(fileURLWithPath: chrome!).lastPathComponent), hidden)."
            + (signedIn ? "" : " Nothing signed in yet: run Joe --browser signin.")
    }

    /// Installs chrome-devtools-mcp into Joe's Application Support folder (about 30 MB).
    private static func setup() -> String {
        guard let npm else { return "Needs Node.js first: brew install node." }
        try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let (ok, output) = shell(npm, ["install", "--silent", "--no-fund", "--no-audit", "--prefix", prefix.path, "chrome-devtools-mcp@latest"])
        guard ok, script != nil else { return "Couldn't install chrome-devtools-mcp:\n\(output.suffix(600))" }
        return "Installed. " + status() + " New questions to Joe use it."
    }

    /// Opens the profile in a normal window to sign in. It must be closed afterwards: a profile
    /// can only be open in one Chrome at a time, and Joe's hidden one uses it.
    private static func signIn(_ links: [String]) -> String {
        guard let chrome else { return status() }
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let pages = links.isEmpty ? ["https://accounts.google.com", "https://managebac.com/login"] : links
        let app = URL(fileURLWithPath: chrome).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check"] + pages
        let done = DispatchSemaphore(value: 0)
        var failed = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            failed = error != nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return failed ? "Couldn't open Joe's browser to sign in."
            : "Joe's browser is open. Sign in to your school sites (Google, ManageBac, anything else), then quit that window (Cmd-Q). Joe stays signed in."
    }

    private static func shell(_ path: String, _ arguments: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: What's on the page

    /// The page's elements from the latest snapshots (uid → role and name), so a click can be
    /// judged by what it hits ("button Submit") instead of an opaque id.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var elements: [String: (role: String, name: String)] = [:]

    /// Reads `uid=1_4 button "Submit"` lines out of a tool result.
    static func remember(_ result: String) {
        guard result.contains("uid=") else { return }
        let pattern = try! NSRegularExpression(pattern: #"uid=(\S+)\s+(\w+)(?:\s+"([^"]*)")?"#)
        let range = NSRange(result.startIndex..., in: result)
        var found: [String: (role: String, name: String)] = [:]
        for match in pattern.matches(in: result, range: range) {
            guard let uid = Range(match.range(at: 1), in: result), let role = Range(match.range(at: 2), in: result) else { continue }
            let name = Range(match.range(at: 3), in: result).map { String(result[$0]) } ?? ""
            found[String(result[uid])] = (String(result[role]), name)
        }
        lock.lock()
        if elements.count > 5000 { elements.removeAll() }
        elements.merge(found) { $1 }
        lock.unlock()
    }

    /// "button Submit" for a uid, or "" when it hasn't been seen.
    static func element(_ uid: Any?) -> String {
        guard let uid = uid as? String else { return "" }
        lock.lock()
        defer { lock.unlock() }
        return elements[uid].map { "\($0.role) \($0.name)" } ?? ""
    }

    /// What the last fill typed into, so pressing Enter there can be judged (a search box is fine,
    /// a message box may send).
    nonisolated(unsafe) static var lastField = ""
}
