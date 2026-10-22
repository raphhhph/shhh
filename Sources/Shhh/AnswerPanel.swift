import AppKit
import Combine
import SwiftUI

/// The card that shows Claude's reply, at the bottom of the screen, or dropping down from the
/// notch (see `Notch`). It grows as the reply streams in, asks for the user's OK before Claude
/// acts, and stays until it's closed.
@MainActor
final class AnswerPanel {
    private let model = AnswerModel()
    private var panel: NSPanel!
    /// Measures how tall the card wants to be: the same view, laid out without scrolling.
    private lazy var sizer = NSHostingController(rootView: AnswerView(model: model, scrolls: false, notch: nil))
    /// The notch the current card hangs from, or nil for a card at the bottom.
    private var notch: NSRect?
    private var changes: AnyCancellable?
    /// At the notch the window shrinks only after the island has (see `resize`), and closes only
    /// after it has gone back into the notch.
    private var shrinkWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    /// At the notch: watches the pointer, so the island opens on hover and tucks back up after.
    private var hoverTimer: Timer?
    private var leftAt: Date?
    var onClose: () -> Void = {}
    var onStopSpeaking: () -> Void = {}
    /// A typed follow-up from the card's chips (Simpler, Example, Quiz me), in the same conversation.
    var onFollowUp: (String) -> Void = { _ in }

    /// Whether Joe is reading the answer aloud (checked every second): the stop button.
    func setSpeaking(_ speaking: Bool) {
        if model.speaking != speaking { model.speaking = speaking }
    }

    static let width: CGFloat = 480
    /// At the notch, once the answer is done: the subject on one line under the notch, with room
    /// above and below (the tick stays in the band, beside the notch).
    static let peekWidth: CGFloat = 400
    static let peekHeight: CGFloat = 42

    var isVisible: Bool { panel.isVisible }
    /// Showing, as far as the app goes: false as soon as it starts tucking away.
    private(set) var isShowing = false
    /// Whether the pointer is over the card (or the island), and when it last was: the card clears
    /// itself a while after the answer, unless it's being read.
    var isHovering: Bool { model.hovering }

