import Foundation

/// Where the time goes in one request, from the key press to Joe's first spoken word: one JSON line
/// per request in Latency.jsonl (Joe's folder), milliseconds since the press for each step. Only
/// the request in front (the card) is timed; `Joe --latency` sums up the last ones.
///
/// Steps, in order: micLive (recording started), released (key let go), audioReady (recording
/// stopped), denoised, transcribed, sent (to Claude Code), cliInit (Claude Code began the turn: the
/// gap before it is its own setup, e.g. connectors), firstEvent (Claude's reply began),
/// firstText (its first words), firstAudio (Joe's voice started), done (the reply was complete).
@MainActor
enum Latency {
    struct Entry: Codable {
        var date: Date
        /// "voice" (a held key) or "typed".
        var kind: String
        /// How long Claude Code had been running when the request was sent (0: started for it).
        var sessionAge: Double?
        var model: String?
        var marks: [String: Int]
    }

    nonisolated static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/Latency.jsonl")

    private static var current: Entry?
    private static var started = Date()
    /// The Claude Code session the timed request went to: other sessions' events don't count.
    private static var session: ObjectIdentifier?
    private static var writeLater: DispatchWorkItem?

    /// A new request starts (the key press, or a typed request). Any earlier one is written now.
    static func begin(_ kind: String) {
        flush()
        started = Date()
        session = nil
        current = Entry(date: started, kind: kind, marks: [:])
    }

    /// The first time this step happened, in ms since `begin`.
    static func mark(_ step: String) {
        guard current != nil, current?.marks[step] == nil else { return }
        current?.marks[step] = Int(Date().timeIntervalSince(started) * 1000)
    }

    /// The request goes to Claude Code (only the first one after `begin` counts).
    static func sent(by owner: AnyObject, sessionAge: TimeInterval, model: String) {
        guard current != nil, session == nil else { return }
        session = ObjectIdentifier(owner)
        current?.sessionAge = (sessionAge * 10).rounded() / 10
        current?.model = model
        mark("sent")
    }

    /// A step of the reply, from the session the timed request went to.
    static func mark(_ step: String, from owner: AnyObject) {
        guard session == ObjectIdentifier(owner) else { return }
        mark(step)
    }

    /// The reply is complete. Written a few seconds later, so the voice's first word is in it.
    static func finished(from owner: AnyObject) {
        guard session == ObjectIdentifier(owner) else { return }
        mark("done")
        writeLater?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { flush() } }
        writeLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// Nothing went to Claude (an alarm, Spotify, a dismissal): not worth a line.
    static func drop() {
        current = nil
        session = nil
    }

    private static func flush() {
        writeLater?.cancel()
        writeLater = nil
        guard let entry = current, entry.marks["sent"] != nil else { current = nil; return }
        current = nil
        session = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
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

    nonisolated static func load() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    /// For `Joe --latency`: the median time of each step over the last requests, and how long each
    /// stage took (the gap from the step before).
    nonisolated static func summary(last count: Int = 20) -> String {
        let entries = Array(load().suffix(count))
        guard !entries.isEmpty else { return "No timed requests yet: ask Joe something with right ⌥, then run this again." }
        let steps = ["micLive", "released", "audioReady", "denoised", "transcribed", "sent", "cliInit", "firstEvent", "firstText", "firstAudio", "done"]
        func median(_ values: [Int]) -> Int? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        var lines = ["Median over the last \(entries.count) requests (ms after the key press; Δ = this stage alone):"]
        for (index, step) in steps.enumerated() {
            guard let at = median(entries.compactMap { $0.marks[step] }) else { continue }
            // The stage: from the step before (by request, so a missing step doesn't skew it).
            let gaps = entries.compactMap { entry -> Int? in
                guard let here = entry.marks[step] else { return nil }
                let before = steps[..<index].reversed().lazy.compactMap { entry.marks[$0] }.first ?? 0
                return here - before
            }
            let gap = median(gaps).map { "Δ \($0)" } ?? ""
            lines.append("  \(step.padding(toLength: 12, withPad: " ", startingAt: 0)) \(String(at).leftPadded(6))   \(gap)")
        }
        // Spoken words only start after the key is let go: what the user waits for.
        let waits = entries.compactMap { entry -> Int? in
            guard let released = entry.marks["released"], let voice = entry.marks["firstAudio"] ?? entry.marks["firstText"] else { return nil }
            return voice - released
        }
        if let wait = median(waits) { lines.append("Let go → first word (spoken, or shown with the voice off): \(wait) ms") }
        let cold = entries.filter { ($0.sessionAge ?? 0) < 1 }.count
        lines.append("Claude Code started for the request (cold) in \(cold) of \(entries.count); models: "
                     + Set(entries.compactMap(\.model)).sorted().joined(separator: ", "))
        return lines.joined(separator: "\n")
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}
