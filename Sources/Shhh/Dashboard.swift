import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// Joe's own window: opening the app shows it. A sidebar like Claude's, and pages for the day
/// (Home), what was said (History), Routines, Alarms, Notes, the Dictionary, Spotify and Settings.
/// While it's open, Joe has a Dock icon; closed, it's back to the notch and the menu bar.
@MainActor
final class Dashboard: NSObject, NSWindowDelegate {
    let model: DashboardModel
    /// After Joe switches between a menu-bar app and a Dock app: put the notch band back in its place.
    var onModeChange: () -> Void = {}
    private var window: NSWindow?
    private var refresh: Timer?

    init(actions: DashboardModel.Actions) {
        model = DashboardModel(actions: actions)
    }

    func show(_ page: DashboardModel.Page? = nil) {
        if let page { model.page = page }
        model.reload()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Joe"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 860, height: 560)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: DashboardView(model: model))
            window.center()
            window.setFrameAutosaveName("JoeDashboard")
            self.window = window
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular) // a Dock icon, and "Joe" at the top left, while it's open
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in MainActor.assumeIsolated { self?.onModeChange() } }
        }
        // Come to the front even when asked from the menu bar or the notch (a background app's
        // plain activate() can be refused).
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                self?.window?.makeKeyAndOrderFront(nil)
            }
        }
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.reload() }
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        refresh?.invalidate()
        refresh = nil
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in MainActor.assumeIsolated { self?.onModeChange() } }
    }
}

// MARK: - Model

