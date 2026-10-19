import AppKit
import Vision

/// Messages in WhatsApp and WeChat, through their Mac apps:
///
///     Joe --message send whatsapp|wechat "<chat>" "<text>"    opens the chat, checks it, sends
///     Joe --message draft whatsapp|wechat "<chat>" "<text>"   the same, but leaves the text unsent
///
/// Sending asks the user first, on a card showing who and what; after that it's one step, with no
/// screenshot for the assistant to read (that round trip made sending slow). The chat is found the
/// way a person does (⌘F, the name, Return), and then confirmed by reading the name at the top of
/// the chat with on-device text recognition (WeChat shows nothing to accessibility). If it can't
/// be confirmed, nothing is typed and the assistant gets a screenshot to sort it out.
enum Messaging {
    enum App: String {
        case whatsapp, wechat
        var bundleID: String { self == .whatsapp ? "net.whatsapp.WhatsApp" : "com.tencent.xinWeChat" }
        var name: String { self == .whatsapp ? "WhatsApp" : "WeChat" }
    }

    static func run(_ arguments: [String]) async -> String {
        var arguments = arguments
        if arguments.first == "open", arguments.count == 3 { arguments.append("") }
        guard arguments.count >= 4, let app = App(rawValue: arguments[1].lowercased()) else {
            return "Use: --message send|draft whatsapp|wechat \"<chat>\" \"<text>\""
        }
        let start = Date()
        let chat = arguments[2], text = arguments[3]
        if let problem = await open(app, chat: chat) { return problem }
        if arguments[0] == "open" { return "Opened “\(chat)” in \(app.name) (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)." }
        paste(text)
        Thread.sleep(forTimeInterval: 0.25)
        guard isFront(app) else { return "\(app.name) lost focus, so the message wasn't sent (it may be typed in the box)." }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
        if arguments[0] == "draft" { return "Drafted in \(app.name) to “\(chat)”, not sent (\(seconds) s)." }
        press(36) // Return: send
        return "Sent in \(app.name) to “\(chat)” (\(seconds) s)."
    }

    /// Opens the chat and confirms it's the right one. Returns what went wrong, or nil.
    ///
    /// Return is only pressed once the name is seen in the search box: if the search didn't get
    /// the keyboard (WeChat's ⌘F sometimes doesn't), the name would be in the open chat's message
    /// box, and Return would send it there.
    private static func open(_ app: App, chat: String) async -> String? {
        guard bringToFront(app) else { return "\(app.name) didn't open (is it installed and signed in?)." }
        press(53) // Esc: out of whatever was open
        Thread.sleep(forTimeInterval: 0.15)
        if app == .wechat, let window = windowFrame(app) {
            click(CGPoint(x: window.minX + 187, y: window.minY + 31)) // its search box, above the chat list
        } else {
            press(3, flags: .maskCommand) // ⌘F
        }
        Thread.sleep(forTimeInterval: 0.3)
        guard isFront(app) else { return "\(app.name) lost focus, so nothing was typed." }
        press(0, flags: .maskCommand) // ⌘A: clear an old search
        paste(chat)
        Thread.sleep(forTimeInterval: 0.9) // results load
        guard isFront(app) else { return "\(app.name) lost focus, so nothing was sent." }
        if ProcessInfo.processInfo.environment["JOE_SEARCH_ONLY"] != nil { return await ScreenControl.look() }
        guard matches(await header(app).search, chat) else {
            press(6, flags: .maskCommand) // ⌘Z: take the name back out of wherever it went
            return "\(app.name)'s search didn't take the name, so nothing was sent (the name was typed and taken back out). Try again."
        }
        press(36) // Return: the first match
        // The chat's name in its title, and gone from the search box (whose results can cover the
        // title while they're open).
        var seen = (title: "", search: "")
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.25)
            seen = await header(app)
            if matches(seen.title, chat), !matches(seen.search, chat) { return nil }
        }
        let look = await ScreenControl.look()
        return """
            Couldn't confirm the open chat is “\(chat)” (its title reads “\(seen.title)”), so nothing was typed or \
            sent. Check the screenshot: if it is the right chat, run --message draft and tell them to press \
            Return; if not, try the name as it appears in \(app.name)'s chat list.
            \(look)
            """
    }

    /// A click at a point on the screen (from the top left), putting the pointer back after.
    private static func click(_ point: CGPoint) {
        let back = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
        }
        if let back { CGWarpMouseCursorPosition(back) }
    }

    // MARK: - Reading the chat's title

    /// The text along the top of the window, read off the screen: the chat's title (right of the
    /// chat list) and the search box (above it).
    private static func header(_ app: App) async -> (title: String, search: String) {
        guard let shot = await ScreenCapture.capture(), let window = windowFrame(app) else { return ("", "") }
        let scale = shot.pixelSize.width / shot.screenFrame.width
        let primaryHeight = NSScreen.screens.first?.frame.height ?? shot.screenFrame.maxY
        let screenTop = primaryHeight - shot.screenFrame.maxY // the display's top edge, from the top
        let band: CGFloat = min(64, window.height)
        let rect = CGRect(x: (window.minX - shot.screenFrame.minX) * scale, y: (window.minY - screenTop) * scale,
                          width: window.width * scale, height: band * scale)
            .intersection(CGRect(origin: .zero, size: shot.pixelSize))
        guard !rect.isEmpty, let crop = shot.image.cropping(to: rect) else { return ("", "") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: crop).perform([request])
        // The chat list is about 340 points wide (with the icon bar); the title starts after it.
        let listEdge = min(340, window.width * 0.6) / window.width
        var title: [String] = [], search: [String] = []
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            if observation.boundingBox.minX >= listEdge { title.append(text) } else { search.append(text) }
        }
        return (title.joined(separator: " | "), search.joined(separator: " | "))
    }

    /// The app's main window, in screen points from the top left.
    private static func windowFrame(_ app: App) -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Whether the title read off the screen is the chat: the same letters (any language), allowing
    /// a slip or two of the text recognition, or a count after the name ("Family (12)").
    static func matches(_ title: String, _ chat: String) -> Bool {
        let key = normalize(chat)
        guard !key.isEmpty else { return !title.isEmpty } // a name of only emoji: the card already showed it
        return title.components(separatedBy: " | ").contains { line in
            let seen = normalize(line)
            guard seen.count >= min(2, key.count) else { return false }
            if seen.contains(key) || (key.contains(seen) && seen.count * 3 >= key.count * 2) { return true }
            return key.count >= 5 && distance(seen, key) <= key.count / 5
        }
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - Keyboard and apps

    private static func bringToFront(_ app: App) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { return false }
        let opened = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in opened.signal() }
        _ = opened.wait(timeout: .now() + 8)
        for _ in 0..<40 {
            if isFront(app) { Thread.sleep(forTimeInterval: 0.4); return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    private static func isFront(_ app: App) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.bundleID
    }

    /// Pastes text through the clipboard (any language, emoji), then puts the clipboard back.
    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        press(9, flags: .maskCommand) // ⌘V
        Thread.sleep(forTimeInterval: 0.3)
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
    }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}
