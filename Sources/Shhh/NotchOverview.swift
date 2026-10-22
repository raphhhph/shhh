import AppKit
import SwiftUI

/// Rest the pointer on the notch and an overview drops out of it, like NotchNook: the time, the
/// next class, what's due, today's five, Joe's running tasks, the next alarm, the music, one-tap
/// questions for Joe and a focus timer. Which
/// widgets show, and in what order, is arranged by dragging in Settings → General → Notch → Edit.
@MainActor
final class NotchOverview {
    enum Widget: String, CaseIterable, Identifiable {
        case clock, nextClass, dueSoon, today, tasks, alarm, music, ask, focus
        var id: String { rawValue }

        var title: String {
            switch self {
            case .clock: "Clock"
            case .nextClass: "Next class"
            case .dueSoon: "Due soon"
            case .today: "Today's five"
            case .tasks: "Joe's tasks"
            case .alarm: "Next alarm"
            case .music: "Now playing"
            case .ask: "Ask Joe"
            case .focus: "Focus timer"
            }
        }

        var symbol: String {
            switch self {
            case .clock: "clock"
            case .nextClass: "graduationcap"
            case .dueSoon: "calendar.badge.exclamationmark"
            case .today: "checklist"
            case .tasks: "sparkle"
            case .alarm: "alarm"
            case .music: "music.note"
            case .ask: "bubble.left.and.text.bubble.right"
            case .focus: "timer"
            }
        }
    }

    /// How many widgets fit side by side in the overview.
    static let maxWidgets = 5

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "notchOverview") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notchOverview") }
    }

    /// The widgets shown, in order.
    static var widgets: [Widget] {
        get { (UserDefaults.standard.stringArray(forKey: "notchWidgets") ?? ["clock", "nextClass", "dueSoon", "tasks", "music"]).compactMap(Widget.init) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "notchWidgets") }
    }

    private let data: DashboardModel
    /// Joe's conversations still working, by what was asked.
    var runningTasks: () -> [String] = { [] }
    /// Whether it may open now (not while recording, an answer is up, or an alarm rings).
    var canShow: () -> Bool = { true }

    private var panel: NSPanel?
    private var timer: Timer?
    private var hoverSince: Date?
    private let model = OverviewModel()

    init(data: DashboardModel) {
        self.data = data
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } }

    private func check() {
        guard Self.isEnabled, Notch.isEnabled, let screen = notchScreen else { hide(); return }
        let mouse = NSEvent.mouseLocation
        let notch = Notch.rect(on: screen).insetBy(dx: -RestingNotch.ear, dy: 0)
        if let panel {
            // Open: stays while the pointer is over it or the notch.
            if !panel.frame.insetBy(dx: -8, dy: -8).contains(mouse), !notch.contains(mouse) { hide() }
            return
        }
        guard notch.contains(mouse), canShow() else { hoverSince = nil; return }
        if hoverSince == nil { hoverSince = Date() }
        if let since = hoverSince, Date().timeIntervalSince(since) > 0.08 { show(on: screen) } // just long enough that passing to the menu bar doesn't open it
    }

    private func show(on screen: NSScreen) {
        hoverSince = nil
        data.reload()
        model.fill(from: data, tasks: runningTasks())
        let notch = Notch.rect(on: screen)
        let size = NSSize(width: 780, height: 190) // five tiles with room for their words
        let panel = NotchPanel(contentRect: NSRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height, width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the system shadow draws a light rim round the black shape
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        model.isOpen = false
        panel.contentView = NSHostingView(rootView: OverviewView(model: model, notchHeight: notch.height, notchWidth: notch.width, music: { [weak self] command in
            self?.data.music(command)
        }, ask: { [weak self] request in
            // The answer card takes over the notch.
            self?.hide()
            self?.data.actions.ask(request)
        }, focus: { [weak self] minutes in
            guard let self else { return }
            data.actions.addAlarm(.add(Alarm(fireAt: Date().addingTimeInterval(Double(minutes) * 60), title: "Focus", kind: .timer)))
            data.reload()
            model.fill(from: data, tasks: runningTasks())
        }, tick: { [weak self] line in
            guard let self else { return }
            data.toggle(line)
            model.fill(from: data, tasks: runningTasks())
        }, buildDaybook: { [weak self] in
            self?.hide()
            self?.data.actions.askInBackground("Build today's Daybook now (how: your instructions), then tell me my five things in one short line.")
        }))
        panel.orderFrontRegardless()
        NotchSpace.pin(panel)
        self.panel = panel
        DispatchQueue.main.async { [weak self] in self?.model.isOpen = true } // grows out of the notch
    }

    /// Shrinks back into the notch, then goes.
    func hide() {
        guard let panel else { return }
        self.panel = nil
        model.isOpen = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            // Unless it was opened again meanwhile (a new panel then shows the model).
            if self?.panel !== panel { panel.orderOut(nil) }
        }
    }
}

