import EventKit

/// Joe's alarms and reminders copied into Apple Reminders (a "Joe" list), so they ring on the
/// iPhone too when the laptop is closed. Timers stay on the Mac. A copy is ticked off when its
/// alarm rings, and removed when the alarm is cancelled before then. Only Joe's own copies are
/// ever touched.
enum ReminderMirror {
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "alarmsToReminders") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "alarmsToReminders") }
    }

    static let store = EKEventStore()
    static let queue = DispatchQueue(label: "Joe.reminders")
    private static let listName = "Joe"
    /// Alarm id → "reminder id|time it was due".
    private static var copies: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "reminderCopies") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "reminderCopies") }
    }

    /// Brings the Joe list in line with the alarms (called when the alarm file changes).
    static func sync(_ alarms: [Alarm]) {
        guard isOn else { return }
        queue.async {
            guard allowed() else { return }
            let wanted = alarms.filter { $0.kind != .timer }
            var copies = self.copies
            for alarm in wanted where copies[alarm.id.uuidString] == nil {
                if let id = add(alarm) { copies[alarm.id.uuidString] = "\(id)|\(alarm.fireAt.timeIntervalSince1970)" }
            }
            let live = Set(wanted.map(\.id.uuidString))
            for (alarmID, value) in copies where !live.contains(alarmID) {
                let parts = value.split(separator: "|")
                if let reminder = store.calendarItem(withIdentifier: String(parts[0])) as? EKReminder {
                    let due = Date(timeIntervalSince1970: Double(parts.last ?? "") ?? 0)
                    // Ticking off a repeating reminder only moves it to its next day, so a cancelled
                    // daily alarm kept ringing on the iPhone: those are removed instead.
                    if due <= Date().addingTimeInterval(60), !reminder.hasRecurrenceRules {
                        reminder.isCompleted = true // it rang
                        try? store.save(reminder, commit: true)
                    } else {
                        try? store.remove(reminder, commit: true) // cancelled
                    }
                }
                copies[alarmID] = nil
            }
            self.copies = copies
        }
    }

    /// Asks once for Reminders access (macOS shows its prompt), then remembers the answer.
    static func allowed() -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized: return true
        case .notDetermined:
            let done = DispatchSemaphore(value: 0)
            var granted = false
            store.requestFullAccessToReminders { ok, _ in granted = ok; done.signal() }
            done.wait()
            return granted
        default: return false
        }
    }

    static func list(_ name: String = listName) -> EKCalendar? {
        if let joe = store.calendars(for: .reminder).first(where: { $0.title == name }) { return joe }
        guard let source = store.defaultCalendarForNewReminders()?.source else { return nil }
        let joe = EKCalendar(for: .reminder, eventStore: store)
        joe.title = name
        joe.source = source
        return (try? store.saveCalendar(joe, commit: true)) != nil ? joe : store.defaultCalendarForNewReminders()
    }

    private static func add(_ alarm: Alarm) -> String? {
        guard let calendar = list() else { return nil }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = alarm.title.isEmpty ? "Alarm" : alarm.title
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: alarm.fireAt)
        reminder.addAlarm(EKAlarm(absoluteDate: alarm.fireAt))
        if let days = alarm.repeatDays {
            let weekdays = days.sorted().compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } }
            reminder.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: days.count == 7 ? .daily : .weekly, interval: 1,
                daysOfTheWeek: days.count == 7 ? nil : weekdays, daysOfTheMonth: nil, monthsOfTheYear: nil,
                weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil))
        }
        reminder.notes = "Set by Joe on your Mac."
        guard (try? store.save(reminder, commit: true)) != nil else { return nil }
        return reminder.calendarItemIdentifier
    }
}

/// Asking Joe from the iPhone, with nothing to install: "Hey Siri, add 'what's due tomorrow' to
/// Ask Joe" puts a reminder in the "Ask Joe" list, iCloud brings it to the Mac, Joe runs it in
/// the background, ticks it off and answers with a "Joe: …" reminder that alerts on the phone.
/// Only while the Mac is awake with Joe running; requests wait in the list until then.
@MainActor
final class PhoneRemote {
    static let listName = "Ask Joe"
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "phoneRemote") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "phoneRemote") }
    }
    private static let answerMark = "Answered by Joe"

    /// Runs a request in the background and calls back with the answer (or the error).
    var run: (_ request: String, _ done: @escaping (String) -> Void) -> Void = { _, _ in }
    private var working: Set<String> = []
    private var lastCheck = Date.distantPast

    /// Every few seconds from the clock tick; looks at the list every 15 seconds.
    func check() {
        guard Self.isOn, Date().timeIntervalSince(lastCheck) > 15 else { return }
        lastCheck = Date()
        let store = ReminderMirror.store
        ReminderMirror.queue.async {
            guard EKEventStore.authorizationStatus(for: .reminder) != .denied, ReminderMirror.allowed(),
                  let list = ReminderMirror.list(Self.listName) else { return }
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
            store.fetchReminders(matching: predicate) { reminders in
                let asks = (reminders ?? []).filter { !($0.notes ?? "").contains(Self.answerMark) && !($0.title ?? "").isEmpty }
                    .map { (id: $0.calendarItemIdentifier, text: [$0.title ?? "", $0.notes ?? ""].filter { !$0.isEmpty }.joined(separator: ". ")) }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.start(asks) } }
            }
        }
    }

    private func start(_ asks: [(id: String, text: String)]) {
        for ask in asks where !working.contains(ask.id) {
            working.insert(ask.id)
            let request = "[From their iPhone, through the Ask Joe list in Reminders: they're away from the Mac, so answer in a few plain sentences and don't touch the screen unless they ask.] \(ask.text)"
            run(request) { [weak self] answer in
                Self.answer(ask.id, answer)
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { MainActor.assumeIsolated { _ = self?.working.remove(ask.id) } }
            }
        }
    }

    /// Ticks the request off and adds the answer as a reminder that alerts in a few seconds.
    private nonisolated static func answer(_ id: String, _ text: String) {
        let store = ReminderMirror.store
        ReminderMirror.queue.async {
            guard let request = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
            request.isCompleted = true
            request.notes = [request.notes, "\(answerMark): \(text)"].compactMap { $0 }.joined(separator: "\n\n")
            try? store.save(request, commit: false)
            let parts = text.components(separatedBy: "\n")
            let reply = EKReminder(eventStore: store)
            reply.calendar = request.calendar
            reply.title = "Joe: " + String(parts[0].prefix(120))
            reply.notes = parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n\(answerMark) (\(request.title ?? ""))"
            reply.addAlarm(EKAlarm(absoluteDate: Date().addingTimeInterval(10)))
            try? store.save(reply, commit: false)
            try? store.commit()
        }
    }
}
