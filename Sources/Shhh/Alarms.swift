import AppKit
import AVFoundation
import SwiftUI

/// Alarms, timers and reminders, on the Mac: "set a timer for 5 minutes", "set an alarm for 6:30
/// called econ quiz", "remind me in 20 minutes to call Ammiel". Kept in a small file, so the
/// assistant (`Shhh --alarm …`) and the app share them. When one is due it rings: a loud repeating
/// beep (Spotify paused, the volume raised if it's low) and a card with Stop and Snooze, until the
/// user stops it, says "stop" or "snooze", or three minutes pass.
struct Alarm: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case alarm, timer, reminder }
    var id = UUID()
    var fireAt: Date
    var title: String
    var kind: Kind
    /// Which days it rings again: "daily", "weekdays", "weekends", or days like "mon,wed,fri".
    var repeats: String? = nil

    /// The weekdays it repeats on (1 = Sunday … 7 = Saturday), or nil for a one-off.
    var repeatDays: Set<Int>? {
        guard let repeats = repeats?.lowercased() else { return nil }
        switch repeats {
        case "daily", "every day": return Set(1...7)
        case "weekdays": return [2, 3, 4, 5, 6]
        case "weekends": return [1, 7]
        default:
            let names = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
            let days = Set(repeats.split(whereSeparator: { !$0.isLetter }).compactMap { names[String($0.prefix(3))] })
            return days.isEmpty ? nil : days
        }
    }

    /// The next time a repeating alarm rings after `date`.
    func next(after date: Date) -> Date? {
        guard let days = repeatDays else { return nil }
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: fireAt)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                  let candidate = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day),
                  candidate > date, days.contains(calendar.component(.weekday, from: candidate)) else { continue }
            return candidate
        }
        return nil
    }

    /// "6:30", or "Sat 6:30" when it isn't today.
    var when: String {
        let time = fireAt.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(fireAt) ? time : fireAt.formatted(.dateTime.weekday(.abbreviated)) + " " + time
    }
}

// MARK: - Storage

enum AlarmStore {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/Alarms.json")

