import AppKit
import ApplicationServices
import SwiftUI

/// "Let Joe click and type": the assistant works the Mac's mouse and keyboard through cliclick
/// (github.com/BlueM/cliclick, `brew install cliclick`), a tiny open-source tool that posts the
/// same events a macro app does. Shhh's Accessibility permission covers it. Claude looks first
/// (`Shhh --look`: a screenshot and the front window's buttons and fields), then clicks with
/// coordinates in that screenshot, which Shhh maps to the screen. Off unless turned on; an orange
/// bar shows while it's in control, and Esc stops it.
@MainActor
final class ScreenControl {
    static let shared = ScreenControl()

    nonisolated static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "screenControl") }
        set { UserDefaults.standard.set(newValue, forKey: "screenControl") }
    }

    nonisolated static var cliclick: String? {
        ["/opt/homebrew/bin/cliclick", "/usr/local/bin/cliclick"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What Claude runs to look: this app's own binary.
    nonisolated static var lookCommand: String {
        "\"\(Bundle.main.executablePath ?? "/Applications/Joe.app/Contents/MacOS/Joe")\" --look"
    }

    private nonisolated static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh", isDirectory: true)
    nonisolated static let lookImage = folder.appendingPathComponent("Look.jpg")
    private nonisolated static let mappingFile = folder.appendingPathComponent("Look.json")

    // MARK: - Screenshot coordinates → screen

    /// Where the last screenshot's display is (its top left, in global coordinates with y going
    /// down, as cliclick uses) and how many points one of its pixels is.
    struct Mapping: Codable {
        var x: Double
        var y: Double
        var scale: Double

        func screen(_ pixel: CGPoint) -> CGPoint {
            CGPoint(x: x + pixel.x * scale, y: y + pixel.y * scale)
        }

        func pixel(_ screen: CGPoint) -> CGPoint {
            CGPoint(x: (screen.x - x) / scale, y: (screen.y - y) / scale)
        }
    }

    /// Remembers where a screenshot came from, so clicks given in its pixels land right.
    nonisolated static func record(_ screenshot: ScreenCapture.Screenshot) {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screenshot.screenFrame.maxY
        let frame = screenshot.screenFrame
        let mapping = Mapping(x: frame.minX, y: mainHeight - frame.maxY, scale: frame.width / screenshot.pixelSize.width)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(mapping).write(to: mappingFile)
    }

    nonisolated static var mapping: Mapping {
        (try? Data(contentsOf: mappingFile)).flatMap { try? JSONDecoder().decode(Mapping.self, from: $0) }
            ?? Mapping(x: 0, y: 0, scale: 1)
    }

    // MARK: - Checking a command

    /// A cliclick command, read: its steps, with coordinates moved from screenshot pixels to the
    /// screen, and what it would do in words.
    struct Command {
        var words: [String]
        var clicks: [CGPoint] = []
        var typed: [String] = []
        var steps: [String] = []
        /// ⌘Space then typing: opening something through Spotlight, which types into the front
        /// app instead when Spotlight is slow to appear.
        var usesSpotlight = false

        var shell: String {
            words.map { word in
                word.allSatisfy { $0.isLetter || $0.isNumber || ":,.+-_/".contains($0) } ? word
                    : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
        }
    }

    /// Reads `cliclick …` (from the words of a command), or nil if it's anything else or uses
    /// something cliclick shouldn't (reading commands from a file).
    nonisolated static func parse(_ words: [String], mapped: Bool = false) -> Command? {
        guard let first = words.first, first == "cliclick" || first.hasSuffix("/cliclick"),
              let path = cliclick else { return nil }
        // Already in screen coordinates (a command Shhh has mapped): left as they are.
        let mapping = mapped ? Mapping(x: 0, y: 0, scale: 1) : Self.mapping
        var command = Command(words: [path])
        var holdingCommand = false
        var rest = words.dropFirst()
        while let word = rest.popFirst() {
            if word == "-r" { command.words.append(word); continue }
            if ["-e", "-w"].contains(word), let value = rest.popFirst(), Int(value) != nil {
                command.words += [word, value]
                continue
            }
            guard let colon = word.firstIndex(of: ":") else { return nil }
            let name = String(word[..<colon])
            let value = String(word[word.index(after: colon)...])
            switch name {
            case "c", "dc", "rc", "tc", "m", "dd", "du", "dm":
                let parts = value.split(separator: ",").map(String.init)
                guard parts.count == 2 else { return nil }
                if let x = Double(parts[0]), let y = Double(parts[1]), !parts[0].hasPrefix("+"), !parts[0].hasPrefix("-") {
                    let point = mapping.screen(CGPoint(x: x, y: y))
                    command.words.append("\(name):\(Int(point.x.rounded())),\(Int(point.y.rounded()))")
                    if name != "m", name != "dm" { command.clicks.append(point) }
                } else {
                    command.words.append(word) // relative ("+10,0") or where the mouse is (".")
                }
                let verb = ["c": "Click", "dc": "Double-click", "rc": "Right-click", "tc": "Triple-click",
                            "m": "Move the mouse", "dd": "Start dragging", "du": "Drop", "dm": "Drag"][name]!
                command.steps.append("\(verb) at \(value)")
            case "t":
                command.words.append(word)
                command.typed.append(value)
                command.steps.append("Type “\(value)”")
            case "kp", "kd", "ku":
                if name == "kd", value.split(separator: ",").contains("cmd") { holdingCommand = true }
                if name == "ku", value.split(separator: ",").contains("cmd") { holdingCommand = false }
                if name == "kp", value == "space", holdingCommand { command.usesSpotlight = true }
                command.words.append(word)
                command.steps.append(name == "kp" ? "Press \(value)" : name == "kd" ? "Hold \(value)" : "Release \(value)")
            case "w", "p":
                command.words.append(word)
            default:
                return nil
            }
        }
        return command
    }

    /// A command made only of cliclick steps and looks, chained with && ("cliclick … && Shhh
    /// --look"): its clicks and typing together, and the command to run (coordinates mapped).
    /// Nil if any part is something else.
    nonisolated static func parseChain(_ text: String, mapped: Bool = false) -> (command: Command?, shell: String)? {
        var combined: Command?
        var parts: [String] = []
        for segment in text.components(separatedBy: "&&") {
            guard let words = ToolPolicy.shellWords(segment.trimmingCharacters(in: .whitespacesAndNewlines)), !words.isEmpty
            else { return nil }
            if words.count == 2, words[0] == Bundle.main.executablePath, words[1] == "--look" {
                parts.append(lookCommand)
            } else if let command = parse(words, mapped: mapped) {
                parts.append(command.shell)
                if var all = combined {
                    all.clicks += command.clicks
                    all.typed += command.typed
                    all.steps += command.steps
                    combined = all
                } else {
                    combined = command
                }
            } else {
                return nil
            }
        }
        return (combined, parts.joined(separator: " && "))
    }

    /// Apps where clicking and typing could do real damage: a terminal runs whatever's typed into
    /// it, and System Settings and the password apps hold the keys to everything.
    private nonisolated static let terminals: Set = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
                                         "com.mitchellh.ghostty", "io.alacritty"]
    /// Password apps: off limits.
    private nonisolated static let passwordApps: Set = ["com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
                                            "com.agilebits.onepassword7", "com.bitwarden.desktop"]
    /// System Settings is fine to use (wallpaper, displays, the Dock…), except the panes where
    /// passwords, permissions and security live: those are off limits.
    private nonisolated static let settings: Set = ["com.apple.systempreferences", "com.apple.Settings"]
    private nonisolated static let blockedPanes = #"privacy|security|touch id|password|users|groups|login items|lock screen|apple account|icloud|internet accounts|wallet|profiles|sharing|general.*(transfer|reset)"#

    enum Verdict { case allow, ask(String), block(String) }

    /// What a command needs: fine, the user's OK first, or never.
    nonisolated static func judge(_ command: Command, typedMoney: Bool, typedSend: Bool) -> Verdict {
        let apps = Set(([NSWorkspace.shared.frontmostApplication?.bundleIdentifier] + command.clicks.map(app(at:))).compactMap { $0 })
        if !command.typed.isEmpty, !apps.isDisjoint(with: terminals) {
            return .block("Joe doesn't let you type into a terminal. Use Bash for commands, or ask the user to.")
        }
        if command.usesSpotlight {
            return .block("Don't open things through Spotlight: the typing can land in the app in front. To open an app, run open -a \"Name\" in Bash.")
        }
        if !command.typed.isEmpty, focusIsSecure() {
            return .block("That's a password field: Joe never types passwords. Ask the user to type it.")
        }
        if typedMoney {
            return .block("Joe blocks anything that spends money. Tell the user to do it themselves.")
        }
        if !apps.isDisjoint(with: settings) {
            let blocked = { (text: String) in text.range(of: blockedPanes, options: [.regularExpression, .caseInsensitive]) != nil }
            let pane = settingsPane() ?? ""
            if let place = blocked(pane) ? pane : command.typed.first(where: blocked) {
                return .block("Joe keeps you out of \(place) in System Settings: passwords, permissions and security are the user's to change. Tell them where it is instead.")
            }
        }
        if !apps.isDisjoint(with: passwordApps) {
            return .block("Joe keeps you out of password apps. Tell the user where to look instead.")
        }
        if typedSend { return .ask("Click and type: this may send or submit something") }
        return .allow
    }

    /// The app whose window is at a point on screen (global coordinates, y going down).
    private nonisolated static func app(at point: CGPoint) -> String? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        return nil
    }

    /// The pane System Settings is showing ("Wallpaper"), from its window's title.
    private nonisolated static func settingsPane() -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
        else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success,
              let window = (windows as? [AXUIElement])?.first else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    private nonisolated static func focusIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return false }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == kAXSecureTextFieldSubrole as String
    }

    // MARK: - While in control

    private var bar: NSPanel?
    private var ripples: NSPanel?
    private var escape: Any?
    private var stop: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    /// Claude is about to act: the bar shows, the clicks flash, and Esc stops it.
    func acting(_ command: Command, stop: @escaping () -> Void) {
        self.stop = stop
        showBar()
        flash(command.clicks)
        if escape == nil {
            escape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return } // Esc
                MainActor.assumeIsolated { ScreenControl.shared.stopNow() }
            }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { ScreenControl.shared.ended() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    /// The turn is over (or was stopped).
    func ended() {
        hideWork?.cancel()
        bar?.orderOut(nil)
        bar = nil
        stop = nil
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
    }

    private func stopNow() {
        let stop = self.stop
        ended()
        stop?()
    }

    private func showBar() {
        guard bar == nil, let screen = NSScreen.screens.first else { return }
        let notch = Notch.rect(on: screen)
        let size = NSSize(width: 300, height: 30)
        let panel = NSPanel(contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: notch.minY - size.height - 6,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .aboveResting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ControlBar(name: Assistant.name == "Assistant" ? "Claude" : Assistant.name))
        panel.orderFrontRegardless()
        bar = panel
    }

    /// A ring where each click is about to land.
    private func flash(_ clicks: [CGPoint]) {
        guard !clicks.isEmpty, let main = NSScreen.screens.first else { return }
        ripples?.orderOut(nil)
        let frame = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .aboveResting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Global (y down from the main screen's top) → this window's own coordinates (y down from its top).
        let points = clicks.map { CGPoint(x: $0.x - frame.minX, y: $0.y - (main.frame.maxY - frame.maxY)) }
        panel.contentView = NSHostingView(rootView: Ripples(points: points).frame(width: frame.width, height: frame.height))
        panel.orderFrontRegardless()
        ripples = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            MainActor.assumeIsolated { if ScreenControl.shared.ripples === panel { panel.orderOut(nil) } }
        }
    }

    // MARK: - Looking (`Shhh --look`)

    /// Takes a screenshot of the screen under the mouse for Claude to read, remembers where it
    /// came from, and lists the front window's buttons and fields with their centres in it.
    /// `look()` for code that can't wait asynchronously (the messaging tool, a command-line run).
    nonisolated static func lookSync() -> String {
        let done = DispatchSemaphore(value: 0)
        var result = "(no screenshot)"
        Task.detached {
            result = await look()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 12)
        return result
    }

    nonisolated static func look() async -> String {
        guard let shot = await ScreenCapture.capture() else {
            return "Couldn't take a screenshot: Joe needs Screen Recording access in System Settings."
        }
        record(shot)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.jpeg.write(to: lookImage)
        var lines = ["Screenshot: \(lookImage.path) (\(Int(shot.pixelSize.width))×\(Int(shot.pixelSize.height)) px). Read it to see the screen; give clicks in its pixels."]
        if let cursor = shot.cursor { lines.append("Mouse at \(Int(cursor.x)),\(Int(cursor.y)).") }
        if let app = NSWorkspace.shared.frontmostApplication {
            let elements = Self.elements(of: app, mapping: mapping, size: shot.pixelSize)
            lines.append("Front app: \(app.localizedName ?? "?")" + (elements.window.map { ", window “\($0)”" } ?? ""))
            if !elements.list.isEmpty {
                lines.append("Its controls (centre x,y in the screenshot):")
                lines += elements.list
            }
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static let roles: [String: String] = [
        "AXButton": "button", "AXTextField": "text field", "AXTextArea": "text area", "AXCheckBox": "checkbox",
        "AXRadioButton": "radio", "AXPopUpButton": "pop-up", "AXMenuButton": "menu button", "AXLink": "link",
        "AXComboBox": "combo box", "AXSearchField": "search field", "AXTab": "tab", "AXSlider": "slider",
        "AXDisclosureTriangle": "disclosure", "AXRow": "row", "AXCell": "cell", "AXImage": "icon", "AXStaticText": "text",
    ]

    private nonisolated static func elements(of app: NSRunningApplication, mapping: Mapping, size: CGSize) -> (window: String?, list: [String]) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
        }
        guard let window = value(root, kAXFocusedWindowAttribute) else { return (nil, []) }
        let windowElement = window as! AXUIElement
        var list: [String] = []
        var queue = [windowElement]
        var visited = 0
        let deadline = Date().addingTimeInterval(0.8)
        while !queue.isEmpty, visited < 4000, list.count < 90, Date() < deadline {
            let element = queue.removeFirst()
            visited += 1
            if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { queue += children }
            guard let role = value(element, kAXRoleAttribute) as? String, let kind = roles[role] else { continue }
            let name = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
                .lazy.compactMap { value(element, $0) as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            guard name != nil || kind.contains("field") || kind == "text area" else { continue }
            if kind == "text" || kind == "row" || kind == "cell" || kind == "icon", name == nil { continue }
            var position = CGPoint.zero, extent = CGSize.zero
            guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
                  AXValueGetValue(p as! AXValue, .cgPoint, &position), AXValueGetValue(s as! AXValue, .cgSize, &extent),
                  extent.width > 2, extent.height > 2 else { continue }
            let centre = mapping.pixel(CGPoint(x: position.x + extent.width / 2, y: position.y + extent.height / 2))
            guard centre.x >= 0, centre.y >= 0, centre.x < size.width, centre.y < size.height else { continue }
            let label = name.map { " “\($0.count > 50 ? $0.prefix(50) + "…" : $0)”" } ?? ""
            list.append("- \(kind)\(label) \(Int(centre.x)),\(Int(centre.y))")
        }
        return ((value(windowElement, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }, list)
    }
}

private struct ControlBar: View {
    let name: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.orange).frame(width: 7, height: 7).opacity(pulse ? 1 : 0.35)
            Text("\(name) is controlling your Mac").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            Text("Esc to stop").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.7), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

private struct Ripples: View {
    let points: [CGPoint]
    @State private var grown = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                Circle()
                    .strokeBorder(Color.orange, lineWidth: 2.5)
                    .frame(width: 34, height: 34)
                    .scaleEffect(grown ? 1.3 : 0.5)
                    .opacity(grown ? 0 : 1)
                    .position(point)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { withAnimation(.easeOut(duration: 0.8)) { grown = true } }
    }
}
