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
        case "read" where arguments.count >= 2: return read(arguments[1])
        case "fill" where arguments.count >= 4: return fill(arguments[1], arguments[2], arguments[3...].joined(separator: " "))
        case "click" where arguments.count >= 3: return click(arguments[1], arguments[2])
        default: return "Use: --tab open <url>… | list | find \"<words>\" | show \"<words>\" | read \"<words>\" | fill \"<words>\" <uid> \"<text>\" | click \"<words>\" <uid>"
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

    // MARK: Working in a tab they have open

    /// The tab to work in: "front" is the current tab of the front window; otherwise the first tab
    /// whose title or address has every word.
    private static func target(_ words: String) -> Result<Tab, ScriptError> {
        if words.lowercased() == "front" {
            for browser in chromium where !NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).isEmpty {
                if let index = script("tell application \"\(browser.name)\" to get active tab index of window 1").flatMap({ Int($0) }) {
                    return .success(Tab(browser: browser.name, window: 1, index: index, title: "", url: ""))
                }
            }
            return .failure(ScriptError(code: 0, message: "No Vivaldi, Chrome, Brave, Edge or Arc window is open."))
        }
        let (found, failures) = matching(words)
        guard let tab = found.first else {
            return .failure(ScriptError(code: 0, message: (["No open tab matches “\(words)”."] + failures).joined(separator: "\n")))
        }
        return .success(tab)
    }

    /// Runs JavaScript in a tab, without bringing it forward. The browser has to allow it once
    /// (Vivaldi: Tools > Allow JavaScript from Apple Events; Chrome: View > Developer); if it
    /// doesn't, this turns the setting on through the menu and tries again.
    private static func javascript(_ code: String, in tab: Tab) -> Result<String, ScriptError> {
        // One line (the code has no // comments), quoted for AppleScript.
        let escaped = code.split(separator: "\n").joined(separator: " ").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"\(tab.browser)\" to execute tab \(tab.index) of window \(tab.window) javascript \"\(escaped)\""
        let result = evaluate(source)
        if case .failure(let error) = result, error.message.lowercased().contains("javascript through applescript is turned off") {
            guard allowJavaScript(in: tab.browser) else {
                return .failure(ScriptError(code: 0, message: "\(tab.browser) doesn't let apps run JavaScript yet. Turn on \(tab.browser == "Vivaldi" ? "Tools > Allow JavaScript from Apple Events" : "View > Developer > Allow JavaScript from Apple Events") once, then try again."))
            }
            return evaluate(source)
        }
        return result
    }

    /// Ticks "Allow JavaScript from Apple Events" in the browser's menus (it's only clicked when
    /// it's off, so it never turns it off).
    private static func allowJavaScript(in browser: String) -> Bool {
        let menus = browser == "Vivaldi" ? ["menu \"Tools\" of menu bar item \"Tools\"", "menu \"Developer\" of menu item \"Developer\" of menu \"View\" of menu bar item \"View\""]
            : ["menu \"Developer\" of menu item \"Developer\" of menu \"View\" of menu bar item \"View\""]
        for menu in menus {
            let source = """
                tell application "System Events" to tell process "\(browser)"
                    click menu item "Allow JavaScript from Apple Events" of \(menu) of menu bar 1
                end tell
                """
            if script(source) != nil { return true }
        }
        return false
    }

    /// The page's text and every visible field, button and link, each tagged with a uid for fill
    /// and click (`uid=t12 button "Add Entry"`). The page's own text is quoted line by line ("| "),
    /// so nothing on the page can pass itself off as an element.
    private static func read(_ words: String) -> String {
        let tab: Tab
        switch target(words) {
        case .success(let found): tab = found
        case .failure(let error): return error.message
        }
        let code = """
            (function () {
              var docs = [document];
              document.querySelectorAll('iframe').forEach(function (f) { try { if (f.contentDocument) docs.push(f.contentDocument); } catch (e) {} });
              var next = window.__joeNext || 1, out = [];
              var pick = 'input:not([type=hidden]), textarea, select, button, a[href], [contenteditable=""], [contenteditable=true], [role=button], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=option], [role=textbox]';
              docs.forEach(function (doc) {
                if (doc !== document && doc.body && (doc.body.isContentEditable || doc.designMode === 'on')) doc.body.setAttribute('contenteditable', 'true');
                doc.querySelectorAll(pick).forEach(function (el) {
                  if (out.length >= 150) return;
                  var r = el.getBoundingClientRect();
                  if ((r.width === 0 && r.height === 0) || el.disabled) return;
                  if (el.isContentEditable && el.parentElement && el.parentElement.isContentEditable) return;
                  var id = el.getAttribute('data-joe');
                  if (!id) { id = 't' + (next++); el.setAttribute('data-joe', id); }
                  var tag = el.tagName.toLowerCase(), type = (el.getAttribute('type') || '').toLowerCase();
                  var role = el.isContentEditable ? 'editor' : tag === 'a' ? 'link' : tag === 'select' ? 'select' : tag === 'textarea' ? 'textbox'
                    : tag === 'input' ? (['checkbox', 'radio'].indexOf(type) >= 0 ? type : ['submit', 'button'].indexOf(type) >= 0 ? 'button' : 'textbox')
                    : (el.getAttribute('role') || 'button');
                  var label = el.getAttribute('aria-label') || '';
                  if (!label && el.labels && el.labels.length) label = el.labels[0].innerText;
                  if (!label && (role === 'checkbox' || role === 'radio') && el.parentElement) label = el.parentElement.innerText;
                  if (!label && role !== 'editor' && role !== 'textbox') label = el.innerText || el.value || '';
                  if (!label) label = el.getAttribute('placeholder') || el.getAttribute('data-placeholder') || el.getAttribute('title') || el.getAttribute('name') || '';
                  label = label.replace(/\\s+/g, ' ').replace(/"/g, "'").trim().slice(0, 80);
                  var state = (role === 'checkbox' || role === 'radio') ? (el.checked || el.getAttribute('aria-checked') === 'true' ? ' (checked)' : ' (unchecked)')
                    : (role === 'textbox' && el.value) ? ' value: ' + el.value.slice(0, 60).replace(/\\s+/g, ' ') : '';
                  out.push('uid=' + id + ' ' + role + ' "' + label + '"' + state);
                });
              });
              window.__joeNext = next;
              var text = (document.body ? document.body.innerText : '').split('\\n').map(function (l) { return l.trim(); }).filter(Boolean).join('\\n').slice(0, 6000);
              return document.title + ' · ' + location.href + (document.readyState === 'complete' ? '' : ' (still loading)') +
                '\\n\\nElements:\\n' + out.join('\\n') + '\\n\\nPage text:\\n' + text.split('\\n').map(function (l) { return '| ' + l; }).join('\\n');
            })()
            """
        switch javascript(code, in: tab) {
        case .success(let text): return text.isEmpty ? "The page didn't answer (it may still be loading)." : text
        case .failure(let error): return error.message
        }
    }

    /// Types into a field or editor, the way typing would (so the page's own code notices).
    private static func fill(_ words: String, _ uid: String, _ text: String) -> String {
        let tab: Tab
        switch target(words) {
        case .success(let found): tab = found
        case .failure(let error): return error.message
        }
        let value = (try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let code = """
            (function () {
              var text = \(value), el = null;
              [document].concat(Array.prototype.map.call(document.querySelectorAll('iframe'), function (f) { try { return f.contentDocument; } catch (e) { return null; } }))
                .forEach(function (doc) { if (!el && doc) el = doc.querySelector('[data-joe="\(uid.filter { $0.isLetter || $0.isNumber })"]'); });
              if (!el) return 'No element \(uid.filter { $0.isLetter || $0.isNumber }) on the page any more: read it again.';
              el.scrollIntoView({ block: 'center' });
              el.focus();
              var tag = el.tagName.toLowerCase();
              if (tag === 'select') {
                var option = Array.prototype.find.call(el.options, function (o) { return o.text.trim().toLowerCase() === text.trim().toLowerCase() || o.value === text; });
                if (!option) return 'No option "' + text + '" in that list.';
                el.value = option.value;
              } else if (tag === 'input' || tag === 'textarea') {
                var setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value').set;
                setter.call(el, text);
              } else if (el.isContentEditable) {
                var doc = el.ownerDocument;
                doc.execCommand('selectAll', false, null);
                text.split('\\n').forEach(function (line, i) { if (i) doc.execCommand('insertParagraph', false, null); if (line) doc.execCommand('insertText', false, line); });
                if (el.innerText.trim().length === 0 && text.trim().length) el.innerText = text;
              } else {
                return 'That element is a ' + tag + ', not a field: use click.';
              }
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return 'Filled.';
            })()
            """
        switch javascript(code, in: tab) {
        case .success(let result): return result
        case .failure(let error): return error.message
        }
    }

    /// Clicks a button, link or checkbox in the tab, without bringing it forward.
    private static func click(_ words: String, _ uid: String) -> String {
        let tab: Tab
        switch target(words) {
        case .success(let found): tab = found
        case .failure(let error): return error.message
        }
        let id = uid.filter { $0.isLetter || $0.isNumber }
        let code = """
            (function () {
              var el = null;
              [document].concat(Array.prototype.map.call(document.querySelectorAll('iframe'), function (f) { try { return f.contentDocument; } catch (e) { return null; } }))
                .forEach(function (doc) { if (!el && doc) el = doc.querySelector('[data-joe="\(id)"]'); });
              if (!el) return 'No element \(id) on the page any more: read it again.';
              el.scrollIntoView({ block: 'center' });
              el.click();
              return 'Clicked.';
            })()
            """
        switch javascript(code, in: tab) {
        case .success(let result): return result + " Read the page again to see what changed."
        case .failure(let error): return error.message
        }
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
