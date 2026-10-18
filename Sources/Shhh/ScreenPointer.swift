import AppKit
import SwiftUI

/// Points at things on screen. When a request comes with a screenshot, Claude can write
/// `[POINT:x,y:label]` (x and y in the screenshot's pixels, from the top left). The tags are taken
/// out of the reply and drawn as pulsing rings with their labels over the screen that was captured.
@MainActor
final class ScreenPointer {
    struct Point: Equatable {
        let x: Double
        let y: Double
        let label: String
    }

    private var panel: NSPanel?
    private var shown: [Point] = []
    private var hideWork: DispatchWorkItem?

    /// The reply without its point tags (and without a tag still being written at the end), and the
    /// points it names.
    static func split(_ text: String) -> (text: String, points: [Point]) {
        let pattern = #"\[POINT:\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*(?::\s*([^\]]*))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return (text, []) }
        let range = NSRange(text.startIndex..., in: text)
        var points: [Point] = []
        for match in regex.matches(in: text, range: range) {
            let value = { (i: Int) in Range(match.range(at: i), in: text).map { String(text[$0]) } }
            if let x = value(1).flatMap(Double.init), let y = value(2).flatMap(Double.init) {
                points.append(Point(x: x, y: y, label: value(3)?.trimmingCharacters(in: .whitespaces) ?? ""))
            }
        }
        var clean = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        // A tag that's still streaming in: "… [POI" or "… [POINT:120,4".
        if let open = clean.range(of: "[", options: .backwards),
           !clean[open.lowerBound...].contains("]"),
           "[POINT:".hasPrefix(clean[open.lowerBound...].prefix(7).uppercased()) {
            clean.removeSubrange(open.lowerBound...)
        }
        clean = clean.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([.,;:!?])"#, with: "$1", options: .regularExpression)
        return (clean, points)
    }

    /// Shows the points over the screen the screenshot came from, for a few seconds.
    func show(_ points: [Point], on screenshot: ScreenCapture.Screenshot) {
        guard !points.isEmpty, points != shown else { return }
        shown = points
        let frame = screenshot.screenFrame
        let scale = CGSize(width: frame.width / screenshot.pixelSize.width, height: frame.height / screenshot.pixelSize.height)
        let marks = points.enumerated().map { index, point in
            PointerMark(position: CGPoint(x: point.x * scale.width, y: point.y * scale.height),
                        label: points.count > 1 ? "\(index + 1). \(point.label)" : point.label)
        }
        // A new window each time: a reused one can stay hidden behind a full-screen app.
        self.panel?.orderOut(nil)
        let panel = makePanel()
        self.panel = panel
        panel.setFrame(frame, display: false)
        panel.contentView = NSHostingView(rootView: PointerView(marks: marks, size: frame.size))
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6 + 2 * Double(points.count), execute: work)
    }

    func hide() {
        hideWork?.cancel()
        shown = []
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // the user clicks straight through to what's pointed at
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

private struct PointerMark {
    let position: CGPoint
    let label: String
}

private struct PointerView: View {
    let marks: [PointerMark]
    let size: CGSize
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                ZStack {
                    Circle()
                        .stroke(Color.orange, lineWidth: 3)
                        .frame(width: 36, height: 36)
                        .scaleEffect(pulse ? 1.3 : 0.9)
                        .opacity(pulse ? 0.35 : 1)
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 10, height: 10)
                }
                .position(mark.position)
                if !mark.label.isEmpty {
                    Text(mark.label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.orange, in: Capsule())
                        .shadow(radius: 3)
                        .fixedSize()
                        // Below the ring, or above it near the bottom of the screen.
                        .position(x: min(max(mark.position.x, 80), size.width - 80),
                                  y: mark.position.y + (mark.position.y > size.height - 60 ? -34 : 34))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