@MainActor
private final class OverviewModel: ObservableObject {
    @Published var widgets: [NotchOverview.Widget] = []
    /// Out of the notch. Flipped after the panel is up, so it grows down from the notch, and back
    /// before the panel goes, so it shrinks into it.
    @Published var isOpen = false
    @Published var nextClass: Daybook.Slot?
    /// The soonest deadline for that class's subject, so the bag gets packed with it in mind.
    @Published var classDue: CalendarFeed.Item?
    @Published var deadlines: [CalendarFeed.Item] = []
    @Published var today: [(line: String, text: String, done: Bool)] = []
    @Published var tasks: [String] = []
    @Published var alarm: Alarm?
    @Published var music: String?
    /// A timer running now (the focus timer's, or one asked for).
    @Published var timer: Alarm?

    func fill(from data: DashboardModel, tasks: [String]) {
        widgets = NotchOverview.widgets
        let now = Date()
        // The next class today, or tomorrow's first in the evening.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        nextClass = data.timeline.first { $0.kind == .lesson && ($0.end ?? $0.start) > now }
            ?? Daybook.timeline(tomorrow).first { $0.kind == .lesson }
        // Matched on the class's first word ("Chinese B SL" → "Chinese …" deadlines).
        let subject = nextClass.flatMap { $0.title.split(separator: " ").first.map(String.init) }
        classDue = subject.flatMap { word in
            data.deadlines.first { ($0.end ?? $0.start) > now && $0.title.range(of: word, options: .caseInsensitive) != nil }
        }
        // Still to come: today's are gone once they're over.
        deadlines = Array(data.deadlines.filter { ($0.end ?? $0.start) > now || $0.allDay && Calendar.current.isDateInToday($0.start) }.prefix(3))
        today = data.tasks.prefix(5).map { ($0.line, $0.text, $0.done) }
        self.tasks = tasks
        alarm = data.alarms.first
        music = data.nowPlaying
        timer = data.alarms.filter { $0.kind == .timer && $0.fireAt > now }.min { $0.fireAt < $1.fireAt }
    }
}

private struct OverviewView: View {
    @ObservedObject var model: OverviewModel
    let notchHeight: CGFloat
    /// The hardware notch's width: where the island starts from and goes back to.
    var notchWidth: CGFloat = 200
    var music: (Spotify.Command) -> Void
    var ask: (String) -> Void = { _ in }
    /// Starts a focus timer of so many minutes.
    var focus: (Int) -> Void = { _ in }
    /// Ticks a task in today's Daybook on or off, by its line.
    var tick: (String) -> Void = { _ in }
    /// Has Joe build today's Daybook now, in the side notch.
    var buildDaybook: () -> Void = {}

    /// One-tap questions a student asks most, short enough for a tile.
    private static let quickAsks: [(label: String, request: String)] = [
        ("What's due?", "What's due this week?"),
        ("Plan tonight", "Plan my evening around my deadlines"),
        ("Quiz me", "Quiz me on my weakest subject"),
    ]