    /// While the user talks, the island folds into the band (see `AnswerModel.listening`).
    func setListening(_ listening: Bool) {
        guard model.listening != listening else { return }
        // Folding is instant: an animated close would slide the ✦ across the notch.
        var transaction = Transaction()
        transaction.disablesAnimations = listening
        withTransaction(transaction) { model.listening = listening }
    }
    private(set) var lastHover = Date.distantPast
    var frame: NSRect { panel.frame }
    var answer: String { model.answer }
    /// The height the whole answer needs. The card grows to it, up to 60% of the screen.
    var contentHeight: CGFloat {
        sizer.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude)).height
    }

    /// Clears the card for a new conversation (it may still be hidden).
    func reset() {
        model.question = nil
        model.canFollowUp = false
        clearTurn()
    }

    /// Shows the request Claude is now working on, replacing the previous reply.
    func beginTurn(question: String) {
        model.question = question
        clearTurn()
        present()
    }

    /// Brings back a conversation that carried on in the background, as it is now.
    func show(question: String, subject: String?, reply: String, status: String?, error: String?,
              approval: Assistant.Approval?, isDone: Bool, canFollowUp: Bool) {
        model.question = question
        model.subject = subject
        model.answer = reply
        model.status = status
        model.error = error
        model.approval = approval
        model.isDone = isDone
        model.canFollowUp = canFollowUp
        present()
    }

    private func present() {
        closeWork?.cancel()
        if !panel.isVisible {
            // A new window, shown at once: a reused one, or one fading in, can stay hidden behind
            // a full-screen app (seen with full-screen Vivaldi).
            let screen = Notch.screenUnderMouse
            notch = Notch.isEnabled ? screen.map { Notch.rect(on: $0) } : nil
            sizer.rootView = AnswerView(model: model, scrolls: false, notch: notch?.size)
            model.islandOpen = false
            panel = makePanel()
            resize(anchorTo: screen)
            panel.orderFrontRegardless()
            if notch != nil { NotchSpace.pin(panel) }
            watchHover()
        }
        lastHover = Date()
        isShowing = true
        // At band size straight away, in place of the listening band: the answer drops from there.
        if notch != nil, !model.islandOpen { model.islandOpen = true }
    }

    func update(_ event: Assistant.Event) {
        switch event {
        case .status(let status): model.status = status
        case .answer(let answer): model.answer = answer
        case .approval(let approval): model.approval = approval
        case .plan: break // the plan shows in the side notch
        case .didAct: break // shown as a toast by the pointer
        case .turnFinished:
            model.isDone = true
            model.canFollowUp = true
        case .failed(let message):
            model.error = message
            model.status = nil
            model.approval = nil
            model.isDone = true
            model.canFollowUp = false
        }
    }

    /// Shows the whole answer for a few seconds without hovering, then tucks it back up.
    func holdOpen(for seconds: TimeInterval) {
        model.pinned = true
        model.seen = true // seen like this, the subject reminder isn't needed afterwards
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.model.pinned = false }
        }
    }

    /// The reply's subject line (see `Subject`), shown as its title.
    func setSubject(_ subject: String?) {
        if model.subject != subject { model.subject = subject }
    }

    private func clearTurn() {
        model.pinned = false
        model.subject = nil
        model.seen = false
        model.answer = ""
        model.status = nil
        model.error = nil
        model.approval = nil
        model.isDone = false
    }

    func hide() {
        isShowing = false
        guard panel.isVisible else { return }
        let panel = self.panel
        hoverTimer?.invalidate()
        model.hovering = false
        if notch != nil {
            model.islandOpen = false // back into the notch, then gone
            let work = DispatchWorkItem { panel?.orderOut(nil) }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            return
        }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel?.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { panel?.orderOut(nil) }
        }
    }

    /// Polls the pointer (a non-activating window doesn't reliably get hover events): over the band
    /// or the open island means hovering; leaving tucks it back up after a short grace.
    private func watchHover() {
        hoverTimer?.invalidate()
        let notch = self.notch
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                let mouse = NSEvent.mouseLocation
                let onCard = NSMouseInRect(mouse, self.panel.frame.insetBy(dx: -4, dy: -4), false)
                let over: Bool
                if let notch {
                    let band = NSRect(x: notch.midX - (notch.width / 2 + RecordingPanel.ear), y: notch.minY - 6,
                                      width: notch.width + 2 * RecordingPanel.ear, height: notch.height + 6)
                    over = NSMouseInRect(mouse, band, false) || ((self.model.expanded || self.model.peek) && onCard)
                } else {
                    over = onCard
                }
                if over {
                    self.leftAt = nil
                    self.lastHover = Date()
                    if !self.model.hovering { self.model.hovering = true }
                    if self.model.hasContent, !self.model.seen { self.model.seen = true }
                } else if self.model.hovering {
                    if let leftAt = self.leftAt {
                        if Date().timeIntervalSince(leftAt) > 0.1 { self.model.hovering = false }
                    } else {
                        self.leftAt = Date()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func makePanel() -> NSPanel {
        let panel = AnswerWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = notch == nil ? .statusBar : .aboveResting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = notch == nil // the island is black on the black notch
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = notch == nil
        panel.isMovable = notch == nil // at the notch it stays put, even on space switches
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: AnswerView(model: model, scrolls: true, notch: notch?.size))
        hosting.sizingOptions = [] // the window's size is set in resize(), not by SwiftUI
        panel.contentView = hosting
        return panel
    }

    init() {
        panel = makePanel()
        model.onClose = { [weak self] in self?.onClose() }
        model.onStopSpeaking = { [weak self] in self?.onStopSpeaking() }
        model.onFollowUp = { [weak self] in self?.onFollowUp($0) }
        // objectWillChange fires before the change lands: measure on the next turn.
        changes = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.resize(anchorTo: nil) }
            }
        }
    }

    /// Fits the window to its content, keeping the bottom edge where it is (or, when first
    /// shown, just above the dictation pill on the given screen). At the notch, the top edge stays
    /// at the top of the screen and the card grows down.
    private func resize(anchorTo screen: NSScreen?) {
        if let notch {
            // The island's shape animates to the new height inside the window. The window grows at
            // once (its extra part is transparent) but shrinks only once the island has, so the
            // island is never cut off mid-animation.
            // Tucked up, the window is only the band, so it never blocks clicks on the menu bar.
            let maxHeight = ((screen ?? panel.screen ?? NSScreen.main)?.frame.height ?? 800) * 0.6
            let expanded = model.expanded
            let peek = model.peek
            let height = expanded ? min(contentHeight, maxHeight).rounded(.up)
                : peek ? notch.height + Self.peekHeight : notch.height
            let width = expanded ? Self.width : peek ? Self.peekWidth : notch.width + 2 * RecordingPanel.ear
            if model.islandHeight != height { model.islandHeight = height }
            let frame = NSRect(x: notch.midX - width / 2, y: notch.maxY - height, width: width, height: height)
            guard frame != panel.frame else { return }
            shrinkWork?.cancel()
            if screen != nil {
                panel.setFrame(frame, display: true)
                return
            }
            // Grow at once (in whichever direction), shrink once the island has.
            let current = panel.frame
            let grown = NSRect(x: notch.midX - max(width, current.width) / 2, y: notch.maxY - max(height, current.height),
                               width: max(width, current.width), height: max(height, current.height))
            if grown != current { panel.setFrame(grown, display: true) }
            if grown != frame {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.panel.setFrame(frame, display: true) }
                }
                shrinkWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
            return
        }
        var frame = panel.frame
        if let visible = screen?.visibleFrame {
            frame.origin = NSPoint(x: visible.midX - Self.width / 2, y: visible.minY + 60)
        }
        let maxHeight = ((screen ?? panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) * 0.6
        frame.size = NSSize(width: Self.width, height: min(contentHeight, maxHeight).rounded(.up))
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

}

