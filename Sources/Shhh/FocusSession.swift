import AppKit

/// Focus mode: a study block with a timer. "Start my block" (the Plan's current or next block in
/// today's Daybook), "focus on Paper 2 for 50 min", "focus for 25 minutes", "stop focus". While it
/// runs, its countdown sits beside the notch (the side-notch capsule, like a timer), a macOS Focus
/// is on when the student made a shortcut named "Joe Focus On" (and "Joe Focus Off"), and a focus
/// playlist plays when one is set (`focusPlaylist`). At the end: a chime, "Block done", the block
/// ticked in Week.md, and a 3-question check on it offered.
///
/// The notch widget's Start button and the block chip call `FocusSession.start(title:minutes:)`
/// or `FocusSession.startPlannedBlock()`, and read `FocusSession.shared` (an ObservableObject).
@MainActor
final class FocusSession: ObservableObject {
    static let shared = FocusSession()

    /// The side-notch item's id (one session at a time).
    let id = UUID()
    @Published private(set) var title = ""
    @Published private(set) var subject: String?
    @Published private(set) var minutes = 0
    /// When it ends; nil while paused or stopped.
    @Published private(set) var endsAt: Date?
    /// Seconds left while paused.
    @Published private(set) var pausedLeft: TimeInterval?
    /// Seconds left, refreshed every second while it runs.
    @Published private(set) var left: TimeInterval = 0
    private(set) var startedAt: Date?
    /// "16:10" when it's a Plan block: how the Week.md line is found to tick it.
    private var blockStart: String?
    private var startedMusic = false
    private var focusOn = false
    private var timer: Timer?
    private var awake: NSObjectProtocol?

    /// A session ended on time.
    struct Ended {
        var title: String
        var subject: String?
        var minutes: Int
        var ticked: Bool
    }

    /// Each second while it runs, and when it starts, pauses or stops (the side notch redraws).
    var onChange: () -> Void = {}
    /// A short line for a toast (started from the notch, not by voice).
    var onNotice: (String) -> Void = { _ in }
    /// Time's up (after the chime): Joe says "Block done" and offers the quiz.
    var onFinished: (Ended) -> Void = { _ in }

    var isRunning: Bool { endsAt != nil || pausedLeft != nil }
    var isPaused: Bool { pausedLeft != nil }
    var remaining: TimeInterval { pausedLeft ?? max(0, endsAt?.timeIntervalSinceNow ?? 0) }

