import Foundation

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
