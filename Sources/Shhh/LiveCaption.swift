import AppKit
import SwiftUI

/// Words as they're spoken, under the recording pill: the last line or two of what Joe has heard
/// so far, updated about once a second while a key is held. The final text is still worked out
/// from the whole recording when the key is let go.
@MainActor
final class LiveCaption {
    /// Settings → General → Dictation → Live words (on by default).
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "liveCaption") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveCaption") }
    }

    private let model = CaptionModel()
    private var panel: NSPanel?

    func show(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isEnabled, !text.isEmpty else { return }
        // The end of it: what they're saying now.
        model.text = text.count > 140 ? "…" + text.suffix(140) : text
        if panel == nil { present() }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        model.text = ""
    }

    private func present() {
        guard let screen = Notch.screenUnderMouse ?? NSScreen.main else { return }
        let size = NSSize(width: 560, height: 70)
        let frame = screen.frame
        // Under the notch (or the top of the screen), clear of the pill.
        let top = Notch.isEnabled ? Notch.rect(on: screen).minY - 44 : screen.visibleFrame.maxY - 60
        let panel = NSPanel(contentRect: NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CaptionView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private final class CaptionModel: ObservableObject {
    @Published var text = ""
}

private struct CaptionView: View {
    @ObservedObject var model: CaptionModel

    var body: some View {
        VStack {
            Text(model.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .animation(.easeOut(duration: 0.12), value: model.text)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
