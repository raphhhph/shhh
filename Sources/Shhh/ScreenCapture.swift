import AppKit
import ScreenCaptureKit

/// A picture of the screen for requests about what's on it ("summarize what's on my screen").
/// Taken when the key goes down, leaving out Shhh's own windows (the pill and the answer card),
/// and only sent along when the request is about the screen. Never saved to disk.
@MainActor
enum ScreenCapture {
    struct Screenshot {
        let jpeg: Data
        let image: CGImage
        /// Where the captured display is, in screen coordinates.
        let screenFrame: NSRect
        /// The image's size in pixels, which Claude's coordinates refer to.
        let pixelSize: CGSize
        /// Where the mouse pointer was, in the image's pixels (from the top left).
        let cursor: CGPoint?

        /// The area around the pointer with a red ring on it: what "this", "him" or "her" means
        /// when the user is pointing at something. About a sixth of the tokens of the whole screen.
        func cursorCrop() -> Data? {
            guard let cursor else { return nil }
            let size = CGSize(width: min(640, pixelSize.width), height: min(400, pixelSize.height))
            let origin = CGPoint(x: min(max(cursor.x - size.width / 2, 0), pixelSize.width - size.width),
                                 y: min(max(cursor.y - size.height / 2, 0), pixelSize.height - size.height))
            guard let crop = image.cropping(to: CGRect(origin: origin, size: size)),
                  let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            // CGContext's origin is the bottom left.
            let ring = CGPoint(x: cursor.x - origin.x, y: CGFloat(crop.height) - (cursor.y - origin.y))
            context.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.1, alpha: 1))
            context.setLineWidth(3)
            context.strokeEllipse(in: CGRect(x: ring.x - 14, y: ring.y - 14, width: 28, height: 28))
            guard let marked = context.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: marked).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        }
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
            // Shhh's own windows (the app's, also when this is `Shhh --look` running for it).
            let shhh = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
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
            let frame = screen.frame
            let cursor = NSMouseInRect(mouse, frame, false)
                ? CGPoint(x: (mouse.x - frame.minX) / frame.width * CGFloat(image.width),
                          y: (frame.maxY - mouse.y) / frame.height * CGFloat(image.height))
                : nil
            let shot = Screenshot(jpeg: jpeg, image: image, screenFrame: frame,
                                  pixelSize: CGSize(width: image.width, height: image.height), cursor: cursor)
            ScreenControl.record(shot) // clicks given in its pixels land right
            return shot
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

    /// "Walk me through submitting on ManageBac", "show me how to share this doc", "step by step".
    static func isWalkthrough(_ request: String) -> Bool {
        request.range(of: #"\b(walk|guide|take|talk) me through\b|\bshow me how\b|\bstep[- ]by[- ]step\b|\bteach me (how )?to (use|do|submit|upload|set|make|find)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// In a walkthrough: they did the step and want the next ("next", "done", "what now", "I'm there").
    static func isNextStep(_ request: String) -> Bool {
        request.count < 50 && request.range(of: #"^\W*((ok(ay)?|alright|right|cool|and)\W+)*(next( step| one)?|done|did it|i did (it|that)|i'?ve done (it|that)|what now|now what|then what|what next|what'?s next|i'?m there|continue|go on|keep going)\b"#,
                                            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether a request is about something the user is pointing at with the mouse: "find his
    /// LinkedIn", "what does this word mean", "who's that person".
    static func pointsAtSomething(_ request: String) -> Bool {
        let things = "guy|girl|person|one|thing|word|name|link|company|product|place|app|logo|brand|book|song|movie|show"
        // "Him" and "her" alone usually mean someone from the conversation ("email her that I'm
        // late"); with a look-up word they mean someone on screen.
        let patterns = [
            #"\b(this|that) (\#(things))\b"#,
            #"\b(over here|right here|i'?m pointing at|my (mouse|cursor|pointer))\b"#,
            #"\b(find|look up|lookup|search( for)?|google|who|what)\b[^.?!]{0,30}\b(him|her|his|hers)\b"#,
            #"\bwho('?s| is)? (he|she)\b"#,
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
