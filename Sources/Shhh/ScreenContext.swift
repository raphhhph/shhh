import AppKit
import Carbon.HIToolbox

/// What the user is working on, as text: their selection, or the text of the window in front.
/// Cheaper and more exact than a screenshot for "rewrite this", "translate this email",
/// "summarize this note". Read through the Accessibility permission Shhh already has.
///
/// Native and Electron apps expose their text this way; browsers don't (Chrome-based ones not at
/// all) and Google Docs draws its text, so there the selection is copied with ⌘C instead, and a
/// window is shown as a screenshot.
@MainActor
enum ScreenContext {
    struct Text {
        let text: String
        let app: String
        /// The app it came from, which must still be in front to paste a replacement into it.
        let pid: pid_t
    }

    private static let browsers: Set = ["com.google.Chrome", "com.vivaldi.Vivaldi", "com.brave.Browser",
                                        "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox",
                                        "com.operasoftware.Opera", "com.apple.Safari", "com.google.Chrome.canary"]
    /// Electron apps only build their accessibility tree when asked; remember which ones were.
    private static var awakened: Set<pid_t> = []

    static var frontPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// The selected text in the front app: asked for through Accessibility, or copied with ⌘C when
    /// the app doesn't say (browsers, Google Docs). The clipboard is put back afterwards.
    static func selection(limit: Int) async -> Text? {
        guard let app = NSWorkspace.shared.frontmostApplication, !IsSecureEventInputEnabled() else { return nil }
        let pid = app.processIdentifier
        let selected = await Task.detached { () -> String? in
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.5)
            guard let focused = element(ax, kAXFocusedUIElementAttribute), !isSecure(focused) else { return nil }
            return value(focused, kAXSelectedTextAttribute) as? String
        }.value
        var text = selected ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = await TextInserter.copySelection() ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Text(text: String(text.prefix(limit)), app: app.localizedName ?? "the app", pid: pid)
    }

    /// The front window's text, or nil for browsers and windows with too little text to go on.
    static func windowText(limit: Int) async -> (text: Text, title: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              !browsers.contains(app.bundleIdentifier ?? "") else { return nil }
        let pid = app.processIdentifier
        let firstTime = !awakened.contains(pid)
        awakened.insert(pid)
        let read = await Task.detached { () -> (String, String) in
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.5)
            if firstTime {
                AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            var result = readWindow(ax, limit: limit)
            if firstTime, result.0.count < 300 { // an Electron app building its tree
                try? await Task.sleep(for: .milliseconds(500))
                result = readWindow(ax, limit: limit)
            }
            return result
        }.value
        guard read.0.count >= 300 else { return nil }
        return (Text(text: read.0, app: app.localizedName ?? "the app", pid: pid), read.1)
    }

    /// Whether a request is about text the user has selected: "make this shorter", "translate
    /// it", "proofread the highlighted bit". Time words don't count: "check what's due this week".
    nonisolated static func refersToSelection(_ request: String) -> Bool {
        let verbs = "make|rewrite|re-?word|rephrase|shorten|lengthen|expand|summari[sz]e|translate|fix|correct|"
            + "proof-?read|improve|simplify|explain|check|edit|polish|format|condense|paraphrase|tighten|clean up|"
            + "turn|convert|reply to|respond to|answer|define|grade|critique|review|continue|finish|complete|mark"
        let notTime = #"(?!\s+(week|weekend|month|year|morning|afternoon|evening|semester|term|time)\b)(?!['’])"#
        let patterns = [
            #"\b(selected|highlighted|selection)\b"#,
            #"\b(\#(verbs))\b(\s+[\w'’]+){0,4}?\s+(this|that|these|it)\b\#(notTime)"#,
        ]
        return patterns.contains { request.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    // MARK: - Replacing the selection

    /// The new version Claude wrote for the selection, if any: `[REPLACE]…[/REPLACE]`.
    static func replacement(in reply: String) -> String? {
        guard let range = reply.range(of: #"\[REPLACE\]([\s\S]*?)\[/REPLACE\]"#, options: .regularExpression) else { return nil }
        let block = String(reply[range]).dropFirst("[REPLACE]".count).dropLast("[/REPLACE]".count)
        let text = block.trimmingCharacters(in: .newlines)
        return text.isEmpty ? nil : text
    }

    /// The reply as shown: the new version stays, its markers (and one still streaming in) go.
    static func display(_ reply: String) -> String {
        var text = reply.replacingOccurrences(of: #"\[/?REPLACE\]"#, with: "", options: .regularExpression)
        if let open = text.range(of: "[", options: .backwards), !text[open.lowerBound...].contains("]"),
           ["[REPLACE]", "[/REPLACE]"].contains(where: { $0.hasPrefix(text[open.lowerBound...].uppercased()) }) {
            text.removeSubrange(open.lowerBound...)
        }
        return text
    }

    /// The reply as spoken: without the new version, which is pasted rather than read out.
    static func spoken(_ reply: String) -> String {
        display(reply.replacingOccurrences(of: #"\[REPLACE\][\s\S]*?(\[/REPLACE\]|$)"#, with: "", options: .regularExpression))
    }

    // MARK: - Accessibility

    /// The window's title and its text in reading order, skipping password fields.
    private nonisolated static func readWindow(_ app: AXUIElement, limit: Int) -> (String, String) {
        guard let window = element(app, kAXFocusedWindowAttribute) ?? (value(app, kAXWindowsAttribute) as? [AXUIElement])?.first else {
            return ("", "")
        }
        var parts: [String] = []
        var total = 0
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard visited < 6000, total < limit, depth < 60 else { return }
            visited += 1
            if isSecure(element) { return }
            let role = value(element, kAXRoleAttribute) as? String ?? ""
            if [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole].contains(role),
               let text = value(element, kAXValueAttribute) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, parts.last != text {
                parts.append(text)
                total += text.count + 1
            }
            for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)
        return (String(parts.joined(separator: "\n").prefix(limit)), value(window, kAXTitleAttribute) as? String ?? "")
    }

    private nonisolated static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private nonisolated static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private nonisolated static func isSecure(_ element: AXUIElement) -> Bool {
        value(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
    }
}