@MainActor
final class DashboardModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case home, history, routines, alarms, notes, dictionary, music, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: "Home"
            case .history: "History"
            case .routines: "Routines"
            case .alarms: "Alarms"
            case .notes: "Notes"
            case .dictionary: "Dictionary"
            case .music: "Spotify"
            case .settings: "Settings"
            }
        }
        var symbol: String {
            switch self {
            case .home: "house"
            case .history: "clock.arrow.circlepath"
            case .routines: "wand.and.stars"
            case .alarms: "alarm"
            case .notes: "note.text"
            case .dictionary: "character.book.closed"
            case .music: "music.note"
            case .settings: "gearshape"
            }
        }
    }

    /// What the dashboard asks the app to do (the things with side effects beyond a setting).
    struct Actions {
        var ask: (String) -> Void
        var status: () -> String
        var setVoice: (SpeechOutput.Engine) -> Void
        var setNaturalVoice: (String) -> Void
        var setNotch: (Bool) -> Void
        var setCleanup: (Bool) -> Void
        var setScreenControl: (Bool) -> Void
        var chooseVault: () -> Void
        var openNotepad: () -> Void
        var microphones: () -> [(uid: String, name: String)]
        var setEnglishOnly: (Bool) -> Void
        var cancelAlarm: (UUID) -> Void
        var addAlarm: (AlarmRequest) -> Void
    }

    let actions: Actions
    @Published var page: Page = .home
    @Published var activity: [Activity] = []
    @Published var stats = ActivityLog.Stats()
    @Published var focus: String?
    @Published var tasks: [(line: String, text: String, detail: String, done: Bool)] = []
    @Published var today: String?
    @Published var timeline: [Daybook.Slot] = []
    @Published var alarms: [Alarm] = []
    @Published var routines: [(name: String, trigger: String)] = []
    @Published var notes: [(title: String, kind: String, date: Date, url: URL)] = []
    @Published var nowPlaying: String?
    @Published var spotifyConnected = false
    @Published var spotifyBusy = false
    @Published var status = ""
    /// Bumped to make settings re-read their values.
    @Published var settingsVersion = 0

    init(actions: Actions) {
        self.actions = actions
    }

    /// Re-reads everything, but only publishes what changed: each change redraws the window, and
    /// redrawing a dozen times every two seconds starved the rest of the app.
    func reload() {
        let newActivity = Array(ActivityLog.load().reversed())
        if newActivity != activity {
            activity = newActivity
            stats = ActivityLog.stats(newActivity)
        }
        update(\.alarms, AlarmStore.load())
        update(\.status, actions.status())
        update(\.today, Daybook.today)
        update(\.timeline, Daybook.timeline())
        update(\.spotifyConnected, Spotify.Account.isConnected)
        loadDaybook()
        loadRoutines()
        loadNotes()
        if page == .music || page == .home {
            Task.detached {
                let playing = Spotify.current()
                await MainActor.run { if self.nowPlaying != playing { self.nowPlaying = playing } }
            }
        }
    }

    private func update<T: Equatable>(_ path: ReferenceWritableKeyPath<DashboardModel, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    // MARK: Daybook

    private func loadDaybook() {
        guard let url = Daybook.url, Daybook.isCurrent, let text = try? String(contentsOf: url, encoding: .utf8) else {
            update(\.focus, nil)
            if !tasks.isEmpty { tasks = [] }
            return
        }
        let lines = text.components(separatedBy: "\n")
        update(\.focus, lines.first { $0.hasPrefix("**Focus:**") }.map { $0.replacingOccurrences(of: "**Focus:**", with: "").trimmingCharacters(in: .whitespaces) })
        var inFive = false
        var found: [(String, String, String, Bool)] = []
        for line in lines {
            if line.hasPrefix("## ") { inFive = line.lowercased().contains("today's five") }
            guard inFive, line.hasPrefix("- ["), line.count > 6 else { continue }
            let done = line.hasPrefix("- [x]") || line.hasPrefix("- [X]")
            let body = String(line.dropFirst(6))
            let parts = body.components(separatedBy: " — ")
            found.append((line, parts[0], parts.dropFirst().joined(separator: " — "), done))
        }
        if found.map({ "\($0.0)\($0.3)" }) != tasks.map({ "\($0.line)\($0.done)" }) { tasks = found }
    }

    /// Ticks or unticks a task in Daybook.md (the same line Joe and Obsidian see).
    func toggle(_ line: String) {
        guard let url = Daybook.url, var text = try? String(contentsOf: url, encoding: .utf8),
              let range = text.range(of: line) else { return }
        let flipped = line.hasPrefix("- [ ]") ? "- [x]" + line.dropFirst(5) : "- [ ]" + line.dropFirst(5)
        text.replaceSubrange(range, with: flipped)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        loadDaybook()
    }

    // MARK: Routines and notes

    private func loadRoutines() {
        guard let url = Daybook.routinesURL, let text = try? String(contentsOf: url, encoding: .utf8) else { routines = []; return }
        let lines = text.components(separatedBy: "\n")
        let found = lines.indices.filter { lines[$0].hasPrefix("## ") }.map { i in
            let trigger = lines[(i + 1)...].prefix(2).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") } ?? ""
            return (name: String(lines[i].dropFirst(3)), trigger: trigger)
        }
        if found.map({ $0.name + $0.trigger }) != routines.map({ $0.name + $0.trigger }) { routines = found }
    }

    private func loadNotes() {
        guard let root = NoteSaver.root else { notes = []; return }
        var found: [(String, String, Date, URL)] = []
        for kind in NoteSaver.Kind.allCases {
            let folder = root.appendingPathComponent(kind.folder, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "md" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let title = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2} "#, with: "", options: .regularExpression)
                found.append((title, kind.label, date, file))
            }
        }
        let sorted = found.sorted { $0.2 > $1.2 }.prefix(40).map { $0 }
        if sorted.map({ $0.3.path + "\($0.2)" }) != notes.map({ $0.url.path + "\($0.date)" }) { notes = sorted }
    }

    func openInObsidian(_ url: URL) {
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url.path
        if let link = URL(string: "obsidian://open?path=\(path)"), NSWorkspace.shared.urlForApplication(toOpen: link) != nil {
            NSWorkspace.shared.open(link)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Spotify

    func music(_ command: Spotify.Command) {
        Task.detached {
            _ = Spotify.run(command)
            let playing = Spotify.current()
            await MainActor.run { if self.nowPlaying != playing { self.nowPlaying = playing } }
        }
    }

    func connectSpotify() {
        spotifyBusy = true
        Task.detached {
            _ = Spotify.Account.login()
            await MainActor.run {
                self.spotifyBusy = false
                self.spotifyConnected = Spotify.Account.isConnected
            }
        }
    }
}

// MARK: - Look

private enum Look {
    static let accent = Color(red: 1, green: 0.58, blue: 0.12)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let line = Color.primary.opacity(0.08)
}

private struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: symbol ?? "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(TitleIconLabel())
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Look.line))
    }
}

