import AppKit
import SwiftUI

/// One conversation with the assistant. Several can run at once: closing the card while one is
/// still working moves it to the side notch (`TaskShelf`), where it carries on.
@MainActor
final class AssistantTask {
    let id = UUID()
    let assistant = Assistant()
    var question = ""
    /// The current reply as Claude writes it, tags and all.
    var reply = ""
    var status: String?
    var error: String?
    var approval: Assistant.Approval?
    var isDone = false
    /// When the current request finished: answers clear themselves a while after.
    var doneAt: Date?
    var canFollowUp = false
    /// What the current request was sent with: the screenshot Claude's point tags refer to, and
    /// the selection a `[REPLACE]` reply is pasted over.
    var screenshot: ScreenCapture.Screenshot?
    var selection: ScreenContext.Text?
    /// The request was about the notepad: a `[REPLACE]` reply goes into it.
    var notepadTarget = false
    /// Whether the conversation is about the screen, so visual follow-ups get a fresh screenshot.
    var screenConversation = false
    /// Guiding them step by step ("show me how to submit on ManageBac"): "next" gets the next step,
    /// worked out from a fresh screenshot.
    var walkthrough = false
    /// Finished, failed or waiting for an OK while in the background, and not looked at yet.
    var unseen = false
    /// Called once with the answer (or what went wrong) when the request finishes: for requests
    /// from the phone.
    var onFinished: ((String) -> Void)?
    /// What it has done so far this turn, in order ("Reading DP_ESS_Bioaccumulation…"), for the
    /// timeline in the side notch; and when the turn started.
    var steps: [String] = []
    /// Its to-do list, for long tasks.
    var plan: [Assistant.PlanStep] = []
    var startedAt = Date()
    /// Asked to work in the background ("… in the background"): off the card as soon as it starts.
    var background = false

    /// A new step, or a vaguer placeholder ("Running a command…") made specific.
    func addStep(_ text: String) {
        let vague: Set<String> = ["Thinking…", "Working…", "Waiting for your OK…", "Running a command…", "Getting tools ready…",
                                  "Reading your notes…", "Searching your notes…", "Updating your notes…", "Connection dropped, trying again…"]
        guard !text.isEmpty, text != steps.last else { return }
        if let last = steps.last, vague.contains(last) { steps[steps.count - 1] = text; return }
        if vague.contains(text), text != "Running a command…", text != "Reading your notes…" { return }
        steps.append(text)
    }

    var isWorking: Bool { !isDone }
    var subject: String? { Subject.split(reply).subject }

    func beginTurn(_ question: String) {
        self.question = question
        reply = ""
        status = nil
        error = nil
        approval = nil
        isDone = false
        doneAt = nil
        screenshot = nil
        selection = nil
        notepadTarget = false
        steps = []
        plan = []
        startedAt = Date()
    }
}

