import AppKit
import PDFKit

/// `Joe --slides inspect|apply …`: Joe's slides tool (Resources/slides.py, with python-pptx in a
/// private Python in Joe's folder, set up the first time). Edits a copy of a deck, keeping its
/// look, instead of clicking around a slide editor.
enum Slides {
    private static let python = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/python")
    static var pythonPath: String { python.appendingPathComponent("bin/python").path }
    static let nodeModules = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/node/node_modules").path

    /// Anthropic's PowerPoint skill (synced into ~/.claude/skills from claude.ai): its design rules,
    /// generator method and checker. Found wherever the sync put it.
    static var designSkill: URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if url.lastPathComponent == "SKILL.md", url.deletingLastPathComponent().lastPathComponent == "pptx" { return url }
            if walker?.level ?? 0 > 4 { walker?.skipDescendants() }
        }
        return nil
    }

    static func run(_ arguments: [String]) -> String {
        if arguments.first == "render", arguments.count >= 2 { return render(arguments[1]) }
        if arguments.first == "keynote", arguments.count >= 2 { return keynote(arguments[1]) }
        return python(arguments)
    }

    /// slides.py in the private Python (set up on first use).
    private static func python(_ arguments: [String]) -> String {
        guard let script = Bundle.main.url(forResource: "slides", withExtension: "py") else { return "The slides tool is missing from the app." }
        let interpreter = python.appendingPathComponent("bin/python")
        if !FileManager.default.isExecutableFile(atPath: interpreter.path) || !shell(interpreter.path, ["-c", "import pptx"]).ok {
            // First use: a private Python with python-pptx (about 10 seconds).
            _ = shell("/usr/bin/env", ["python3", "-m", "venv", python.path])
            let install = shell(python.appendingPathComponent("bin/pip").path, ["install", "--quiet", "python-pptx"])
            guard install.ok else { return "Couldn't set up the slides tool: \(install.output)" }
        }
        return shell(interpreter.path, [script.path] + arguments).output
    }

    /// A PDF (slides exported to PDF, a handout) as a Keynote deck to present: each page a slide,
    /// looking exactly as it does, saved as "<name>.key" beside the PDF and opened. The text isn't
    /// editable; to change the content, rebuild the deck from the PDF's text instead.
    static func keynote(_ path: String) -> String {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let pdf = PDFDocument(url: source), pdf.pageCount > 0 else { return "Couldn't open \(source.path) as a PDF." }
        let manager = FileManager.default
        let pages = source.deletingPathExtension().appendingPathExtension("pages")
        try? manager.removeItem(at: pages)
        try? manager.createDirectory(at: pages, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: pages) }

        // Each page as a sharp PNG, 2400 pixels across.
        var images: [String] = []
        var aspect: CGFloat = 9 / 16
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            var bounds = page.bounds(for: .mediaBox).size
            if page.rotation % 180 != 0 { bounds = CGSize(width: bounds.height, height: bounds.width) }
            if index == 0, bounds.width > 0 { aspect = bounds.height / bounds.width }
            let width = 2400, height = Int(2400 * bounds.height / max(bounds.width, 1))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            let cg = context.cgContext
            cg.setFillColor(NSColor.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            cg.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
            page.draw(with: .mediaBox, to: cg)
            let file = pages.appendingPathComponent(String(format: "%03d.png", index + 1))
            guard (try? bitmap.representation(using: .png, properties: [:])?.write(to: file)) != nil else { continue }
            images.append(file.path)
        }
        guard !images.isEmpty else { return "Couldn't draw the PDF's pages." }

        // A PowerPoint file of the pictures, then Keynote saves it as its own.
        let name = source.deletingPathExtension().lastPathComponent
        let folder = source.deletingLastPathComponent()
        let pptx = folder.appendingPathComponent("\(name) (pages).pptx")
        let built = python(["images", pptx.path, "13.333", String(format: "%.3f", 13.333 * aspect)] + images)
        guard manager.fileExists(atPath: pptx.path) else { return "Couldn't build the deck: \(built)" }
        defer { try? manager.trashItem(at: pptx, resultingItemURL: nil) }
        var key = folder.appendingPathComponent("\(name).key")
        if manager.fileExists(atPath: key.path) { key = folder.appendingPathComponent("\(name) (Joe).key") }
        let escape = { (text: String) in text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = """
            tell application "Keynote"
              set startCount to count of documents
              open POSIX file "\(escape(pptx.path))"
              repeat 60 times
                if (count of documents) > startCount then exit repeat
                delay 0.5
              end repeat
              if (count of documents) is startCount then return "Keynote couldn't open it."
              set theDoc to front document
              save theDoc in POSIX file "\(escape(key.path))"
              delay 0.5
              -- The imported copy can stay open after saving: close it by name.
              close (every document whose name is "\(escape(pptx.deletingPathExtension().lastPathComponent))") saving no
              return "ok"
            end tell
            """
        let result = shell("/usr/bin/osascript", ["-e", script])
        guard result.output.contains("ok"), manager.fileExists(atPath: key.path) else {
            return "Keynote couldn't save it: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        NSWorkspace.shared.open(key)
        return "Made \(key.path): \(images.count) slides, each page exactly as in the PDF, and opened it in Keynote."
    }

    /// Every slide as a PNG, through Keynote (which opens PowerPoint files), so the assistant can
    /// look at its work: into "<deck> slides/" beside the deck. Leaves the user's other Keynote
    /// documents alone.
    static func render(_ path: String) -> String {
        let deck = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: deck.path) else { return "No file at \(deck.path)." }
        let folder = deck.deletingPathExtension().appendingPathExtension("slides")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let escape = { (text: String) in text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = """
            tell application "Keynote"
              set startCount to count of documents
              open POSIX file "\(escape(deck.path))"
              repeat 60 times
                if (count of documents) > startCount then exit repeat
                delay 0.5
              end repeat
              if (count of documents) is startCount then return "Keynote couldn't open it (its format may be broken)."
              set theDoc to front document
              export theDoc to POSIX file "\(escape(folder.path))" as slide images with properties {image format:PNG, skipped slides:false}
              close theDoc saving no
              return "ok"
            end tell
            """
        let result = shell("/usr/bin/osascript", ["-e", script])
        // An import error leaves a dialog: close it.
        _ = shell("/usr/bin/osascript", ["-e", "tell application \"System Events\" to tell process \"Keynote\" to if exists (button \"OK\" of window 1) then click button \"OK\" of window 1"])
        let images = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        guard result.output.contains("ok"), !images.isEmpty else {
            return "Couldn't render it: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return "Rendered \(images.count) slides. Read each image to check it:\n" + images.map { folder.appendingPathComponent($0).path }.joined(separator: "\n")
    }

    private static func shell(_ path: String, _ arguments: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (false, "couldn't run \(path)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }
}
