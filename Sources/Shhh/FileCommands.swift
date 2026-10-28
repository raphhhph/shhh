import Foundation

/// The assistant managing the user's files through Bash: looking (ls, du, find…) anywhere in
/// their own folders, and organizing (mkdir, mv, cp, touch) inside the everyday ones — Desktop,
/// Documents, Downloads, Pictures, Movies, Music and the notes vault. Nothing is ever deleted:
/// "deleting" means moving to the Trash. Every change is logged, so it can be undone.
///
/// A command is read the way the shell would, and only plain commands chained with |, &&, || or ;
/// pass. Anything that could run something else ($(…), backticks, redirects into files, xargs,
/// find -exec, sudo…) isn't a file command, and asks as before.
enum FileCommands {
    enum Verdict: Equatable {
        case look, change
        case blocked(String)
        /// A change big enough to show first: moving folders or many files. The text lists them.
        case confirm(String)

        var changes: Bool {
            switch self {
            case .change, .confirm: true
            default: false
            }
        }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    /// Where files may be moved, copied and created.
    private static var writable: [String] {
        ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].map { home + "/" + $0 }
            + [Assistant.vaultURL?.resolvingSymlinksInPath().path].compactMap { $0 }
    }
    private static let trash = home + "/.Trash"

    private static let lookers: Set = ["ls", "du", "find", "stat", "file", "wc", "head", "tail", "cat", "mdls", "mdfind",
                                       "tree", "pwd", "echo", "sort", "uniq", "grep", "cd", "basename", "dirname", "df"]
    private static let changers: Set = ["mkdir", "mv", "cp", "touch"]
    private static let deleters: Set = ["rm", "rmdir", "unlink", "trash", "srm", "shred"]

    static let log = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/File changes.log")

    /// What a Bash command does to files, or nil if it isn't a file command.
    static func judge(_ command: String, cwd: URL) -> Verdict? {
        guard let commands = split(command) else { return nil }
        var cwd = cwd.standardizedFileURL.path
        var changes = false
        var moved: [String] = []
        for words in commands {
            guard let first = words.first else { continue }
            let program = (first as NSString).lastPathComponent
            guard first == program || ["/bin/", "/usr/bin/"].contains(where: first.hasPrefix) else { return nil }
            let arguments = Array(words.dropFirst())
            let paths = arguments.filter { !$0.hasPrefix("-") }
            if deleters.contains(program) {
                return .blocked("Joe doesn't delete files. To get rid of something, move it to the Trash: mv <file> ~/.Trash/")
            }
            if program == "open" {
                guard opens(arguments, cwd: cwd) else { return nil }
                continue
            }
            if lookers.contains(program) {
                if program == "find", arguments.contains(where: { ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"].contains($0) }) {
                    return nil
                }
                if program == "cd" {
                    guard let path = paths.first.map({ resolve($0, cwd: cwd) }), readable(path) else { return nil }
                    cwd = path
                    continue
                }
                // Find's paths come before its expression; grep's pattern isn't a path; the rest must be readable.
                let checked = program == "find" ? Array(arguments.prefix { !$0.hasPrefix("-") })
                    : program == "grep" ? Array(paths.dropFirst()) : program == "echo" ? [] : paths
                guard checked.allSatisfy({ readable(resolve($0, cwd: cwd)) }) else { return nil }
                continue
            }
            guard changers.contains(program), !paths.isEmpty else { return nil }
            if program == "mv" {
                // What's moved, wildcards expanded: never code, the School folder or Joe's own
                // folders, and folders or a pile of files are shown before they go.
                for source in paths.dropLast().flatMap({ expand($0, cwd: cwd) }) {
                    if let reason = protected(source) { return .blocked(reason) }
                    moved.append(source)
                }
            }
            for (index, path) in paths.enumerated() {
                let resolved = resolve(path, cwd: cwd)
                let isDestination = program == "mv" && index == paths.count - 1
                guard changeable(resolved) || (isDestination && (resolved == trash || resolved.hasPrefix(trash + "/"))) else {
                    return .blocked("Joe only moves, copies and creates files in Desktop, Documents, Downloads, Pictures, Movies, Music and the notes vault (and moves to ~/.Trash). \(path) is outside them: tell the user.")
                }
            }
            changes = true
        }
        let folders = moved.filter { var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isFolder) && isFolder.boolValue }
        if !folders.isEmpty || moved.count >= 5 {
            let names = moved.map { ($0 as NSString).lastPathComponent }
            return .confirm("Move \(names.count == 1 ? names[0] : "\(names.count) items: " + names.prefix(12).joined(separator: ", ") + (names.count > 12 ? "…" : ""))")
        }
        return changes ? .change : .look
    }