    var body: some View {
        GeometryReader { space in
            let open = model.isOpen
            let shape = NotchShape(top: NotchShape.shoulder, bottom: open ? 26 : min(10, notchHeight / 3))
            let width = open ? space.size.width : notchWidth + 2 * NotchShape.shoulder
            let height = open ? space.size.height : notchHeight
            VStack(spacing: 0) {
                Color.clear.frame(height: notchHeight) // the notch itself
                HStack(alignment: .top, spacing: 10) {
                    ForEach(model.widgets) { widget in tile(widget) }
                }
                .padding(.horizontal, 14 + NotchShape.shoulder)
                .padding(.top, 6)
                .padding(.bottom, 14)
                Spacer(minLength: 0)
            }
            .frame(width: space.size.width, height: space.size.height, alignment: .top)
            // The tiles come in just behind the shape, and leave first.
            .opacity(open ? 1 : 0)
            .scaleEffect(open ? 1 : 0.9, anchor: .top)
            .blur(radius: open ? 0 : 8)
            .animation(open ? .easeOut(duration: 0.16).delay(0.03) : .easeIn(duration: 0.08), value: open)
            .background(alignment: .top) { shape.fill(Color.black).frame(width: width, height: height) }
            .mask(alignment: .top) { shape.frame(width: width, height: height) }
            .animation(open ? NotchShape.opening : NotchShape.closing, value: open)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func tile(_ widget: NotchOverview.Widget) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(widget.title.uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white.opacity(0.45))
            switch widget {
            case .clock:
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 26, weight: .semibold).monospacedDigit())
                        Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                // The next alarm lives here now that it's no longer in the notch band.
                if !model.widgets.contains(.alarm), let alarm = model.alarm {
                    Label("\(alarm.when) · \(alarm.title)", systemImage: "alarm.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange).lineLimit(1)
                }
            case .nextClass:
                if let slot = model.nextClass {
                    Text(slot.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let minutes = Int(slot.start.timeIntervalSince(context.date) / 60)
                        Text(minutes <= 0 ? "now" + (slot.end.map { ", until \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                             : minutes < 60 ? "in \(minutes) min"
                             : (Calendar.current.isDateInToday(slot.start) ? "" : "Tomorrow ") + slot.start.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11.5)).foregroundStyle(.orange)
                    }
                    if !slot.detail.isEmpty { Text(slot.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)) }
                    if let due = model.classDue {
                        Text("Due \(due.start.formatted(.dateTime.weekday(.abbreviated))): \(due.title)")
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.red.opacity(0.85)).lineLimit(2)
                    }
                } else { empty("Nothing more today") }
            case .dueSoon:
                if model.deadlines.isEmpty { empty("Nothing due soon") }
                ForEach(model.deadlines) { item in
                    // Tap one: Joe breaks it into steps and plans the first.
                    Button { ask(item.startRequest) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(item.start.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.red.opacity(0.85))
                                .frame(width: 26, alignment: .leading) // titles share a left edge
                            Text(item.title).font(.system(size: 11.5)).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Help me start this")
                }
            case .today:
                if model.today.isEmpty {
                    empty("No Daybook yet")
                    Button { buildDaybook() } label: {
                        Text("Build it").font(.system(size: 11.5, weight: .semibold)).fixedSize()
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Color.orange.opacity(0.85), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(model.today.enumerated()), id: \.offset) { _, task in
                    // Tick it off from the notch, without opening the dashboard.
                    Button { tick(task.line) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: task.done ? "checkmark.circle.fill" : "circle").font(.system(size: 10)).foregroundStyle(task.done ? .orange : .white.opacity(0.5))
                            Text(task.text).font(.system(size: 11.5)).lineLimit(1).strikethrough(task.done)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            case .tasks:
                if model.tasks.isEmpty { empty("Nothing running") }
                ForEach(model.tasks.prefix(3), id: \.self) { task in
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(task).font(.system(size: 11.5)).lineLimit(1)
                    }
                }
            case .alarm:
                if let alarm = model.alarm {
                    Text(alarm.when).font(.system(size: 20, weight: .semibold).monospacedDigit())
                    Text(alarm.title).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                } else { empty("No alarm set") }
            case .music:
                Text(model.music ?? "Nothing playing").font(.system(size: 12)).lineLimit(2)
                HStack(spacing: 14) {
                    Button { music(.previous) } label: { Image(systemName: "backward.fill") }
                    Button { music(model.music == nil ? .resume : .pause) } label: { Image(systemName: model.music == nil ? "play.fill" : "pause.fill") }
                    Button { music(.next) } label: { Image(systemName: "forward.fill") }
                }
                .buttonStyle(.plain).font(.system(size: 13))
            case .ask:
                ForEach(Self.quickAsks, id: \.label) { item in
                    Button { ask(item.request) } label: {
                        Text(item.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1).fixedSize()
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Color.white.opacity(0.1), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            case .focus:
                if let timer = model.timer {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(timer.fireAt.timeIntervalSince(context.date)))
                        Text(String(format: "%d:%02d", left / 60, left % 60)).font(.system(size: 24, weight: .semibold).monospacedDigit())
                    }
                    Text(timer.title).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                } else {
                    Text("Nothing running").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                    HStack(spacing: 6) {
                        ForEach([25, 50], id: \.self) { minutes in
                            Button { focus(minutes) } label: {
                                Text("\(minutes)m").font(.system(size: 11.5, weight: .semibold).monospacedDigit()).fixedSize()
                                    .padding(.horizontal, 8).frame(height: 22)
                                    .background(Color.orange.opacity(0.85), in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
    }
}

extension NotchOverview {
    /// `Joe --overview-preview <file.png>`: the overview with real data, drawn off screen.
    func preview(to file: URL, done: @escaping () -> Void) {
        data.reload()
        model.fill(from: data, tasks: ["Consolidating Econ notes"])
        model.widgets = [.clock, .nextClass, .dueSoon, .ask, .focus] // a full row, as wide as on screen
        model.isOpen = true
        let host = NSHostingView(rootView: OverviewView(model: model, notchHeight: 32, notchWidth: 200, music: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 780, height: 190), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .gray
        window.contentView = host
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                }
                done()
            }
        }
    }
}