    static func load() -> [Alarm] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? Data(contentsOf: url)).flatMap { try? decoder.decode([Alarm].self, from: $0) } ?? []).sorted { $0.fireAt < $1.fireAt }
    }

    static func save(_ alarms: [Alarm]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(alarms.sorted { $0.fireAt < $1.fireAt }).write(to: url, options: .atomic)
    }

    static func add(_ alarm: Alarm) {
        UndoJournal.add(["alarm", alarm.id.uuidString, alarm.title]) // for "undo that"
        save(load() + [alarm])
    }

    /// Cancels the ones whose title contains `words` (all of them for nil). Returns how many.
    @discardableResult
    static func cancel(matching words: String?, kind: Alarm.Kind? = nil) -> Int {
        let all = load()
        let keep = all.filter { alarm in
            if let kind, alarm.kind != kind { return true }
            guard let words, !words.isEmpty else { return false }
            // "cancel my 6:45 alarm": by its time, as well as by its title.
            let time = alarm.fireAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
            let hasTime = words.range(of: #"\d{1,2}[:.]\d{2}"#, options: .regularExpression) != nil
            let spokenTime = words.replacingOccurrences(of: ".", with: ":").replacingOccurrences(of: #"\s*(am|pm)"#, with: "", options: .regularExpression)
            if hasTime, time.hasSuffix(spokenTime) || alarm.when.replacingOccurrences(of: ".", with: ":").contains(spokenTime) { return false }
            return !alarm.title.lowercased().contains(words.lowercased())
        }
        save(keep)
        return all.count - keep.count
    }

    static var summary: String {
        let alarms = load()
        guard !alarms.isEmpty else { return "No alarms or timers set." }
        return alarms.prefix(4).map { alarm in
            let left = alarm.kind == .timer ? " (\(remaining(alarm.fireAt)) left)" : ""
            let again = alarm.repeats.map { " (\($0))" } ?? ""
            return "\(alarm.when) \(alarm.title)\(left)\(again)"
        }.joined(separator: " · ") + (alarms.count > 4 ? " · +\(alarms.count - 4) more" : "")
    }

    static func remaining(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}

// MARK: - Understanding a request

enum AlarmRequest {
    case add(Alarm)
    case list
    case cancel(String?, Alarm.Kind?)

    /// A spoken alarm, timer or reminder request, or nil (it goes to the assistant as usual).
    static func parse(_ request: String, now: Date = Date()) -> AlarmRequest? {
        var text = " " + request.lowercased()
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\W*((hey|ok|okay|yo)\W+)?(joe\W+)?((can|could|would) you\W+|please\W+|i need you to\W+)*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\W+(please|thanks|thank you|joe)$"#, with: "", options: .regularExpression) + " "
        text = numbers(in: text)
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if trimmed.range(of: #"^(cancel|delete|remove|turn off|clear|stop|get rid of) (all )?(my |the |all my |that |this )?(alarms?|timers?|reminders?)\b"#, options: .regularExpression) != nil {
            let kind: Alarm.Kind? = trimmed.contains("timer") ? .timer : trimmed.contains("reminder") ? .reminder : trimmed.contains("alarm") ? .alarm : nil
            let rest = trimmed.replacingOccurrences(of: #"^.*?(alarms?|timers?|reminders?)\s*((for|called|named|titled|about)\s+)?"#, with: "", options: .regularExpression)
            return .cancel(rest.isEmpty || rest == "all" ? nil : rest, trimmed.contains("all") ? nil : kind)
        }
        // "Cancel the pasta timer", "delete my gym alarm".
        if let regex = try? NSRegularExpression(pattern: #"^(?:cancel|delete|remove|turn off|stop) (?:the |my |that )?(.+?) (alarm|timer|reminder)$"#),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let words = Range(match.range(at: 1), in: trimmed), let kind = Range(match.range(at: 2), in: trimmed) {
            return .cancel(String(trimmed[words]), Alarm.Kind(rawValue: String(trimmed[kind])))
        }
        if trimmed.range(of: #"^((what|which|any) (alarms|timers|reminders)|(list|show)( me)? (my |the )?(alarms|timers|reminders)|(do i have|have i got) (any )?(alarms|timers|reminders)|how (long|much time)( is)? left)"#, options: .regularExpression) != nil {
            return .list
        }

        // It has to ask for one: "set/start an alarm/timer", "remind me", "wake me up", "timer for…".
        let kind: Alarm.Kind
        // Relative to something only the assistant can look up ("30 minutes before my econ class").
        if trimmed.range(of: #"\b(before|after|until|ahead of|when)\b (?!\d)"#, options: .regularExpression) != nil { return nil }
        if trimmed.range(of: #"^(set|start|make|create|put|add|give me)( up)?( me)?( an?| another)? (\d+[ -]?(second|minute|hour|min)s?[ -])?timer\b|^timer( for| of)?\b|^\d+[ -]?(minute|hour|second|min)s? timer"#, options: .regularExpression) != nil {
            kind = .timer
        } else if trimmed.range(of: #"^(set|make|create|put|add|give me)( up)?( me)?( an?| another)? alarm\b|^wake me( up)?\b|^alarm (for|at|in)\b"#, options: .regularExpression) != nil {
            kind = .alarm
        } else if trimmed.range(of: #"^remind me\b|^(set|make|create|add)( me)?( an?)? reminder\b"#, options: .regularExpression) != nil {
            kind = .reminder
        } else {
            return nil
        }

        var fireAt: Date?
        var spans: [Range<String.Index>] = [] // the time words, left out of the title
        // A length of time: "in 5 minutes", "for an hour and a half", "20 min", "1 hour 30 minutes".
        let unit = #"(seconds?|secs?|minutes?|mins?|hours?|hrs?|h|m)\b"#
        if let range = text.range(of: #"\b(in|for|after)?\s*(\d+(?:\.\d+)?)\s*"# + unit + #"(\s*(and\s*)?(\d+)\s*(minutes?|mins?|seconds?|secs?))?(\s+and a half)?"#, options: .regularExpression) {
            let span = String(text[range])
            let numbers = span.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).filter { !$0.isEmpty }.compactMap(Double.init)
            let multiplier = { (word: String) -> Double in
                word.hasPrefix("h") ? 3600 : word.hasPrefix("s") ? 1 : 60
            }
            let words = span.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            let units = words.filter { $0.range(of: "^" + unit, options: .regularExpression) != nil }
            var seconds = 0.0
            for (index, number) in numbers.enumerated() where index < units.count { seconds += number * multiplier(units[index]) }
            if span.contains("and a half"), let first = units.first { seconds += 0.5 * multiplier(first) }
            if seconds > 0 {
                fireAt = now.addingTimeInterval(seconds)
                spans.append(range)
            }
        }
        // A time of day: "at 6:30", "for 7am", "7 pm", "noon", "tomorrow at 6".
        if fireAt == nil {
            var hour: Int?, minute = 0, meridiem: String?
            if let range = text.range(of: #"\b(at|for|by)?\s*(noon|midday|midnight)\b"#, options: .regularExpression) {
                hour = text[range].contains("midnight") ? 0 : 12
                meridiem = "set"
                spans.append(range)
            } else if let range = text.range(of: #"\b(at|for|by)?\s*(half past|quarter past|quarter to)\s+(\d{1,2})\b(\s*(am|pm|a\.m\.|p\.m\.))?"#, options: .regularExpression) {
                let span = String(text[range])
                let number = Int(span.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
                hour = span.contains("quarter to") ? number - 1 : number
                minute = span.contains("half past") ? 30 : span.contains("quarter past") ? 15 : 45
                meridiem = span.contains("p") && span.range(of: #"p\.?m"#, options: .regularExpression) != nil ? "pm" : span.range(of: #"a\.?m"#, options: .regularExpression) != nil ? "am" : nil
                spans.append(range)
            } else if let range = text.range(of: #"\b(at|for|by)\s*(\d{1,2})(:(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?|\b(\d{1,2})(:(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)|\b(\d{1,2}):(\d{2})\b"#, options: .regularExpression) {
                let span = String(text[range])
                let digits = span.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
                hour = digits.first.flatMap(Int.init)
                minute = digits.count > 1 ? Int(digits[1]) ?? 0 : 0
                meridiem = span.range(of: #"p\.?m"#, options: .regularExpression) != nil ? "pm" : span.range(of: #"a\.?m"#, options: .regularExpression) != nil ? "am" : nil
                spans.append(range)
            }
            if var hour, hour >= 0, hour <= 23, minute < 60 {
                if meridiem == "pm", hour < 12 { hour += 12 }
                if meridiem == "am", hour == 12 { hour = 0 }
                let calendar = Calendar.current
                var day = now
                if let range = text.range(of: #"\btomorrow\b"#, options: .regularExpression) {
                    day = calendar.date(byAdding: .day, value: 1, to: now) ?? now
                    spans.append(range)
                }
                var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? now
                if date <= now {
                    // "at 7" at 3 pm means 7 pm; otherwise the same time tomorrow.
                    if meridiem == nil, hour < 12, let evening = calendar.date(byAdding: .hour, value: 12, to: date), evening > now {
                        date = evening
                    } else {
                        date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
                    }
                }
                fireAt = date
            }
        }
        guard var fireAt else { return nil } // no time it could read: the assistant works it out

        // "Every weekday", "every day", "on weekends", "every monday and wednesday".
        var repeats: String?
        if let range = text.range(of: #"\b(every ?day|daily|each day|every (week)?day|on weekdays|weekdays|every morning|every school day|on weekends|weekends|every weekend|every (mon|tue|wed|thu|fri|sat|sun)\w*( and (mon|tue|wed|thu|fri|sat|sun)\w*)*)\b"#, options: .regularExpression) {
            let span = String(text[range])
            repeats = span.contains("weekend") ? "weekends"
                : span.contains("weekday") || span.contains("school") ? "weekdays"
                : span.contains("day") && !span.contains("mon") && !span.contains("tue") && !span.contains("wed") && !span.contains("thu") && !span.contains("fri") && !span.contains("sat") && !span.contains("sun") || span.contains("daily") || span.contains("morning") ? "daily"
                : span
            spans.append(range)
        }


        // The title: "called econ quiz", "remind me to call Ammiel", "…to check the oven", "timer for pasta".
        var rest = text
        for span in spans.sorted(by: { $0.lowerBound > $1.lowerBound }) { rest.replaceSubrange(span, with: " ") }
        rest = rest.replacingOccurrences(of: #"^\s*(set|start|make|create|put|add|give me)( up)?( me)?( an?| another)?\s*(alarm|timer|reminder)?|^\s*remind me|^\s*wake me( up)?|^\s*(alarm|timer)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b(today|tonight|this (morning|afternoon|evening)|from now|on my mac|please)\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        rest = rest.replacingOccurrences(of: #"\btimer\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        if let labelled = rest.range(of: #"\b(called|titled|named|labell?ed|saying|that says|about)\s+"#, options: .regularExpression) {
            rest = String(rest[labelled.upperBound...])
        } else {
            rest = rest.replacingOccurrences(of: #"^(that |so )?(i need to |i have to |i've got to |i gotta )?(to |for |so i can |so i )"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^(to|for)\s+"#, with: "", options: .regularExpression)
        }
        rest = rest.replacingOccurrences(of: #"^(i need to|i have to|i've got to|i gotta|that i need to|that i have to)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        rest = rest.replacingOccurrences(of: #"^(i need to|i have to|i've got to|i gotta|that i need to|that i have to)\s+"#, with: "", options: .regularExpression)
        let fallback = ["alarm": "Alarm", "timer": "Timer", "reminder": "Reminder"][kind.rawValue]!
        // In their own capitals ("Call Ammiel", "the EE form"), when it's word for word in what they said.
        if let original = request.range(of: rest, options: .caseInsensitive) { rest = String(request[original]) }
        let title = rest.isEmpty ? fallback : rest.prefix(1).uppercased() + rest.dropFirst()
        var alarm = Alarm(fireAt: fireAt, title: String(title.prefix(80)), kind: kind, repeats: repeats)
        // A repeating one starts on its first matching day.
        if alarm.repeatDays != nil, let days = alarm.repeatDays, !days.contains(Calendar.current.component(.weekday, from: fireAt)),
           let first = alarm.next(after: fireAt.addingTimeInterval(-1)) {
            fireAt = first
            alarm.fireAt = first
        }
        return .add(alarm)
    }

    /// "five minutes" → "5 minutes", "an hour" → "1 hour", "half an hour" → "30 minutes".
    private static func numbers(in text: String) -> String {
        var text = text
            .replacingOccurrences(of: #"\bhalf an? hour\b"#, with: "30 minutes", options: .regularExpression)
            .replacingOccurrences(of: #"\ban? (hour|minute|second)\b"#, with: "1 $1", options: .regularExpression)
            .replacingOccurrences(of: #"\ba couple (of )?(minutes|hours)\b"#, with: "2 $2", options: .regularExpression)
            .replacingOccurrences(of: #"\ba few minutes\b"#, with: "3 minutes", options: .regularExpression)
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
                     "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
                     "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90]
        for (word, number) in words.sorted(by: { $0.key.count > $1.key.count }) {
            text = text.replacingOccurrences(of: #"\b"# + word + #"\b"#, with: String(number), options: .regularExpression)
        }
        // "twenty five" → "20 5" → "25"
        return text.replacingOccurrences(of: #"\b([2-9])0 ([1-9])\b"#, with: "$1$2", options: .regularExpression)
    }

    /// While an alarm rings: "stop", "turn it off", "I'm up" → stop; "snooze (for 10 minutes)" → snooze.
    static func ringingCommand(_ request: String) -> (stop: Bool, snoozeMinutes: Int)? {
        let text = request.lowercased().trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            .replacingOccurrences(of: #"^((hey|ok|okay)\W+)?(joe\W+)?"#, with: "", options: .regularExpression)
        if text.range(of: #"\bsnooze\b"#, options: .regularExpression) != nil {
            let minutes = Int(numbers(in: " " + text + " ").components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty } ?? "") ?? 5
            return (false, min(max(minutes, 1), 60))
        }
        if text.range(of: #"^(stop|turn (it )?off|dismiss|ok|okay|i'?m up|i'?m awake|shut up|enough|done|got it|thanks|thank you|stop (it|that|the alarm|the timer|ringing))\b"#, options: .regularExpression) != nil {
            return (true, 0)
        }
        return nil
    }
}

// MARK: - Ringing

@MainActor
final class AlarmClock {
    /// Said when an alarm is added, cancelled or listed (a toast).
    var onNotice: (String) -> Void = { _ in }

    private(set) var ringing: Alarm?
    private var known: [Alarm] = []
    private var modified: Date?
    private var modifiedShown: Date? = .distantPast
    private var awake: NSObjectProtocol?
    private let model = AlarmModel()
    private var panel: NSPanel?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var stopWork: DispatchWorkItem?
    private var resumeSpotify = false
    private var volumeBefore: Int?

    init() {
        model.onStop = { [weak self] in self?.stop() }
        model.onSnooze = { [weak self] in self?.snooze(minutes: 5) }
    }

    var isRinging: Bool { ringing != nil }

    /// The alarms still to come, soonest first.
    var pending: [Alarm] { known }

    /// An alarm stopped by the user (not snoozed, not missed): for a focus timer's wrap-up.
    var onStopped: (Alarm) -> Void = { _ in }

    /// Fires each second while alarms are pending (and once when the last goes), for the side notch.
    var onChange: () -> Void = {}

    func cancel(id: UUID) {
        AlarmStore.save(AlarmStore.load().filter { $0.id != id })
        tick()
    }

    /// Every second: picks up alarms added elsewhere, and rings the one that's due.
    func tick() {
        let stamp = (try? AlarmStore.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if stamp != modified {
            modified = stamp
            known = AlarmStore.load()
            stayAwake(!known.isEmpty)
            ReminderMirror.sync(known)
        }
        if !known.isEmpty || stamp != modifiedShown {
            modifiedShown = stamp
            onChange() // countdowns tick, and the side notch empties when the last one goes
        }
        guard ringing == nil, let due = known.first, due.fireAt <= Date() else { return }
        known.removeFirst()
        // A repeating one goes back in for its next day.
        if let next = due.next(after: Date()) {
            var again = due
            again.fireAt = next
            known.append(again)
            known.sort { $0.fireAt < $1.fireAt }
        }
        AlarmStore.save(known)
        modified = (try? AlarmStore.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        stayAwake(!known.isEmpty)
        ring(due)
    }

    /// A pending alarm keeps the Mac from idling to sleep and Shhh out of App Nap, so it rings on time.
    private func stayAwake(_ yes: Bool) {
        if yes, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "An alarm is set")
        } else if !yes, let activity = awake {
            ProcessInfo.processInfo.endActivity(activity)
            awake = nil
        }
    }

    func handle(_ request: AlarmRequest) {
        switch request {
        case let .add(alarm):
            AlarmStore.add(alarm)
            tick()
            let left = alarm.kind == .alarm ? "" : " (in \(AlarmStore.remaining(alarm.fireAt)))"
            onNotice("\(alarm.kind == .timer ? "Timer" : alarm.kind == .reminder ? "Reminder" : "Alarm") \(alarm.when)\(left): \(alarm.title)")
        case .list:
            onNotice(AlarmStore.summary)
        case let .cancel(words, kind):
            let count = AlarmStore.cancel(matching: words, kind: kind)
            tick()
            onNotice(count == 0 ? "No matching alarms" : "Cancelled \(count) \(count == 1 ? (kind?.rawValue ?? "alarm") : (kind?.rawValue ?? "alarm") + "s")")
        }
    }

    // MARK: Ring, stop, snooze

    private func ring(_ alarm: Alarm) {
        ringing = alarm
        model.alarm = alarm
        showPanel()
        // Music off while it rings; the volume up if it's low, so it's heard.
        if script("tell application \"System Events\" to (name of processes) contains \"Spotify\"") == "true",
           script("tell application \"Spotify\" to player state as string") == "playing" {
            _ = script("tell application \"Spotify\" to pause")
            resumeSpotify = true
        }
        if let volume = script("output volume of (get volume settings)").flatMap(Int.init), volume < 60 {
            volumeBefore = volume
            _ = script("set volume output volume 65")
        }
        _ = script("set volume without output muted")
        startBeeping(gentle: alarm.kind == .reminder)
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.stop(missed: true) } }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (alarm.kind == .reminder ? 20 : 180), execute: work)
    }

    func stop(missed: Bool = false) {
        guard let alarm = ringing else { return }
        ringing = nil
        stopWork?.cancel()
        player.stop()
        engine.stop()
        panel?.orderOut(nil)
        panel = nil
        if let volumeBefore { _ = script("set volume output volume \(volumeBefore)") }
        volumeBefore = nil
        if resumeSpotify { _ = script("tell application \"Spotify\" to play") }
        resumeSpotify = false
        // A reminder that rang out stays on screen as a toast; an alarm nobody stopped says so.
        if missed { onNotice(alarm.kind == .reminder ? "\(alarm.title)" : "Missed: \(alarm.title) (\(alarm.when))") }
        else if !snoozing { onStopped(alarm) }
        tick() // the next one, if it's due too
    }

    private var snoozing = false

    func snooze(minutes: Int) {
        guard var alarm = ringing else { return }
        snoozing = true
        stop()
        snoozing = false
        alarm.id = UUID()
        alarm.fireAt = Date().addingTimeInterval(Double(minutes) * 60)
        AlarmStore.add(alarm)
        tick()
        onNotice("Snoozed \(minutes) min: \(alarm.title)")
    }

    // MARK: Sound: beep-beep-beep-beep, pause, again

    private func startBeeping(gentle: Bool) {
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let beep = 0.11, gap = 0.07, rest = 0.55, count = gentle ? 2 : 4
        let length = Int(rate * (Double(count) * (beep + gap) + rest))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)) else { return }
        buffer.frameLength = AVAudioFrameCount(length)
        let samples = buffer.floatChannelData![0]
        for i in 0..<length {
            let t = Double(i) / rate
            let cycle = t.truncatingRemainder(dividingBy: beep + gap)
            let on = t < Double(count) * (beep + gap) && cycle < beep
            // A square-ish 2.6 kHz tone, like a clock radio: hard to sleep through.
            let tone = sin(2 * .pi * 2600 * t) + 0.3 * sin(2 * .pi * 5200 * t)
            let edge = min(1, min(cycle, beep - cycle) / 0.005) // no clicks
            samples[i] = on ? Float(tone * 0.42 * edge) : 0
        }
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        try? engine.start()
        player.scheduleBuffer(buffer, at: nil, options: gentle ? [] : .loops)
        if gentle { // a reminder: two short rounds, then quiet, the card stays
            player.scheduleBuffer(buffer, at: nil, options: [])
        }
        player.play()
    }

    private func script(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }

    // MARK: The card

    private func showPanel() {
        panel?.orderOut(nil)
        guard let screen = Notch.screenUnderMouse ?? NSScreen.main else { return }
        let size = NSSize(width: 440, height: 210)
        let frame = screen.visibleFrame
        let panel = NSPanel(contentRect: NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 40, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: AlarmView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

final class AlarmModel: ObservableObject {
    @Published var alarm: Alarm?
    var onStop: () -> Void = {}
    var onSnooze: () -> Void = {}
}

/// The ringing card, in the same style as the approval cards.
private struct AlarmView: View {
    @ObservedObject var model: AlarmModel
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.alarm?.kind == .timer ? "timer" : model.alarm?.kind == .reminder ? "bell.fill" : "alarm.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 40, height: 40)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .scaleEffect(pulse ? 1.08 : 0.94)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.alarm?.title ?? "Alarm")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(Date().formatted(date: .omitted, time: .shortened) + " · " + (model.alarm?.kind.rawValue.capitalized ?? "Alarm"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5)
            HStack(spacing: 10) {
                Text("Say “stop” or “snooze”").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.45))
                Spacer()
                Button("Snooze 5 min", action: model.onSnooze).buttonStyle(AlarmButton(prominent: false))
                Button("Stop", action: model.onStop).buttonStyle(AlarmButton(prominent: true))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.orange.opacity(pulse ? 0.9 : 0.3), lineWidth: 1.5))
        .padding(10)
        .environment(\.colorScheme, .dark)
        .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

private struct AlarmButton: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.7))
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background {
                if prominent { Capsule().fill(Color.orange) } else { Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1) }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
