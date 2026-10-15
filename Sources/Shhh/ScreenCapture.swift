import AppKit
import ScreenCaptureKit

/// A picture of the screen for requests about what's on it ("summarize what's on my screen").
/// Taken when the key goes down, leaving out Shhh's own windows (the pill and the answer card),
/// and only sent along when the request is about the screen. Never saved to disk.
@MainActor
enum ScreenCapture {
    struct Screenshot {
        let jpeg: Data
        /// Where the captured display is, in screen coordinates.
        let screenFrame: NSRect
        /// The image's size in pixels, which Claude's coordinates refer to.
        let pixelSize: CGSize
    }

    /// The display under the mouse as JPEG, at most 1568 px on its long side (the size Claude
    /// reads best), or nil without the Screen Recording permission.
    static func capture() async -> Screenshot? {
        guard CGPreflightScreenCaptureAccess() else { return nil } // asked for in requestAccess()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let screen, let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            let shhh = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: shhh, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = min(1, 1568 / CGFloat(max(display.width, display.height)))
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                return nil
            }
            return Screenshot(jpeg: jpeg, screenFrame: screen.frame, pixelSize: CGSize(width: image.width, height: image.height))
        } catch {
            return nil
        }
    }

    /// Shows macOS's Screen Recording prompt the first time; after that, it does nothing.
    static func requestAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Whether a request is about what's on screen: "summarize what's on my screen", "what does
    /// this error mean", "reply to this email", "point to where I change the font", "which button
    /// do I press". "The email" on its own usually means one in Gmail, so only "this", "that" and
    /// "these" count there.
    static func isAbout(_ request: String) -> Bool {
        let things = "page|window|tab|document|doc|email|e-mail|mail|message|slide|slides|error|chart|graph|diagram|"
            + "picture|image|photo|video|question|questions|problem|text|article|code|table|form|site|website|"
            + "assignment|essay|paragraph|post|thread|file|pdf|note|notes|app"
        let controls = "button|menu|option|setting|settings|icon|toolbar|sidebar|dropdown|toggle|switch|field|box|"
            + "checkbox|link|tab|panel|bar|control|key|shortcut"
        let actions = "click|press|tap|find|change|set|turn|open|select|type|put|upload|submit|switch|make|get|"
            + "adjust|edit|add|move|enable|disable|toggle|format"
        let patterns = [
            #"\b(screens?|screenshot|écran|on here|in here)\b"#,
            #"\bwhat (am i|i'?m) (looking at|seeing|reading|watching)\b"#,
            #"\b(is|does|was) (this|that) (look )?(right|correct|good|ok|okay)\b"#,
            #"\b(this|that|these) (\#(things))\b"#,
            #"\bpoint (to|at|out|me)\b"#,                                   // "point to where…"
            #"\bshow me (where|how|which)\b"#,
            #"\bwhere (do|can|should|would) i (\#(actions))\b"#,             // "where do I click"
            #"\b(where'?s|where is|where are|which) (the |a |an )?(\w+ ){0,2}(\#(controls))\b"#,
            #"\bwhat (do|should) i (click|press|tap|select)\b"#,
        ]
        return patterns.contains { request.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Whether a screen request needs the picture rather than the text: finding or pointing at
    /// something, or anything visual. Text requests ("rewrite this", "summarize this page") are
    /// cheaper and more exact as text (see `ScreenContext`).
    static func wantsPicture(_ request: String) -> Bool {
        let pattern = #"\b(point (to|at|out|me)|show me|where('?s| is| are| do| can| should| would)?|which|click|press|tap|"#
            + #"chart|graph|diagram|image|picture|photo|video|screenshot|looks?( like)?|looking at|layout|design|"#
            + #"colou?rs?|icon|button|menu)\b"#
        return request.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
