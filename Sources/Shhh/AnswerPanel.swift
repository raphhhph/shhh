import AppKit
import Combine
import SwiftUI

/// The card that shows Claude's reply, at the bottom of the screen. It grows upwards as the
/// reply streams in, asks for the user's OK before Claude acts, and stays until it's closed.
@MainActor
final class AnswerPanel {
    private let model = AnswerModel()
    private lazy var panel: NSPanel = makePanel()
    /// Measures how tall the card wants to be: the same view, laid out without scrolling.
    private lazy var sizer = NSHostingController(rootView: AnswerView(model: model, scrolls: false))
    private var changes: AnyCancellable?
    var onClose: () -> Void = {}

    static let width: CGFloat = 480

    var isVisible: Bool { panel.isVisible }
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
        if !panel.isVisible {
            panel.alphaValue = 0
            resize(anchorTo: screenUnderMouse())
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    func update(_ event: Assistant.Event) {
        switch event {
        case .status(let status): model.status = status
        case .answer(let answer): model.answer = answer
        case .approval(let approval): model.approval = approval
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

    private func clearTurn() {
        model.answer = ""
        model.status = nil
        model.error = nil
        model.approval = nil
        model.isDone = false
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { self.panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = AnswerWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: AnswerView(model: model, scrolls: true))
        hosting.sizingOptions = [] // the window's size is set in resize(), not by SwiftUI
        panel.contentView = hosting
        model.onClose = { [weak self] in self?.onClose() }
        // objectWillChange fires before the change lands: measure on the next turn.
        changes = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.resize(anchorTo: nil) }
            }
        }
        return panel
    }

    /// Fits the window to its content, keeping the bottom edge where it is (or, when first
    /// shown, just above the dictation pill on the given screen).
    private func resize(anchorTo screen: NSScreen?) {
        var frame = panel.frame
        if let visible = screen?.visibleFrame {
            frame.origin = NSPoint(x: visible.midX - Self.width / 2, y: visible.minY + 60)
        }
        let maxHeight = ((screen ?? panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) * 0.6
        frame.size = NSSize(width: Self.width, height: min(contentHeight, maxHeight).rounded(.up))
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

/// Can take clicks (links, text selection) without pulling focus from the app the user is in.
private final class AnswerWindow: NSPanel {
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
    var onClose: () -> Void = {}
}

private struct AnswerView: View {
    @ObservedObject var model: AnswerModel
    /// The card on screen scrolls when the answer is taller than it; the copy that measures
    /// the answer's full height doesn't.
    let scrolls: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if scrolls {
                ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            // Outside the scrolling area, so it's never scrolled out of sight.
            if let approval = model.approval {
                ApprovalView(approval: approval)
            } else if model.isDone, model.canFollowUp {
                Text("Hold right ⌥ to follow up")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: AnswerPanel.width)
        .frame(maxHeight: scrolls ? .infinity : nil, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .foregroundStyle(.orange)
            Text(model.question ?? "Listening…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.isDone, !model.answer.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.answer, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy answer")
            }
            Button { model.onClose() } label: { Image(systemName: "xmark") }
                .help("Close")
        }
        .buttonStyle(.borderless)
        .onChange(of: model.answer) { copied = false }
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

/// "Claude wants to…" with the action's details and the user's three choices.
private struct ApprovalView: View {
    let approval: Assistant.Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.title, systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Deny") { approval.decide(.deny) }
                Spacer()
                Button("Allow for this task") { approval.decide(.allowForTask) }
                Button("Allow") { approval.decide(.allow) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5))
    }
}

/// Renders the markdown Claude writes: paragraphs, "- " bullets, bold, italics, code and links.
private struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                if let bullet = paragraph.bullet {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(bullet))
                    }
                    .padding(.leading, CGFloat(paragraph.indent) * 14)
                } else {
                    Text(inline(paragraph.text))
                }
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }

    private struct Paragraph {
        let text: String
        let bullet: String?
        let indent: Int
    }

    private var paragraphs: [Paragraph] {
        markdown.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let indent = (line.prefix { $0 == " " }.count) / 2
            for marker in ["- ", "* ", "• "] where trimmed.hasPrefix(marker) {
                return Paragraph(text: trimmed, bullet: String(trimmed.dropFirst(marker.count)), indent: indent)
            }
            // Headings, in case Claude writes one anyway: show them as bold text.
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return Paragraph(text: "**\(title)**", bullet: nil, indent: 0)
            }
            return Paragraph(text: trimmed, bullet: nil, indent: 0)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