/// Can take clicks (links, text selection) without pulling focus from the app the user is in.
private final class AnswerWindow: NotchPanel {
    override var canBecomeKey: Bool { true }
}

final class AnswerModel: ObservableObject {
    @Published var question: String?
    @Published var answer = ""
    @Published var status: String?
    @Published var error: String?
    @Published var isDone = false
    @Published var approval: Assistant.Approval?
    @Published var canFollowUp = false
    /// At the notch: whether the island is out (false while it opens and after it closes), and the
    /// height it's heading for.
    @Published var islandOpen = false
    @Published var islandHeight: CGFloat = 0

    /// At the notch: whether the pointer is over the island.
    @Published var hovering = false
    /// The reply's subject line, like an email's.
    @Published var subject: String?
    /// Whether the answer has been opened (hovered): the subject was a reminder, so it goes.
    @Published var seen = false

    /// Joe is reading the answer out loud: the card shows a stop button.
    @Published var speaking = false
    var onStopSpeaking: () -> Void = {}

    /// Whether there's something to show: the reply, an error, an action waiting for an OK, or just
    /// a subject line (a one-line answer), or Joe talking (so the stop button can be reached).
    var hasContent: Bool { !answer.isEmpty || error != nil || approval != nil || speaking || !(subject ?? "").isEmpty }

    /// At the notch, the island drops down only while the pointer is over it, or by itself for an
    /// action waiting for an OK or an error. Otherwise it stays a slim band: ✦ and sound waves.
    var expanded: Bool { hasContent && !listening && (hovering || pinned || approval != nil || error != nil) }
    /// The user is talking (a follow-up): the island folds back into the band, under the listening
    /// band, so there's one ✦ at the notch, not two.
    @Published var listening = false
    /// Held open without hovering, for a little while (the morning briefing).
    @Published var pinned = false