    /// "24:13", or "1:05:00" over an hour.
    var clock: String {
        let seconds = Int(remaining.rounded(.up))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// For the notch's block chip: "Paper 2 · 24m".
    var chip: String? {
        guard isRunning else { return nil }
        let left = Int((remaining / 60).rounded(.up))
        return "\(title) · \(left)m" + (isPaused ? " (paused)" : "")
    }

    // MARK: - The API for the notch widget and chip

    /// Starts a block of `minutes` (25, 50 or any) on `title`. A Plan block of the same title today
    /// gets its subject and is the one ticked in Week.md at the end. Replaces a running session.
    static func start(title: String, minutes: Int, subject: String? = nil) {
        var plan = FocusPlan.resolve(title: title, minutes: minutes, untilEnd: false)
        if let subject { plan.subject = subject }
        shared.begin(plan, announce: true)
    }

    /// Starts the Plan's current block (until its end) or its next one (for its length); a
    /// 25-minute "Study block" when today's Plan has none left.
    static func startPlannedBlock(minutes: Int? = nil) {
        shared.begin(FocusPlan.resolve(title: nil, minutes: minutes, untilEnd: minutes == nil), announce: true)
    }

    static func stop() { shared.end(finished: false) }
    static func pause() { shared.hold() }
    static func resume() { shared.carryOn() }

    // MARK: - Voice requests

    /// What a focus request did, for the card (and the line read aloud).
    static func handle(_ request: FocusRequest, now: Date = Date()) -> StudyLoop.Reply {
        let session = shared
        switch request {
        case let .start(title, minutes, untilEnd):
            let plan = FocusPlan.resolve(title: title, minutes: minutes, untilEnd: untilEnd, now: now)
            let previous = session.isRunning ? session.title : nil
            session.begin(plan, announce: false)
            let until = Daybook.hhmm(now.addingTimeInterval(Double(plan.minutes) * 60))
            var card = "Started **\(plan.title)**: \(plan.minutes) minutes, until \(until)."
            if let block = plan.block { card += " It's your \(block)." }
            if let previous, previous != plan.title { card += " (\(previous) stopped.)" }
            switch FocusShortcuts.known?.contains(FocusShortcuts.on) {
            case true?: card += "\n\nFocus is on (your \"\(FocusShortcuts.on)\" shortcut)."
            case false?: card += "\n\nTo silence notifications too, make a shortcut named \"\(FocusShortcuts.on)\" that turns on a Focus (and \"\(FocusShortcuts.off)\" to turn it off) in Shortcuts."
            case nil: break
            }
            card += "\n\nSay \"stop focus\" to end it early."
            return StudyLoop.Reply(subject: "Focus: \(plan.title) · \(plan.minutes) min", card: card,
                                   spoken: "Focus on \(plan.title) for \(plan.minutes) minutes.")
        case .stop:
            guard session.isRunning else {
                return StudyLoop.Reply(subject: "No focus block running", card: "There's no focus block running.", spoken: "There's no focus block running.")
            }
            let title = session.title
            let done = Int(((now.timeIntervalSince(session.startedAt ?? now)) / 60).rounded())
            session.end(finished: false)
            return StudyLoop.Reply(subject: "Focus stopped: \(title)", card: "Stopped **\(title)** after \(done) min. The block stays open in Week.md.",
                                   spoken: "Stopped \(title) after \(done) minutes.")
        case .pause:
            guard session.isRunning, !session.isPaused else {
                return StudyLoop.Reply(subject: "Nothing to pause", card: "There's no focus block running.", spoken: "There's no focus block running.")
            }
            session.hold()
            return StudyLoop.Reply(subject: "Focus paused: \(session.title)", card: "Paused **\(session.title)** with \(session.clock) left. Say \"resume focus\" to carry on.",
                                   spoken: "Paused, \(Int((session.remaining / 60).rounded(.up))) minutes left.")
        case .resume:
            guard session.isPaused else {
                return StudyLoop.Reply(subject: "Nothing to resume", card: session.isRunning ? "**\(session.title)** is already running." : "There's no paused focus block.",
                                       spoken: session.isRunning ? "It's already running." : "There's no paused focus block.")
            }
            session.carryOn()
            return StudyLoop.Reply(subject: "Focus: \(session.title)", card: "Back to **\(session.title)**: \(session.clock) left.",
                                   spoken: "Back to \(session.title).")
        }
    }

    // MARK: - Running

    private func begin(_ plan: FocusPlan.Start, announce: Bool) {
        let wasOn = focusOn
        if isRunning { stopTimer() } // replaced: Focus stays on, the music keeps playing
        title = plan.title
        subject = plan.subject
        minutes = plan.minutes
        blockStart = plan.blockStart
        startedAt = Date()
        pausedLeft = nil
        endsAt = Date().addingTimeInterval(Double(plan.minutes) * 60)
        left = remaining
        startTimer()
        if !wasOn {
            focusOn = true
            Task.detached { FocusShortcuts.run(FocusShortcuts.on) }
        }
        let playlist = (UserDefaults.standard.string(forKey: FocusPlan.playlistKey) ?? "").trimmingCharacters(in: .whitespaces)
        if !playlist.isEmpty, !startedMusic {
            startedMusic = true
            Task.detached {
                let result = Spotify.run(.myPlaylist(playlist, shuffle: true))
                if !result.hasPrefix("▶") { _ = Spotify.run(.play(playlist, .playlist)) }
            }
        }
        if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "A focus block is running")
        }
        if announce { onNotice("Focus: \(plan.title) · \(plan.minutes) min") }
        onChange()
    }

    private func hold() {
        guard let endsAt else { return }
        pausedLeft = max(0, endsAt.timeIntervalSinceNow)
        self.endsAt = nil
        stopTimer()
        left = remaining
        onChange()
    }

    private func carryOn() {
        guard let pausedLeft else { return }
        endsAt = Date().addingTimeInterval(pausedLeft)
        self.pausedLeft = nil
        startTimer()
        left = remaining
        onChange()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let endsAt else { return }
        left = max(0, endsAt.timeIntervalSinceNow)
        if left <= 0 { end(finished: true) } else { onChange() }
    }

    /// Over: on time (`finished`: chime, tick the block, `onFinished`) or stopped early.
    private func end(finished: Bool) {
        guard isRunning else { return }
        let ended = title, endedSubject = subject, length = minutes, start = blockStart
        stopTimer()
        endsAt = nil
        pausedLeft = nil
        left = 0
        title = ""
        subject = nil
        blockStart = nil
        startedAt = nil
        if focusOn {
            focusOn = false
            Task.detached { FocusShortcuts.run(FocusShortcuts.off) }
        }
        if startedMusic {
            startedMusic = false
            Task.detached { _ = Spotify.run(.pause) }
        }
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        onChange()
        guard finished else { return }
        NSSound(named: "Hero")?.play()
        let ticked = FocusPlan.tickWeek(title: ended, start: start)
        onFinished(Ended(title: ended, subject: endedSubject, minutes: length, ticked: ticked))
    }
}

