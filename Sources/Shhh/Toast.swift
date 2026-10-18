import AppKit
import SwiftUI

/// A small "done" bubble by the mouse pointer after the assistant acts ("Email sent"). Like
/// VoiceOS's: it pops in (from 55% and 8 pt lower, on a fast-out curve) and fades away after a
/// couple of seconds. Clicks go straight through it.
@MainActor
final class Toast {
    private let model = ToastModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 280, height: 44)

    func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: Color = .green) {
        hideWork?.cancel()
        panel?.orderOut(nil)
        model.text = text
        model.symbol = symbol
        model.tint = tint
        model.shown = false

        // Just below and right of the pointer, kept on its screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x + 14, y: mouse.y - Self.size.height - 10)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - Self.size.height - 8)
        }
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ToastView(model: model))
        self.panel = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            MainActor.assumeIsolated { self.model.shown = true }
        }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.shown = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated { if !self.model.shown { panel.orderOut(nil) } }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }
}

final class ToastModel: ObservableObject {
    @Published var text = ""
    @Published var symbol = "checkmark.circle.fill"
    @Published var tint = Color.green
    @Published var shown = false
}

private struct ToastView: View {
    @ObservedObject var model: ToastModel

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: model.symbol)
                .foregroundStyle(model.tint)
            Text(model.text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(Color.black.opacity(0.75))
            Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        }
        .environment(\.colorScheme, .dark)
        .scaleEffect(model.shown ? 1 : 0.55, anchor: .topLeading)
        .offset(y: model.shown ? 0 : 8)
        .opacity(model.shown ? 1 : 0)
        .animation(model.shown ? .timingCurve(0.22, 1, 0.36, 1, duration: 0.6) : .easeIn(duration: 0.25), value: model.shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
