import EventKit
import Speech
import AppKit
import AVFoundation
import ServiceManagement
import Charts
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
            window.minSize = NSSize(width: 720, height: 520)
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
        case home, calendar, study, history, routines, alarms, notes, dictionary, music, usage, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: "Home"
            case .calendar: "Calendar"
            case .study: "Study"
            case .usage: "Usage"
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
            case .calendar: "calendar"
            case .study: "graduationcap"
            case .usage: "chart.bar"
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
        /// A request that runs in the side notch, off the card (syncing the calendar).
        var askInBackground: (String) -> Void
        var status: () -> String
        var setVoice: (SpeechOutput.Engine) -> Void
        var setNotch: (Bool) -> Void
        var setCleanup: (Bool) -> Void
        var setScreenControl: (Bool) -> Void
        var chooseVault: () -> Void
        var showOnboarding: () -> Void
        var openNotepad: () -> Void
        var microphones: () -> [(uid: String, name: String)]
        var setSpeechLanguages: (String) -> Void
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
    /// ManageBac deadlines in the next two weeks, for Home and the calendar.
    @Published var deadlines: [CalendarFeed.Item] = []
    private var deadlinesRead = Date.distantPast
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
    /// When History.json was last read: it's decoded again only after it changes (decoding a
    /// thousand entries every two seconds made scrolling stutter).
    private var activityStamp: Date?

    func reload() {
        let stamp = (try? ActivityLog.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if stamp != activityStamp {
            activityStamp = stamp
            let newActivity = Array(ActivityLog.load().reversed())
            if newActivity != activity {
                activity = newActivity
                stats = ActivityLog.stats(newActivity)
            }
        }
        update(\.alarms, AlarmStore.load())
        update(\.status, actions.status())
        update(\.today, Daybook.today)
        update(\.timeline, Daybook.timeline())
        // Reading the calendar sources takes a moment: once a minute is plenty for deadlines.
        if (page == .home || page == .calendar), Date().timeIntervalSince(deadlinesRead) > 60 {
            deadlinesRead = Date()
            let start = Calendar.current.startOfDay(for: Date())
            update(\.deadlines, CalendarFeed.items(from: start, days: 14).filter { $0.kind == .deadline })
        }
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

    /// What the last Connect said ("Connected as Raph", "No answer…").
    @Published var spotifyMessage: String?

    func connectSpotify() {
        spotifyBusy = true
        spotifyMessage = "Spotify's sign-in page is open in your browser: log in and press Agree."
        Task.detached {
            let result = Spotify.Account.login()
            await MainActor.run {
                self.spotifyBusy = false
                self.spotifyConnected = Spotify.Account.isConnected
                self.spotifyMessage = result
            }
        }
    }
}

// MARK: - Look

/// The app's styles (Settings → General → Style): Classic orange, Midnight (navy and gold,
/// always dark), Paper (warm paper, serif headings), Ocean (blue, rounded).
enum Theme: String, CaseIterable {
    case classic, midnight, paper, ocean
    static let key = "theme"
    static var current: Theme { Theme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .classic }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .midnight: "Midnight"
        case .paper: "Paper"
        case .ocean: "Ocean"
        }
    }
}

private enum Look {
    static var accent: Color {
        switch Theme.current {
        case .classic: Color(red: 1, green: 0.58, blue: 0.12)
        case .midnight: Color(red: 0.96, green: 0.77, blue: 0.33)
        case .paper: Color(red: 0.74, green: 0.25, blue: 0.2)
        case .ocean: Color(red: 0.16, green: 0.5, blue: 0.96)
        }
    }
    static var sidebar: Color {
        switch Theme.current {
        case .midnight: Color(red: 0.05, green: 0.07, blue: 0.13)
        case .paper: dynamic(light: (0.95, 0.93, 0.89), dark: (0.11, 0.1, 0.09))
        default: Color(nsColor: .windowBackgroundColor)
        }
    }
    static var card: Color {
        switch Theme.current {
        case .midnight: Color(red: 0.1, green: 0.13, blue: 0.22)
        case .paper: dynamic(light: (1, 0.99, 0.97), dark: (0.17, 0.16, 0.14))
        default: Color(nsColor: .controlBackgroundColor)
        }
    }
    /// Behind the pages.
    static var page: Color {
        switch Theme.current {
        case .midnight: Color(red: 0.07, green: 0.09, blue: 0.16)
        case .paper: dynamic(light: (0.98, 0.96, 0.92), dark: (0.13, 0.12, 0.11))
        case .ocean: dynamic(light: (0.96, 0.97, 1), dark: (0.09, 0.1, 0.13))
        case .classic: Color(nsColor: .textBackgroundColor).opacity(0.5)
        }
    }
    /// Page titles: serif on Paper, rounded on Ocean.
    static var titleDesign: Font.Design {
        switch Theme.current {
        case .paper: .serif
        case .ocean: .rounded
        default: .default
        }
    }
    static let line = Color.primary.opacity(0.08)

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
    static let deadline = Color(red: 0.88, green: 0.24, blue: 0.3)
    /// Personal events (Google Calendar), in the colour chosen on the timeline.
    static var personal: Color { Color(hex: UserDefaults.standard.string(forKey: "timelinePersonal") ?? "#FF9420") }
}

private struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    /// Fill the height it's given, so cards side by side end level.
    var stretch = false
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
        .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
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
            Text(title).font(.system(size: 28, weight: .bold, design: Look.titleDesign))
            if let subtitle { Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary) }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Window

private struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @AppStorage(Theme.key) private var theme = Theme.classic.rawValue

    var body: some View {
        GeometryReader { geometry in
            // Narrow window: the sidebar shrinks to icons. Wide or full screen: the page stays a
            // readable width, centred.
            let compact = geometry.size.width < 1000
            let content = geometry.size.width - (compact ? 68 : 210)
            HStack(spacing: 0) {
                sidebar(compact: compact)
                Rectangle().fill(Look.line).frame(width: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        switch model.page {
                        case .home: HomePage(model: model)
                        case .calendar: CalendarPage(model: model)
                        case .study: StudyPage(model: model)
                        case .usage: UsagePage()
                        case .history: HistoryPage(model: model)
                        case .routines: RoutinesPage(model: model)
                        case .alarms: AlarmsPage(model: model)
                        case .notes: NotesPage(model: model)
                        case .dictionary: DictionaryPage()
                        case .music: MusicPage(model: model)
                        case .settings: SettingsPage(model: model)
                        }
                    }
                    .environment(\.narrow, content < 820)
                    .environment(\.wide, content >= 1000)
                    .padding(.horizontal, content < 820 ? 24 : 40)
                    .padding(.top, 44)
                    .padding(.bottom, 36)
                    .frame(maxWidth: model.page == .calendar ? 1500 : 1060, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .background(Look.page)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .tint(Look.accent)
        .id(theme) // a new style redraws everything in it
    }

    /// The pages in groups, like Linear's sidebar: your day, Joe's tools, and the app.
    private static let groups: [(title: String?, pages: [DashboardModel.Page])] = [
        (nil, [.home, .calendar, .study, .history]),
        ("Joe", [.routines, .alarms, .notes, .dictionary, .music]),
    ]

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: compact ? .center : .leading, spacing: 1) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 16, weight: .bold)).foregroundStyle(Look.accent)
                if !compact { Text("Joe").font(.system(size: 18, weight: .bold, design: Look.titleDesign)) }
            }
            .padding(.horizontal, compact ? 0 : 10)
            .padding(.top, 46)
            .padding(.bottom, 16)
            ForEach(Self.groups.indices, id: \.self) { index in
                let group = Self.groups[index]
                if let title = group.title {
                    if compact {
                        Divider().frame(width: 28).padding(.vertical, 8)
                    } else {
                        Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
                    }
                }
                ForEach(group.pages) { page in item(page, compact: compact) }
            }
            Spacer()
            item(.usage, compact: compact)
            item(.settings, compact: compact)
            let trouble = model.status.range(of: #"loading|no microphone|blocking|failed|couldn"#, options: [.regularExpression, .caseInsensitive]) != nil
            if compact {
                Circle().fill(trouble ? Color.orange : Color.green).frame(width: 8, height: 8).padding(.vertical, 16)
                    .help(trouble ? model.status : "Ready")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(trouble ? Color.orange : Color.green).frame(width: 7, height: 7)
                        Text(trouble ? model.status : "Ready").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        AppearanceToggle()
                    }
                    shortcut("Dictate", "right ⌘")
                    shortcut("Ask Joe", "right ⌥")
                    shortcut("Long request", "double-tap")
                }
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, compact ? 12 : 10)
        .frame(width: compact ? 68 : 210)
        .background(Look.sidebar)
    }

    private func item(_ page: DashboardModel.Page, compact: Bool) -> some View {
        let current = model.page == page
        return Button { model.page = page; model.reload() } label: {
            HStack(spacing: 9) {
                Image(systemName: page.symbol).font(.system(size: 13, weight: current ? .semibold : .regular)).frame(width: 18)
                    .foregroundStyle(current ? Look.accent : .secondary)
                if !compact {
                    Text(page.title)
                    Spacer()
                    if page == .alarms, !model.alarms.isEmpty {
                        Text("\(model.alarms.count)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 13, weight: current ? .semibold : .regular))
            .padding(.horizontal, compact ? 0 : 10)
            .frame(width: compact ? 40 : nil, height: 30)
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            .background(current ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(page.title)
    }

    /// "Ask Joe   right ⌥", the key drawn as a keycap.
    private func shortcut(_ action: String, _ key: String) -> some View {
        HStack {
            Text(action).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(key).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).frame(height: 17)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Look.line))
        }
    }
}

private struct NarrowKey: EnvironmentKey { static let defaultValue = false }
private struct WideKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Room for a side column beside the page (the calendar's details and deadlines).
    var wide: Bool {
        get { self[WideKey.self] }
        set { self[WideKey.self] = newValue }
    }

    /// The page has little width: side-by-side cards stack.
    var narrow: Bool {
        get { self[NarrowKey.self] }
        set { self[NarrowKey.self] = newValue }
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.narrow) private var narrow
    @State private var request = ""

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Up late" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = Profile.name
        return name.isEmpty ? part : "\(part), \(name)"
    }

    /// "Tuesday, 20 October · Day 1 · Cycle A": the school's rotation day when the timetable has one.
    private var subtitle: String {
        let date = Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard let today = model.today, today.hasPrefix("Today"),
              let range = today.range(of: #"Day \d+ · Cycle \w+"#, options: .regularExpression) else { return date }
        return "\(date) · \(today[range])"
    }

    /// One-tap requests a student makes most, like the starters in ChatGPT and Claude.
    private var suggestions: [String] {
        let subjects = Profile.subjects.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let subject = subjects.isEmpty ? "my weakest subject" : subjects[day % subjects.count]
        return ["What's due this week?", "Plan my evening around my deadlines", "Quiz me on \(subject)", "Summarise today's notes", "Draw on my screen"]
    }

    var body: some View {
        PageTitle(title: greeting, subtitle: subtitle)

        // Ask Joe, by typing, with a few starters underneath.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").font(.system(size: 15, weight: .semibold)).foregroundStyle(Look.accent)
                TextField("Ask Joe anything, or tell him what to do…", text: $request)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(request.isEmpty ? Color.secondary.opacity(0.5) : Look.accent)
                    .disabled(request.isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(Look.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Look.line))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button { model.actions.ask(suggestion) } label: { Text(suggestion) }
                            .buttonStyle(ChipButton())
                    }
                }
            }
        }

        HStack(alignment: .top, spacing: 16) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                NowNext(slots: model.timeline, now: context.date)
            }
            if !narrow, !model.alarms.isEmpty || model.nowPlaying != nil {
                status.frame(width: 320)
            }
        }
        .fixedSize(horizontal: false, vertical: true)

        let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            Card(title: "Today's five", symbol: "checklist", stretch: true) {
                if let focus = model.focus {
                    Text(focus).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                }
                if model.tasks.isEmpty {
                    Text("Today's Daybook isn't built yet. Joe makes it on your first wake each morning.").foregroundStyle(.secondary).font(.system(size: 13))
                    Button { model.actions.askInBackground("Build today's Daybook now (how: your instructions), then tell me my five things in one short line.") } label: {
                        Label("Build it now", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(PillButton(prominent: true))
                }
                VStack(spacing: 2) {
                    ForEach(model.tasks, id: \.line) { task in
                        Button { model.toggle(task.line) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.done ? Look.accent : Color.secondary.opacity(0.6))
                                    .font(.system(size: 17))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.text).font(.system(size: 13.5, weight: .medium)).strikethrough(task.done)
                                        .foregroundStyle(task.done ? .secondary : .primary)
                                    if !task.detail.isEmpty, !task.done {
                                        Text(Self.shortDetail(task.detail)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            DueSoon(deadlines: model.deadlines, synced: CalendarFeed.syncedAt != nil || CalendarFeed.linksReadAt != nil, stretch: true) { model.page = .calendar }
                .frame(width: narrow ? nil : 320)
        }
        .fixedSize(horizontal: false, vertical: true)
        if narrow, !model.alarms.isEmpty || model.nowPlaying != nil { status }


        Card(title: "Today", symbol: "calendar.day.timeline.left") {
            TodayTimeline(slots: model.timeline + model.alarms
                .filter { Calendar.current.isDateInToday($0.fireAt) }
                .map { Daybook.Slot(start: $0.fireAt, title: $0.title, kind: .alarm) })
        }

        Card(title: "Recent", symbol: "clock") {
            if model.activity.isEmpty {
                Text("What you dictate and ask shows up here.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(model.activity.prefix(5)) { entry in
                ActivityRow(entry: entry)
            }
        }

        // The numbers, quietly, at the end.
        HStack(spacing: 18) {
            stat("\(model.stats.wordsToday)", "words today")
            stat("\(model.stats.minutesSaved) min", "saved this week")
            stat("\(model.stats.asksThisWeek)", "requests this week")
            stat("\(model.stats.streak)", model.stats.streak == 1 ? "day streak" : "day streak")
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func send() {
        let text = request.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.actions.ask(text)
        request = ""
    }

    /// The next alarm and what's playing, small, beside Now/Next.
    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let alarm = model.alarms.first {
                HStack(spacing: 8) {
                    Image(systemName: "alarm").font(.system(size: 12)).foregroundStyle(Look.accent)
                    Text(alarm.when).font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Text(alarm.title).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if model.alarms.count > 1 {
                        Text("+\(model.alarms.count - 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            if let playing = model.nowPlaying {
                HStack(spacing: 8) {
                    Image(systemName: "music.note").font(.system(size: 12)).foregroundStyle(.green)
                    Text(playing).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { model.music(.pause) } label: { Image(systemName: "pause.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Button { model.music(.next) } label: { Image(systemName: "forward.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Look.line))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// The first clause of a task's note: the rest is in the Daybook.
    private static func shortDetail(_ detail: String) -> String {
        detail.components(separatedBy: " · ").first ?? detail
    }
}

/// What's on now and what's next, big, with a countdown.
private struct NowNext: View {
    let slots: [Daybook.Slot]
    let now: Date

    var body: some View {
        let timed = slots.filter { $0.kind != .alarm }
        let current = timed.last { $0.start <= now && ($0.end ?? $0.start.addingTimeInterval(1800)) > now }
        let next = timed.first { $0.start > now }
        let lessons = timed.filter { $0.kind == .lesson }
        HStack(spacing: 14) {
            if let current { tile("Now", current, until: current.end) }
            if let next { tile("Next", next, until: nil) }
            if current == nil && next == nil {
                HStack(spacing: 10) {
                    Image(systemName: "moon.stars").font(.system(size: 18)).foregroundStyle(.secondary)
                    Text(lessons.isEmpty ? "Nothing scheduled today." : "Done for today. Classes finished at \(lessons.last?.end?.formatted(date: .omitted, time: .shortened) ?? "").")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 78, maxHeight: .infinity, alignment: .leading)
                .background(Look.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Look.line))
            }
        }
    }

    private func tile(_ label: String, _ slot: Daybook.Slot, until: Date?) -> some View {
        let color = slot.kind == .lesson ? SubjectGroup.color(for: slot.title) : Look.personal
        let minutes = Int(((until ?? slot.start).timeIntervalSince(now) / 60).rounded(.up))
        let countdown = until != nil ? "\(Self.span(minutes)) left" : "in \(Self.span(minutes))"
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased()).font(.system(size: 10.5, weight: .bold)).foregroundStyle(color)
                Text(slot.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text([slot.start.formatted(date: .omitted, time: .shortened) + (slot.end.map { "–" + $0.formatted(date: .omitted, time: .shortened) } ?? ""), slot.detail]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(countdown).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .padding(.horizontal, 10).frame(height: 26)
                .background(color.opacity(0.12), in: Capsule())
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 78, maxHeight: .infinity, alignment: .leading)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Look.line))
    }

    private static func span(_ minutes: Int) -> String {
        minutes < 60 ? "\(max(minutes, 1)) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// ManageBac deadlines in the next two weeks, soonest first, with how long is left.
private struct DueSoon: View {
    let deadlines: [CalendarFeed.Item]
    let synced: Bool
    var stretch = false
    var open: () -> Void

    var body: some View {
        Card(title: "Due soon", symbol: "flag", stretch: stretch) {
            if deadlines.isEmpty {
                Text(synced ? "Nothing due in the next two weeks." : "Sync the calendar to bring in ManageBac.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(deadlines.prefix(5)) { item in
                    let days = Self.daysLeft(item.start)
                    HStack(spacing: 10) {
                        VStack(spacing: 0) {
                            Text(item.start.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            Text(item.start.formatted(.dateTime.day())).font(.system(size: 15, weight: .semibold).monospacedDigit())
                        }
                        .frame(width: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if let group = SubjectGroup.of(item.subject ?? item.title) ?? SubjectGroup.of(item.detail) {
                                Text(item.subject ?? group.name).font(.system(size: 11)).foregroundStyle(group.color)
                            } else if let subject = item.subject {
                                Text(subject).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(days == 0 ? "Today" : days == 1 ? "Tomorrow" : "\(days) days")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(days <= 1 ? Look.deadline : days <= 3 ? Color.orange : .secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: open)
                }
            }
        }
    }

    static func daysLeft(_ date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
    }
}

/// A rounded suggestion chip.
private struct ChipButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.045), in: Capsule())
            .overlay(Capsule().strokeBorder(Look.line))
            .contentShape(Capsule())
    }
}

/// IB subject groups, each with a colour, so a class looks the same everywhere in Joe: on the
/// calendar, the timeline and next to a deadline.
enum SubjectGroup: CaseIterable {
    case language, acquisition, societies, sciences, maths, arts, core

    var name: String {
        switch self {
        case .language: "Language & literature"
        case .acquisition: "Language acquisition"
        case .societies: "Individuals & societies"
        case .sciences: "Sciences"
        case .maths: "Mathematics"
        case .arts: "The arts"
        case .core: "Core"
        }
    }

    var color: Color {
        switch self {
        case .language: Color(red: 0.23, green: 0.51, blue: 0.96)
        case .acquisition: Color(red: 0.05, green: 0.66, blue: 0.62)
        case .societies: Color(red: 0.84, green: 0.62, blue: 0.0)
        case .sciences: Color(red: 0.13, green: 0.68, blue: 0.33)
        case .maths: Color(red: 0.49, green: 0.36, blue: 0.95)
        case .arts: Color(red: 0.91, green: 0.29, blue: 0.6)
        case .core: Color(red: 0.45, green: 0.5, blue: 0.58)
        }
    }

    /// "Maths AI HL" → maths, "Chinese B" → acquisition, "ESS" → sciences; nil for anything else.
    static func of(_ title: String) -> SubjectGroup? {
        let text = " " + title.lowercased() + " "
        func has(_ pattern: String) -> Bool { text.range(of: #"\b("# + pattern + #")\b"#, options: .regularExpression) != nil }
        if has(#"tok|theory of knowledge|extended essay|ee|cas|advisory|homeroom|assembly|tutor|core"#) { return .core }
        if has(#"maths?|mathematics|aa|ai sl|ai hl"#) { return .maths }
        if has(#"business|econ\w*|history|geography|psychology|global politics|philosophy|anthropology|digital society|itgs"#) { return .societies }
        if has(#"ess|environmental|physics|chemistry|biology|computer science|design technology|sports|science"#) { return .sciences }
        if has(#"visual arts?|music|theatre|film|dance"#) { return .arts }
        if has(#"literature|l&l|lang(uage)? (and|&) lit\w*"#) || (has(#"a"#) && has(#"english|chinese|french|spanish|german|korean|japanese|dutch|language"#)) { return .language }
        if has(#"b|ab initio|chinese|mandarin|french|spanish|german|korean|japanese|english"#) { return .acquisition }
        return nil
    }

    /// A class's colour: its group's, or the school colour when the subject isn't recognised.
    static func color(for title: String) -> Color {
        of(title)?.color ?? Color(hex: UserDefaults.standard.string(forKey: "timelineSchool") ?? "#5B7CFA")
    }
}

/// Today as blocks on one line: classes in the school colour, other events in the personal one
/// (both can be changed), alarms as pins and a red line for now. Click a block for its details;
/// below, what's on now and next.
private struct TodayTimeline: View {
    let slots: [Daybook.Slot]
    @AppStorage("timelineSchool") private var schoolHex = "#5B7CFA"
    @AppStorage("timelinePersonal") private var personalHex = "#FF9420"
    @State private var selected: String?
    @State private var hovered: String?

    private var school: Color { Color(hex: schoolHex) }
    private var personal: Color { Color(hex: personalHex) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let range = hours(now)
            VStack(alignment: .leading, spacing: 14) {
                legend
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let span = range.upperBound.timeIntervalSince(range.lowerBound)
                    let x = { (date: Date) -> CGFloat in width * CGFloat(date.timeIntervalSince(range.lowerBound) / span) }
                    let hourCount = Int(span / 3600)
                    let step = width / CGFloat(max(hourCount, 1)) < 44 ? 2 : 1
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(stride(from: 0, through: hourCount, by: step)), id: \.self) { index in
                            let hour = range.lowerBound.addingTimeInterval(Double(index) * 3600)
                            Rectangle().fill(Look.line).frame(width: 1, height: 64).offset(x: x(hour), y: 14)
                            Text(hour.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))))
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                                .offset(x: min(x(hour) + 3, width - 16), y: 82)
                        }
                        ForEach(slots.filter { $0.kind != .alarm && range.contains($0.start) }) { slot in block(slot, x: x, now: now) }
                        ForEach(slots.filter { $0.kind == .alarm && range.contains($0.start) }) { slot in
                            Image(systemName: "alarm.fill").font(.system(size: 10)).foregroundStyle(Look.accent)
                                .offset(x: x(slot.start) - 5, y: 0)
                                .help("\(slot.start.formatted(date: .omitted, time: .shortened)) \(slot.title)")
                        }
                        if range.contains(now) {
                            Rectangle().fill(Color.red).frame(width: 2, height: 66).offset(x: x(now) - 1, y: 13)
                            Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: x(now) - 3.5, y: 10)
                        }
                    }
                }
                .frame(height: 96)
                details(now)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 3) {
                ForEach([SubjectGroup.language, .societies, .sciences, .maths], id: \.self) { group in
                    RoundedRectangle(cornerRadius: 2).fill(group.color).frame(width: 8, height: 8)
                }
                Text("Classes, by subject group").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 3)
            }
            swatch("Personal", $personalHex)
            HStack(spacing: 5) {
                Image(systemName: "alarm.fill").font(.system(size: 10)).foregroundStyle(Look.accent)
                Text("Alarms").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            let lessons = slots.filter { $0.kind == .lesson && $0.title != "Advisory" }
            if let last = lessons.last?.end {
                Text("\(lessons.count) classes · done at \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("No school today").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// A colour dot that opens the colour picker.
    private func swatch(_ title: String, _ hex: Binding<String>) -> some View {
        HStack(spacing: 5) {
            ColorPicker("", selection: Binding(get: { Color(hex: hex.wrappedValue) }, set: { hex.wrappedValue = $0.hex }), supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(0.7)
                .frame(width: 22, height: 18)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .help("Click the colour to change it")
    }

    private func block(_ slot: Daybook.Slot, x: (Date) -> CGFloat, now: Date) -> some View {
        let end = slot.end ?? slot.start.addingTimeInterval(1800)
        let width = max(4, x(end) - x(slot.start) - 3)
        let color = slot.kind == .lesson ? SubjectGroup.color(for: slot.title) : personal
        let past = end < now
        let lit = selected == slot.id || hovered == slot.id
        return VStack(alignment: .leading, spacing: 1) {
            if width > 30 {
                Text(Self.short(slot.title)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            if width > 44, !slot.detail.isEmpty {
                Text(slot.detail).font(.system(size: 9.5, weight: .medium)).opacity(0.8).lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(width: width, height: 60, alignment: .leading)
        .background(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .background(color.opacity(lit ? 0.3 : 0.16))
        .background(Look.card) // solid underneath: the hour lines don't show through
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(color.opacity(selected == slot.id ? 0.8 : 0), lineWidth: 1.5))
        .opacity(past ? 0.5 : 1)
        .offset(x: x(slot.start) + 1.5, y: 16)
        .onHover { inside in hovered = inside ? slot.id : (hovered == slot.id ? nil : hovered) }
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { selected = selected == slot.id ? nil : slot.id } }
        .help("\(Self.times(slot)) · \(slot.title) \(slot.detail)")
    }

    /// The clicked block, or what's on now and the next few.
    @ViewBuilder
    private func details(_ now: Date) -> some View {
        if let slot = slots.first(where: { $0.id == selected }) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3).fill(slot.kind == .lesson ? SubjectGroup.color(for: slot.title) : slot.kind == .alarm ? Look.accent : personal).frame(width: 5, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(slot.title).font(.system(size: 15, weight: .semibold))
                    Text([Self.times(slot), slot.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.relative(slot, now)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if slots.isEmpty {
            Text("Nothing on today: no classes, events or alarms.").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    /// "Maths AI HL" → "Maths", "Chinese B" → "Chinese": what fits in a block.
    private static func short(_ title: String) -> String {
        title.count <= 7 ? title : String(title.split(separator: " ").first ?? Substring(title))
    }

    private static func times(_ slot: Daybook.Slot) -> String {
        let start = slot.start.formatted(date: .omitted, time: .shortened)
        return slot.end.map { "\(start)–\($0.formatted(date: .omitted, time: .shortened))" } ?? start
    }

    private static func relative(_ slot: Daybook.Slot, _ now: Date) -> String {
        if let end = slot.end, end < now { return "Done" }
        if slot.start <= now { return slot.end == nil ? "Now" : "Now · until \(slot.end!.formatted(date: .omitted, time: .shortened))" }
        let minutes = Int(slot.start.timeIntervalSince(now) / 60)
        return minutes < 60 ? "in \(minutes) min" : "in \(minutes / 60) h \(minutes % 60) min"
    }

    /// 7:00–19:00, widened to whole hours around anything outside it.
    private func hours(_ now: Date) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        var start = day.addingTimeInterval(7 * 3600), end = day.addingTimeInterval(19 * 3600)
        // Overnight things (sleep, an alarm at 6) don't stretch it: the day starts at 6 at the earliest.
        for slot in slots where slot.start >= day.addingTimeInterval(6 * 3600) {
            start = min(start, slot.start)
            end = max(end, slot.end ?? slot.start.addingTimeInterval(1800)) // as long as it's drawn
        }
        start = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        end = calendar.dateInterval(of: .hour, for: end.addingTimeInterval(3599))?.start ?? end
        return start...end
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x5B7CFA
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    var hex: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
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
        PageTitle(title: "History", subtitle: "Everything you've dictated and asked · on this Mac only")
        HStack(spacing: 10) {
            Picker("", selection: $kind) {
                Text("All").tag("all")
                Text("Dictation").tag("dictation")
                Text("Joe").tag("ask")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            Spacer()
            SearchField(text: $search)
        }
        let shown = model.activity.filter { entry in
            (kind == "all" || entry.kind.rawValue == kind)
                && (search.isEmpty || entry.text.localizedCaseInsensitiveContains(search) || (entry.answer ?? "").localizedCaseInsensitiveContains(search))
        }.prefix(300)
        if shown.isEmpty {
            Card { Text(search.isEmpty ? "Nothing here yet." : "Nothing matches “\(search)”.").foregroundStyle(.secondary).font(.system(size: 13)) }
        }
        ForEach(Self.lines(Array(shown))) { line in
            switch line {
            case let .day(day, count):
                HStack {
                    Text(Self.title(day)).font(.system(size: 13, weight: .semibold))
                    Text("\(count)").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .padding(.leading, 4)
                .padding(.top, 6)
            case let .entry(entry, first, last):
                HistoryRow(entry: entry, onDelete: { ActivityLog.delete(entry.id); model.reload() },
                           onContinue: { followUp in model.actions.ask(Self.continuing(entry, followUp)) })
                    .background(Look.card, in: UnevenRoundedRectangle(topLeadingRadius: first ? 14 : 0, bottomLeadingRadius: last ? 14 : 0,
                                                                     bottomTrailingRadius: last ? 14 : 0, topTrailingRadius: first ? 14 : 0, style: .continuous))
                    .overlay(alignment: .bottom) { if !last { Rectangle().fill(Look.line).frame(height: 1).padding(.leading, 62) } }
                    .padding(.top, first ? 0 : -18) // rows of a day sit together; the page spaces children by 18
            }
        }
    }

    /// The page as a flat list (a day's title, then its entries), so the scroll view only builds
    /// the rows on screen.
    private enum Line: Identifiable {
        case day(Date, Int)
        case entry(Activity, first: Bool, last: Bool)
        var id: String {
            switch self {
            case let .day(day, _): "day \(day.timeIntervalSince1970)"
            case let .entry(entry, _, _): entry.id.uuidString
            }
        }
    }

    private static func lines(_ entries: [Activity]) -> [Line] {
        let calendar = Calendar.current
        var lines: [Line] = []
        var index = 0
        while index < entries.count {
            let day = calendar.startOfDay(for: entries[index].date)
            var end = index
            while end + 1 < entries.count, calendar.isDate(entries[end + 1].date, inSameDayAs: day) { end += 1 }
            lines.append(.day(day, end - index + 1))
            for position in index...end {
                lines.append(.entry(entries[position], first: position == index, last: position == end))
            }
            index = end + 1
        }
        return lines
    }

    /// A follow-up to an old conversation, with what was said then (sessions aren't kept).
    private static func continuing(_ entry: Activity, _ followUp: String) -> String {
        """
        [Continuing a conversation from \(entry.date.formatted(date: .abbreviated, time: .shortened)). I asked: \
        “\(entry.text)”. You answered: “\((entry.reply ?? entry.answer ?? "").prefix(2500))”.]
        \(followUp)
        """
    }

    private static func title(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// One thing said: the time, what was said, and for a request Joe's answer. Click to see it all;
/// the copy button shows on hover.
private struct HistoryRow: View {
    let entry: Activity
    var onDelete: () -> Void = {}
    var onContinue: (String) -> Void = { _ in }
    @State private var open = false
    @State private var hovering = false
    @State private var copied = false
    @State private var followUp = ""
    @State private var continuing = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
                .padding(.top, 2)
            Image(systemName: entry.kind == .ask ? "sparkle" : "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(entry.kind == .ask ? Look.accent : .secondary)
                .frame(width: 22, height: 22)
                .background((entry.kind == .ask ? Look.accent : Color.secondary).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text).font(.system(size: 13.5)).lineLimit(open ? nil : 2).textSelection(.enabled)
                if open, let reply = entry.reply, !reply.isEmpty {
                    // The whole answer, as Joe gave it.
                    VStack(alignment: .leading, spacing: 4) {
                        if let subject = entry.answer { Text(subject).font(.system(size: 12.5, weight: .semibold)) }
                        Text(reply).font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                } else if let answer = entry.answer {
                    Text(answer).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(open ? nil : 1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
                if continuing {
                    HStack(spacing: 8) {
                        TextField("Ask a follow-up…", text: $followUp)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(send)
                        Button("Send", action: send).buttonStyle(PillButton(prominent: true)).disabled(followUp.isEmpty)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                if entry.kind == .ask {
                    Button { continuing.toggle(); open = true } label: { Image(systemName: "arrowshape.turn.up.left").font(.system(size: 12)) }
                        .buttonStyle(.plain).help("Continue this conversation")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.reply.map { entry.text + "\n\n" + $0 } ?? entry.text, forType: .string)
                    copied = true
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12)) }
                    .buttonStyle(.plain).help("Copy")
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 12)) }
                    .buttonStyle(.plain).help("Delete from history")
            }
            .foregroundStyle(.secondary)
            .opacity(hovering || copied || continuing ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(hovering ? Color.primary.opacity(0.03) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } }
    }

    private func send() {
        let text = followUp.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        onContinue(text)
        followUp = ""
        continuing = false
    }
}

/// A search box in the dashboard's style.
private struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 240, height: 30)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Look.line))
    }
}

// MARK: - Usage

/// What Joe's requests cost (from the usage log): today, this week, by kind, and what a month
/// looks like at this rate. On a Claude plan it's what the same use would cost on the API.
private struct UsagePage: View {
    @Environment(\.narrow) private var narrow
    @State private var entries: [UsageLog.Entry] = []
    @AppStorage("usageCurrency") private var currency = "USD"

    /// Yuan per US dollar, for the RMB view: a reference, not a live rate.
    static let yuanPerDollar = 7.1

    var body: some View {
        HStack(alignment: .top) {
            PageTitle(title: "Usage", subtitle: (AIAccount.usesAPIKey ? "Billed to your API key, per request." : "On your Claude plan. Costs show what the same use would cost on the API.")
                + (currency == "CNY" ? " RMB at ¥\(String(format: "%.1f", Self.yuanPerDollar)) per $1." : ""))
            Spacer()
            Picker("", selection: $currency) {
                Text("USD $").tag("USD")
                Text("RMB ¥").tag("CNY")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .padding(.top, 6)
        }
        let calendar = Calendar.current
        let today = entries.filter { calendar.isDateInToday($0.date) }
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let week = entries.filter { $0.date > weekAgo }
        let days = Set(week.map { calendar.startOfDay(for: $0.date) }).count
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: narrow ? 2 : 4), spacing: 12) {
            stat(Self.dollars(today.reduce(0) { $0 + $1.cost }), "today", "sun.max")
            stat(Self.dollars(week.reduce(0) { $0 + $1.cost }), "last 7 days", "calendar")
            stat("\(week.count)", "requests, last 7 days", "sparkle")
            stat(Self.dollars(days == 0 ? 0 : week.reduce(0) { $0 + $1.cost } / Double(days) * 30), "a month at this rate", "chart.line.uptrend.xyaxis")
        }
        let layout = narrow ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            Card(title: "Each day, last 7 days", symbol: "chart.bar", stretch: true) {
                Chart(Self.daily(week)) { bar in
                    BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Cost", bar.cost))
                        .foregroundStyle(by: .value("Model", bar.model))
                        .cornerRadius(4)
                }
                .chartForegroundStyleScale(["Haiku": Color.green, "Sonnet": Color.blue, "Opus": Look.accent])
                // Always the whole week, so one busy day is a bar, not the whole chart.
                .chartXScale(domain: Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
                             ... Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!)
                .chartYAxis { AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let cost = value.as(Double.self) { Text(cost == 0 ? "$0" : Self.dollars(cost)) } }
                } }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .frame(height: 170)
            }
            Card(title: "By model, last 7 days", symbol: "cpu", stretch: true) {
                ForEach(Self.byModel(week), id: \.model) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(group.model).font(.system(size: 13.5, weight: .medium))
                            Spacer()
                            Text(Self.dollars(group.total)).font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                        }
                        Text("\(group.count) requests · avg \(Self.dollars(group.total / Double(group.count)))")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                Text("Joe uses Haiku for most things and Opus only for designing and doing schoolwork.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: narrow ? nil : 300)
        }
        .fixedSize(horizontal: false, vertical: true)
        Card(title: "By kind, last 7 days", symbol: "square.grid.2x2") {
            if week.isEmpty { Text("Nothing logged yet: costs appear after Joe's next request.").font(.system(size: 13)).foregroundStyle(.secondary) }
            ForEach(Self.byKind(week), id: \.kind) { group in
                HStack {
                    Text(group.kind).font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text("\(group.count) × avg \(Self.dollars(group.total / Double(group.count)))").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Text(Self.dollars(group.total)).font(.system(size: 14, weight: .semibold).monospacedDigit()).frame(width: 80, alignment: .trailing)
                }
            }
        }
        Card(title: "Most expensive, last 7 days", symbol: "arrow.up.circle") {
            ForEach(week.sorted { $0.cost > $1.cost }.prefix(8)) { entry in
                HStack(spacing: 10) {
                    Text(Self.dollars(entry.cost)).font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 64, alignment: .leading)
                    Text(entry.request.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    Text(entry.model.replacingOccurrences(of: "claude-", with: "")).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { entries = UsageLog.load() }
    }

    /// "claude-haiku-5-5" → "Haiku".
    private static func family(_ model: String) -> String {
        ["Opus", "Sonnet", "Haiku"].first { model.lowercased().contains($0.lowercased()) } ?? "Other"
    }

    private struct DayBar: Identifiable {
        let day: Date
        let model: String
        let cost: Double
        var id: String { "\(day.timeIntervalSince1970)\(model)" }
    }

    private static func daily(_ entries: [UsageLog.Entry]) -> [DayBar] {
        var totals: [String: (Date, String, Double)] = [:]
        for entry in entries {
            let day = Calendar.current.startOfDay(for: entry.date)
            let model = family(entry.model)
            let key = "\(day.timeIntervalSince1970)\(model)"
            totals[key] = (day, model, (totals[key]?.2 ?? 0) + entry.cost)
        }
        return totals.values.map { DayBar(day: $0.0, model: $0.1, cost: $0.2) }.sorted { $0.day < $1.day }
    }

    private static func byModel(_ entries: [UsageLog.Entry]) -> [(model: String, count: Int, total: Double)] {
        var groups: [String: (count: Int, total: Double)] = [:]
        for entry in entries {
            let current = groups[family(entry.model)] ?? (0, 0)
            groups[family(entry.model)] = (current.count + 1, current.total + entry.cost)
        }
        return groups.map { (model: $0.key, count: $0.value.count, total: $0.value.total) }.sorted { $0.total > $1.total }
    }

    private static func byKind(_ entries: [UsageLog.Entry]) -> [(kind: String, count: Int, total: Double)] {
        var groups: [String: (count: Int, total: Double)] = [:]
        for entry in entries {
            let current = groups[entry.kind] ?? (0, 0)
            groups[entry.kind] = (current.count + 1, current.total + entry.cost)
        }
        return groups.map { (kind: $0.key, count: $0.value.count, total: $0.value.total) }.sorted { $0.total > $1.total }
    }

    /// In dollars, or yuan when RMB is picked.
    private static func dollars(_ value: Double) -> String {
        if UserDefaults.standard.string(forKey: "usageCurrency") == "CNY" {
            let yuan = value * yuanPerDollar
            return yuan < 1 ? String(format: "¥%.3f", yuan) : String(format: "¥%.2f", yuan)
        }
        return value < 1 ? String(format: "$%.3f", value) : String(format: "$%.2f", value)
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

// MARK: - Calendar

/// A week like Google Calendar's: classes, events, ManageBac deadlines and alarms, day by day.
/// Three days at a time in a narrow window.
private struct CalendarPage: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.narrow) private var narrow
    @Environment(\.wide) private var wide
    @State private var anchor = Date()
    @State private var selected: CalendarFeed.Item?
    @State private var syncStarted: Date?

    private static let hourHeight: CGFloat = 52
    private static let gutter: CGFloat = 48

    /// Monday of the week (or the anchor day itself when narrow).
    private var first: Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: anchor)
        guard !narrow else { return day }
        let weekday = calendar.component(.weekday, from: day) // 1 = Sunday
        return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day) ?? day
    }

    private var span: Int { narrow ? 3 : 7 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let items = CalendarFeed.items(from: first, days: span)
            let dates = shownDays(items)
            VStack(alignment: .leading, spacing: 16) {
                header(dates, now)
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        Card { week(dates, items, now) }
                        rail(now).frame(width: 270)
                    }
                } else {
                    if let selected { detail(selected) }
                    Card { week(dates, items, now) }
                    DueSoon(deadlines: model.deadlines, synced: CalendarFeed.syncedAt != nil || CalendarFeed.linksReadAt != nil) {}
                }
            }
        }
    }

    /// The days to draw: a school week, plus Saturday and Sunday only when something is on then
    /// (alarms don't count).
    private func shownDays(_ items: [CalendarFeed.Item]) -> [Date] {
        let calendar = Calendar.current
        let all = (0..<span).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
        guard !narrow else { return all }
        return all.filter { date in
            !calendar.isDateInWeekend(date) || calendar.isDateInToday(date)
                || items.contains { $0.kind != .alarm && calendar.isDate($0.start, inSameDayAs: date) }
        }
    }

    // MARK: Header

    private func header(_ dates: [Date], _ now: Date) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(first.formatted(.dateTime.month(.wide).year())).font(.system(size: 28, weight: .bold))
                Text(range(dates) + "  ·  " + syncLabel(now)).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 0) {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 28) }
                Divider().frame(height: 16)
                Button("Today") { anchor = Date(); selected = nil }.padding(.horizontal, 10).frame(height: 28)
                Divider().frame(height: 16)
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 28) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .background(Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(Look.line))
            Button {
                syncStarted = Date()
                if CalendarFeed.links.isEmpty {
                    model.actions.askInBackground(CalendarFeed.syncInstructions)
                } else {
                    // Calendar links: read them directly, in a second, no Claude needed.
                    Task { await CalendarFeed.refreshLinks(); syncStarted = nil; model.reload() }
                }
            } label: { Label(syncing(now) ? "Syncing…" : "Sync", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(PillButton(prominent: true))
                .disabled(syncing(now))
                .help("Joe fetches Google Calendar and ManageBac for the next 3 weeks")
        }
    }

    private func range(_ dates: [Date]) -> String {
        guard let start = dates.first, let end = dates.last else { return "" }
        return "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private func syncing(_ now: Date) -> Bool {
        guard let started = syncStarted else { return false }
        return now.timeIntervalSince(started) < 120 && (CalendarFeed.syncedAt ?? .distantPast) < started
    }

    private func syncLabel(_ now: Date) -> String {
        if !CalendarFeed.links.isEmpty, let read = CalendarFeed.linksReadAt { return "calendar links read " + read.formatted(.relative(presentation: .named)) }
        guard let synced = CalendarFeed.syncedAt else { return "Add your ManageBac link in Settings, or Sync" }
        return "synced " + synced.formatted(.relative(presentation: .named))
    }

    private func move(_ direction: Int) {
        anchor = Calendar.current.date(byAdding: .day, value: direction * span, to: anchor) ?? anchor
        selected = nil
    }

    // MARK: Week

    private func week(_ dates: [Date], _ items: [CalendarFeed.Item], _ now: Date) -> some View {
        let calendar = Calendar.current
        let timed = items.filter { !$0.allDay && $0.kind != .deadline && $0.kind != .alarm }
        let startHour = min(8, timed.map { calendar.component(.hour, from: $0.start) }.min() ?? 8)
        let endHour = max(18, (timed.map { calendar.component(.hour, from: $0.end ?? $0.start) }.max() ?? 18) + 1)
        return VStack(spacing: 0) {
            // Day names, then deadlines, all-day events and alarms for the day.
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: Self.gutter)
                ForEach(dates, id: \.self) { date in
                    let today = calendar.isDateInToday(date)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(date.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(today ? Look.accent : .secondary)
                            Text(date.formatted(.dateTime.day()))
                                .font(.system(size: 20, weight: today ? .bold : .semibold).monospacedDigit())
                                .foregroundStyle(today ? Look.accent : .primary)
                        }
                        .padding(.leading, 6)
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(items.filter { ($0.allDay || $0.kind == .deadline) && calendar.isDate($0.start, inSameDayAs: date) }) { item in
                                chip(item)
                            }
                            let alarms = items.filter { $0.kind == .alarm && calendar.isDate($0.start, inSameDayAs: date) }
                            if !alarms.isEmpty {
                                Text(alarms.map { "\($0.start.formatted(date: .omitted, time: .shortened)) \($0.title)" }.joined(separator: ", "))
                                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                                    .padding(.leading, 6)
                                    .help(alarms.map(\.title).joined(separator: ", "))
                            }
                        }
                        .padding(.horizontal, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 8)
                }
            }
            Rectangle().fill(Look.line).frame(height: 1)
            // The hours.
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(startHour..<endHour, id: \.self) { hour in
                        Text(String(format: "%02d:00", hour)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: Self.gutter - 8, height: Self.hourHeight, alignment: .topTrailing)
                            .offset(y: -6)
                    }
                }
                .frame(width: Self.gutter, alignment: .leading)
                ForEach(dates, id: \.self) { date in
                    dayColumn(date, timed.filter { calendar.isDate($0.start, inSameDayAs: date) }, startHour: startHour,
                              hours: endHour - startHour, now: now)
                }
            }
            .padding(.top, 8)
        }
    }

    private func dayColumn(_ date: Date, _ items: [CalendarFeed.Item], startHour: Int, hours: Int, now: Date) -> some View {
        let calendar = Calendar.current
        let origin = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: date) ?? date
        let y = { (time: Date) in CGFloat(time.timeIntervalSince(origin) / 3600) * Self.hourHeight }
        let lanes = Self.lanes(items)
        let today = calendar.isDateInToday(date)
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                if today { Look.accent.opacity(0.035) }
                ForEach(0..<hours, id: \.self) { hour in
                    Rectangle().fill(Look.line.opacity(0.7)).frame(height: 1).offset(y: CGFloat(hour) * Self.hourHeight)
                }
                Rectangle().fill(Look.line).frame(width: 1).frame(maxHeight: .infinity)
                ForEach(items) { item in
                    let lane = lanes[item.id] ?? (0, 1)
                    let end = item.end ?? item.start.addingTimeInterval(1800)
                    let laneWidth = (width - 6) / CGFloat(lane.count)
                    block(item, height: max(20, y(end) - y(item.start) - 2), past: end < now)
                        .frame(width: max(10, laneWidth - 2))
                        .offset(x: 3 + CGFloat(lane.index) * laneWidth, y: y(item.start) + 1)
                }
                if today, now > origin, y(now) < CGFloat(hours) * Self.hourHeight {
                    Rectangle().fill(Color.red).frame(height: 1.5).offset(y: y(now))
                    Circle().fill(Color.red).frame(width: 9, height: 9).offset(x: -4.5, y: y(now) - 3.75)
                }
            }
        }
        .frame(height: CGFloat(hours) * Self.hourHeight)
        .frame(maxWidth: .infinity)
    }

    /// Side by side where things overlap: each item's lane, and how many lanes its cluster has.
    private static func lanes(_ items: [CalendarFeed.Item]) -> [String: (index: Int, count: Int)] {
        var result: [String: (Int, Int)] = [:]
        var cluster: [(item: CalendarFeed.Item, lane: Int)] = []
        var clusterEnd = Date.distantPast
        var laneEnds: [Date] = []
        func close() {
            let count = (cluster.map(\.lane).max() ?? 0) + 1
            for entry in cluster { result[entry.item.id] = (entry.lane, count) }
            cluster = []
            laneEnds = []
        }
        for item in items.sorted(by: { $0.start < $1.start }) {
            let end = item.end ?? item.start.addingTimeInterval(1800)
            if item.start >= clusterEnd { close() }
            let lane = laneEnds.firstIndex { $0 <= item.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(end) } else { laneEnds[lane] = end }
            cluster.append((item, lane))
            clusterEnd = max(clusterEnd, end)
        }
        close()
        return result
    }

    private func color(_ item: CalendarFeed.Item) -> Color {
        switch item.kind {
        case .lesson: SubjectGroup.color(for: item.title)
        case .event: Look.personal
        case .deadline: Look.deadline
        case .alarm: Color.secondary
        }
    }

    /// A tinted block with a coloured edge, like Notion Calendar's: easy to read, quiet when many.
    private func block(_ item: CalendarFeed.Item, height: CGFloat, past: Bool) -> some View {
        let color = color(item)
        let isSelected = selected?.id == item.id
        return HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(height > 44 ? 2 : 1)
                if height > 32 {
                    Text([item.start.formatted(date: .omitted, time: .shortened), item.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
        .frame(height: height, alignment: .topLeading)
        .background(color.opacity(isSelected ? 0.3 : 0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(color.opacity(isSelected ? 0.8 : 0), lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(past ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { selected = isSelected ? nil : item } }
        .help("\(item.title) · \(Self.when(item))")
    }

    /// An all-day item or a deadline, under the day.
    private func chip(_ item: CalendarFeed.Item) -> some View {
        let color = color(item)
        return HStack(spacing: 4) {
            Image(systemName: item.kind == .deadline ? "flag.fill" : "circle.fill").font(.system(size: item.kind == .deadline ? 8 : 5))
                .foregroundStyle(color)
            Text(item.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selected = selected?.id == item.id ? nil : item }
        .help(item.title)
    }

    // MARK: Side

    private func rail(_ now: Date) -> some View {
        VStack(spacing: 16) {
            if let selected { detail(selected) }
            DueSoon(deadlines: model.deadlines, synced: CalendarFeed.syncedAt != nil || CalendarFeed.linksReadAt != nil) {}
            Card(title: "Subjects", symbol: "square.grid.2x2") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(SubjectGroup.allCases, id: \.self) { group in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(group.color).frame(width: 10, height: 10)
                            Text(group.name).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Look.personal).frame(width: 10, height: 10)
                        Text("Personal events").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func detail(_ item: CalendarFeed.Item) -> some View {
        let color = color(item)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Self.label(item))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                Spacer()
                Button { selected = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text(item.title).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Label(Self.when(item), systemImage: "clock").font(.system(size: 12.5)).foregroundStyle(.secondary)
            if !item.detail.isEmpty {
                Label(item.detail, systemImage: item.kind == .lesson ? "mappin" : "text.alignleft").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            if item.kind == .deadline || item.kind == .lesson {
                Button {
                    model.actions.ask(item.kind == .deadline ? "Help me plan for \"\(item.title)\", due \(Self.when(item))." : "What should I prepare for \(item.title) on \(Self.when(item))?")
                } label: { Label("Ask Joe about this", systemImage: "sparkle") }
                    .buttonStyle(PillButton())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.opacity(0.3)))
    }

    /// "Mathematics", "Deadline · Economics HL", "Alarm", "Event".
    private static func label(_ item: CalendarFeed.Item) -> String {
        switch item.kind {
        case .lesson: SubjectGroup.of(item.title)?.name ?? "Class"
        case .deadline: item.subject.map { "Deadline · \($0)" } ?? "Deadline"
        case .alarm: "Alarm"
        case .event: "Event"
        }
    }

    private static func when(_ item: CalendarFeed.Item) -> String {
        let day = item.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if item.allDay { return day }
        let start = item.start.formatted(date: .omitted, time: .shortened)
        return day + ", " + (item.end.map { "\(start)–\($0.formatted(date: .omitted, time: .shortened))" } ?? start)
    }
}

// MARK: - Study

/// Joe as a study buddy: a card per subject with how the quizzes have gone and a button to start one.
private struct StudyPage: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.narrow) private var narrow
    @State private var request = ""
    @State private var results: [StudyBuddy.Result] = []

    /// Their subjects from Settings, and TOK, which everyone takes.
    private var subjects: [String] {
        var list = Profile.subjects.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !list.contains(where: { StudyBuddy.pack(for: $0) == "Theory of Knowledge" }) { list.append("TOK") }
        return list
    }

    var body: some View {
        PageTitle(title: "Study", subtitle: "Joe quizzes you on the IB syllabus, from your own notes and textbooks, and marks you like an examiner.")
        HStack(spacing: 10) {
            Image(systemName: "graduationcap.fill").font(.system(size: 15)).foregroundStyle(Look.accent)
            TextField("Quiz me on… (a subject, a topic, or “my weakest topic”)", text: $request)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(start)
            Button("Start", action: start).buttonStyle(PillButton(prominent: !request.isEmpty)).disabled(request.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Look.line))
        Text("Questions open on the whiteboard: type your answer, or hold right ⌥ and say it. Joe marks it like an examiner and gives a model answer.")
            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 4)
        Card(title: "Real past papers", symbol: "doc.text.magnifyingglass") {
            Text("IB papers are sold by the IB, so Joe can't ship them. Put the ones you have (from school, IB Questionbank or a teacher) in your notes under _files/School/<subject>/Past papers, with their markschemes, and Joe asks those real questions and marks with the real markscheme. Otherwise he writes questions in the exact style of each paper.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }

        let columns = narrow ? 1 : 2
        let rows = stride(from: 0, to: subjects.count, by: columns).map { Array(subjects[$0..<min($0 + columns, subjects.count)]) }
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index], id: \.self) { subject in card(subject) }
                    if rows[index].count < columns { Color.clear }
                }
            }
        }

        if !Profile.programme.uppercased().contains("MYP") { PointsCalculator(subjects: subjects.filter { StudyBuddy.pack(for: $0) != "Theory of Knowledge" }) }

        Card(title: "Recent answers", symbol: "checkmark.seal") {
            if results.isEmpty {
                Text("Nothing yet. Start a quiz and each marked answer shows up here (and in “Quiz log” in your notes).")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(Array(results.suffix(8).reversed().enumerated()), id: \.offset) { _, result in
                HStack(spacing: 10) {
                    Text("\(result.score)/\(result.total)").font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Self.color(result.score, result.total))
                        .frame(width: 40, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.topic).font(.system(size: 13)).lineLimit(1)
                        Text([result.subject, result.note].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(result.date).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { results = StudyBuddy.results() }
    }

    private func card(_ subject: String) -> some View {
        let pack = StudyBuddy.pack(for: subject)
        let mine = results.filter { StudyBuddy.pack(for: $0.subject) == pack && pack != nil }
        let scored = mine.reduce(0) { $0 + $1.score }, possible = mine.reduce(0) { $0 + $1.total }
        let weakest = Dictionary(grouping: mine, by: \.topic)
            .map { (topic: $0.key, ratio: Double($0.value.reduce(0) { $0 + $1.score }) / Double(max(1, $0.value.reduce(0) { $0 + $1.total }))) }
            .min { $0.ratio < $1.ratio }
        let color = SubjectGroup.of(subject)?.color ?? Look.accent
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subject).font(.system(size: 15, weight: .semibold))
                    Text(SubjectGroup.of(subject)?.name ?? "DP core").font(.system(size: 11.5)).foregroundStyle(color)
                }
                Spacer()
                if possible > 0 {
                    Text("\(Int((Double(scored) / Double(possible) * 100).rounded()))%")
                        .font(.system(size: 18, weight: .bold).monospacedDigit())
                        .foregroundStyle(Self.color(scored, possible))
                }
            }
            Group {
                if mine.isEmpty {
                    Text(pack == nil ? "No syllabus map yet: Joe uses your notes and what he knows." : "Not quizzed yet.")
                } else {
                    Text("\(mine.count) answered" + (weakest.map { " · weakest: \($0.topic)" } ?? ""))
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button { model.actions.ask("Quiz me on \(subject): five questions, mixed topics, focusing on my weak spots.") } label: {
                    Label("Quiz me", systemImage: "play.fill")
                }
                .buttonStyle(PillButton(prominent: true))
                Button("Exam question") {
                    model.actions.ask("Give me one full exam-style \(subject) question, like a real paper, and mark my answer.")
                }
                .buttonStyle(PillButton())
                if let weakest {
                    Button("Revise weakest") { model.actions.ask("Quiz me on \(subject), topic \(weakest.topic).") }
                        .buttonStyle(PillButton())
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Look.line))
    }

    private static func color(_ score: Int, _ total: Int) -> Color {
        let ratio = Double(score) / Double(max(total, 1))
        return ratio >= 0.7 ? .green : ratio >= 0.45 ? .orange : Look.deadline
    }

    private func start() {
        let text = request.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.actions.ask(text.lowercased().hasPrefix("quiz") ? text : "Quiz me on \(text)")
        request = ""
    }
}

/// "What would I get?": predicted grades for each subject (1–7) plus the core points from TOK
/// and the EE (the IB's matrix), out of 45, with the conditions that fail a diploma.
private struct PointsCalculator: View {
    let subjects: [String]
    @AppStorage("predictedGrades") private var stored = "{}"
    @AppStorage("predictedTOK") private var tok = "B"
    @AppStorage("predictedEE") private var ee = "B"

    private var grades: [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: Data(stored.utf8))) ?? [:]
    }

    private func grade(_ subject: String) -> Binding<Int> {
        Binding(get: { grades[subject] ?? 5 }, set: { value in
            var all = grades
            all[subject] = value
            stored = (try? String(data: JSONEncoder().encode(all), encoding: .utf8)) ?? "{}"
        })
    }

    /// TOK × EE → core points; nil means a failing E.
    static func core(_ tok: String, _ ee: String) -> Int? {
        let order = ["A", "B", "C", "D"]
        guard let t = order.firstIndex(of: tok), let e = order.firstIndex(of: ee) else { return nil }
        let matrix = [[3, 3, 2, 2], [3, 2, 1, 1], [2, 1, 1, 0], [2, 1, 0, 0]]
        return matrix[t][e]
    }

    var body: some View {
        let subjectTotal = subjects.reduce(0) { $0 + grade($1).wrappedValue }
        let corePoints = Self.core(tok, ee)
        let total = subjectTotal + (corePoints ?? 0)
        let problems = [corePoints == nil ? "An E in TOK or the EE fails the diploma." : nil,
                        total < 24 ? "Under 24 points fails the diploma." : nil,
                        subjects.contains { grade($0).wrappedValue == 1 } ? "A grade 1 in any subject fails the diploma." : nil].compactMap { $0 }
        Card(title: "Predicted points", symbol: "function") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(total)").font(.system(size: 34, weight: .bold).monospacedDigit())
                    .foregroundStyle(problems.isEmpty ? (total >= 38 ? Color.green : total >= 30 ? Color.primary : Color.orange) : Color.red)
                Text("/ 45").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(subjectTotal) from subjects + \(corePoints.map(String.init) ?? "0") core").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(subjects, id: \.self) { subject in
                HStack {
                    RoundedRectangle(cornerRadius: 2).fill(SubjectGroup.of(subject)?.color ?? Look.accent).frame(width: 4, height: 16)
                    Text(subject).font(.system(size: 13))
                    Spacer()
                    Picker("", selection: grade(subject)) { ForEach((1...7).reversed(), id: \.self) { Text("\($0)").tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                }
            }
            HStack(spacing: 16) {
                Text("TOK").font(.system(size: 13))
                Picker("", selection: $tok) { ForEach(["A", "B", "C", "D", "E"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Spacer()
                Text("EE").font(.system(size: 13))
                Picker("", selection: $ee) { ForEach(["A", "B", "C", "D", "E"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            ForEach(problems, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(.red) }
            Text("Also needed for a diploma: CAS completed, at least 12 points from HL subjects and 9 from SL, and no academic misconduct.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Routines

private struct RoutinesPage: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.narrow) private var narrow
    @State private var idea = ""

    var body: some View {
        PageTitle(title: "Routines", subtitle: "Say a routine's phrase and Joe runs it. Tell him to change one any time.")
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").font(.system(size: 16)).foregroundStyle(Look.accent)
            TextField("New routine: when I say “let's work on WellPrepped”, open my creator pipeline…", text: $idea)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(save)
            Button("Save", action: save).buttonStyle(PillButton(prominent: !idea.isEmpty)).disabled(idea.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Look.line))
        // Two to a row, each row as tall as its taller card, so the grid lines up.
        let columns = narrow ? 1 : 2
        let rows = stride(from: 0, to: model.routines.count, by: columns).map { Array(model.routines[$0..<min($0 + columns, model.routines.count)]) }
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index], id: \.name) { routine in card(routine) }
                    if rows[index].count < columns { Color.clear }
                }
            }
        }
    }

    private func card(_ routine: (name: String, trigger: String)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").font(.system(size: 12)).foregroundStyle(Look.accent)
                Text(routine.name).font(.system(size: 14.5, weight: .semibold))
            }
            Text(routine.trigger).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                Button { model.actions.ask("Run my “\(routine.name)” routine.") } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(PillButton(prominent: true))
                if let url = Daybook.routinesURL {
                    Button("Edit") { model.openInObsidian(url) }.buttonStyle(PillButton())
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Look.line))
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
    @State private var kind: Alarm.Kind = .alarm
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var label = ""
    @State private var days: Set<Int> = []
    @State private var minutes = 25
    @State private var request = ""
    @State private var problem: String?
    @State private var done: String?

    private static let dayLetters = [(2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"), (1, "S")]

    var body: some View {
        PageTitle(title: "Alarms", subtitle: "They ring loudly on this Mac (lid open), with Stop and Snooze, and on your iPhone through Reminders.")
        Card(title: "New", symbol: "plus") {
            Picker("", selection: $kind) {
                Label("Alarm", systemImage: "alarm").tag(Alarm.Kind.alarm)
                Label("Timer", systemImage: "timer").tag(Alarm.Kind.timer)
                Label("Reminder", systemImage: "bell").tag(Alarm.Kind.reminder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            if kind == .timer {
                HStack(spacing: 6) {
                    ForEach([5, 10, 15, 25, 30, 45, 60], id: \.self) { value in
                        Button("\(value) min") { minutes = value }.buttonStyle(PillButton(prominent: minutes == value))
                    }
                }
                Stepper(value: $minutes, in: 1...720) {
                    Text("\(minutes) minutes").font(.system(size: 13, weight: .medium).monospacedDigit())
                }
            } else {
                HStack(alignment: .center, spacing: 22) {
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                        .controlSize(.large)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            ForEach(Self.dayLetters, id: \.0) { day, letter in
                                Button { if days.contains(day) { days.remove(day) } else { days.insert(day) } } label: {
                                    Text(letter).font(.system(size: 12, weight: .semibold))
                                        .frame(width: 26, height: 26)
                                        .foregroundStyle(days.contains(day) ? Color.white : .secondary)
                                        .background(days.contains(day) ? Look.accent : Color.primary.opacity(0.06), in: Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 10) {
                            preset("Once", [])
                            preset("Weekdays", [2, 3, 4, 5, 6])
                            preset("Weekends", [1, 7])
                            preset("Every day", Set(1...7))
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                TextField(kind == .timer ? "Label: pasta, focus…" : kind == .reminder ? "What to remind you about" : "Label: Go to school, gym…", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(set)
                Button(kind == .timer ? "Start timer" : "Set \(kind.rawValue)", action: set)
                    .buttonStyle(PillButton(prominent: true))
            }
            Text(done ?? preview).font(.system(size: 12)).foregroundStyle(done == nil ? Color.secondary : Color.green)
        }

        Card(title: "Coming up", symbol: "alarm") {
            if model.alarms.isEmpty { Text("Nothing set.").foregroundStyle(.secondary).font(.system(size: 13)) }
            ForEach(Array(model.alarms.enumerated()), id: \.element.id) { index, alarm in
                HStack(spacing: 14) {
                    Image(systemName: alarm.kind == .timer ? "timer" : alarm.kind == .reminder ? "bell.fill" : "alarm.fill")
                        .foregroundStyle(Look.accent)
                        .frame(width: 34, height: 34)
                        .background(Look.accent.opacity(0.13), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alarm.when).font(.system(size: 20, weight: .semibold).monospacedDigit())
                        Text([alarm.title, alarm.repeats.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Self.countdown(alarm.fireAt)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Button { model.actions.cancelAlarm(alarm.id); model.reload() } label: { Image(systemName: "xmark") }
                        .buttonStyle(PillButton())
                        .help("Cancel")
                }
                .padding(.vertical, 6)
                if index < model.alarms.count - 1 { Rectangle().fill(Look.line).frame(height: 1) }
            }
        }

        Card(title: "Or type it", symbol: "text.cursor") {
            HStack {
                TextField("Timer for 25 minutes · alarm at 6:30 every weekday · remind me at 3pm to submit the form", text: $request)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Set", action: add).buttonStyle(PillButton()).disabled(request.isEmpty)
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.orange) }
        }
    }

    private func preset(_ title: String, _ value: Set<Int>) -> some View {
        Button(title) { days = value }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: days == value ? .semibold : .regular))
            .foregroundStyle(days == value ? Look.accent : .secondary)
    }

    /// The alarm as set from the controls.
    private var draft: Alarm {
        let now = Date()
        let name = label.trimmingCharacters(in: .whitespaces)
        if kind == .timer {
            return Alarm(fireAt: now.addingTimeInterval(Double(minutes) * 60), title: name.isEmpty ? "\(minutes)-minute timer" : name, kind: .timer)
        }
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        var fire = calendar.date(bySettingHour: parts.hour ?? 7, minute: parts.minute ?? 0, second: 0, of: now) ?? now
        if fire <= now { fire = calendar.date(byAdding: .day, value: 1, to: fire) ?? fire }
        var alarm = Alarm(fireAt: fire, title: name.isEmpty ? (kind == .reminder ? "Reminder" : "Alarm") : name, kind: kind, repeats: repeats)
        if let next = alarm.next(after: now) { alarm.fireAt = next }
        return alarm
    }

    private var repeats: String? {
        switch days {
        case []: return nil
        case Set(1...7): return "daily"
        case [2, 3, 4, 5, 6]: return "weekdays"
        case [1, 7]: return "weekends"
        default:
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            return days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { names[$0 - 1] }.joined(separator: ",")
        }
    }

    private var preview: String {
        let alarm = draft
        let when = Calendar.current.isDateInToday(alarm.fireAt) ? "today" : Calendar.current.isDateInTomorrow(alarm.fireAt) ? "tomorrow" : alarm.fireAt.formatted(.dateTime.weekday(.wide))
        return kind == .timer ? "Rings at \(alarm.fireAt.formatted(date: .omitted, time: .shortened))."
            : "Rings \(when) at \(alarm.fireAt.formatted(date: .omitted, time: .shortened)), \(Self.countdown(alarm.fireAt))" + (repeats.map { ", then \($0)." } ?? ".")
    }

    private func set() {
        let alarm = draft
        model.actions.addAlarm(.add(alarm))
        done = "Set: \(alarm.title), \(alarm.when)."
        label = ""
        model.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { done = nil }
    }

    private static func countdown(_ date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSinceNow / 60))
        if minutes < 60 { return "in \(minutes) min" }
        if minutes < 24 * 60 { return "in \(minutes / 60) h \(minutes % 60) min" }
        return "in \(minutes / (24 * 60)) d \(minutes / 60 % 24) h"
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
    @State private var kind = "All"

    var body: some View {
        PageTitle(title: "Notes", subtitle: "Lecture and meeting notes from the notepad, saved in your Obsidian vault.")
        HStack(spacing: 10) {
            Button { model.actions.openNotepad() } label: { Label("Open the notepad", systemImage: "square.and.pencil") }
                .buttonStyle(PillButton(prominent: true))
            Text("Or say “take notes, this is a lecture”.").font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $kind) {
                ForEach(["All", "Lecture", "Meeting", "Notes"], id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
        }
        let shown = model.notes.filter { kind == "All" || $0.kind.hasPrefix(kind) }
        let calendar = Calendar.current
        let days = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        if shown.isEmpty {
            Card { Text(model.notes.isEmpty ? "No saved notes yet." : "None of this kind yet.").foregroundStyle(.secondary).font(.system(size: 13)) }
        }
        ForEach(days, id: \.key) { day, notes in
            VStack(alignment: .leading, spacing: 8) {
                Text(calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday" : day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(notes.enumerated()), id: \.element.url) { index, note in
                        if index > 0 { Divider().padding(.leading, 52) }
                        Button { model.openInObsidian(note.url) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: note.kind.hasPrefix("Lecture") ? "graduationcap" : note.kind.hasPrefix("Meeting") ? "person.2" : "note.text")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Look.accent)
                                    .frame(width: 28, height: 28)
                                    .background(Look.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                                    Text(note.kind).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(note.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.tertiary)
                                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Look.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Look.line))
            }
        }
    }
}

// MARK: - Dictionary

/// The dictionary as a list: words and names spelled their way (fixed when they sound close) and
/// exact swaps ("manage back" → ManageBac). Same file as before, so Joe and the old format still work.
private struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

private struct DictionaryPage: View {
    @Environment(\.narrow) private var narrow
    struct Entry: Identifiable, Hashable {
        var written: String
        var heard: String // empty: fixed by sound
        var id: String { heard + "→" + written }
        var line: String { heard.isEmpty ? written : "\(heard) -> \(written)" }
    }

    @State private var entries: [Entry] = []
    @State private var header: [String] = []
    @State private var word = ""
    @State private var heardAs = ""
    @State private var search = ""
    @State private var trial = ""
    @State private var editingText = false
    @State private var raw = ""

    var body: some View {
        PageTitle(title: "Dictionary", subtitle: "Names and words Joe always spells your way, in dictation and when you ask him things.")

        HStack(spacing: 12) {
            count("\(entries.filter { $0.heard.isEmpty }.count)", "words and names", "textformat")
            count("\(entries.filter { !$0.heard.isEmpty }.count)", "exact swaps", "arrow.left.arrow.right")
        }

        Card(title: "Add", symbol: "plus") {
            HStack(spacing: 10) {
                TextField("Spelled: Ammiel, ManageBac, WellPrepped", text: $word).textFieldStyle(.roundedBorder).onSubmit(add)
                TextField("Joe hears (optional): manage back", text: $heardAs).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).buttonStyle(PillButton(prominent: true)).disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Leave “Joe hears” empty and he fixes anything that sounds close. Fill it in and he swaps those exact words every time.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }

        Card(title: "Try it", symbol: "wand.and.stars") {
            TextField("Type a sentence the way Joe might mishear it…", text: $trial).textFieldStyle(.roundedBorder)
            if !trial.isEmpty {
                let fixed = Vocabulary.apply(trial)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: fixed == trial ? "equal.circle" : "checkmark.circle.fill").foregroundStyle(fixed == trial ? Color.secondary : Color.green)
                    Text(fixed == trial ? "No changes." : fixed).font(.system(size: 13)).textSelection(.enabled)
                }
            }
        }

        Card(title: "Your words", symbol: "character.book.closed") {
            HStack {
                SearchField(text: $search, prompt: "Search your words")
                Spacer()
                Button(editingText ? "Done" : "Edit as text") {
                    if editingText { saveRaw() } else { raw = (try? String(contentsOf: Vocabulary.url, encoding: .utf8)) ?? "" }
                    editingText.toggle()
                }
                .buttonStyle(PillButton())
            }
            if editingText {
                TextEditor(text: $raw)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else {
                let shown = entries.filter { search.isEmpty || $0.written.localizedCaseInsensitiveContains(search) || $0.heard.localizedCaseInsensitiveContains(search) }
                if shown.isEmpty {
                    Text(entries.isEmpty ? "No words yet. Add names Joe gets wrong: teachers, friends, products." : "Nothing matches.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: narrow ? 1 : 2), spacing: 10) {
                    ForEach(shown) { entry in
                        HStack(spacing: 10) {
                            Circle().fill(entry.heard.isEmpty ? Look.accent : Color.blue).frame(width: 7, height: 7)
                                .help(entry.heard.isEmpty ? "Fixed when it sounds close" : "Exact swap")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.written).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                                if !entry.heard.isEmpty {
                                    Text("heard as “\(entry.heard)”").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            Button { remove(entry) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove")
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
                HStack(spacing: 14) {
                    Label("Sounds like", systemImage: "circle.fill").foregroundStyle(Look.accent)
                    Label("Exact swap", systemImage: "circle.fill").foregroundStyle(.blue)
                }
                .font(.system(size: 11))
                .labelStyle(DotLabel())
            }
        }
        .onAppear(perform: load)
    }

    private func count(_ value: String, _ label: String, _ symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Look.accent).frame(width: 32, height: 32).background(Look.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 20, weight: .bold).monospacedDigit())
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Look.line))
    }

    private func load() {
        let text = (try? String(contentsOf: Vocabulary.url, encoding: .utf8)) ?? ""
        header = []
        entries = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { header.append(line); continue }
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
            entries.append(parts.count == 2 ? Entry(written: parts[1], heard: parts[0]) : Entry(written: trimmed, heard: ""))
        }
    }

    private func save() {
        if header.isEmpty { header = ["# Your dictionary (edited in Joe → Dictionary). A word per line; “heard -> Written” for an exact swap."] }
        let text = (header + [""] + entries.map(\.line)).joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: Vocabulary.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: Vocabulary.url, atomically: true, encoding: .utf8)
    }

    private func saveRaw() {
        try? raw.write(to: Vocabulary.url, atomically: true, encoding: .utf8)
        load()
    }

    private func add() {
        let written = word.trimmingCharacters(in: .whitespaces), heard = heardAs.trimmingCharacters(in: .whitespaces)
        guard !written.isEmpty else { return }
        let entry = Entry(written: written, heard: heard)
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        save()
        word = ""
        heardAs = ""
    }

    private func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
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
                // Never disabled: clicking again while it waits opens the sign-in page again.
                Button(model.spotifyBusy ? "Open sign-in again" : model.spotifyConnected ? "Reconnect" : "Connect") { model.connectSpotify() }
                    .buttonStyle(PillButton(prominent: !model.spotifyConnected))
            }
            if let message = model.spotifyMessage {
                Text(message).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    @State private var permissionsSeen = 0
    @State private var voiceLearned = 0
    @AppStorage("useAPIKey") private var useAPIKey = false
    @AppStorage("ibQuestion") private var ibQuestion = true
    @AppStorage("wakeChallenge") private var wakeChallenge = true
    @AppStorage("reduceNoise") private var reduceNoise = true
    @AppStorage("liveCaption") private var liveWords = true
    @AppStorage("notchOverview") private var overviewOn = true
    @State private var overviewWidgets = NotchOverview.widgets.map(\.rawValue)
    @AppStorage("chineseVoice") private var chineseVoice = "zf_001"
    @AppStorage("modelMirrorChina") private var chinaMirror = false
    @AppStorage("profileSchool") private var profileSchool = ""
    @AppStorage("profileProgramme") private var profileProgramme = ""
    @AppStorage("profileSubjects") private var profileSubjects = ""
    @AppStorage("profileProject") private var profileProject = ""

    private func profileRow(_ label: String, _ detail: String, _ value: Binding<String>, _ placeholder: String) -> some View {
        row(label, detail) {
            TextField(placeholder, text: value)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 12)
                .frame(width: 280, height: 28)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(Look.line))
        }
    }
    @State private var apiKeyDraft = ""
    @State private var openRouterDraft = ""
    @AppStorage("useOpenRouter") private var useOpenRouter = false
    @AppStorage("openRouterModel") private var openRouterModel = "openrouter/auto"
    @AppStorage("customEndpoint") private var customEndpoint = "https://openrouter.ai/api"
    @AppStorage("strongModelForWork") private var strongForWork = true
    @AppStorage("assistantModel") private var assistantModel = Assistant.Model.opus.rawValue
    @AppStorage("assistantEffort") private var effort = Assistant.Effort.low.rawValue
    @AppStorage("assistantAutonomy") private var autonomy = Assistant.Autonomy.careful.rawValue
    @AppStorage("rememberConversations") private var remember = true
    @AppStorage("saveNotesToVault") private var saveNotes = true
    @AppStorage("keepHistory") private var keepHistory = true
    @AppStorage("screenAware") private var screenAware = true
    @AppStorage("speakBriefing") private var speakBriefing = true
    @AppStorage("userName") private var userName = ""
    @AppStorage("joeChattiness") private var chattiness = "normal"
    @AppStorage("joeTone") private var tone = "direct"
    @AppStorage("joeHype") private var hype = false
    @State private var notch = Notch.isEnabled
    @State private var speechLanguages = Transcriber.languages.rawValue
    @State private var cleanup = UserDefaults.standard.bool(forKey: "aiCleanup")
    @State private var control = ScreenControl.isEnabled
    @State private var voice = SpeechOutput.engine
    @State private var login = false // read on appear: asking macOS is slow, too slow for every redraw

    @AppStorage("settingsTab") private var tab = "general"
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage(Theme.key) private var theme = Theme.classic.rawValue
    @State private var newLink = ""
    @State private var calendarLinks = CalendarFeed.links

    private func addLink() {
        let link = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.contains("://") else { return }
        CalendarFeed.links = Array(Set(CalendarFeed.links + [link]))
        calendarLinks = CalendarFeed.links
        newLink = ""
        Task { await CalendarFeed.refreshLinks() }
    }
    @AppStorage("alarmsAtNotch") private var alarmsAtNotch = "full"

    private static let tabs: [(id: String, title: String, symbol: String)] = [
        ("general", "General", "gearshape"),
        ("personality", "Personality", "face.smiling"),
        ("automations", "Automations", "clock.badge.checkmark"),
        ("privacy", "Privacy", "lock"),
        ("advanced", "Advanced", "slider.horizontal.3"),
    ]

    var body: some View {
        PageTitle(title: "Settings")
            .onAppear { login = SMAppService.mainApp.status == .enabled }

        HStack(spacing: 4) {
            ForEach(Self.tabs, id: \.id) { item in
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = item.id } } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 13, weight: tab == item.id ? .semibold : .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(tab == item.id ? Look.card : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tab == item.id ? Look.line : .clear))
                        .foregroundStyle(tab == item.id ? .primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

        switch tab {
        case "personality": personality
        case "automations": automations
        case "privacy": privacy
        case "advanced": advanced
        default: general
        }
    }

    @ViewBuilder private var general: some View {
        section("You", "person.crop.circle") {
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
            profileRow("School", "Where you study", $profileSchool, "Your school")
            profileRow("Programme", "e.g. IB Diploma, year 1 (DP1)", $profileProgramme, "IB Diploma, year 1")
            profileRow("Subjects", "Joe’s IB help and daily question use these", $profileSubjects, "Math AI HL, ESS SL…")
            profileRow("Your project", "A business or club Joe should know about", $profileProject, "Optional")
            row("Welcome tour", "See the first-launch tour again; your settings stay") {
                Button("Replay") { model.actions.showOnboarding() }.buttonStyle(PillButton())
            }
            row("Calendar links", calendarLinks.isEmpty ? "ManageBac: Calendar → Subscribe → copy the link. Google: settings → Secret address in iCal format" : "\(calendarLinks.count) added: read every half hour") {
                HStack(spacing: 6) {
                    TextField("Paste a calendar link", text: $newLink)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .padding(.horizontal, 10).frame(width: 200, height: 28)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .onSubmit(addLink)
                    Button("Add", action: addLink).buttonStyle(PillButton()).disabled(!newLink.contains("://"))
                    if !calendarLinks.isEmpty {
                        Button("Clear") { CalendarFeed.links = []; calendarLinks = [] }.buttonStyle(PillButton(destructive: true))
                    }
                }
            }
            row("Style", "How Joe looks: Classic, Midnight (navy and gold), Paper (serif, warm) or Ocean") {
                Choice(options: Theme.allCases.map { ($0.rawValue, $0.title) }, selection: $theme)
                    .onChange(of: theme) { AppAppearance.apply() }
            }
            row("Appearance", "Light, dark, or follow the Mac") {
                Choice(options: AppAppearance.allCases.map { ($0.rawValue, $0.title) }, selection: $appearance)
                    .onChange(of: appearance) { AppAppearance.apply() }
            }
            row("Open Joe at login", last: true) {
                switchOn($login) { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSSound.beep() }
                }
            }
        }
        section("Dictation", "waveform") {
            row("Writing style", "How your dictation is punctuated") {
                Choice(options: WritingStyle.allCases.map { ($0.rawValue, $0.title) }, selection: $writingStyle)
            }
            row("Microphone") {
                Choice(options: [("", "Automatic")] + model.actions.microphones().map { ($0.uid, $0.name) }, selection: $microphone)
            }
            row("Live words", "Shows what you're saying under the pill as you talk") { switchOn($liveWords) }
            row("Reduce background noise", "Takes out fans and chatter before your words are written, on this Mac") { switchOn($reduceNoise) }
            row("Languages", "What you speak to Joe in. English only stops it mishearing you as Russian", last: true) {
                Choice(options: [("english", "English only"), ("chinese", "English + Chinese"), ("european", "25 European languages")],
                       selection: $speechLanguages)
                    .onChange(of: speechLanguages) { model.actions.setSpeechLanguages(speechLanguages) }
            }
        }
        section("Notch", "rectangle.topthird.inset.filled") {
            row("Overview on hover", "Rest the pointer on the notch: time, next class, what's due, your tasks, music") { switchOn($overviewOn) }
            row("Overview widgets", overviewWidgets.map { NotchOverview.Widget(rawValue: $0)?.title ?? $0 }.joined(separator: " · ")) {
                Menu {
                    ForEach(NotchOverview.Widget.allCases) { widget in
                        Button {
                            if overviewWidgets.contains(widget.rawValue) { overviewWidgets.removeAll { $0 == widget.rawValue } }
                            else { overviewWidgets.append(widget.rawValue) }
                            NotchOverview.widgets = overviewWidgets.compactMap(NotchOverview.Widget.init)
                        } label: {
                            if overviewWidgets.contains(widget.rawValue) { Label(widget.title, systemImage: "checkmark") } else { Text(widget.title) }
                        }
                    }
                    Divider()
                    ForEach(Array(overviewWidgets.enumerated()), id: \.offset) { index, raw in
                        if index > 0 {
                            Button("Move \(NotchOverview.Widget(rawValue: raw)?.title ?? raw) left") {
                                overviewWidgets.swapAt(index, index - 1)
                                NotchOverview.widgets = overviewWidgets.compactMap(NotchOverview.Widget.init)
                            }
                        }
                    }
                } label: { Text("Choose…") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            row("Answers at the notch", "Answers drop down from the notch") { switchOn($notch) { model.actions.setNotch($0) } }
            row("Alarms at the notch", "The capsule beside the notch", last: true) {
                Choice(options: [("full", "Time"), ("icon", "Icon only"), ("soon", "Last hour only"), ("off", "Hidden")], selection: $alarmsAtNotch)
            }
        }
        section("Joe", "power") {
            row("Quit Joe", "Dictation and the notch stop until you open Joe again", last: true) {
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(PillButton())
            }
        }
    }

    @ViewBuilder private var personality: some View {
        section("How Joe talks", "bubble.left.and.text.bubble.right") {
            row("Answers", "How much Joe says") {
                Choice(options: [("brief", "Brief"), ("normal", "Normal"), ("chatty", "Chatty")], selection: $chattiness)
            }
            row("Tone", "How Joe puts things") {
                Choice(options: [("gentle", "Gentle"), ("direct", "Direct"), ("blunt", "Blunt")], selection: $tone)
            }
            row("Hype you up", "Joe cheers when you get things done", last: true) { switchOn($hype) }
        }
        section("Voice", "speaker.wave.2") {
            row("Joe's voice", "Joe answers out loud in Alba's voice") {
                Choice(options: [(SpeechOutput.Engine.lifelike, "On"), (.off, "Off")], selection: $voice)
                    .onChange(of: voice) { model.actions.setVoice(voice) }
            }
            row("Chinese voice", "Used for sentences in Chinese") {
                Choice(options: SpeechOutput.chineseVoices.map { ($0.id, $0.name) }, selection: $chineseVoice)
            }
            row("Read briefings aloud", last: true) { switchOn($speakBriefing) }
        }
    }

    @ViewBuilder private var automations: some View {
        section("Every day", "sun.horizon") {
            row("Morning briefing", "On your first wake of the day") { switchOn($morning) }
            row("Evening check", "19:30: new ManageBac tasks and grades into your Daybook") { switchOn($evening) }
            row("Night shutdown", "21:30 on school nights") { switchOn($night) }
            row("IB question of the day", "One short question from your subjects, at the end of the morning brief") { switchOn($ibQuestion) }
            row("Wake-up challenge", "Morning alarms only stop once you read a verse or a fact aloud, or answer a question (right ⌥)", last: true) { switchOn($wakeChallenge) }
        }
        section("iPhone", "iphone") {
            row("Alarms on iPhone", "Copies alarms to a “Joe” list in Reminders") { switchOn($toReminders) }
            row("Ask from iPhone", "“Hey Siri, add … to Ask Joe”", last: true) { switchOn($phoneRemote) }
        }
        section("Hands-free", "ear") {
            row("“Hey Joe”", "Talk without a key. On your Mac only; the mic stays on") { switchOn($wakeWord) }
            row("Your voice", voiceLearned >= 3 ? "Learned from \(voiceLearned) recordings: Joe listens for you, not the room"
                    : "Learning: talk to Joe holding the key a few times (\(voiceLearned) of 3)", last: true) {
                Button("Reset") {
                    Task { await VoicePrint.shared.reset(); voiceLearned = 0 }
                }
                .buttonStyle(PillButton())
                .disabled(voiceLearned == 0)
            }
            .task { voiceLearned = await VoicePrint.shared.learned }
        }
    }

    @ViewBuilder private var privacy: some View {
        section("What Joe keeps", "tray.full") {
            row("Look at my screen", "Every question goes with the window in front, so you don't have to say “screen”. "
                    + "Never password managers") { switchOn($screenAware) }
            row("Keep history", "What you dictate and ask, on this Mac only") { switchOn($keepHistory) }
            row("Remember conversations", "A log in your vault, Joe's memory of past days") { switchOn($remember) }
            row("Save notes to Obsidian", "When the notepad closes") { switchOn($saveNotes) }
            row("Clear history", last: true) {
                Button("Clear") { ActivityLog.clear(); model.reload() }.buttonStyle(PillButton(destructive: true))
            }
        }
        section("Permissions", "checkmark.shield") {
            permission("Accessibility", "Typing and shortcuts", AXIsProcessTrusted(), "Privacy_Accessibility")
            permission("Microphone", "Hearing you", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Privacy_Microphone")
            permission("Screen Recording", "Reading your screen", CGPreflightScreenCaptureAccess(), "Privacy_ScreenCapture")
            let reminders = EKEventStore.authorizationStatus(for: .reminder)
            permission("Reminders", "Alarms on iPhone, Ask from iPhone", reminders == .fullAccess, "Privacy_Reminders",
                       ask: reminders == .notDetermined ? { done in ReminderMirror.store.requestFullAccessToReminders { _, _ in done() } } : nil)
            let events = EKEventStore.authorizationStatus(for: .event)
            permission("Calendar", "Your Mac's calendars on Joe's Calendar page (optional)", events == .fullAccess, "Privacy_Calendars",
                       ask: events == .notDetermined ? { done in CalendarFeed.requestMacCalendar(done) } : nil)
            let speech = SFSpeechRecognizer.authorizationStatus()
            permission("Speech Recognition", "“Hey Joe”", speech == .authorized, "Privacy_SpeechRecognition", last: true,
                       ask: speech == .notDetermined ? { done in SFSpeechRecognizer.requestAuthorization { _ in done() } } : nil)
                .id(permissionsSeen)
        }
    }

    @ViewBuilder private var advanced: some View {
        section("AI account", "creditcard") {
            row("Pay for Claude with", useAPIKey ? "An Anthropic API key, billed per request" : "The Claude plan Claude Code is signed in to", last: !useAPIKey) {
                Choice(options: [(false, "Claude plan"), (true, "API key")], selection: $useAPIKey)
            }
            if useAPIKey {
                row("API key", AIAccount.maskedKey.map { "Saved: \($0). New conversations use it." } ?? "From console.anthropic.com → API keys", last: true) {
                    HStack(spacing: 8) {
                        SecureField("sk-ant-…", text: $apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        Button("Save") { AIAccount.save(apiKeyDraft); apiKeyDraft = ""; model.settingsVersion += 1 }
                            .buttonStyle(PillButton(prominent: true))
                            .disabled(apiKeyDraft.count < 20)
                    }
                }
            }
        }
        section("Other models and custom APIs", "square.stack.3d.up") {
            row("Use another model", "GPT, DeepSeek, Qwen, Gemini… through OpenRouter, or your own Anthropic-compatible API. Gmail, Calendar and Chrome connectors aren't available in this mode") {
                switchOn($useOpenRouter)
            }
            row("Endpoint", "OpenRouter, or any Anthropic-compatible base URL (LiteLLM, a gateway, a local server)") {
                TextField("https://openrouter.ai/api", text: $customEndpoint)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
            row("API key", AIAccount.maskedOpenRouterKey.map { "Saved: \($0)" } ?? "OpenRouter: openrouter.ai → Keys") {
                HStack(spacing: 8) {
                    SecureField("sk-or-…", text: $openRouterDraft).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button("Save") { AIAccount.save(openRouterDraft, as: "openRouterKey"); openRouterDraft = ""; model.settingsVersion += 1 }
                        .buttonStyle(PillButton(prominent: true)).disabled(openRouterDraft.count < 20)
                }
            }
            row("Model", "An OpenRouter model ID, e.g. openai/…, deepseek/…, qwen/…; openrouter/auto picks one", last: true) {
                TextField("openrouter/auto", text: $openRouterModel)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
        }
        section("Brain", "cpu") {
            row("Model", "Smarter, or faster and lighter on your usage") {
                Choice(options: Assistant.Model.allCases.map { ($0.rawValue, $0.name) }, selection: $assistantModel)
            }
            row("Opus for big jobs", "Doing schoolwork or designing slides switches to Opus. Off: everything stays on the model above") {
                switchOn($strongForWork)
            }
            row("Effort", "How hard Joe thinks before answering", last: true) {
                Choice(options: Assistant.Effort.allCases.map { ($0.rawValue, $0.name) }, selection: $effort)
            }
        }
        section("Control", "hand.raised") {
            row("Permissions", (Assistant.Autonomy(rawValue: autonomy)?.title.components(separatedBy: ": ").dropFirst().first).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "What Joe may do without asking") {
                Choice(options: Assistant.Autonomy.allCases.map { ($0.rawValue, $0.title.components(separatedBy: ":")[0]) }, selection: $autonomy)
            }
            row("Click and type", "Joe can use your mouse and keyboard") { switchOn($control) { model.actions.setScreenControl($0) } }
            row("AI cleanup", "Removes filler words from dictation, on this Mac", last: true) { switchOn($cleanup) { model.actions.setCleanup($0) } }
        }
        section("Downloads", "arrow.down.circle") {
            row("Download models from", chinaMirror ? "HF-Mirror: works in mainland China without a VPN" : "Hugging Face", last: true) {
                Choice(options: [(false, "Hugging Face"), (true, "China mirror")], selection: Binding(
                    get: { chinaMirror }, set: { chinaMirror = $0; ModelDownloads.useChinaMirror = $0 }))
            }
        }
        section("Memory", "brain") {
            row("Memory vault", Assistant.vaultURL?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "None") {
                Button("Choose…") { model.actions.chooseVault() }.buttonStyle(PillButton())
            }
            row("Instructions", "Your standing notes for Joe", last: true) {
                Button("Edit…") { Assistant.openInstructions() }.buttonStyle(PillButton())
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

    private func permission(_ label: String, _ detail: String, _ granted: Bool, _ pane: String, last: Bool = false,
                            ask: ((@escaping () -> Void) -> Void)? = nil) -> some View {
        row(label, detail, last: last) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button("Allow…") {
                    // Not asked yet: macOS's own prompt. Asked and refused: the pane in System Settings.
                    if let ask { ask { DispatchQueue.main.async { permissionsSeen += 1 } }; return }
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
                .buttonStyle(PillButton(prominent: true))
            }
        }
    }
}

// MARK: - Snapshots

extension Dashboard {
    /// `Joe --snapshot <page> <file.png> [width height] [dark]`: draws a page off screen, with the
    /// real data, to check the design without opening the window.
    static func snapshot(page: DashboardModel.Page, to file: URL, size: NSSize, dark: Bool, done: @escaping () -> Void) {
        let model = DashboardModel(actions: .init(
            ask: { _ in }, askInBackground: { _ in }, status: { "" }, setVoice: { _ in }, setNotch: { _ in },
            setCleanup: { _ in }, setScreenControl: { _ in }, chooseVault: {}, showOnboarding: {}, openNotepad: {},
            microphones: { [] }, setSpeechLanguages: { _ in }, cancelAlarm: { _ in }, addAlarm: { _ in }))
        model.page = page
        model.reload()
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = NSHostingView(rootView: DashboardView(model: model))
        window.contentView = view
        window.orderFrontRegardless()
        // Let the page load its data and settle before drawing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                }
                window.orderOut(nil)
                done()
            }
        }
    }
}

// MARK: - Appearance

/// Light, dark, or whatever the Mac is set to, for all of Joe's windows.
enum AppAppearance: String, CaseIterable {
    case system, light, dark
    static let key = "appearance"

    var title: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    @MainActor static func apply() {
        if Theme.current == .midnight { NSApp.appearance = NSAppearance(named: .darkAqua); return }
        NSApp.appearance = switch current {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The sun/moon at the bottom of the sidebar: flips between light and dark.
private struct AppearanceToggle: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            appearance = (scheme == .dark ? AppAppearance.light : .dark).rawValue
            AppAppearance.apply()
        } label: {
            Image(systemName: scheme == .dark ? "sun.max" : "moon")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(scheme == .dark ? "Light mode" : "Dark mode")
    }
}
