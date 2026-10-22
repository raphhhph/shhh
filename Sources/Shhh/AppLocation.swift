import AppKit
import ApplicationServices

/// Where Joe runs from, and starting it again. Opened straight from the disk image, or from
/// Downloads without being moved, macOS runs a read-only copy from a random folder ("App
/// Translocation"): the Accessibility switch the student turns on then belongs to a copy that's
/// gone next time, so Joe never sees it. Moving it to Applications first avoids all that.
@MainActor
enum AppLocation {
    static var needsMove: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    /// At launch: if Joe isn't in an Applications folder, offers to copy it there and reopen it.
    static func offerMove() {
        guard needsMove else { return }
        let alert = NSAlert()
        alert.messageText = "Move Joe to Applications?"
        alert.informativeText = "Joe is running from the disk image or Downloads, where macOS doesn't keep its permissions. I'll copy it to Applications and reopen it from there."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        // /Applications needs an admin account; a student's own account falls back to ~/Applications.
        for folder in [URL(fileURLWithPath: "/Applications", isDirectory: true), home] {
            let target = folder.appendingPathComponent("Joe.app")
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) } // an older Joe
                try fm.copyItem(at: Bundle.main.bundleURL, to: target)
            } catch {
                continue
            }
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", target.path]
            try? xattr.run()
            xattr.waitUntilExit()
            relaunch(target)
            return
        }
        let failed = NSAlert()
        failed.messageText = "Couldn't move Joe"
        failed.informativeText = "Drag Joe from the disk image onto the Applications folder, then open it from Applications."
        failed.runModal()
    }

    /// Quits and opens Joe again (or the copy at `app`) once this one has really gone.
    static func relaunch(_ app: URL = Bundle.main.bundleURL) {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/sh")
        opener.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                            app.path, String(ProcessInfo.processInfo.processIdentifier)]
        try? opener.run()
        NSApp.terminate(nil)
    }

    /// Takes Joe off macOS's Accessibility list and asks again. An entry left by an earlier copy of
    /// Joe (each test build is signed differently) shows as on but doesn't count for this one.
    static func resetAccessibility() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "io.github.tibophlp.shhh"]
        try? reset.run()
        reset.waitUntilExit()
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
    }
}
