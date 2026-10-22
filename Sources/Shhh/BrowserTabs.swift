import AppKit

/// `Joe --tab open <url>… | list | find "<words>" | show "<words>"`: the browser's tabs without
/// looking at the screen or clicking. Pages open in the background, so the user keeps working in
/// whatever's in front; finding a tab reads every window's titles and addresses by AppleScript
/// (Chrome, Vivaldi, Brave, Edge, Arc share Chrome's dictionary). Nothing is typed or clicked.
enum BrowserTabs {
    /// Chromium browsers that answer Chrome's AppleScript (bundle id, application name).
    private static let chromium: [(id: String, name: String)] = [
        ("com.vivaldi.Vivaldi", "Vivaldi"), ("com.google.Chrome", "Google Chrome"), ("com.brave.Browser", "Brave Browser"),
        ("com.microsoft.edgemac", "Microsoft Edge"), ("company.thebrowser.Browser", "Arc"),
    ]

    static func run(_ arguments: [String]) -> String {
        switch arguments.first {
        case "open" where arguments.count >= 2: return open(Array(arguments.dropFirst()))
        case "list": return list()
        case "find" where arguments.count >= 2: return find(arguments.dropFirst().joined(separator: " "))
        case "show" where arguments.count >= 2: return show(arguments.dropFirst().joined(separator: " "))
        default: return "Use: --tab open <url>… | list | find \"<words>\" | show \"<words>\""
        }
    }

    /// The browser that opens links: the default one.
    private static var defaultBrowser: URL? {
        URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    /// Opens pages in the default browser, behind the app in front (no switching, no waiting).
    private static func open(_ links: [String]) -> String {
        let urls = links.compactMap { link -> URL? in
            let text = link.contains("://") ? link : "https://" + link
            return URL(string: text).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        }
        guard !urls.isEmpty, let browser = defaultBrowser else { return "Nothing to open: give full web addresses." }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let done = DispatchSemaphore(value: 0)
        var failed = false
        NSWorkspace.shared.open(urls, withApplicationAt: browser, configuration: configuration) { _, error in
            failed = error != nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        let name = FileManager.default.displayName(atPath: browser.path).replacingOccurrences(of: ".app", with: "")
        return failed ? "\(name) didn't open them." : "Opened \(urls.count == 1 ? urls[0].host ?? "it" : "\(urls.count) pages") in \(name), in the background."
    }

    private struct Tab { let browser: String; let window: Int; let index: Int; let title: String; let url: String }

    /// Every tab of every running Chromium browser, and the browsers that refused to answer.
    /// Inside a browser's `tell`, the word `tab` means its tab class, not the tab character, so
    /// the separator is set before it. Titles and addresses come a window at a time (one Apple
    /// event each instead of one per tab).
    private static func tabs() -> (tabs: [Tab], failures: [String]) {
        var all: [Tab] = []
        var failures: [String] = []
        for browser in chromium where !NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).isEmpty {
            let source = """
                set sep to character id 9
                set out to ""
                tell application "\(browser.name)"
                    repeat with w from 1 to count of windows
                        set titles to title of every tab of window w
                        set links to URL of every tab of window w
                        repeat with t from 1 to count of titles
                            set out to out & w & sep & t & sep & (item t of titles) & sep & (item t of links) & linefeed
                        end repeat
                    end repeat
                end tell
                return out
                """
            switch evaluate(source) {
            case .success(let text):
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 4, let w = Int(parts[0]), let t = Int(parts[1]) else { continue }
                    all.append(Tab(browser: browser.name, window: w, index: t, title: parts[2], url: parts[3]))
                }
            case .failure(let error):
                failures.append(error.code == -1743
                    ? "Joe isn't allowed to read \(browser.name): turn on \(browser.name) under Joe in System Settings > Privacy & Security > Automation."
                    : "\(browser.name) didn't answer (\(error.message)).")
            }
        }
        return (all, failures)
    }

    private static func list() -> String {
        let (all, failures) = tabs()
        guard !all.isEmpty else {
            return failures.isEmpty ? "No open tabs in Vivaldi, Chrome, Brave, Edge or Arc (Safari isn't read)." : failures.joined(separator: "\n")
        }
        return (all.prefix(80).map { "\($0.browser) · \($0.title) · \($0.url)" } + failures).joined(separator: "\n")
    }

    /// Tabs whose title or address has every word.
    private static func matching(_ words: String) -> (tabs: [Tab], failures: [String]) {
        let keys = words.lowercased().split(separator: " ").map(String.init)
        let (all, failures) = tabs()
        return (all.filter { tab in keys.allSatisfy { (tab.title + " " + tab.url).lowercased().contains($0) } }, failures)
    }

    private static func find(_ words: String) -> String {
        let (found, failures) = matching(words)
        return found.isEmpty ? (["No open tab matches “\(words)”."] + failures).joined(separator: "\n")
            : found.prefix(20).map { "\($0.browser) · \($0.title) · \($0.url)" }.joined(separator: "\n")
    }

    /// Makes the matching tab the current one in its window, without bringing the browser forward.
    private static func show(_ words: String) -> String {
        let (found, failures) = matching(words)
        guard let tab = found.first else { return (["No open tab matches “\(words)”."] + failures).joined(separator: "\n") }
        guard script("tell application \"\(tab.browser)\" to set active tab index of window \(tab.window) to \(tab.index)") != nil else {
            return "\(tab.browser) didn't switch tabs."
        }
        return "“\(tab.title)” is now the current tab in \(tab.browser)\(found.count > 1 ? " (\(found.count - 1) other tabs also matched)" : "")."
    }

    private struct ScriptError: Error { let code: Int; let message: String }

    private static func evaluate(_ source: String) -> Result<String, ScriptError> {
        if !Thread.isMainThread { return DispatchQueue.main.sync { evaluate(source) } }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            return .failure(ScriptError(code: error[NSAppleScript.errorNumber] as? Int ?? 0,
                                        message: error[NSAppleScript.errorMessage] as? String ?? "AppleScript error"))
        }
        return .success(result?.stringValue ?? "")
    }

    private static func script(_ source: String) -> String? {
        try? evaluate(source).get()
    }
}
