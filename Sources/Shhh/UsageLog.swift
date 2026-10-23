import Foundation

/// What each request to Claude costs, for the dashboard's Usage page and for pricing Joe: one JSON
/// line per finished request in Usage.jsonl (Joe's folder): when, which model, tokens, cost in
/// US dollars (Claude Code reports it, also on a subscription, where it's what the API would
/// charge) and the start of the request.
enum UsageLog {
    struct Entry: Codable, Identifiable {
        var date: Date
        var model: String
        var cost: Double
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
        var request: String
        var id: Date { date }

        /// "Morning briefing", "Background task", or "Request".
        var kind: String {
            if request.hasPrefix("[Morning briefing") { return "Morning brief" }
            if request.hasPrefix("[Evening check") || request.hasPrefix("[Night shutdown") || request.hasPrefix("[Timed routine") { return "Scheduled" }
            if request.hasPrefix("[From their iPhone") { return "iPhone" }
            if request.hasPrefix("[My lecture") || request.hasPrefix("[My meeting") { return "Notes" }
            return "Request"
        }
    }

    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/Usage.jsonl")

    /// From a Claude Code "result" message. Its total_cost_usd counts the whole conversation, so
    /// this request's cost is the difference from the last one (`total` carries it along).
    static func record(_ result: [String: Any], model: String, request: String, total: inout Double) {
        let conversationCost = result["total_cost_usd"] as? Double ?? total
        let cost = max(0, conversationCost - total)
        total = conversationCost
        let usage = result["usage"] as? [String: Any] ?? [:]
        let entry = Entry(date: Date(), model: model, cost: cost,
                          input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0,
                          cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                          cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                          request: String(request.prefix(120)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        }
    }

    static func load() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }
}
