import AppKit

/// `Shhh --workspace "<name>"`: switches Vivaldi to one of its workspaces, for routines like
/// "let's get to work". Vivaldi has no command for it, so this brings Vivaldi to the front, opens
/// its Quick Commands (⌘E), types the workspace's name and presses Return, checking before each
/// keystroke that Vivaldi is still the app in front, so nothing is ever typed into another app.
enum Workspace {
    private static let vivaldi = "com.vivaldi.Vivaldi"

    /// The workspaces Vivaldi has, from its settings.
    static var names: [String] {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vivaldi/Default/Preferences")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = ((json["vivaldi"] as? [String: Any])?["workspaces"] as? [String: Any])?["list"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["name"] as? String }
    }

    static func switchTo(_ wanted: String) -> String {
        let all = names
        guard let name = all.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame })
            ?? all.first(where: { $0.lowercased().contains(wanted.lowercased()) }) else {
            return "Vivaldi has no workspace called “\(wanted)”. It has: \(all.joined(separator: ", "))."
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vivaldi) else { return "Vivaldi isn't installed." }
        bringToFront(url)
        guard waitForFront(seconds: 4),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: vivaldi).first else {
            return "Vivaldi didn't come to the front."
        }
        // As a person would: click the Workspaces button, then the workspace in its list. Vivaldi
        // ignores its menus' Activate and its ⌃⇧N shortcuts when they come from a program, but not clicks.
        Thread.sleep(forTimeInterval: 0.2)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let button = find(in: root, where: { role, title in role == "AXPopUpButton" && title == "Workspaces" }) else {
            return "Couldn't find Vivaldi's Workspaces button (is the tab bar showing?)."
        }
        let mouse = CGEvent(source: nil)?.location
        defer { if let mouse { CGWarpMouseCursorPosition(mouse) } } // the pointer goes back where it was
        guard isFront, click(button) else { return "Vivaldi lost focus, so nothing was clicked." }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            if let item = find(in: root, where: { role, title in role == "AXButton" && title.hasPrefix(name) }) {
                guard isFront, click(item) else { return "Vivaldi lost focus, so nothing was clicked." }
                return "Switched Vivaldi to the “\(name)” workspace."
            }
        }
        press(53) // Esc: close the list
        return "Opened Vivaldi's workspace list but couldn't find “\(name)” in it."
    }

    /// A real click in the middle of an element.
    private static func click(_ element: AXUIElement) -> Bool {
        var position: CFTypeRef?, size: CFTypeRef?
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return false }
        let centre = CGPoint(x: point.x + extent.width / 2, y: point.y + extent.height / 2)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: centre, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        return true
    }

    /// `Shhh --workspace-reset`: closes every tab in the workspace Vivaldi is showing, leaving one
    /// new tab: a new tab (⌘T), then Vivaldi's own "Close Other Tabs" on it, which stays within
    /// the workspace. Closed tabs come back with ⌘⇧T.
    static func reset() -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: vivaldi).first,
              let url = app.bundleURL else {
            return "Vivaldi isn't open."
        }
        bringToFront(url)
        guard waitForFront(seconds: 3) else { return "Vivaldi didn't come to the front." }
        Thread.sleep(forTimeInterval: 0.2)
        guard isFront else { return "Vivaldi lost focus, so nothing was done." }
        press(17, flags: .maskCommand) // ⌘T: the tab that stays
        Thread.sleep(forTimeInterval: 0.5)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        func selected(_ element: AXUIElement) -> Bool {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            return (value as? NSNumber)?.boolValue == true
        }
        guard let tab = find(in: root, where: { role, _ in role == "AXRadioButton" }, also: selected) else {
            return "Opened a new tab but couldn't find it in the tab bar, so nothing was closed."
        }
        AXUIElementPerformAction(tab, kAXShowMenuAction as CFString)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            if let item = find(in: root, where: { _, title in title == "Close Other Tabs" }) {
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                return "Cleared the workspace: one new tab left. ⌘⇧T brings closed tabs back."
            }
        }
        press(53) // Esc: close the menu
        return "Couldn't find “Close Other Tabs” in the tab's menu, so nothing was closed."
    }

    /// The first element (breadth first, within reason) whose role and title match.
    private static func find(in root: AXUIElement, where matches: (String, String) -> Bool,
                             also: (AXUIElement) -> Bool = { _ in true }) -> AXUIElement? {
        func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
        }
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
        var queue = (windows as? [AXUIElement]) ?? [root]
        var visited = 0
        while !queue.isEmpty, visited < 6000 {
            let element = queue.removeFirst()
            visited += 1
            let role = value(element, kAXRoleAttribute) as? String ?? ""
            let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].lazy
                .compactMap { value(element, $0) as? String }.first { !$0.isEmpty } ?? ""
            if matches(role, title.trimmingCharacters(in: .whitespaces)), also(element) { return element }
            if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { queue += children }
        }
        return nil
    }

    /// Opening the app the way the Dock does: a background tool can't just activate it.
    private static func bringToFront(_ url: URL) {
        let opened = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in opened.signal() }
        _ = opened.wait(timeout: .now() + 5)
    }

    private static var isFront: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == vivaldi }

    private static func waitForFront(seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isFront { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
