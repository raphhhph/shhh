import AppKit
import SwiftUI

/// Rest the pointer on the notch and an overview drops out of it, like NotchNook: the time, the
/// next class, what's due, today's five, Joe's running tasks, the next alarm and the music. Which
/// widgets show, and in what order, is arranged by dragging in Settings → General → Notch → Edit.
@MainActor
final class NotchOverview {
    enum Widget: String, CaseIterable, Identifiable {
        case clock, nextClass, dueSoon, today, tasks, alarm, music
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
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
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
        if let since = hoverSince, Date().timeIntervalSince(since) > 0.35 { show(on: screen) }
    }

    private func show(on screen: NSScreen) {
        hoverSince = nil
        data.reload()
        model.fill(from: data, tasks: runningTasks())
        let notch = Notch.rect(on: screen)
        let size = NSSize(width: 680, height: 190)
        let panel = NotchPanel(contentRect: NSRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height, width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverviewView(model: model, notchHeight: notch.height, music: { [weak self] command in
            self?.data.music(command)
        }))
        panel.orderFrontRegardless()
        NotchSpace.pin(panel)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
private final class OverviewModel: ObservableObject {
    @Published var widgets: [NotchOverview.Widget] = []
    @Published var nextClass: Daybook.Slot?
    @Published var deadlines: [CalendarFeed.Item] = []
    @Published var today: [(text: String, done: Bool)] = []
    @Published var tasks: [String] = []
    @Published var alarm: Alarm?
    @Published var music: String?

    func fill(from data: DashboardModel, tasks: [String]) {
        widgets = NotchOverview.widgets
        let now = Date()
        // The next class today, or tomorrow's first in the evening.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        nextClass = data.timeline.first { $0.kind == .lesson && ($0.end ?? $0.start) > now }
            ?? Daybook.timeline(tomorrow).first { $0.kind == .lesson }
        // Still to come: today's are gone once they're over.
        deadlines = Array(data.deadlines.filter { ($0.end ?? $0.start) > now || $0.allDay && Calendar.current.isDateInToday($0.start) }.prefix(3))
        today = data.tasks.prefix(5).map { ($0.text, $0.done) }
        self.tasks = tasks
        alarm = data.alarms.first
        music = data.nowPlaying
    }
}

private struct OverviewView: View {
    @ObservedObject var model: OverviewModel
    let notchHeight: CGFloat
    var music: (Spotify.Command) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight) // the notch itself
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.widgets) { widget in tile(widget) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 14)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous))
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
                } else { empty("Nothing more today") }
            case .dueSoon:
                if model.deadlines.isEmpty { empty("Nothing due soon") }
                ForEach(model.deadlines) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(item.start.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.red.opacity(0.85))
                        Text(item.title).font(.system(size: 11.5)).lineLimit(1)
                    }
                }
            case .today:
                if model.today.isEmpty { empty("No Daybook yet") }
                ForEach(Array(model.today.enumerated()), id: \.offset) { _, task in
                    HStack(spacing: 5) {
                        Image(systemName: task.done ? "checkmark.circle.fill" : "circle").font(.system(size: 10)).foregroundStyle(task.done ? .orange : .white.opacity(0.5))
                        Text(task.text).font(.system(size: 11.5)).lineLimit(1).strikethrough(task.done)
                    }
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
        model.widgets = Widget.allCases.filter { $0 != .today } // a full row
        let host = NSHostingView(rootView: OverviewView(model: model, notchHeight: 32, music: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 190), styleMask: [.borderless], backing: .buffered, defer: false)
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