/// Every reply starts with a subject line, like an email's ("Subject: Econ quiz is next"). It
/// titles the card and the done line at the notch, and labels the task in the side notch.
enum Subject {
    /// The subject and the rest of the reply. While the subject is still streaming in, it grows
    /// and the body is empty.
    static func split(_ reply: String) -> (subject: String?, body: String) {
        let start = reply.drop { $0.isWhitespace || $0 == "*" }
        let marker = "subject:"
        let head = start.prefix(marker.count).lowercased()
        guard head == marker else {
            // Possibly "Subj" so far: show nothing yet rather than flash it.
            return !start.isEmpty && head.count < marker.count && marker.hasPrefix(head) ? (nil, "") : (nil, reply)
        }
        let rest = start.dropFirst(marker.count)
        let newline = rest.firstIndex(of: "\n")
        let subject = rest[..<(newline ?? rest.endIndex)]
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*")))
        let body = newline.map { String(rest[$0...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return (subject.isEmpty ? nil : subject, body)
    }
}

/// What Joe is doing, in the notch itself: conversations running (or done) in the background and
/// the alarms to come take over the notch band. A spinner and the step while they work, ✋ when
/// one needs an OK, ✓ when they're done, the next alarm's time. Click the band and the list drops
/// out of the notch; click a task to bring its card back, × to stop or dismiss it.
@MainActor
final class TaskShelf {
    struct Item: Identifiable, Equatable {
        enum State { case working, needsOK, done, failed, alarm }
        let id: UUID
        let question: String
        let state: State
        var steps: [String] = []
        var plan: [Assistant.PlanStep] = []
        var started: Date?
    }

    var onOpen: (UUID) -> Void = { _ in }
    var onStop: (UUID) -> Void = { _ in }

    private let model = ShelfModel()
    private var panel: NSPanel?

    init() {
        model.onToggle = { [weak self] in
            guard let self else { return }
            if model.expanded {
                // Back into the notch, then the window shrinks to the band.
                model.expanded = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                    MainActor.assumeIsolated { if self?.model.expanded == false { self?.place() } }
                }
            } else {
                // The window grows first, then the list drops out of the notch inside it.
                place(expanded: true)
                DispatchQueue.main.async { [weak self] in self?.model.expanded = true }
            }
        }
        model.onOpen = { [weak self] id in
            self?.model.expanded = false
            self?.onOpen(id)
        }
        model.onStop = { [weak self] id in self?.onStop(id) }
        model.onDrag = { [weak self] ended in self?.drag(ended: ended) }
        model.onReset = { [weak self] in self?.resetPosition() }
    }

    /// Called every second while alarms are pending: only what changed is redrawn or moved.
    func update(_ items: [Item]) {
        if model.items != items { model.items = items }
        guard !items.isEmpty else {
            if model.expanded { model.expanded = false }
            if panel?.isVisible == true { panel?.orderOut(nil) }
            return
        }
        var shown = false
        if panel?.isVisible != true {
            // A new window each time: a reused one can stay hidden behind a full-screen app.
            panel?.orderOut(nil)
            panel = makePanel()
            shown = true
        }
        place()
        if shown, let panel {
            panel.orderFrontRegardless()
            NotchSpace.pin(panel)
        }
    }

    /// Centred on the notch, as the notch band itself (it covers the resting band while it's up).
    /// The window is only as big as what's shown, so it never blocks clicks around it.
    private func place(expanded: Bool? = nil) {
        guard let panel, let screen = Self.screen else { return }
        let notch = Notch.rect(on: screen)
        if model.notch != notch.size { model.notch = notch.size }
        let size = size(notch: notch, expanded: expanded ?? model.expanded)
        let frame = NSRect(x: notch.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Either side of the notch: room for the step a task is on, an alarm's time, or just an icon.
    static func ear(for items: [Item]) -> CGFloat {
        if items.contains(where: { $0.state == .working }) { return 150 }
        if items.allSatisfy({ $0.state == .alarm }), !alarmIconOnly { return 64 }
        return RecordingPanel.ear
    }

    private func size(notch: NSRect, expanded: Bool) -> NSSize {
        let band = NSSize(width: notch.width + 2 * Self.ear(for: model.items), height: notch.height)
        guard expanded else { return band }
        let rows = model.items.reduce(CGFloat(0)) { $0 + ShelfView.height(of: $1) }
        let alarmButtons: CGFloat = model.items.contains { $0.state == .alarm } ? 34 : 0
        let wide = model.items.contains { !$0.steps.isEmpty || !$0.plan.isEmpty }
        return NSSize(width: max(band.width, wide ? 400 : 340), height: notch.height + rows + alarmButtons + 16)
    }

    /// Whether the list is open (the hover overview stays away meanwhile).
    var isExpanded: Bool { model.expanded }
    var isVisible: Bool { panel?.isVisible == true }

    /// The screen with the notch (or the main one): the capsule doesn't follow the mouse around.
    private static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// Where the user dragged it: its left edge, from the notch's middle.
    private static var savedOffset: CGFloat? {
        get { (UserDefaults.standard.object(forKey: "shelfOffset") as? Double).map { CGFloat($0) } }
        set { UserDefaults.standard.set(newValue.map(Double.init), forKey: "shelfOffset") }
    }

    // MARK: Clicks

    /// Dragging used to slide the capsule along the top of the screen; it lives in the notch now.
    fileprivate func drag(ended: Bool) {}

    /// A double-click: just closes the list.
    fileprivate func resetPosition() {
        Self.savedOffset = nil
        if model.expanded { model.onToggle() }
    }

    private func makePanel() -> NSPanel {
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 50, height: 38),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .aboveResting // it is the notch band while it's up
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false // macOS moved it down the screen on space switches; dragging is ours
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = ShelfHost(rootView: ShelfView(model: model))
        host.isClosed = { [weak self] in self?.model.expanded == false }
        host.onClick = { [weak self] count in
            if count >= 2 { self?.resetPosition() } else { self?.model.onToggle() }
        }
        host.onDrag = { [weak self] ended in self?.drag(ended: ended) }
        panel.contentView = host
        return panel
    }
}

extension TaskShelf {
    /// How alarms show beside the notch: "full" (the time), "icon", "soon" (only in their last
    /// hour, and timers) or "off". They ring the same either way.
    nonisolated static var alarmStyle: String {
        get { UserDefaults.standard.string(forKey: "alarmsAtNotch") ?? "full" }
        set { UserDefaults.standard.set(newValue, forKey: "alarmsAtNotch") }
    }
    nonisolated static var alarmIconOnly: Bool { alarmStyle == "icon" }
}

/// "1:23": how long a task has been at it, ticking by itself.
private struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

final class ShelfModel: ObservableObject {
    @Published var items: [TaskShelf.Item] = []
    @Published var expanded = false
    /// The notch's size: the band is built around it.
    @Published var notch = CGSize(width: 200, height: 32)
    var onToggle: () -> Void = {}
    var onDrag: (_ ended: Bool) -> Void = { _ in }
    var onReset: () -> Void = {}
    var onOpen: (UUID) -> Void = { _ in }
    var onStop: (UUID) -> Void = { _ in }
}

private struct ShelfView: View {
    @ObservedObject var model: ShelfModel

    var body: some View {
        GeometryReader { space in
            let open = model.expanded
            let ear = TaskShelf.ear(for: model.items)
            let band = model.notch.width + 2 * ear
            VStack(alignment: .leading, spacing: 0) {
                // The band: what's going on, either side of the notch. Click: the list drops out.
                HStack(spacing: 0) {
                    leftEar.frame(width: ear)
                    Color.clear.frame(width: model.notch.width) // behind the notch
                    rightEar.frame(width: ear)
                }
                .frame(width: band, height: model.notch.height)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { model.onToggle() } // open: closes it (closed, the window handles the mouse)
                .help(open ? "Click to close" : "Click for what Joe is doing")
                list
                    .padding(.top, 6)
                    .opacity(open ? 1 : 0)
                    .scaleEffect(open ? 1 : 0.94, anchor: .top)
                    .blur(radius: open ? 0 : 6)
                    .animation(open ? .easeOut(duration: 0.24).delay(0.12) : .easeIn(duration: 0.1), value: open)
            }
            .frame(width: space.size.width, height: space.size.height, alignment: .top)
            .background(alignment: .top) {
                NotchShape(top: NotchShape.shoulder, bottom: open ? 22 : 13)
                    .fill(Color.black)
                    .frame(width: open ? space.size.width : band, height: open ? space.size.height : model.notch.height)
            }
            .mask(alignment: .top) {
                NotchShape(top: NotchShape.shoulder, bottom: open ? 22 : 13)
                    .frame(width: open ? space.size.width : band, height: open ? space.size.height : model.notch.height)
            }
            .animation(open ? NotchShape.opening : NotchShape.closing, value: open)
        }
        .environment(\.colorScheme, .dark)
    }

    /// Left of the notch: the state that matters most, and the step a task is on.
    private var leftEar: some View {
        HStack(spacing: 5) {
            summaryIcon
            if let working = model.items.first(where: { $0.state == .working }) {
                Text(Self.summary(working))
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.leading, NotchShape.shoulder + 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Right of the notch: how long it's been at it, the next alarm's time, or how many there are.
    private var rightEar: some View {
        HStack(spacing: 5) {
            if let working = model.items.first(where: { $0.state == .working }) {
                if let started = working.started { Elapsed(since: started) }
                if model.items.count > 1 {
                    Text("+\(model.items.count - 1)").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                }
            } else if model.items.allSatisfy({ $0.state == .alarm }), !TaskShelf.alarmIconOnly, let next = model.items.first {
                // The next alarm's time, or a timer's countdown.
                Text(next.question.components(separatedBy: " · ").first ?? "")
                    .font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.white)
            } else if model.items.count > 1 {
                Text("\(model.items.count)").font(.caption.weight(.bold)).foregroundStyle(.white)
            }
        }
        .padding(.trailing, NotchShape.shoulder + 6)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The open list: every task and alarm, with its steps while it works.
    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.items) { item in
                HStack(spacing: 8) {
                    icon(item.state).frame(width: 16)
                    Text(item.question)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.onStop(item.id) } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help(item.state == .working ? "Stop" : item.state == .alarm ? "Cancel" : "Dismiss")
                }
                .frame(height: 34)
                .padding(.horizontal, 12 + NotchShape.shoulder)
                .contentShape(Rectangle())
                .onTapGesture { model.onOpen(item.id) }
                if item.state == .working, !item.plan.isEmpty { checklist(item) }
                else if item.state == .working, !item.steps.isEmpty { timeline(item) }
            }
            if model.items.contains(where: { $0.state == .alarm }) {
                // Less in the band: just the icon, or nothing until an alarm is under an hour away.
                HStack(spacing: 6) {
                    shelfButton(TaskShelf.alarmIconOnly ? "Show the time" : "Icon only") {
                        TaskShelf.alarmStyle = TaskShelf.alarmIconOnly ? "full" : "icon"
                        model.onToggle()
                    }
                    shelfButton("Hide until close") {
                        TaskShelf.alarmStyle = "soon"
                        model.onToggle()
                    }
                }
                .padding(.horizontal, 12 + NotchShape.shoulder)
                .padding(.vertical, 6)
            }
        }
    }

    /// The steps a working task has taken: done ones ticked, the one it's on spinning.
    private func timeline(_ item: TaskShelf.Item) -> some View {
        let shown = Array(item.steps.suffix(ShelfView.maxSteps).enumerated())
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.offset) { index, step in
                let current = index == shown.count - 1
                HStack(spacing: 8) {
                    if current {
                        ProgressView().controlSize(.mini).tint(.orange).frame(width: 12)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green).frame(width: 12)
                    }
                    Text(step).font(.caption).foregroundStyle(.white.opacity(current ? 0.95 : 0.55)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if current, let started = item.started { Elapsed(since: started) }
                }
                .frame(height: ShelfView.stepHeight)
            }
        }
        .padding(.leading, 36 + NotchShape.shoulder)
        .padding(.trailing, 12 + NotchShape.shoulder)
        .padding(.bottom, 6)
    }

