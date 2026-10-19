import Foundation
import SQLite3

/// `Joe --whatsapp chats | unread | read "<chat>" [n] | search "<text>"`: WhatsApp's messages read
/// straight from the database the Mac app keeps (ChatStorage.sqlite), read-only, so the assistant
/// can catch up on chats without opening the app or taking screenshots. Nothing is sent or changed;
/// sending still goes through `--message send` and its approval card.
enum WhatsAppLog {
    static let database = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")

    static func run(_ arguments: [String]) -> String {
        guard FileManager.default.fileExists(atPath: database.path) else {
            return "WhatsApp on this Mac has no chats yet: open WhatsApp, link it to the phone (Settings → Linked devices → scan the QR code) and let it sync, then try again."
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            return "Couldn't open WhatsApp's database (Joe may need Full Disk Access)."
        }
        defer { sqlite3_close(db) }
        guard tables(db).contains("ZWAMESSAGE") else {
            return "WhatsApp's database has a layout Joe doesn't know. Tables: \(tables(db).sorted().joined(separator: ", "))"
        }
        let limit = arguments.count > 2 ? Int(arguments[2]) ?? 30 : 30
        switch arguments.first {
        case "chats":
            return rows(db, """
                SELECT COALESCE(ZPARTNERNAME, ZCONTACTJID), ZUNREADCOUNT, ZLASTMESSAGEDATE, COALESCE(ZLASTMESSAGETEXT, '')
                FROM ZWACHATSESSION WHERE ZLASTMESSAGEDATE IS NOT NULL ORDER BY ZLASTMESSAGEDATE DESC LIMIT 40
                """) { "\($0[0]) · \(when($0[2]))\(($0[1] as NSString).integerValue > 0 ? " · \($0[1]) unread" : "") · \($0[3].prefix(80))" }
        case "unread":
            let chats = rows(db, """
                SELECT Z_PK, COALESCE(ZPARTNERNAME, ZCONTACTJID), ZUNREADCOUNT FROM ZWACHATSESSION
                WHERE ZUNREADCOUNT > 0 ORDER BY ZLASTMESSAGEDATE DESC LIMIT 15
                """) { $0.joined(separator: "\t") }
            guard !chats.isEmpty, !chats.hasPrefix("Nothing") else { return "No unread WhatsApp messages." }
            return chats.split(separator: "\n").map { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                let count = min(max(Int(parts[2]) ?? 1, 1), 20)
                return "## \(parts[1]) (\(parts[2]) unread)\n" + messages(db, chat: parts[0], limit: count)
            }.joined(separator: "\n\n")
        case "read" where arguments.count > 1:
            let name = arguments[1].replacingOccurrences(of: "'", with: "''")
            let matches = rows(db, """
                SELECT Z_PK, COALESCE(ZPARTNERNAME, ZCONTACTJID) FROM ZWACHATSESSION
                WHERE ZPARTNERNAME LIKE '%\(name)%' ORDER BY ZLASTMESSAGEDATE DESC LIMIT 1
                """) { $0.joined(separator: "\t") }
            let parts = matches.split(separator: "\t").map(String.init)
            guard parts.count == 2 else { return "No WhatsApp chat matching “\(arguments[1])”. Try --whatsapp chats." }
            return "## \(parts[1])\n" + messages(db, chat: parts[0], limit: limit)
        case "search" where arguments.count > 1:
            let text = arguments[1].replacingOccurrences(of: "'", with: "''")
            return rows(db, """
                SELECT COALESCE(s.ZPARTNERNAME, ''), m.ZMESSAGEDATE, m.ZISFROMME, m.ZTEXT FROM ZWAMESSAGE m
                JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION WHERE m.ZTEXT LIKE '%\(text)%'
                ORDER BY m.ZMESSAGEDATE DESC LIMIT 25
                """) { "\($0[0]) · \(when($0[1])) · \($0[2] == "1" ? "You" : "Them"): \($0[3])" }
        default:
            return "Use: --whatsapp chats | unread | read \"<chat>\" [count] | search \"<text>\""
        }
    }

    /// The last messages of a chat, oldest first, with who sent each (group members by name).
    private static func messages(_ db: OpaquePointer, chat: String, limit: Int) -> String {
        let list = rows(db, """
            SELECT m.ZMESSAGEDATE, m.ZISFROMME, COALESCE(g.ZCONTACTNAME, m.ZPUSHNAME, ''), COALESCE(m.ZTEXT, '[media]')
            FROM ZWAMESSAGE m LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
            WHERE m.ZCHATSESSION = \(Int(chat) ?? -1) ORDER BY m.ZMESSAGEDATE DESC LIMIT \(limit)
            """) { "\(when($0[0])) \($0[1] == "1" ? "You" : ($0[2].isEmpty ? "Them" : $0[2])): \($0[3])" }
        return list.split(separator: "\n").reversed().joined(separator: "\n")
    }

    private static func when(_ seconds: String) -> String {
        let date = Date(timeIntervalSinceReferenceDate: Double(seconds) ?? 0) // Core Data: seconds since 2001
        return date.formatted(Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated).hour().minute())
    }

    private static func tables(_ db: OpaquePointer) -> Set<String> {
        Set(rows(db, "SELECT name FROM sqlite_master WHERE type = 'table'") { $0[0] }.split(separator: "\n").map(String.init))
    }

    /// A query's rows, each formatted into a line; "Nothing found." if there are none.
    private static func rows(_ db: OpaquePointer, _ sql: String, _ line: ([String]) -> String) -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return "Query failed: \(String(cString: sqlite3_errmsg(db)))"
        }
        defer { sqlite3_finalize(statement) }
        var lines: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let values = (0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            }
            lines.append(line(values))
        }
        return lines.isEmpty ? "Nothing found." : lines.joined(separator: "\n")
    }
}
