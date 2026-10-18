import Foundation

/// What the assistant changed, so "undo that" can put it back. One line per change in
/// Undo/journal.log in Joe's folder, newest last:
///
///     <time> | file | <path> | <backup copy>      a file it changed (restore the copy)
///     <time> | new | <path>                       a file it created (move it to the Trash)
///     <time> | liked | <spotify uri>              a song it saved (unlike it)
///     <time> | alarm | <id> | <title>             an alarm it set (cancel it)
///
/// File moves are in "File changes.log" already. Backups older than a week are cleared.
enum UndoJournal {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/Undo", isDirectory: true)
    static var log: URL { folder.appendingPathComponent("journal.log") }

    static func add(_ fields: [String]) {
        let line = ([Date().formatted(.iso8601)] + fields).joined(separator: " | ") + "\n"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    /// Before the assistant edits or writes a file: a copy of it, or a note that it's new.
    static func beforeChanging(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return add(["new", url.path]) }
        let stamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let backup = folder.appendingPathComponent("\(stamp) \(url.lastPathComponent)")
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? manager.copyItem(at: url, to: backup)) != nil else { return }
        add(["file", url.path, backup.path])
        clearOld()
    }

    /// Backups from more than a week ago.
    private static func clearOld() {
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        where file.lastPathComponent != "journal.log" {
            if let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate, created < weekAgo {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