/// A focus request, said or typed: start (a Plan block, or a title and length), stop, pause, resume.
enum FocusRequest: Equatable {
    /// `title` nil: the Plan's current or next block. `minutes` nil: the block's own length (25 without one).
    case start(title: String?, minutes: Int?, untilEnd: Bool)
    case stop, pause, resume

    /// What `--route` prints.
    var route: String {
        switch self {
        case .start: "local (focus start)"
        case .stop: "local (focus stop)"
        case .pause: "local (focus pause)"
        case .resume: "local (focus resume)"
        }
    }

    /// What a block is called when said: "block", "study block", "focus (mode/session)", "pomodoro"…
    private static let block = #"((study|focus|revision|work)\s+)?block|focus(\s+(mode|session|timer))?|pomodoro"#

    static func parse(_ said: String) -> FocusRequest? {
        var text = said.replacingOccurrences(of: "’", with: "'").lowercased()
            .replacingOccurrences(of: #"^\W*((hey|ok|okay|yo),?\s+)?(joe,?\s+)?((can|could|would) you\s+|please\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(,?\s*(please|for me|thanks|thank you|joe))+\W*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s.!?]+$"#, with: "", options: .regularExpression)
        guard !text.isEmpty, text.count <= 100 else { return nil }
        text = AlarmRequest.numbers(in: " " + text + " ").trimmingCharacters(in: .whitespaces)
        // A "study session" on its own is the whiteboard's (quiz), not a timer.
        if text.range(of: #"\bstudy session\b"#, options: .regularExpression) != nil { return nil }

        let block = Self.block
        if text.range(of: #"^(stop|end|finish|cancel|quit|exit|leave|turn off|switch off|kill)\s+((the|my|this)\s+)?("# + block + #")(\s+(now|early))?$|^(focus(\s+mode)?)\s+off$|^(i'm|i am)\s+(done|finished)\s+focusing$"#,
                      options: .regularExpression) != nil { return .stop }
        if text.range(of: #"^(pause|hold)\s+((the|my|this)\s+)?("# + block + #")$"#, options: .regularExpression) != nil { return .pause }
        if text.range(of: #"^(resume|unpause|continue|restart)\s+((the|my|this)\s+)?("# + block + #")$"#, options: .regularExpression) != nil { return .resume }

        // The length: "for 50 min", "25 minutes", "an hour" (now "1 hour"), "50m"; or "until the block ends".
        var minutes: Int?
        if let range = text.range(of: #"\b(for\s+)?(\d{1,3})(\s*|-)(minutes?|mins?|m|hours?|hrs?|h)\b"#, options: .regularExpression) {
            let span = String(text[range])
            let number = Int(span.components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty } ?? "") ?? 0
            let hours = span.range(of: #"\d\s*-?\s*(hours?|hrs?|h)\b"#, options: .regularExpression) != nil
            minutes = hours ? number * 60 : number
            text.replaceSubrange(range, with: " ")
        }
        var untilEnd = false
        if let range = text.range(of: #"\b(until|till|til|to)\s+(the\s+end(\s+of\s+(the|my|this)\s+block)?|(the|my)\s+block\s+ends)\b"#, options: .regularExpression) {
            untilEnd = true
            text.replaceSubrange(range, with: " ")
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let minutes, !(1...240).contains(minutes) { return nil }

        // The Plan's block: "start my block", "start a study block", "start the next block", "focus mode on", "focus".
        let planned = #"^(let's\s+)?(start|begin|kick off|do|go)\s+(up\s+|into\s+|on\s+)?((my|the|a|an|this|next|another)\s+)?((next|current|planned)\s+)?(\d+\s*-?\s*(minutes?|mins?)\s+)?("#
            + block + #")(\s+now)?$|^(turn on|switch on|enter|go into)\s+(focus(\s+mode)?)$|^focus(\s+mode)?(\s+on|\s+now)?$|^(let's\s+)?focus$"#
        if text.range(of: planned, options: .regularExpression) != nil { return .start(title: nil, minutes: minutes, untilEnd: untilEnd) }
        // "Study for 50 minutes": only with a length (else it's a question for Claude).
        if minutes != nil, text.range(of: #"^(let's\s+)?(study|revise|work)(\s+now)?$"#, options: .regularExpression) != nil {
            return .start(title: nil, minutes: minutes, untilEnd: untilEnd)
        }

        // A title: "focus on Paper 2", "start a study block on taxes", "start my Paper 2 block".
        let titled = [
            #"^(let's\s+)?(focus|start focusing|focus mode)\s+(on|for)\s+(?<item>.+)$"#,
            #"^(let's\s+)?(start|begin|do)\s+((my|the|a|an)\s+)?("# + block + #")\s+(on|for)\s+(?<item>.+)$"#,
            #"^(let's\s+)?(start|begin|do)\s+((my|the|a|an)\s+)?(?<item>.+?)\s+((study|focus|revision)\s+)?block$"#,
        ]
        for pattern in titled {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(withName: "item"), in: text) else { continue }
            let item = String(text[range]).replacingOccurrences(of: #"^(the|my)\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if ["next", "current", "planned", "study", "focus", "first", "a", "an", "this", "it", "that"].contains(item) {
                return .start(title: nil, minutes: minutes, untilEnd: untilEnd)
            }
            guard !item.isEmpty, item.split(separator: " ").count <= 8, !item.contains(",") else { return nil }
            // In their own capitals ("Paper 2", "the EE outline") when it's word for word in what they said.
            var title = item.prefix(1).uppercased() + item.dropFirst()
            if let own = said.range(of: item, options: .caseInsensitive) { title = String(said[own]) }
            return .start(title: title, minutes: minutes, untilEnd: untilEnd)
        }
        return nil
    }
}

/// Where a focus block comes from: today's Plan (the Daybook's, or Week.md's day when the Daybook
/// isn't today's), and ticking its Week.md line at the end. Works off the main thread (the CLI).
enum FocusPlan {
    /// A setting: the Spotify playlist (one of theirs, by name) to play during a block. Unset: no music.
    static let playlistKey = "focusPlaylist"

    /// A study block on today's Plan.
    struct Block {
        var title: String
        var subject: String?
        var label: String
        var start: Date
        var end: Date
        var startText: String
    }

    /// What a request starts: its title, subject and length, and the Plan block it is (if any).
    struct Start {
        var title: String
        var subject: String?
        var minutes: Int
        var blockStart: String?
        /// "16:10–17:40 after-school block", for the card.
        var block: String?
    }

    /// Today's blocks, open ones only, in time order.
    static func todayBlocks(_ now: Date = Date()) -> [Block] {
        let today = now.formatted(.localDay)
        let daybook = Daybook.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if daybook.contains("date: \(today)") {
            let found = Daybook.section("Plan", of: daybook).compactMap { block($0, on: now) }
            if !found.isEmpty { return found.sorted { $0.start < $1.start } }
        }
        let week = WeekPlan.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        var inside = false
        var found: [Block] = []
        for line in week.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inside = line.hasSuffix(today); continue }
            if inside, let block = block(line, on: now) { found.append(block) }
        }
        return found.sorted { $0.start < $1.start }
    }

    /// "- 16:10–17:40 (after school): get ahead on Taxes · Economics — due Fri" (a Daybook Plan
    /// line, or an open Week.md one) as a block on `day`. Nil for anything else, or a ticked one.
    static func block(_ line: String, on day: Date) -> Block? {
        guard !line.contains("~~"),
              let range = line.range(of: #"^- (\[ \] )?\d{2}:\d{2}–\d{2}:\d{2} \("#, options: .regularExpression),
              let title = WeekPlan.blockTitle(line), !title.isEmpty else { return nil }
        let times = line[range].components(separatedBy: CharacterSet(charactersIn: "0123456789:").inverted)
            .filter { $0.contains(":") }
        guard times.count == 2 else { return nil }
        func at(_ text: String) -> Date? {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
        }
        guard let start = at(times[0]), let end = at(times[1]), end > start,
              let open = line.range(of: " ("), let close = line.range(of: "): ") else { return nil }
        let label = String(line[open.upperBound..<close.lowerBound])
        // " · Economics" after the title, before " — due …".
        let rest = String(line[close.upperBound...]).replacingOccurrences(of: #" · moved from .*$"#, with: "", options: .regularExpression)
        let parts = (rest.components(separatedBy: " — ").first ?? rest).components(separatedBy: " · ")
        let subject = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        return Block(title: title, subject: subject == "project" ? nil : subject, label: label, start: start, end: end, startText: times[0])
    }

    /// Minutes from `now` to `date`, at least 1.
    private static func minutes(until date: Date, from now: Date) -> Int {
        max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// What to start. No title: the block on now (until its end) or the next one today (its
    /// length; with a length said, only one starting within half an hour). A title: that, matched
    /// to a Plan block of the same name when there is one. Without either, a 25-minute block.
    static func resolve(title: String?, minutes said: Int?, untilEnd: Bool, now: Date = Date()) -> Start {
        let blocks = todayBlocks(now)
        let current = blocks.first { $0.start <= now && now < $0.end }
        var chosen: Block?
        if let title {
            chosen = blocks.filter { $0.end > now }.first { block in
                Daybook.sameTask(block.title, title) || StudyLoop.words(title).isSubset(of: StudyLoop.words(block.title))
                    && !StudyLoop.words(title).isEmpty
            }
        } else {
            let next = blocks.first { block in
                block.start > now && (said == nil || block.start.timeIntervalSince(now) <= 30 * 60)
            }
            chosen = current ?? next
        }
        var length: Int
        if let said, !untilEnd {
            length = said
        } else if let chosen {
            length = chosen.start <= now ? minutes(until: chosen.end, from: now) : minutes(until: chosen.end, from: chosen.start)
        } else {
            length = said ?? 25
        }
        length = min(max(length, 1), 240)
        let name = title ?? chosen?.title ?? "Study block"
        let subject = chosen?.subject ?? title.flatMap { StudyIntent.subject(in: $0.lowercased())?.name }
        let description = chosen.map { "\($0.startText)–\(Daybook.hhmm($0.end)) \($0.label) block" }
        return Start(title: name, subject: subject, minutes: length, blockStart: chosen?.startText, block: description)
    }

    /// Ticks today's Week.md block for `title` (the one at `start` when given). False when the
    /// week plan has no such open block today.
    @discardableResult
    static func tickWeek(title: String, start: String?, on day: Date = Date()) -> Bool {
        guard let url = WeekPlan.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let today = day.formatted(.localDay)
        var lines = text.components(separatedBy: "\n")
        var inside = false
        var candidates: [Int] = []
        for index in lines.indices {
            let line = lines[index]
            if line.hasPrefix("## ") { inside = line.hasSuffix(today); continue }
            guard inside, line.hasPrefix("- [ ] "), let other = WeekPlan.blockTitle(line) else { continue }
            if other.lowercased() == title.lowercased() || Daybook.sameTask(other, title) { candidates.append(index) }
        }
        guard let index = candidates.first(where: { start != nil && lines[$0].dropFirst(6).hasPrefix(start ?? "") }) ?? candidates.first else { return false }
        lines[index] = "- [x] " + String(lines[index].dropFirst(6))
        return (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// `--focus-preview "<request>"`: what it would start, without starting it.
    static func preview(_ said: String, now: Date = Date()) -> String {
        guard let request = FocusRequest.parse(said) else { return "Not a focus request: it goes elsewhere." }
        let shortcut = FocusShortcuts.available().contains(FocusShortcuts.on)
        let off = FocusShortcuts.available().contains(FocusShortcuts.off)
        guard case let .start(title, minutes, untilEnd) = request else {
            return "\(request.route)\nShortcut \"\(FocusShortcuts.off)\": " + (off ? "present (would run)" : "missing (skipped)")
        }
        let plan = resolve(title: title, minutes: minutes, untilEnd: untilEnd, now: now)
        let playlist = UserDefaults.standard.string(forKey: playlistKey) ?? ""
        return """
            \(request.route)
            Title: \(plan.title)
            Subject: \(plan.subject ?? "(none)")
            Minutes: \(plan.minutes), until \(Daybook.hhmm(now.addingTimeInterval(Double(plan.minutes) * 60)))
            Plan block: \(plan.block ?? "(none)")
            Shortcut "\(FocusShortcuts.on)": \(shortcut ? "present (would run)" : "missing (skipped)")
            Shortcut "\(FocusShortcuts.off)": \(off ? "present (runs at the end)" : "missing (skipped)")
            Music: \(playlist.isEmpty ? "off (no \(playlistKey) set)" : "the \"\(playlist)\" playlist")
            At the end: a chime, "Block done", \(plan.blockStart == nil ? "nothing to tick in Week.md" : "tick the \(plan.blockStart ?? "") block in Week.md"), and offer "Quick 3-question check on \(plan.title)"
            """
    }
}

/// The macOS Focus, through the student's own shortcuts ("Joe Focus On", "Joe Focus Off"): there's
/// no public API to turn a Focus on. `shortcuts list` is read once; a missing one is skipped silently.
enum FocusShortcuts {
    static let on = "Joe Focus On"
    static let off = "Joe Focus Off"
    private static let lock = NSLock()
    private static var cached: Set<String>?

    /// The shortcut names, if they've been read yet (for the card, without waiting).
    static var known: Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// The shortcut names (read once with `shortcuts list`; empty when it can't run).
    static func available() -> Set<String> {
        if let known { return known }
        let names = Set((output(["list"]) ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        lock.lock()
        cached = names
        lock.unlock()
        return names
    }

    /// Runs the shortcut if they have it (blocks until it's done: call off the main thread).
    static func run(_ name: String) {
        guard available().contains(name) else { return }
        _ = output(["run", name])
    }

    private static func output(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