private struct TitleIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(Look.accent)
            configuration.title
        }
    }
}

private struct PageTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 28, weight: .bold))
            if let subtitle { Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary) }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Window

private struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Look.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.page {
                    case .home: HomePage(model: model)
                    case .history: HistoryPage(model: model)
                    case .routines: RoutinesPage(model: model)
                    case .alarms: AlarmsPage(model: model)
                    case .notes: NotesPage(model: model)
                    case .dictionary: DictionaryPage()
                    case .music: MusicPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 44)
                .padding(.bottom, 36)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
        .frame(minWidth: 860, minHeight: 560)
        .tint(Look.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 18, weight: .semibold)).foregroundStyle(Look.accent)
                Text("Joe").font(.system(size: 20, weight: .bold))
            }
            .padding(.horizontal, 12)
            .padding(.top, 44)
            .padding(.bottom, 18)
            ForEach(DashboardModel.Page.allCases) { page in
                Button { model.page = page; model.reload() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: page.symbol).frame(width: 18)
                        Text(page.title)
                        Spacer()
                        if page == .alarms, !model.alarms.isEmpty {
                            Text("\(model.alarms.count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 14, weight: model.page == page ? .semibold : .regular))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(model.page == page ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    let trouble = model.status.range(of: #"loading|no microphone|blocking|failed|couldn"#, options: [.regularExpression, .caseInsensitive]) != nil
                    Circle().fill(trouble ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(trouble ? model.status : "Ready").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("Right ⌘ to dictate · right ⌥ to ask Joe").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(12)
        }
        .padding(.horizontal, 10)
        .frame(width: 220)
        .background(Look.sidebar)
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var model: DashboardModel
    @State private var request = ""

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Up late" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = UserDefaults.standard.string(forKey: "userName") ?? "Raphael"
        return "\(part), \(name)"
    }

    var body: some View {
        PageTitle(title: greeting, subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))

        // Ask Joe, by typing.
        HStack(spacing: 10) {
            Image(systemName: "sparkle").foregroundStyle(Look.accent)
            TextField("Ask Joe anything, or tell him what to do…", text: $request)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .onSubmit(send)
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                .buttonStyle(.plain)
                .foregroundStyle(request.isEmpty ? Color.secondary : Look.accent)
                .disabled(request.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Look.line))

        // Stats, like VoiceOS.
        HStack(spacing: 12) {
            stat("\(model.stats.wordsToday)", "words dictated today", "waveform")
            stat("\(model.stats.minutesSaved) min", "saved this week", "bolt")
            stat("\(model.stats.asksThisWeek)", "requests to Joe this week", "sparkle")
            stat("\(model.stats.streak) 🔥", "day streak", "flame")
        }

        Card(title: "Timeline", symbol: "calendar.day.timeline.left") {
            TodayTimeline(slots: model.timeline + model.alarms
                .filter { Calendar.current.isDateInToday($0.fireAt) }
                .map { Daybook.Slot(start: $0.fireAt, title: $0.title, kind: .alarm) })
        }

        HStack(alignment: .top, spacing: 16) {
            Card(title: "Today", symbol: "sun.max") {
                if let focus = model.focus {
                    Text(focus).font(.system(size: 14, weight: .medium))
                }
                if model.tasks.isEmpty {
                    Text("Today's Daybook isn't built yet: Joe makes it on your first wake, or ask him.").foregroundStyle(.secondary).font(.system(size: 13))
                }
                ForEach(model.tasks, id: \.line) { task in
                    Button { model.toggle(task.line) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.done ? Look.accent : .secondary)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.text).font(.system(size: 14)).strikethrough(task.done).foregroundStyle(task.done ? .secondary : .primary)
                                if !task.detail.isEmpty {
                                    Text(task.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let today = model.today {
                    Divider()
                    Text(today).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 16) {
                Card(title: "Alarms", symbol: "alarm") {
                    if model.alarms.isEmpty {
                        Text("None set. Say “set a timer for 5 minutes”.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    ForEach(model.alarms.prefix(4)) { alarm in
                        HStack {
                            Text(alarm.when).font(.system(size: 14, weight: .semibold).monospacedDigit())
                            Text(alarm.title).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Card(title: "Now playing", symbol: "music.note") {
                    Text(model.nowPlaying ?? "Nothing playing").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 14) {
                        Button { model.music(.previous) } label: { Image(systemName: "backward.fill") }
                        Button { model.music(model.nowPlaying == nil ? .resume : .pause) } label: { Image(systemName: model.nowPlaying == nil ? "play.fill" : "pause.fill") }
                        Button { model.music(.next) } label: { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 15))
                }
            }
            .frame(width: 280)
        }

        Card(title: "Recent", symbol: "clock") {
            if model.activity.isEmpty {
                Text("What you dictate and ask shows up here.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(model.activity.prefix(6)) { entry in
                ActivityRow(entry: entry)
            }
        }
    }

    private func send() {
        let text = request.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.actions.ask(text)
        request = ""
    }

    private func stat(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Look.accent)
            Text(value).font(.system(size: 22, weight: .bold).monospacedDigit())
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Look.line))
    }
}

/// Today on one line, 7:00 to 22:00 (stretched for anything earlier or later): classes in
/// grey, calendar events in orange, alarms as pins, and a line for now. Below it, what's next.
private struct TodayTimeline: View {
    let slots: [Daybook.Slot]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let range = hours(now)
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let x = { (date: Date) in width * CGFloat((date.timeIntervalSince(range.lowerBound)) / range.upperBound.timeIntervalSince(range.lowerBound)) }
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 6).fill(Look.line).frame(height: 26).offset(y: 8)
                        ForEach(slots.filter { $0.kind != .alarm }) { slot in
                            let end = slot.end ?? slot.start.addingTimeInterval(1800)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(slot.kind == .event ? Look.accent.opacity(0.85) : Color.secondary.opacity(end < now ? 0.18 : 0.38))
                                .frame(width: max(3, x(end) - x(slot.start) - 2), height: 26)
                                .offset(x: x(slot.start) + 1, y: 8)
                                .help("\(slot.start.formatted(date: .omitted, time: .shortened)) \(slot.title) \(slot.detail)")
                        }
                        ForEach(slots.filter { $0.kind == .alarm }) { slot in
                            Image(systemName: "alarm.fill").font(.system(size: 10)).foregroundStyle(Look.accent)
                                .offset(x: x(slot.start) - 5, y: -6)
                                .help("\(slot.start.formatted(date: .omitted, time: .shortened)) \(slot.title)")
                        }
                        if range.contains(now) {
                            Rectangle().fill(Color.red).frame(width: 2, height: 36).offset(x: x(now) - 1, y: 3)
                        }
                        ForEach(Array(stride(from: 0, through: hourCount(range), by: 3)), id: \.self) { step in
                            let hour = range.lowerBound.addingTimeInterval(Double(step) * 3600)
                            Text(hour.formatted(.dateTime.hour())).font(.system(size: 10)).foregroundStyle(.secondary)
                                .offset(x: min(x(hour), width - 24), y: 38)
                        }
                    }
                }
                .frame(height: 52)

                let upcoming = slots.filter { ($0.end ?? $0.start) > now }.prefix(4)
                if slots.isEmpty {
                    Text("Nothing on today: no classes, events or alarms.").font(.system(size: 13)).foregroundStyle(.secondary)
                } else if upcoming.isEmpty {
                    Text("That's everything for today.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                ForEach(Array(upcoming)) { slot in
                    HStack(spacing: 10) {
                        Circle().fill(slot.kind == .lesson ? Color.secondary : Look.accent).frame(width: 7, height: 7)
                        Text(slot.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 64, alignment: .leading)
                        Text(slot.title).font(.system(size: 13)).lineLimit(1)
                        if !slot.detail.isEmpty { Text(slot.detail).font(.system(size: 12)).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        if slot.start <= now { Text("now").font(.system(size: 11, weight: .semibold)).foregroundStyle(Look.accent) }
                    }
                }
            }
        }
    }

    /// 7:00–22:00, widened to whole hours around anything outside it.
    private func hours(_ now: Date) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        var start = day.addingTimeInterval(7 * 3600), end = day.addingTimeInterval(22 * 3600)
        for slot in slots {
            start = min(start, slot.start)
            end = max(end, slot.end ?? slot.start)
        }
        start = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        end = calendar.dateInterval(of: .hour, for: end.addingTimeInterval(3599))?.start ?? end
        return start...end
    }

    private func hourCount(_ range: ClosedRange<Date>) -> Int {
        Int(range.upperBound.timeIntervalSince(range.lowerBound) / 3600)
    }
}