    /// Why a path must stay where it is, or nil. Code (a folder with .git or Package.swift, or
    /// holding such folders, like ~/Desktop/Code), the School folder, and folders Joe uses (the
    /// notes vault), or anything holding them. Moving these broke Joe's own build on 28 Oct.
    static func protected(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if name.lowercased() == "school" { return "Joe doesn't move the School folder: other features read it there. Leave it and tell the user." }
        let joe = [Assistant.vaultURL?.resolvingSymlinksInPath().path, log.deletingLastPathComponent().path].compactMap { $0 }
        if let used = joe.first(where: { $0 == path || $0.hasPrefix(path + "/") }) {
            return "Joe doesn't move \(name): Joe uses \(used == path ? "it" : "a folder inside it"). Leave it and tell the user."
        }
        if isCode(path) { return "Joe doesn't move \(name): it holds code (a git repository or Swift package), and moving it breaks builds. Leave it and tell the user." }
        return nil
    }

    /// A code project, or a folder of them (one level down).
    private static func isCode(_ path: String) -> Bool {
        let markers = [".git", "Package.swift"]
        let manager = FileManager.default
        if markers.contains(where: { manager.fileExists(atPath: path + "/" + $0) }) { return true }
        if (path as NSString).pathExtension == "xcodeproj" { return true }
        let children = (try? manager.contentsOfDirectory(atPath: path)) ?? []
        return children.prefix(200).contains { child in
            markers.contains { manager.fileExists(atPath: path + "/" + child + "/" + $0) } || child.hasSuffix(".xcodeproj")
        }
    }

