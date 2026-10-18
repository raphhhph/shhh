import AppKit

/// Messages in WhatsApp and WeChat, through their Mac apps, in two steps so nothing goes out by
/// mistake:
///
///     Joe --message draft whatsapp|wechat "<chat>" "<text>"   opens the chat and types the text, unsent
///     Joe --message send whatsapp|wechat "<chat>" "<text>"    presses Return (only after the user's OK)
///
/// The draft step searches for the chat the way a person does (⌘F, the name, Return) and pastes
/// the text (so Chinese and emoji survive), then takes a screenshot for the assistant to check
/// it's the right chat. Sending always asks first, on a card showing who and what.
enum Messaging {
    enum App: String {
        case whatsapp, wechat
        var bundleID: String { self == .whatsapp ? "net.whatsapp.WhatsApp" : "com.tencent.xinWeChat" }
        var name: String { self == .whatsapp ? "WhatsApp" : "WeChat" }
    }

    static func run(_ arguments: [String]) async -> String {
        guard arguments.count >= 4, let app = App(rawValue: arguments[1].lowercased()) else {
            return "Use: --message draft|send whatsapp|wechat \"<chat>\" \"<text>\""
        }
        switch arguments[0] {
        case "draft": return await draft(app, chat: arguments[2], text: arguments[3])
        case "send": return send(app, chat: arguments[2])
        default: return "Use draft first, then send."
        }
    }

    private static func draft(_ app: App, chat: String, text: String) async -> String {
        guard bringToFront(app) else { return "\(app.name) didn't open (is it installed and signed in?)." }
        press(53) // Esc: out of whatever was open
        Thread.sleep(forTimeInterval: 0.2)
        press(3, flags: .maskCommand) // ⌘F: search the chats
        Thread.sleep(forTimeInterval: 0.5)
        guard isFront(app) else { return "\(app.name) lost focus, so nothing was typed." }
        press(0, flags: .maskCommand) // ⌘A: clear an old search
        paste(chat)
        Thread.sleep(forTimeInterval: 1.4) // results load
        guard isFront(app) else { return "\(app.name) lost focus, so nothing was typed." }
        press(36) // Return: the first match
        Thread.sleep(forTimeInterval: 1.0)
        guard isFront(app) else { return "\(app.name) lost focus, so nothing was typed." }
        paste(text)
        Thread.sleep(forTimeInterval: 0.4)
        let look = await ScreenControl.look()
        return """
            Drafted in \(app.name), not sent. Check the screenshot: the open chat must be “\(chat)” and the \
            message box must hold the text. If it's the wrong chat, clear the box (⌘A, Delete) and say so; \
            if it's right, send it with --message send \(app.rawValue) "\(chat)" "<the same text>".
            \(look)
            """
    }

    private static func send(_ app: App, chat: String) -> String {
        guard bringToFront(app) else { return "\(app.name) isn't open." }
        Thread.sleep(forTimeInterval: 0.3)
        guard isFront(app) else { return "\(app.name) lost focus, so nothing was sent." }
        press(36) // Return: send
        return "Sent in \(app.name) to “\(chat)”."
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