private struct ActivityRow: View {
    let entry: Activity
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind == .ask ? "sparkle" : "waveform")
                .foregroundStyle(entry.kind == .ask ? Look.accent : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text).font(.system(size: 13)).lineLimit(3).textSelection(.enabled)
                if let answer = entry.answer {
                    Text("→ " + answer).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(entry.date.formatted(Calendar.current.isDateInToday(entry.date) ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated).hour().minute()))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                copied = true
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - History

private struct HistoryPage: View {
    @ObservedObject var model: DashboardModel
    @State private var search = ""
    @State private var kind = "all"

    var body: some View {
        PageTitle(title: "History", subtitle: "Everything you've dictated and asked, kept on this Mac only.")
        HStack {
            Picker("", selection: $kind) {
                Text("All").tag("all")
                Text("Dictation").tag("dictation")
                Text("Joe").tag("ask")
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            Spacer()
            TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
        }
        Card {
            let shown = model.activity.filter { entry in
                (kind == "all" || entry.kind.rawValue == kind)
                    && (search.isEmpty || entry.text.localizedCaseInsensitiveContains(search) || (entry.answer ?? "").localizedCaseInsensitiveContains(search))
            }
            if shown.isEmpty { Text("Nothing here yet.").foregroundStyle(.secondary).font(.system(size: 13)) }
            ForEach(shown.prefix(200)) { entry in
                ActivityRow(entry: entry)
                Divider().opacity(0.5)
            }
        }
    }
}

// MARK: - Routines

private struct RoutinesPage: View {
    @ObservedObject var model: DashboardModel
    @State private var idea = ""

