import AppKit
import SwiftUI

/// The small pill at the bottom of the screen, or at the notch (see `Notch`). Only visible while
/// recording or transcribing.
@MainActor
final class RecordingPanel {
    /// At the notch: how far the pill sticks out on each side of it.
    static let ear: CGFloat = 46
    /// Whether the current pill hangs from the notch (it then closes back into it).
    private var atNotch = false
    private let model = PillModel()
    private var panel: NSPanel?
    /// Bumped on every show so a fade-out that finishes late can't hide a newer pill.
    private var generation = 0
    /// Whether the pill is up (or fading in). False as soon as a fade-out starts.
    private var isShown = false

    /// `assistant`: right ⌥ (the assistant) rather than right ⌘ (dictation), shown at the notch.
    func showRecording(assistant: Bool = false) {
        model.assistant = assistant
        model.mode = .recording
        model.levels = Array(repeating: 0, count: PillModel.barCount)
        present()
    }

    func showProcessing() {
        model.mode = .processing
        present() // normally already up; covers a recording pill that missed its cue
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        let hiding = generation
        let panel = self.panel
        if atNotch {
            // Straight off: the resting band or the answer's band takes its place, same size.
            panel?.orderOut(nil)
            model.mode = .idle
            return
        }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel?.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                guard self.generation == hiding else { return }
                panel?.orderOut(nil)
                self.model.mode = .idle // the processing dots would keep animating off screen
            }
        }
    }

    private func present() {
        guard !isShown else { return }
        isShown = true
        generation += 1
        // A new window each time, shown at once: a reused one, or one fading in, can stay hidden
        // behind a full-screen app (seen with full-screen Vivaldi).
        self.panel?.orderOut(nil)
        let screen = Notch.screenUnderMouse
        let notch = Notch.isEnabled ? screen.map { Notch.rect(on: $0) } : nil
        let panel = makePanel(notch: notch)
        self.panel = panel
        atNotch = notch != nil
        model.open = atNotch // at full size straight away, in place of the resting band
        if let notch {
            panel.setFrameOrigin(NSPoint(x: notch.midX - panel.frame.width / 2, y: notch.minY))
        } else {
            position(panel)
        }
        panel.orderFrontRegardless()
        if atNotch { NotchSpace.pin(panel) }
    }

    /// Feed microphone loudness (0...1). Called from the audio thread.
    nonisolated func push(level: Float) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.append(level: level) }
        }
    }

    private func append(level: Float) {
        guard model.mode == .recording else { return }
        model.levels.removeFirst()
        model.levels.append(CGFloat(level))
    }

    private func makePanel(notch: NSRect?) -> NSPanel {
        let size = notch.map { NSSize(width: $0.width + 2 * Self.ear, height: $0.height) } ?? NSSize(width: 96, height: 30)
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = notch == nil ? .statusBar : .aboveResting
        panel.isMovable = notch == nil
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PillView(model: model, notchWidth: notch?.width))
        return panel
    }

    /// Bottom-centre of the screen the mouse is on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        // NSMouseInRect, not contains: the mouse can sit on a screen's top edge (the menu bar),
        // which contains() leaves out, and the pill would land on another display.
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 18))
    }
}

final class PillModel: ObservableObject {
    enum Mode { case idle, recording, processing }
    static let barCount = 11
    @Published var mode: Mode = .idle
    @Published var levels: [CGFloat] = Array(repeating: 0, count: barCount)
    /// At the notch: whether the pill is out, and whether it's for the assistant.
    @Published var open = false
    @Published var assistant = false
}

private struct PillView: View {
    @ObservedObject var model: PillModel
    /// At the notch, how wide it is: the pill widens it, a mic on one side and the bars on the other.
    let notchWidth: CGFloat?

    var body: some View {
        if let notchWidth {
            // The same band as at rest: the ✦ where it always is, and on the right the live
            // waveform (dots while transcribing).
            let full = notchWidth + 2 * RecordingPanel.ear
            let radius: CGFloat = model.open ? 13 : 10
            ZStack {
                UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                    .fill(Color.black)
                    .frame(width: model.open ? full : notchWidth)
                HStack(spacing: 0) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: RecordingPanel.ear)
                    Color.clear.frame(width: notchWidth) // behind the notch
                    Group {
                        if model.mode == .processing {
                            ProcessingDots()
                        } else {
                            HStack(spacing: 2) {
                                ForEach(Array(model.levels.suffix(5).enumerated()), id: \.offset) { _, level in
                                    Capsule().fill(Color.white).frame(width: 3, height: 4 + level * 16)
                                }
                            }
                            .animation(.easeOut(duration: 0.08), value: model.levels)
                        }
                    }
                    .frame(width: RecordingPanel.ear)
                }
                .opacity(model.open ? 1 : 0)
                .animation(model.open ? .easeOut(duration: 0.2).delay(0.08) : .easeIn(duration: 0.15), value: model.open)
            }
            .frame(width: full)
            .frame(maxHeight: .infinity)
            .animation(model.open ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.46) : .timingCurve(0.5, 0, 0.75, 0, duration: 0.3),
                       value: model.open)
        } else {
            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.85))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                indicator(spacing: 3)
            }
            .frame(width: 96, height: 30)
        }
    }

    @ViewBuilder
    private func indicator(spacing: CGFloat) -> some View {
        if model.mode == .recording {
            HStack(spacing: spacing) {
                ForEach(0..<model.levels.count, id: \.self) { i in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 3, height: 4 + model.levels[i] * 14)
                }
            }
            .animation(.easeOut(duration: 0.08), value: model.levels)
        } else if model.mode == .processing {
            ProcessingDots()
        }
    }
}

private struct ProcessingDots: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 6 - Double(i) * 0.8)))
                }
            }
        }
    }
}