    /// At the notch, once the answer is done and the pointer is elsewhere: a tick and the subject,
    /// one line under the notch.
    var peek: Bool { !expanded && !listening && !seen && isDone && error == nil && !(subject ?? "").isEmpty }

    var onClose: () -> Void = {}
    var onFollowUp: (String) -> Void = { _ in }
}

private struct AnswerView: View {
    @ObservedObject var model: AnswerModel
    /// The card on screen scrolls when the answer is taller than it; the copy that measures
    /// the answer's full height doesn't.
    let scrolls: Bool
    /// At the notch, its size: the card is an island that comes out of it (see `Island`).
    let notch: CGSize?
    @State private var copied = false
    @State private var saved = false

    var body: some View {
        if let notch, scrolls {
            Island(notch: notch, open: model.islandOpen, expanded: model.expanded, peek: model.peek,
                   height: model.islandHeight, listening: model.listening) {
                band(notch: notch)
            } peekLine: {
                Text(model.subject ?? "")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 2) // optically centred: a touch more room below than above
            } content: {
                card
            }
            .darkAtNotch(true)
        } else {
            card
                .background { if notch == nil { background } }
                .darkAtNotch(notch != nil)
        }
    }

    /// The content and its padding: the same on screen and in the copy that measures it.
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if notch == nil { header } // at the notch, the buttons sit beside it (`band`)
            if scrolls {
                ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            // Outside the scrolling area, so it's never scrolled out of sight.
            if let approval = model.approval {
                ApprovalView(approval: approval)
            } else if model.isDone, model.canFollowUp, !model.answer.isEmpty {
                followUpChips
                if notch == nil {
                    Text("Or hold right ⌥ to follow up")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, notch == nil ? 16 : 20)
        .padding(.bottom, 16)
        .padding(.top, notch.map { $0.height + 4 } ?? 16) // right under the notch
        .frame(width: AnswerPanel.width)
        .frame(maxHeight: scrolls ? .infinity : nil, alignment: .top)
    }

    /// What a student asks next most, one tap each, in the same conversation.
    private static let followUps: [(label: String, symbol: String, request: String)] = [
        ("Simpler", "wand.and.stars", "Explain that more simply, as if I'm new to it. Keep it short."),
        ("Example", "lightbulb", "Give me one worked example of that, step by step."),
        ("Quiz me", "checkmark.bubble", "Quiz me on that: three short questions, one at a time. Wait for my answer and mark it before the next."),
    ]

    private var followUpChips: some View {
        HStack(spacing: 6) {
            ForEach(Self.followUps, id: \.label) { item in
                Button { model.onFollowUp(item.request) } label: {
                    Label(item.label, systemImage: item.symbol)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .foregroundStyle(.orange)
            if let subject = model.subject, !subject.isEmpty {
                Text(subject).font(.callout.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            buttons
        }
        .buttonStyle(.borderless)
    }

    /// Stop Joe talking (while he is), copy and save to notes (once the reply is done) and close.
    @ViewBuilder
    private var buttons: some View {
        if model.speaking {
            Button { model.onStopSpeaking() } label: { Image(systemName: "speaker.slash.fill") }
                .help("Stop speaking")
        }
        if model.isDone, !model.answer.isEmpty {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.answer, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy answer")
            .onChange(of: model.answer) { copied = false; saved = false }
            if NoteSaver.root != nil {
                Button {
                    saved = NoteSaver.saveAnswer(model.answer, question: model.question, subject: model.subject) != nil
                } label: {
                    Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                }
                .help(saved ? "Saved to your notes" : "Save to notes")
                .disabled(saved)
            }
        }
        Button { model.onClose() } label: { Image(systemName: "xmark") }
            .help("Close")
    }

    /// At the notch, the strip beside it: the assistant's ✦ on the left, and on the right sound
    /// waves while Claude works, a green tick once the reply is done (hover to read it), or copy
    /// and close while it's open.
    private func band(notch: CGSize) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: model.expanded ? nil : RecordingPanel.ear) // where it sits at rest
                .opacity(model.listening ? 0 : 1) // the listening band's ✦ is the one showing
                .animation(nil, value: model.listening)
            Spacer(minLength: notch.width) // behind the notch
            if model.expanded {
                buttons.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            } else if model.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .frame(width: RecordingPanel.ear)
            } else if model.isDone {
                DoneTick().frame(width: RecordingPanel.ear)
            } else {
                WaveBars(moving: true).frame(width: RecordingPanel.ear)
            }
        }
        .padding(.horizontal, model.expanded ? 20 : 0)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.answer.isEmpty {
                MarkdownText(markdown: model.answer)
            }
            if let error = model.error {
                Label {
                    Text((try? AttributedString(markdown: error)) ?? AttributedString(error))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
            }
            if let status = model.status, !model.isDone {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// "Joe wants to…": a dark card like a share sheet. The app it's for and what it'll do, then the
/// details as rows (To, Message…), then Cancel and the action itself.
private struct ApprovalView: View {
    let approval: Assistant.Approval

    var body: some View {
        switch approval.preview {
        case let .email(to, cc, subject, body):
            card(title: "Send email", icon: .tile("envelope.fill", .red),
                 rows: [("To", to), ("Cc", cc), ("Subject", subject)], message: body,
                 cancel: "Cancel", confirm: "Send")
        case let .message(app, appName, to, text):
            card(title: "Send message", icon: NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
                    .map { .app(NSWorkspace.shared.icon(forFile: $0.path)) } ?? .tile("message.fill", .green),
                 rows: [("App", appName), ("To", to)], message: text, cancel: "Cancel", confirm: "Send")
        case let .event(title, when, location, guests):
            card(title: "Add event", icon: .tile("calendar", .red),
                 rows: [("Event", title.isEmpty ? "Untitled event" : title), ("When", when), ("Where", location), ("Invites", guests)],
                 cancel: "Cancel", confirm: "Add")
        case nil:
            card(title: approval.title, icon: Self.icon(for: approval.tool), rows: detailRows,
                 cancel: "Deny", confirm: "Allow", forTask: true)
        }
    }

    // MARK: Layout

    private func card(title: String, icon: Icon, rows: [(String, String)], message: String? = nil,
                      cancel: String, confirm: String, forTask: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                icon.view
                // "Click in Chrome: this may send or submit something": the second part goes under.
                let parts = title.components(separatedBy: ": ")
                VStack(alignment: .leading, spacing: 1) {
                    Text(parts[0])
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    if parts.count > 1 {
                        Text(parts.dropFirst().joined(separator: ": ").prefix(1).uppercased() + parts.dropFirst().joined(separator: ": ").dropFirst())
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            line
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(rows.filter { !$0.1.isEmpty }.enumerated()), id: \.offset) { _, row in
                    self.row(row.0, Text(row.1).lineLimit(row.0 == "Run" ? 6 : 3), mono: row.0 == "Run")
                }
                if let message, !message.isEmpty {
                    if message.count > 400 { // a long email scrolls
                        row("Message", ScrollView {
                            Text(message).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 150))
                    } else {
                        row("Message", Text(message).fixedSize(horizontal: false, vertical: true))
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            line
            HStack(spacing: 8) {
                Spacer()
                Button(cancel) { approval.decide(.deny) }
                    .buttonStyle(CapsuleButton(prominent: false))
                    .keyboardShortcut(.cancelAction)
                if forTask {
                    Button("Allow for this task") { approval.decide(.allowForTask) }
                        .buttonStyle(CapsuleButton(prominent: false))
                }
                Button(confirm) { approval.decide(.allow) }
                    .buttonStyle(CapsuleButton(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
        }
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: some View, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(width: 64, alignment: .leading)
            value
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13.5))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13.5))
    }

    private var line: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5)
    }

    /// The details as rows: the summary first ("What"), then each "key: value" line.
    private var detailRows: [(String, String)] {
        approval.detail.components(separatedBy: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if let colon = line.firstIndex(of: ":"), line[..<colon].allSatisfy({ $0.isLetter || $0 == "_" }) {
                let key = String(line[..<colon])
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let names = ["command": "Run", "file_path": "File", "path": "File", "url": "Page", "new_string": "New text",
                             "content": "Text", "text": "Text", "value": "Value"]
                return (names[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized, value)
            }
            return ("What", line)
        }
    }

    // MARK: Icons

    enum Icon {
        case tile(String, Color)
        case app(NSImage)

        @ViewBuilder var view: some View {
            switch self {
            case let .tile(symbol, color):
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24, height: 24)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            case let .app(image):
                Image(nsImage: image).resizable().frame(width: 26, height: 26)
            }
        }
    }

    /// The app the action is in: the browser for Chrome actions, Obsidian for the notes, Terminal
    /// for commands, or a tile for the Google services.
    static func icon(for tool: String) -> Icon {
        let name = tool.lowercased()
        func app(_ ids: [String]) -> Icon? {
            for id in ids {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    return .app(NSWorkspace.shared.icon(forFile: url.path))
                }
            }
            return nil
        }
        if name.contains("chrome") {
            return app(["com.vivaldi.Vivaldi", "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser"])
                ?? .tile("globe", .blue)
        }
        if name.contains("gmail") { return .tile("envelope.fill", .red) }
        if name.contains("calendar") { return .tile("calendar", .red) }
        if name.contains("drive") || name.contains("doc") { return .tile("doc.text.fill", .blue) }
        if name == "bash" { return app(["com.apple.Terminal"]) ?? .tile("terminal.fill", .black) }
        if ["edit", "write", "read", "glob", "grep"].contains(name) || name.contains("obsidian") {
            return app(["md.obsidian"]) ?? .tile("doc.fill", .purple)
        }
        return .tile("sparkle", .orange)
    }
}

/// Cancel (an outline) and the action (filled blue, with a ring like a focused button).
private struct CapsuleButton: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.6))
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background {
                if prominent {
                    Capsule().fill(Color(red: 0.2, green: 0.45, blue: 0.9))
                } else {
                    Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                }
            }
            .padding(prominent ? 2.5 : 0)
            .overlay {
                if prominent { Capsule().strokeBorder(Color(red: 0.2, green: 0.45, blue: 0.9).opacity(0.45), lineWidth: 1.5) }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Renders the markdown Claude writes: paragraphs, "- " bullets, bold, italics, code and links.
/// Claude's Markdown on the card: headings (title, subtitle), bullets and numbered lists, checklists,
/// quotes, code blocks, tables and dividers; bold, italics, links and code inline.
private struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, indent: Int)
        case numbered(String, String, indent: Int)
        case task(Bool, String)
        case quote(String)
        case code(String)
        case table([[String]])
        case rule
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(.system(size: level == 1 ? 17 : level == 2 ? 15 : 13.5, weight: .semibold))
                .foregroundStyle(level >= 3 ? .secondary : .primary)
                .padding(.top, 4)
        case let .paragraph(text):
            Text(inline(text))
        case let .bullet(text, indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(indent > 0 ? "◦" : "•").foregroundStyle(.secondary)
                Text(inline(text))
            }
            .padding(.leading, CGFloat(indent) * 14)
        case let .numbered(number, text, indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number + ".").foregroundStyle(.secondary).monospacedDigit()
                Text(inline(text))
            }
            .padding(.leading, CGFloat(indent) * 14)
        case let .task(done, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(done ? Color.accentColor : .secondary)
                Text(inline(text)).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
            }
        case let .quote(text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Text(inline(text)).foregroundStyle(.secondary)
            }
        case let .code(text):
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case let .table(rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell)).font(.system(size: 12.5, weight: index == 0 ? .semibold : .regular))
                        }
                    }
                    if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        var code: [String]?
        var table: [[String]] = []
        func flushTable() { if !table.isEmpty { blocks.append(.table(table)); table = [] } }
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))); code = nil } else { flushTable(); code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }
            // Tables: | a | b |, skipping the |---| row.
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                let cells = trimmed.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable()
            guard !trimmed.isEmpty else { continue }
            let indent = (line.prefix { $0 == " " }.count) / 2
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil { blocks.append(.rule); continue }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                blocks.append(.heading(level, trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("> ") { blocks.append(.quote(String(trimmed.dropFirst(2)))); continue }
            if let match = trimmed.range(of: #"^[-*] \[( |x|X)\] "#, options: .regularExpression) {
                blocks.append(.task(trimmed[match].lowercased().contains("x"), String(trimmed[match.upperBound...])))
                continue
            }
            if let marker = ["- ", "* ", "• "].first(where: { trimmed.hasPrefix($0) }) {
                blocks.append(.bullet(String(trimmed.dropFirst(marker.count)), indent: indent))
                continue
            }
            if let match = trimmed.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) {
                let number = trimmed[match].trimmingCharacters(in: CharacterSet(charactersIn: ".) "))
                blocks.append(.numbered(number, String(trimmed[match.upperBound...]), indent: indent))
                continue
            }
            blocks.append(.paragraph(trimmed))
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushTable()
        return blocks
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// At the notch: a glass island that comes out of the notch like the iPhone's Dynamic Island.
/// While Claude works it's a slim band, the notch a little wider (`band`); once there's an
/// answer it drops down and follows the reply's height as it streams in. The window is already
/// full size; only the shape moves, so every change animates smoothly.
///
/// Motion and material follow VoiceOS's notch: it opens in 460 ms on a fast-out curve with a long
/// settle (no bounce) and closes in 300 ms, accelerating back in; the content fades in 80 ms behind
/// the shape and grows from 97%. The glass is solid black at the notch, fading into a dark,
/// blurred tint, with a faint light rim along the bottom edge.
private struct Island<Band: View, PeekLine: View, Content: View>: View {
    let notch: CGSize
    /// Out of the notch at all.
    let open: Bool
    /// Dropped down, showing the answer; otherwise the slim band.
    let expanded: Bool
    /// Done and not hovered: one line under the notch (the tick and subject).
    let peek: Bool
    let height: CGFloat
    /// The user is talking: the island folds at once, with no animation (see `AnswerModel.listening`).
    let listening: Bool
    @ViewBuilder let band: Band
    @ViewBuilder let peekLine: PeekLine
    @ViewBuilder let content: Content
    @State private var shown: CGFloat = 0

    static var opening: Animation { NotchShape.opening }
    static var closing: Animation { NotchShape.closing }
    /// Following the reply as it streams: the same spring, settling sooner.
    static var growing: Animation { NotchShape.growing }

    var body: some View {
        GeometryReader { space in
            let dropped = open && expanded
            let width = !open ? notch.width
                : expanded ? AnswerPanel.width
                : peek ? AnswerPanel.peekWidth
                : notch.width + 2 * RecordingPanel.ear
            let peeking = open && peek && !expanded
            let radius: CGFloat = !open ? min(10, notch.height / 3) : expanded ? 30 : peek ? 18 : 13
            // Shoulders curving into the screen's top edge, like the iPhone's notch.
            let shape = NotchShape(top: NotchShape.shoulder, bottom: radius)
            let shapeHeight = max(shown, notch.height)
            let solid = min(1, (notch.height + 2) / max(shapeHeight, 1)) // where the notch ends
            content
                .frame(width: AnswerPanel.width, height: space.size.height, alignment: .top)
                .frame(width: space.size.width, height: space.size.height, alignment: .top)
                .opacity(dropped ? 1 : 0)
                .scaleEffect(dropped ? 1 : 0.94, anchor: .top)
                .blur(radius: dropped ? 0 : 6)
                .animation(listening ? nil : dropped ? .easeOut(duration: 0.24).delay(0.12) : .easeIn(duration: 0.1), value: dropped)
                .background(alignment: .top) {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        // Solid at the notch, then a dark tint the blur shows through, darker than
                        // VoiceOS's so the reply stays readable over any background.
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: solid),
                            .init(color: .black.opacity(0.9), location: min(1, solid + 0.12)),
                            .init(color: .black.opacity(0.8), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                        // The rim: light catching the bottom edge.
                        LinearGradient(stops: [
                            .init(color: .white.opacity(0), location: 0.46),
                            .init(color: .white.opacity(0.05), location: 0.74),
                            .init(color: .white.opacity(0.09), location: 0.985),
                            .init(color: .white.opacity(0.3), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                        .opacity(dropped || peeking ? 1 : 0)
                    }
                    .frame(width: width, height: shapeHeight)
                    .clipShape(shape)
                }
                .overlay(alignment: .top) {
                    band
                        .frame(width: width, height: notch.height)
                        .opacity(open ? 1 : 0)
                        .animation(open ? .easeOut(duration: 0.2).delay(0.08) : .easeIn(duration: 0.15), value: open)
                }
                .overlay(alignment: .top) {
                    peekLine
                        .frame(width: width, height: AnswerPanel.peekHeight)
                        .offset(y: notch.height)
                        .opacity(peeking ? 1 : 0)
                        .animation(listening ? nil : peeking ? .easeOut(duration: 0.2).delay(0.08) : .easeIn(duration: 0.1), value: peeking)
                }
                .mask(alignment: .top) { shape.frame(width: width, height: shapeHeight) }
                .animation(listening ? nil : peek ? Self.opening : Self.closing, value: peek)
                .animation(open ? Self.opening : Self.closing, value: open)
                .animation(listening ? nil : expanded ? Self.opening : Self.closing, value: expanded)
                .frame(width: space.size.width, height: space.size.height, alignment: .top)
        }
        .onChange(of: open && (expanded || peek) ? height : notch.height, initial: true) { _, target in
            let dropping = shown <= notch.height + 1
            let tucking = target <= notch.height + 1
            if listening { shown = target; return } // folding for a follow-up: at once
            withAnimation(!open || tucking ? Self.closing : dropping ? Self.opening : Self.growing) { shown = target }
        }
    }
}

/// "Done": a green tick that pops in beside the notch when the reply is finished, so it's clear
/// even for a quick question.
private struct DoneTick: View {
    @State private var shown = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.green)
            .scaleEffect(shown ? 1 : 0.4)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { shown = true }
            }
    }
}

/// The sound waves in the band beside the notch: rippling while Claude works, settled into a
/// still wave once the answer's ready (hover to read it).
private struct WaveBars: View {
    let moving: Bool
    private static let resting: [CGFloat] = [0.35, 0.7, 1, 0.6, 0.3]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    let level = moving ? 0.35 + 0.65 * abs(sin(t * 5 + Double(i) * 0.9)) : Self.resting[i]
                    Capsule()
                        .fill(Color.white.opacity(moving ? 0.95 : 0.7))
                        .frame(width: 3, height: 3 + level * 13)
                }
            }
        }
    }
}

private extension View {
    /// Light text on the black notch card, whatever the system appearance.
    @ViewBuilder
    func darkAtNotch(_ atNotch: Bool) -> some View {
        if atNotch { environment(\.colorScheme, .dark) } else { self }
    }
}