    /// Its to-do list: done ticked, the one it's on spinning, the rest to come; with the step it's
    /// taking right now under the list.
    private func checklist(_ item: TaskShelf.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(item.plan.prefix(ShelfView.maxPlan).enumerated()), id: \.offset) { _, step in
                HStack(spacing: 8) {
                    switch step.state {
                    case .completed: Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green).frame(width: 12)
                    case .inProgress: ProgressView().controlSize(.mini).tint(.orange).frame(width: 12)
                    case .pending: Image(systemName: "circle").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)).frame(width: 12)
                    }
                    Text(step.text).font(.caption.weight(step.state == .inProgress ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(step.state == .pending ? 0.5 : step.state == .completed ? 0.6 : 0.95))
                        .strikethrough(step.state == .completed, color: .white.opacity(0.4))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(height: ShelfView.stepHeight)
            }
            if let now = item.steps.last {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    Text(now).font(.caption2).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let started = item.started { Elapsed(since: started) }
                }
                .frame(height: ShelfView.stepHeight)
            }
        }
        .padding(.leading, 36 + NotchShape.shoulder)
        .padding(.trailing, 12 + NotchShape.shoulder)
        .padding(.bottom, 6)
    }

    /// The closed capsule's line: "2/5 · Answering question 3", or the step it's taking.
    static func summary(_ item: TaskShelf.Item) -> String {
        guard !item.plan.isEmpty else { return item.steps.last ?? "Starting…" }
        let done = item.plan.filter { $0.state == .completed }.count
        let current = item.plan.first { $0.state == .inProgress }?.text ?? item.steps.last ?? "Working"
        return "\(done)/\(item.plan.count) · \(current)"
    }

    static let maxSteps = 6
    static let maxPlan = 8
    static let stepHeight: CGFloat = 20

    /// A row's height in the open list: its title, and a working task's plan or steps.
    static func height(of item: TaskShelf.Item) -> CGFloat {
        guard item.state == .working else { return 34 }
        if !item.plan.isEmpty { return 34 + CGFloat(min(item.plan.count, maxPlan) + (item.steps.isEmpty ? 0 : 1)) * stepHeight + 6 }
        return 34 + (item.steps.isEmpty ? 0 : CGFloat(min(item.steps.count, maxSteps)) * stepHeight + 6)
    }

    private func shelfButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 9).frame(height: 22)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The one that matters most: an OK to give, then work going on, then done.
    @ViewBuilder
    private var summaryIcon: some View {
        let states = model.items.map(\.state)
        if states.contains(.needsOK) { icon(.needsOK) }
        else if states.contains(.working) { icon(.working) }
        else if states.contains(.failed) { icon(.failed) }
        else if states.allSatisfy({ $0 == .alarm }) { icon(.alarm) }
        else { icon(.done) }
    }

    @ViewBuilder
    private func icon(_ state: TaskShelf.Item.State) -> some View {
        switch state {
        case .working: ProgressView().controlSize(.mini).tint(.white)
        case .needsOK: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .alarm: Image(systemName: "alarm.fill").foregroundStyle(.orange)
        }
    }
}

/// The capsule's view, handling the mouse itself while it's closed: a click opens the list, a
/// drag slides it along the top of the screen, a double-click puts it back beside the notch.
/// (SwiftUI's own drag doesn't work well in a panel that never becomes key.)
private final class ShelfHost: NSHostingView<ShelfView> {
    var isClosed: () -> Bool = { true }
    var onClick: (Int) -> Void = { _ in }
    var onDrag: (_ ended: Bool) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { return onClick(2) } // a double-click, whether its first click opened the list or not
        guard isClosed(), let window else { return super.mouseDown(with: event) }
        let start = NSEvent.mouseLocation
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            if dragged || hypot(now.x - start.x, now.y - start.y) > 3 {
                dragged = true
                onDrag(false)
            }
        }
        if dragged { onDrag(true) } else { onClick(event.clickCount) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
