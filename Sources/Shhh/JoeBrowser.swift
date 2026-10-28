import AppKit
import CryptoKit

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
    static var profile: URL { support.appendingPathComponent("Joe browser profile", isDirectory: true) }
    /// The first version's profile, made by Vivaldi (which hangs when hidden, so it's no longer used).
    private static var oldProfile: URL { support.appendingPathComponent("Browser profile", isDirectory: true) }

    /// Node: Homebrew's, or Joe's own copy (a fresh Mac has neither Homebrew nor Node).
    private static var node: String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", ownNode.appendingPathComponent("bin/node").path]
            .first(where: FileManager.default.isExecutableFile)
    }
    /// Joe's own Node, unpacked from nodejs.org's official build by `prepare()`. No admin rights needed.
    private static var ownNode: URL { prefix.appendingPathComponent("node", isDirectory: true) }
    /// The pinned build and its published SHA-256, per processor.
    private static let nodeVersion = "v22.20.0"
    private static var nodeBuild: (name: String, sha256: String) {
        #if arch(arm64)
        ("node-\(nodeVersion)-darwin-arm64", "cc04a76a09f79290194c0646f48fec40354d88969bec467789a5d55dd097f949")
        #else
        ("node-\(nodeVersion)-darwin-x64", "00df9c5df3e4ec6848c26b70fb47bf96492f342f4bed6b17f12d99b3a45eeecc")
        #endif
    }
    /// npm's script, run by `node` (npm's own launcher looks for node on PATH): Homebrew's
    /// (in its lib folder, not the Cellar), or the one inside Joe's own Node.
    private static var npmScript: String? {
        ["/opt/homebrew/lib", "/usr/local/lib", ownNode.appendingPathComponent("lib").path]
            .map { $0 + "/node_modules/npm/bin/npm-cli.js" }
            .first(where: FileManager.default.fileExists)
    }
    /// The server's script, with npm's .bin link resolved so node can run it directly.
    private static var script: String? {
        let link = prefix.appendingPathComponent("node_modules/.bin/chrome-devtools-mcp").path
        guard FileManager.default.fileExists(atPath: link) else { return nil }
        return URL(fileURLWithPath: link).resolvingSymlinksInPath().path
    }

    /// Chromium browsers the server can drive. Not Vivaldi: hidden, it never loads a page (28 Oct:
    /// 40 s and nothing, where curl took 0.7 s). Without one of these, Joe uses its own Chrome
    /// for Testing, which `prepare()` downloads.
    private static let browsers = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    ]
    /// Where Joe's own Chrome for Testing goes (about 300 MB unpacked).
    private static var ownChrome: URL { prefix.appendingPathComponent("chrome", isDirectory: true) }
    private static var chrome: String? {
        if let installed = browsers.first(where: FileManager.default.isExecutableFile) { return installed }
        let found = FileManager.default.enumerator(at: ownChrome, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL }
            .first { $0.path.hasSuffix("Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing") }
        return found?.path
    }
    /// A browser it can drive is ready (if not, `prepare()` downloads one).
    static var hasChrome: Bool { chrome != nil }

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
        case "setup": return wait { await prepare() }
        case "signin": return openSignIn(Array(arguments.dropFirst()))
        case "status": return status()
        default: return "Use: --browser setup | signin [<url>…] | status"
        }
    }

    /// Runs async work from the command line, which has no run loop of its own to wait on.
    private static func wait(_ work: @escaping @Sendable () async -> String) -> String {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = ""
        Task.detached {
            result = await work()
            done.signal()
        }
        done.wait()
        return result
    }

    private static func status() -> String {
        if !isEnabled { return "Joe's browser is off (Settings)." }
        if chrome == nil || node == nil || script == nil { return "Not set up yet: run Joe --browser setup." }
        let signedIn = ["Default/Cookies", "Default/Network/Cookies"].contains {
            FileManager.default.fileExists(atPath: profile.appendingPathComponent($0).path)
        }
        return "Joe's browser is ready (\(URL(fileURLWithPath: chrome!).lastPathComponent), hidden)."
            + (signedIn ? "" : " Nothing signed in yet: run Joe --browser signin.")
    }

    /// Gets everything the hidden browser needs, if it's missing: Node (from nodejs.org, about 45 MB,
    /// checked against its published hash), chrome-devtools-mcp (about 30 MB) and, without Chrome,
    /// Brave or Edge, Chrome for Testing (about 150 MB download). One line back.
    static func prepare() async -> String {
        if node != nil, script != nil, browsersCLI != nil, chrome != nil { return "Joe's browser is ready." + (isEnabled ? "" : " It's off in Settings.") }
        if node == nil || npmScript == nil, let failure = await downloadNode() { return failure }
        guard let node, let npm = npmScript else { return "Couldn't set up Node for Joe's browser." }
        try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        if script == nil || browsersCLI == nil {
            let (ok, output) = shell(node, [npm, "install", "--silent", "--no-fund", "--no-audit", "--prefix", prefix.path,
                                            "chrome-devtools-mcp@latest", "@puppeteer/browsers@latest"])
            guard ok, script != nil else { return "Couldn't install chrome-devtools-mcp:\n\(output.suffix(600))" }
        }
        if chrome == nil {
            // No Chrome, Brave or Edge: Google's Chrome for Testing, kept inside Joe's folder.
            // Google's servers are blocked in mainland China, so its mirror is tried as well.
            guard let cli = browsersCLI else { return "Couldn't install the Chrome downloader." }
            let versions = await chromeVersions()
            guard !versions.isEmpty else { return "Couldn't find out which Chrome to download (no answer from Google or its China mirror)." }
            var output = ""
            for version in versions {
                for base in chromeMirrors where chrome == nil {
                    let result = shell(node, [cli, "install", "chrome@\(version)", "--base-url", base, "--path", ownChrome.path], timeout: 900)
                    output += "\(version) from \(base): \(result.output.suffix(300))\n"
                }
            }
            guard chrome != nil else { return "Couldn't download Chrome for Joe's browser:\n\(output.suffix(900))" }
        }
        // The first version's profile was Vivaldi's, which hangs when hidden: to the Trash.
        if FileManager.default.fileExists(atPath: oldProfile.appendingPathComponent("Default/AdBlockRules").path) {
            try? FileManager.default.trashItem(at: oldProfile, resultingItemURL: nil)
        }
        return "Joe's browser is set up." + (isEnabled ? "" : " It's off in Settings.")
    }

    /// Where Chrome for Testing downloads from: npmmirror's copy first (reachable in China, where
    /// Raph is), then Google's own.
    private static let chromeMirrors = ["https://cdn.npmmirror.com/binaries/chrome-for-testing",
                                        "https://storage.googleapis.com/chrome-for-testing-public"]

    /// Chrome for Testing versions to try: Google's current stable, then the newest on npmmirror
    /// (which may lag Google's by a day). 15 s each.
    private static func chromeVersions() async -> [String] {
        var found: [String] = []
        let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 15; return c }())
        if let url = URL(string: "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json"),
           let (data, _) = try? await session.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stable = ((json["channels"] as? [String: Any])?["Stable"] as? [String: Any])?["version"] as? String {
            found.append(stable)
        }
        guard let url = URL(string: "https://registry.npmmirror.com/-/binary/chrome-for-testing/"),
              let (data, _) = try? await session.data(from: url),
              let folders = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return found }
        let versions = folders.compactMap { ($0["name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { $0.split(separator: ".").count == 4 && $0.split(separator: ".").allSatisfy { Int($0) != nil } }
        // The newest but one: the newest may still be copying.
        let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        if let mirrored = sorted.count >= 2 ? sorted[sorted.count - 2] : sorted.last, !found.contains(mirrored) { found.append(mirrored) }
        return found
    }

    /// Puppeteer's browser downloader, with npm's .bin link resolved.
    private static var browsersCLI: String? {
        let link = prefix.appendingPathComponent("node_modules/.bin/browsers").path
        guard FileManager.default.fileExists(atPath: link) else { return nil }
        return URL(fileURLWithPath: link).resolvingSymlinksInPath().path
    }

    /// Downloads and unpacks Joe's own Node, or says why it couldn't.
    private static func downloadNode() async -> String? {
        let build = nodeBuild
        guard let url = URL(string: "https://nodejs.org/dist/\(nodeVersion)/\(build.name).tar.gz") else { return "Bad Node address." }
        let file: URL
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "Couldn't download Node (nodejs.org answered \((response as? HTTPURLResponse)?.statusCode ?? 0))." }
            file = downloaded
        } catch {
            return "Couldn't download Node: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == build.sha256 else {
            return "The Node download didn't match its published checksum, so it wasn't used."
        }
        let unpack = prefix.appendingPathComponent("node-unpack", isDirectory: true)
        try? FileManager.default.removeItem(at: unpack)
        try? FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unpack) }
        let (ok, output) = shell("/usr/bin/tar", ["-xzf", file.path, "-C", unpack.path])
        guard ok else { return "Couldn't unpack Node: \(output.suffix(300))" }
        try? FileManager.default.removeItem(at: ownNode)
        do {
            try FileManager.default.moveItem(at: unpack.appendingPathComponent(build.name), to: ownNode)
        } catch {
            return "Couldn't put Node in place: \(error.localizedDescription)"
        }
        return nil
    }

    /// Opens the profile in a normal window to sign in. It must be closed afterwards: a profile
    /// can only be open in one Chrome at a time, and Joe's hidden one uses it.
    static func openSignIn(_ links: [String] = []) -> String {
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

    private static func shell(_ path: String, _ arguments: [String], timeout: TimeInterval = 600) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // npm's install scripts look for node on PATH: the one running it first.
        environment["PATH"] = [node.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .compactMap { $0 }.joined(separator: ":")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, error.localizedDescription) }
        // A download that stalls (a blocked server) is stopped instead of hanging setup.
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        defer { stop.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: What's on the page

    /// The page's elements from the latest snapshots (uid → role and name), so a click can be
    /// judged by what it hits ("button Submit") instead of an opaque id.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var elements: [String: (role: String, name: String)] = [:]

    /// The page each uid was seen on, and the page Joe's browser is on, for telling a CAS
    /// reflection (Joe may file it alone) from a graded task (always asks).
    nonisolated(unsafe) private static var pages: [String: String] = [:]
    nonisolated(unsafe) static var currentPage = ""

    /// Reads `uid=1_4 button "Submit"` lines out of a tool result, with the page they're on: given
    /// (`--tab read`), or the selected one a Chrome DevTools result lists ("0: <url> [selected]").
    static func remember(_ result: String, page: String? = nil) {
        guard result.contains("uid=") || result.contains("[selected]") else { return }
        var page = page
        if page == nil, let selected = result.firstMatch(of: #/(\S+) \[selected\]/#) {
            page = String(selected.1)
        }
        let pattern = try! NSRegularExpression(pattern: #"uid=(\S+)\s+(\w+)(?:\s+"([^"]*)")?"#)
        let range = NSRange(result.startIndex..., in: result)
        var found: [String: (role: String, name: String)] = [:]
        for match in pattern.matches(in: result, range: range) {
            guard let uid = Range(match.range(at: 1), in: result), let role = Range(match.range(at: 2), in: result) else { continue }
            let name = Range(match.range(at: 3), in: result).map { String(result[$0]) } ?? ""
            found[String(result[uid])] = (String(result[role]), name)
        }
        lock.lock()
        if elements.count > 5000 { elements.removeAll(); pages.removeAll() }
        elements.merge(found) { $1 }
        if let page {
            if result.contains("[selected]") { currentPage = page }
            for uid in found.keys { pages[uid] = page }
        }
        lock.unlock()
    }

    /// "button Submit" for a uid, or "" when it hasn't been seen.
    static func element(_ uid: Any?) -> String {
        guard let uid = uid as? String else { return "" }
        lock.lock()
        defer { lock.unlock() }
        return elements[uid].map { "\($0.role) \($0.name)" } ?? ""
    }

    /// The address of the page a uid was seen on, or "".
    static func page(_ uid: Any?) -> String {
        guard let uid = uid as? String else { return "" }
        lock.lock()
        defer { lock.unlock() }
        return pages[uid] ?? ""
    }

    /// Pages where submitting isn't graded, so Joe may file things there without asking (in
    /// Hands-off): ManageBac's CAS (reflections, evidence, experiences). Tasks, dropboxes and
    /// anything assessed stay behind the approval card.
    static func isUngraded(_ address: String) -> Bool {
        let url = address.lowercased()
        guard url.contains("managebac") else { return false }
        let graded = ["/core_tasks", "/tasks", "/assignments", "/dropbox", "/submission", "/assessment", "/grades", "/exam", "/units"]
        if graded.contains(where: url.contains) { return false }
        return ["/activity/cas", "/cas/", "/cas?", "/reflections", "/cas_"].contains(where: url.contains) || url.hasSuffix("/cas")
    }

    /// What the last fill typed into, so pressing Enter there can be judged (a search box is fine,
    /// a message box may send).
    nonisolated(unsafe) static var lastField = ""
}
