import AppKit
import SwiftUI

/// Drawing on the screen: circle a graph, underline a sentence, sketch an arrow, then "Ask Joe
/// about this" sends the screen with the drawing on it. Esc or Done puts the pen away.
@MainActor
final class ScreenPen {
    private var panel: NSPanel?
    private let model = ScreenPenModel()
    /// Asks Joe about the screen as it looks now, drawing included.
    var ask: (_ request: String, _ screenshot: Data) -> Void = { _, _ in }

    var isOpen: Bool { panel != nil }

    func show() {
        guard panel == nil, let screen = Notch.screenUnderMouse ?? NSScreen.main else { return }
        model.strokes = []
        let panel = KeyPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        model.onDone = { [weak self] in self?.hide() }
        model.onAsk = { [weak self] in self?.askAboutScreen() }
        panel.contentView = NSHostingView(rootView: ScreenPenView(model: model))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func askAboutScreen() {
        model.toolbar = false // not in the picture
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            let shot = await ScreenCapture.capture()
            hide()
            model.toolbar = true
            guard let shot else { NSSound.beep(); return }
            ask("Look at what I've drawn on my screen (the coloured marks) and help me with it: explain it, answer it, or tell me what I'm pointing at.", shot.jpeg)
        }
    }
}

/// A panel that takes keys (for Esc) without becoming the active app's main window.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ScreenPenModel: ObservableObject {
    @Published var strokes: [SketchPad.Stroke] = []
    @Published var ink = Color.red
    @Published var toolbar = true
    var onDone: () -> Void = {}
    var onAsk: () -> Void = {}
}

private struct ScreenPenView: View {
    @ObservedObject var model: ScreenPenModel
    @State private var drawing = false

    var body: some View {
        ZStack(alignment: .top) {
            Canvas { context, _ in
                for stroke in model.strokes where stroke.points.count > 1 {
                    var path = Path()
                    path.addLines(stroke.points)
                    context.stroke(path, with: .color(stroke.color), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            // Almost clear, so clicks land here rather than going through to the apps below.
            .background(Color.black.opacity(0.001))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if drawing, !model.strokes.isEmpty {
                        model.strokes[model.strokes.count - 1].points.append(value.location)
                    } else {
                        drawing = true
                        model.strokes.append(SketchPad.Stroke(points: [value.location], color: model.ink))
                    }
                }
                .onEnded { _ in drawing = false })
            if model.toolbar {
                HStack(spacing: 12) {
                    Image(systemName: "pencil.tip").foregroundStyle(.white)
                    ForEach([Color.red, Color.yellow, Color.green, Color.blue, Color.white], id: \.self) { color in
                        Circle().fill(color).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: model.ink == color ? 2 : 0).padding(-3))
                            .onTapGesture { model.ink = color }
                    }
                    Divider().frame(height: 18)
                    Button("Undo") { if !model.strokes.isEmpty { model.strokes.removeLast() } }
                    Button("Clear") { model.strokes = [] }
                    Button { model.onAsk() } label: { Label("Ask \(Assistant.name) about this", systemImage: "sparkle") }
                        .disabled(model.strokes.isEmpty)
                    Button("Done") { model.onDone() }.keyboardShortcut(.cancelAction)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: 40)
                .background(Color.black.opacity(0.82), in: Capsule())
                .padding(.top, 60)
            }
        }
        .ignoresSafeArea()
    }
}