    /// The paths a word names, with wildcards expanded the way the shell would.
    private static func expand(_ word: String, cwd: String) -> [String] {
        var pattern = word
        if pattern == "~" || pattern.hasPrefix("~/") { pattern = home + pattern.dropFirst() }
        if !pattern.hasPrefix("/") { pattern = cwd + "/" + pattern }
        guard pattern.contains(where: { "*?[".contains($0) }) else { return [resolve(word, cwd: cwd)] }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(pattern, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { matches.gl_pathv[$0].map { String(cString: $0) } }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    /// `open`: an app by name (open -a Calculator), a folder or file in their folders, or a web,
    /// Obsidian or mail link. Not scripts, installers or apps from outside Applications, which
    /// would run code.
    private static func opens(_ arguments: [String], cwd: String) -> Bool {
        let running: Set = ["command", "sh", "zsh", "bash", "tool", "terminal", "pkg", "mpkg", "dmg", "scpt", "applescript",
                            "workflow", "jar", "py", "rb", "pl", "js", "action", "osax", "prefpane", "mobileconfig", "webloc", "inetloc"]
        var rest = arguments[...]
        var opened = false
        while let word = rest.popFirst() {
            switch word {
            case "-a", "-b":
                guard let app = rest.popFirst() else { return false }
                // A path to an app must be an installed one; a name or bundle ID is looked up by macOS.
                if app.contains("/"), !(resolve(app, cwd: cwd).hasPrefix("/Applications/") || resolve(app, cwd: cwd).hasPrefix("/System/Applications/")) {
                    return false
                }
                opened = true
            case "-g", "-n", "-F", "-W", "-R", "-e", "-t", "-j", "-h", "--hide", "--background", "--fresh", "--new", "--reveal":
                continue
            default:
                if word.hasPrefix("-") { return false }
                if let scheme = word.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: [.regularExpression, .caseInsensitive]) {
                    guard ["http:", "https:", "obsidian:", "mailto:"].contains(word[scheme].lowercased()) else { return false }
                } else {
                    let path = resolve(word, cwd: cwd)
                    let kind = (path as NSString).pathExtension.lowercased()
                    guard readable(path), !running.contains(kind),
                          kind != "app" || path.hasPrefix("/Applications/") else { return false }
                }
                opened = true
            }
        }
        return opened
    }

    /// Notes a change, for undoing it later.
    static func record(_ command: String) {
        let line = "\(Date().formatted(.iso8601)) \(command.replacingOccurrences(of: "\n", with: " "))\n"
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    // MARK: - Paths

    /// An absolute path for a word: ~ expanded, relative to the working folder, and up to any
    /// wildcard (the folder the wildcard picks from), with links followed.
    private static func resolve(_ word: String, cwd: String) -> String {
        var path = word
        if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
        if !path.hasPrefix("/") { path = cwd + "/" + path }
        // A wildcard picks things inside a folder: check that folder, as a place inside it.
        var wildcard = false
        if let star = path.firstIndex(where: { "*?[".contains($0) }) {
            path = String(path[..<star])
            if !path.hasSuffix("/") { path = (path as NSString).deletingLastPathComponent }
            wildcard = true
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Follow links on the part that exists, so a link on the Desktop can't lead elsewhere.
        var existing = url
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let resolved = rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL.path
        return wildcard ? resolved + "/*" : resolved
    }

    /// Where passwords, keys and logins live: never read, whatever the mode.
    static func isSecret(_ path: String) -> Bool {
        let lower = path.lowercased()
        let folders = ["/.ssh", "/.gnupg", "/.aws", "/.config/gh", "/.netrc", "/library/keychains", "/library/cookies",
                       "/library/application support/shhh/spotify.json", "/.claude/.credentials", "/.claude.json"]
        let files = ["login data", "cookies", "key3.db", "key4.db", "logins.json", "keychain"]
        return folders.contains { lower.contains($0) } || files.contains { (lower as NSString).lastPathComponent.hasPrefix($0) }
    }

    /// Anywhere in the user's own folders except Library and hidden ones, and the apps.
    static func readable(_ path: String) -> Bool {
        if path.hasPrefix("/Applications") || path.hasPrefix("/Volumes") { return true }
        // Claude skills (read-only guides and scripts, like the PowerPoint one).
        if path.hasPrefix(home + "/.claude/skills/") { return true }
        // Shhh's own folder: the change log, the screenshots it takes, the notepad.
        if path.hasPrefix(log.deletingLastPathComponent().path + "/") || path == log.deletingLastPathComponent().path { return true }
        guard path == home || path.hasPrefix(home + "/") else { return false }
        let inside = path.dropFirst(home.count).split(separator: "/")
        return inside.first != "Library" && !inside.contains { $0.hasPrefix(".") && $0 != ".Trash" }
    }

    /// A working file the assistant may write without asking in Hands-off mode: a script, plan or
    /// note (build.js, plan.json) in the everyday folders. Their documents, decks and the rest still ask.
    static func isWorkingFile(_ path: String) -> Bool {
        let full = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        let kinds: Set = ["js", "mjs", "cjs", "json", "py", "md", "txt", "csv", "html", "css", "svg"]
        return changeable(full) && kinds.contains((full as NSString).pathExtension.lowercased())
    }

    /// Inside one of the everyday folders (not the folder itself), and not in an app, a git
    /// repository's internals or a hidden folder.
    static func changeable(_ path: String) -> Bool {
        guard writable.contains(where: { path.hasPrefix($0 + "/") }) else { return false }
        let parts = path.split(separator: "/")
        return !parts.contains { $0.hasPrefix(".") || $0.hasSuffix(".app") }
    }

    // MARK: - Reading the command

    /// The simple commands in a command line, as words, or nil if it does anything beyond plain
    /// commands chained with |, &&, || or ; (and output thrown away with 2>/dev/null).
    private static func split(_ command: String) -> [[String]]? {
        var commands: [[String]] = [[]]
        var word = ""
        var inWord = false
        var quote: Character?
        var characters = Array(command)
        var index = 0
        func endWord() {
            if inWord { commands[commands.count - 1].append(word) }
            word = ""
            inWord = false
        }
        while index < characters.count {
            let c = characters[index]
            if let open = quote {
                if c == open { quote = nil } else if open == "\"", "$`\\".contains(c) { return nil } else { word.append(c) }
                index += 1
                continue
            }
            let rest = String(characters[index...])
            if c == "'" || c == "\"" {
                quote = c
                inWord = true
            } else if c == " " || c == "\t" {
                endWord()
            } else if c == "\n" || c == ";" || c == "|" || c == "&" {
                // ;, |, ||, && end a command; a lone & (running in the background) isn't allowed.
                if c == "&", !rest.hasPrefix("&&") { return nil }
                endWord()
                commands.append([])
                if rest.hasPrefix("&&") || rest.hasPrefix("||") { index += 1 }
            } else if c == ">" || c == "<" || (c == "2" && !inWord && rest.hasPrefix("2>")) {
                guard let skip = ["2>/dev/null", ">/dev/null", "2>&1"].first(where: rest.hasPrefix) else { return nil }
                endWord()
                index += skip.count
                continue
            } else if c == "\\", index + 1 < characters.count, characters[index + 1] != "\n" {
                // An escaped character ("Application\ Support"): just that character.
                word.append(characters[index + 1])
                inWord = true
                index += 2
                continue
            } else if "$`(){}\\#!".contains(c) {
                return nil
            } else {
                word.append(c)
                inWord = true
            }
            index += 1
        }
        guard quote == nil else { return nil }
        endWord()
        characters = []
        let result = commands.filter { !$0.isEmpty }
        return result.isEmpty ? nil : result
    }
}