    var body: some View {
        PageTitle(title: "Routines", subtitle: "Say a routine's phrase and Joe runs it. Tell him to change one any time.")
        Card(title: "New routine", symbol: "plus") {
            HStack {
                TextField("When I say “let's work on WellPrepped”, open my creator pipeline and Business Workspace…", text: $idea)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save).disabled(idea.isEmpty)
            }
        }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            ForEach(model.routines, id: \.name) { routine in
                Card {
                    Text(routine.name).font(.system(size: 15, weight: .semibold))
                    Text(routine.trigger).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    HStack {
                        Button("Run") { model.actions.ask("Run my “\(routine.name)” routine.") }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        if let url = Daybook.routinesURL {
                            Button("Edit") { model.openInObsidian(url) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    private func save() {
        guard !idea.isEmpty else { return }
        model.actions.ask("Save this as a routine: \(idea)")
        idea = ""
    }
}

// MARK: - Alarms

private struct AlarmsPage: View {
    @ObservedObject var model: DashboardModel
    @State private var request = ""
    @State private var problem: String?

    var body: some View {
        PageTitle(title: "Alarms", subtitle: "They ring loudly on this Mac (lid open), with Stop and Snooze.")
        Card(title: "Set one", symbol: "plus") {
            HStack {
                TextField("Timer for 25 minutes · alarm at 6:30 called econ quiz · remind me at 3pm to submit the form", text: $request)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Set", action: add).disabled(request.isEmpty)
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.orange) }
        }
        Card(title: "Coming up", symbol: "alarm") {
            if model.alarms.isEmpty { Text("Nothing set.").foregroundStyle(.secondary).font(.system(size: 13)) }
            ForEach(model.alarms) { alarm in
                HStack(spacing: 12) {
                    Image(systemName: alarm.kind == .timer ? "timer" : alarm.kind == .reminder ? "bell" : "alarm")
                        .foregroundStyle(Look.accent).frame(width: 20)
                    Text(alarm.when).font(.system(size: 16, weight: .semibold).monospacedDigit()).frame(width: 90, alignment: .leading)
                    Text(alarm.title).font(.system(size: 14))
                    Spacer()
                    Text(alarm.kind.rawValue.capitalized).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button { model.actions.cancelAlarm(alarm.id); model.reload() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func add() {
        let text = request.lowercased().hasPrefix("set") || request.lowercased().hasPrefix("remind") || request.lowercased().hasPrefix("wake")
            || request.lowercased().hasPrefix("timer") || request.lowercased().hasPrefix("alarm") ? request : "set an alarm " + request
        guard let parsed = AlarmRequest.parse(text) ?? AlarmRequest.parse("set a " + request) else {
            problem = "Couldn't read a time in that. Try “timer for 10 minutes” or “alarm at 7:15 called gym”."
            return
        }
        problem = nil
        model.actions.addAlarm(parsed)
        request = ""
        model.reload()
    }
}

// MARK: - Notes

private struct NotesPage: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        PageTitle(title: "Notes", subtitle: "Lecture and meeting notes from the notepad, saved in your Obsidian vault.")
        HStack {
            Button { model.actions.openNotepad() } label: { Label("Open the notepad", systemImage: "square.and.pencil") }
                .buttonStyle(.borderedProminent)
            Text("Or say “take notes, this is a lecture”.").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        Card {
            if model.notes.isEmpty { Text("No saved notes yet.").foregroundStyle(.secondary).font(.system(size: 13)) }
            ForEach(model.notes, id: \.url) { note in
                Button { model.openInObsidian(note.url) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: note.kind.hasPrefix("Lecture") ? "graduationcap" : note.kind.hasPrefix("Meeting") ? "person.2" : "note.text")
                            .foregroundStyle(Look.accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title).font(.system(size: 14))
                            Text(note.kind).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(note.date.formatted(.dateTime.day().month(.abbreviated))).font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Dictionary

private struct DictionaryPage: View {
    @State private var text = ""
    @State private var saved = true

    var body: some View {
        PageTitle(title: "Dictionary", subtitle: "Names and words Joe should spell your way. One per line; “heard -> Written” for a fixed swap.")
        Card {
            TextEditor(text: $text)
                .font(.system(size: 14, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 340)
                .onChange(of: text) { saved = false }
            HStack {
                Text(saved ? "Saved" : "Not saved").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Save") {
                    try? FileManager.default.createDirectory(at: Vocabulary.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? text.write(to: Vocabulary.url, atomically: true, encoding: .utf8)
                    saved = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
            }
        }
        .onAppear {
            text = (try? String(contentsOf: Vocabulary.url, encoding: .utf8)) ?? ""
            DispatchQueue.main.async { saved = true }
        }
    }
}

// MARK: - Spotify

private struct MusicPage: View {
    @ObservedObject var model: DashboardModel
    @State private var request = ""

    var body: some View {
        PageTitle(title: "Spotify", subtitle: "Say “play…”, “pause”, “skip”, “play my liked songs” or “like this song”.")
        Card(title: "Now playing", symbol: "music.note") {
            Text(model.nowPlaying ?? "Nothing playing").font(.system(size: 16, weight: .semibold))
            HStack(spacing: 18) {
                Button { model.music(.previous) } label: { Image(systemName: "backward.fill") }
                Button { model.music(model.nowPlaying == nil ? .resume : .pause) } label: { Image(systemName: model.nowPlaying == nil ? "play.fill" : "pause.fill") }
                Button { model.music(.next) } label: { Image(systemName: "forward.fill") }
                Button { model.music(.like) } label: { Image(systemName: "heart") }.help("Save to liked songs")
            }
            .buttonStyle(.plain)
            .font(.system(size: 18))
            HStack {
                TextField("Play… (a song, artist, album, or “my liked songs”)", text: $request)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(play)
                Button("Play", action: play).disabled(request.isEmpty)
            }
        }
        Card(title: "Your account", symbol: "person.crop.circle") {
            HStack {
                Image(systemName: model.spotifyConnected ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(model.spotifyConnected ? .green : .secondary)
                Text(model.spotifyConnected ? "Connected: your liked songs and playlists work." : "Not connected: only search-and-play works.")
                    .font(.system(size: 13))
                Spacer()
                Button(model.spotifyBusy ? "Waiting for Spotify…" : model.spotifyConnected ? "Reconnect" : "Connect") { model.connectSpotify() }
                    .disabled(model.spotifyBusy)
            }
        }
    }

    private func play() {
        let text = request.lowercased().hasPrefix("play") || request.lowercased().hasPrefix("shuffle") ? request : "play " + request
        if let command = Spotify.command(in: text) { model.music(command) }
        request = ""
    }
}

// MARK: - Settings

/// A choice in Joe's style: a soft pill with the current value and a chevron, opening a menu.
private struct Choice<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    if option.value == selection { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(options.first { $0.value == selection }?.title ?? "Choose")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Look.line))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A small pill button, to go with `Choice`.
private struct PillButton: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.white : destructive ? Color.red : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(prominent ? Look.accent : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Look.line))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

private struct SettingsPage: View {
    @ObservedObject var model: DashboardModel
    @AppStorage("writingStyle") private var writingStyle = WritingStyle.casual.rawValue
    @AppStorage("microphoneUID") private var microphone = ""
    @AppStorage("morningBriefing") private var morning = true
    @AppStorage("nightShutdown") private var night = true
    @AppStorage("eveningCheck") private var evening = true
    @AppStorage("alarmsToReminders") private var toReminders = true
    @AppStorage("phoneRemote") private var phoneRemote = true
    @AppStorage("wakeWord") private var wakeWord = false
    @AppStorage("assistantModel") private var assistantModel = Assistant.Model.opus.rawValue
    @AppStorage("assistantEffort") private var effort = Assistant.Effort.low.rawValue
    @AppStorage("assistantAutonomy") private var autonomy = Assistant.Autonomy.careful.rawValue
    @AppStorage("rememberConversations") private var remember = true
    @AppStorage("saveNotesToVault") private var saveNotes = true
    @AppStorage("keepHistory") private var keepHistory = true
    @AppStorage("expressiveSounds") private var sounds = true
    @AppStorage("speakBriefing") private var speakBriefing = true
    @AppStorage("userName") private var userName = "Raphael"
    @AppStorage("joeChattiness") private var chattiness = "normal"
    @AppStorage("joeTone") private var tone = "direct"
    @AppStorage("joeHype") private var hype = false
    @State private var notch = Notch.isEnabled
    @State private var englishOnly = Transcriber.englishOnly
    @State private var cleanup = UserDefaults.standard.bool(forKey: "aiCleanup")
    @State private var control = ScreenControl.isEnabled
    @State private var voice = SpeechOutput.engine
    @State private var naturalVoice = SpeechOutput.naturalVoice
    @State private var login = false // read on appear: asking macOS is slow, too slow for every redraw

    var body: some View {
        PageTitle(title: "Settings")
            .onAppear { login = SMAppService.mainApp.status == .enabled }

        section("Dictation", "waveform") {
            row("Writing style", "How your dictation is punctuated") {
                Choice(options: WritingStyle.allCases.map { ($0.rawValue, $0.title) }, selection: $writingStyle)
            }
            row("Microphone") {
                Choice(options: [("", "Automatic")] + model.actions.microphones().map { ($0.uid, $0.name) }, selection: $microphone)
            }
            row("Languages", "English only stops it mishearing you as Russian") {
                Choice(options: [(true, "English only"), (false, "25 languages")], selection: $englishOnly)
                    .onChange(of: englishOnly) { model.actions.setEnglishOnly(englishOnly) }
            }
            row("AI cleanup", "Removes filler words, on this Mac") { switchOn($cleanup) { model.actions.setCleanup($0) } }
            row("Show at the notch", "Answers drop down from the notch", last: true) { switchOn($notch) { model.actions.setNotch($0) } }
        }

        section("Joe", "sparkle") {
            row("Your name", "What Joe calls you") {
                TextField("", text: $userName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 12)
                    .frame(width: 180, height: 28)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(Look.line))
            }
            row("Answers", "How much Joe says") {
                Choice(options: [("brief", "Brief"), ("normal", "Normal"), ("chatty", "Chatty")], selection: $chattiness)
            }
            row("Tone", "How Joe puts things") {
                Choice(options: [("gentle", "Gentle"), ("direct", "Direct"), ("blunt", "Blunt")], selection: $tone)
            }
            row("Hype you up", "Joe cheers when you get things done") { switchOn($hype) }
            row("Model", "Smarter, or faster and lighter on your usage") {
                Choice(options: Assistant.Model.allCases.map { ($0.rawValue, $0.name) }, selection: $assistantModel)
            }
            row("Effort", "How hard Joe thinks before answering") {
                Choice(options: Assistant.Effort.allCases.map { ($0.rawValue, $0.name) }, selection: $effort)
            }
            row("Permissions", (Assistant.Autonomy(rawValue: autonomy)?.title.components(separatedBy: ": ").dropFirst().first).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "What Joe may do without asking") {
                Choice(options: Assistant.Autonomy.allCases.map { ($0.rawValue, $0.title.components(separatedBy: ":")[0]) }, selection: $autonomy)
            }
            row("Click and type", "Joe can use your mouse and keyboard") { switchOn($control) { model.actions.setScreenControl($0) } }
            row("Morning briefing", "On your first wake of the day") { switchOn($morning) }
            row("Night shutdown", "21:30 on school nights") { switchOn($night) }
            row("Evening check", "19:30: new ManageBac tasks and grades into your Daybook") { switchOn($evening) }
            row("Alarms on iPhone", "Copies alarms into a “Joe” list in Reminders, so your phone rings too") { switchOn($toReminders) }
            row("Ask from iPhone", "“Hey Siri, add … to Ask Joe”: Joe answers in Reminders while your Mac is awake") { switchOn($phoneRemote) }
            row("“Hey Joe”", "Talk without a key. Listens on your Mac only; the mic stays on (orange dot)") { switchOn($wakeWord) }
            row("Remember conversations", "A log in your vault") { switchOn($remember) }
            row("Save notes to Obsidian", "When the notepad closes") { switchOn($saveNotes) }
            row("Memory vault", Assistant.vaultURL?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "None") {
                Button("Choose…") { model.actions.chooseVault() }.buttonStyle(PillButton())
            }
            row("Instructions", "Your standing notes for Joe", last: true) {
                Button("Edit…") { Assistant.openInstructions() }.buttonStyle(PillButton())
            }
        }

        section("Voice", "speaker.wave.2") {
            row("Joe's voice", "Off, or how Joe sounds when he answers") {
                Choice(options: SpeechOutput.Engine.allCases.map { ($0, $0.title.components(separatedBy: ":")[0]) }, selection: $voice)
                    .onChange(of: voice) { model.actions.setVoice(voice) }
            }
            row("Natural voice") {
                Choice(options: SpeechOutput.naturalVoices.map { ($0.id, $0.name) }, selection: $naturalVoice)
                    .onChange(of: naturalVoice) { model.actions.setNaturalVoice(naturalVoice) }
            }
            row("Laughs and sighs", "In the Expressive voice") { switchOn($sounds) }
            row("Read briefings aloud", last: true) { switchOn($speakBriefing) }
        }

        section("Privacy", "lock") {
            row("Keep history", "What you dictate and ask, on this Mac only") { switchOn($keepHistory) }
            row("Clear history", last: true) {
                Button("Clear") { ActivityLog.clear(); model.reload() }.buttonStyle(PillButton(destructive: true))
            }
        }

        section("Permissions", "checkmark.shield") {
            permission("Accessibility", "Typing and shortcuts", AXIsProcessTrusted(), "Privacy_Accessibility")
            permission("Microphone", "Hearing you", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Privacy_Microphone")
            permission("Screen Recording", "Reading your screen", CGPreflightScreenCaptureAccess(), "Privacy_ScreenCapture", last: true)
        }

        section("General", "gearshape") {
            row("Open Joe at login") {
                switchOn($login) { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSSound.beep() }
                }
            }
            row("Quit Joe", "Dictation and the notch stop until you open Joe again", last: true) {
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(PillButton())
            }
        }
    }

    private func section<Content: View>(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        Card(title: title, symbol: symbol) {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }

    private func row<Content: View>(_ label: String, _ detail: String? = nil, last: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 13.5, weight: .medium))
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 12)
                content()
            }
            .padding(.vertical, 10)
            if !last { Rectangle().fill(Look.line).frame(height: 1) }
        }
    }

    private func switchOn(_ value: Binding<Bool>, _ changed: ((Bool) -> Void)? = nil) -> some View {
        Toggle("", isOn: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; changed?($0) }))
            .toggleStyle(.switch)
            .tint(Look.accent)
            .labelsHidden()
            .controlSize(.small)
    }

    private func permission(_ label: String, _ detail: String, _ granted: Bool, _ pane: String, last: Bool = false) -> some View {
        row(label, detail, last: last) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button("Allow…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
                .buttonStyle(PillButton(prominent: true))
            }
        }
    }
}
