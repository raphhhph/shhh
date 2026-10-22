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

    /// Every tab of every running Chromium browser.
    private static func tabs() -> [Tab] {
        var all: [Tab] = []
        for browser in chromium where !NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).isEmpty {
            let source = """
                set out to ""
                tell application "\(browser.name)"
                    repeat with w from 1 to count of windows
                        repeat with t from 1 to count of tabs of window w
                            set out to out & w & tab & t & tab & (title of tab t of window w) & tab & (URL of tab t of window w) & linefeed
                        end repeat
                    end repeat
                end tell
                return out
                """
            for line in (script(source) ?? "").split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4, let w = Int(parts[0]), let t = Int(parts[1]) else { continue }
                all.append(Tab(browser: browser.name, window: w, index: t, title: parts[2], url: parts[3]))
            }
        }
        return all
    }

    private static func list() -> String {
        let all = tabs()
        guard !all.isEmpty else { return "No open tabs in Vivaldi, Chrome, Brave, Edge or Arc (Safari isn't read)." }
        return all.prefix(80).map { "\($0.browser) · \($0.title) · \($0.url)" }.joined(separator: "\n")
    }

    /// Tabs whose title or address has every word.
    private static func matching(_ words: String) -> [Tab] {
        let keys = words.lowercased().split(separator: " ").map(String.init)
        return tabs().filter { tab in keys.allSatisfy { (tab.title + " " + tab.url).lowercased().contains($0) } }
    }

    private static func find(_ words: String) -> String {
        let found = matching(words)
        return found.isEmpty ? "No open tab matches “\(words)”."
            : found.prefix(20).map { "\($0.browser) · \($0.title) · \($0.url)" }.joined(separator: "\n")
    }

    /// Makes the matching tab the current one in its window, without bringing the browser forward.
    private static func show(_ words: String) -> String {
        let found = matching(words)
        guard let tab = found.first else { return "No open tab matches “\(words)”." }
        guard script("tell application \"\(tab.browser)\" to set active tab index of window \(tab.window) to \(tab.index)") != nil else {
            return "\(tab.browser) didn't switch tabs."
        }
        return "“\(tab.title)” is now the current tab in \(tab.browser)\(found.count > 1 ? " (\(found.count - 1) other tabs also matched)" : "")."
    }

    private static func script(_ source: String) -> String? {
        if !Thread.isMainThread { return DispatchQueue.main.sync { script(source) } }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? (result?.stringValue ?? "") : nil
    }
}
