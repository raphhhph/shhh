import AppKit
import SwiftUI

extension NSWindow.Level {
    /// The listening band and the answer island: just above the resting band (`statusBar`), which
    /// they cover exactly, so switching between them never shows the bare notch.
    static let aboveResting = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
}

/// A window hanging from the notch. macOS pushes windows below the menu bar when a full-screen
/// app's space comes or goes (seen: the island stuck 84 points down); this one stays where it's put.
class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A space of Joe's own, above all the others, for the notch windows. Without it they belong to
/// whichever space is showing and slide away with the menu bar each time a full-screen app's space
/// comes or goes, then jump back. Uses the window server's private space functions (as notch apps
/// like Boring Notch do), looked up at run time: if they're ever missing, nothing changes.
@MainActor
enum NotchSpace {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int, CFDictionary?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias Show = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindows = @convention(c) (Int32, CFArray, CFArray) -> Void

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) } // RTLD_DEFAULT
    }

    private static let space: (connection: Int32, id: UInt64, add: AddWindows)? = {
        guard let connection = symbol("CGSMainConnectionID", Connection.self)?(),
              let create = symbol("CGSSpaceCreate", Create.self),
              let setLevel = symbol("CGSSpaceSetAbsoluteLevel", SetLevel.self),
              let show = symbol("CGSShowSpaces", Show.self),
              let add = symbol("CGSAddWindowsToSpaces", AddWindows.self) else { return nil }
        let id = create(connection, 1, nil)
        guard id != 0 else { return nil }
        setLevel(connection, id, Int32.max)
        show(connection, [NSNumber(value: id)] as CFArray)
        return (connection, id, add)
    }()

    private static var added: Set<Int> = []

    /// Puts a shown window in the space (once; call after it's on screen, when it has a number).
    static func pin(_ window: NSWindow) {
        let number = window.windowNumber
        guard number > 0, !added.contains(number), let space else { return }
        added.insert(number)
        if added.count > 400 { added = [number] }
        space.add(space.connection, [NSNumber(value: number)] as CFArray, [NSNumber(value: space.id)] as CFArray)
    }
}

/// "Show at the notch": the pill and the answer card come out of the top of the screen, like the
/// iPhone's Dynamic Island, instead of sitting at the bottom. On a screen without a notch they use
/// the same spot, at the top centre.
enum Notch {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "showAtNotch") }
        set { UserDefaults.standard.set(newValue, forKey: "showAtNotch") }
    }

    /// The notch on this screen in screen coordinates, or a notch-sized spot at the top centre of a
    /// screen without one.
    @MainActor
    static func rect(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let height = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The side areas are in screen coordinates on some systems and screen-relative on others.
            let offset = abs(left.minX - frame.minX) < 1 ? 0 : frame.minX
            return NSRect(x: left.maxX + offset, y: frame.maxY - height, width: right.minX - left.maxX, height: height)
        }
        let width: CGFloat = 190
        return NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
    }

    /// The screen the mouse is on.
    @MainActor
    static var screenUnderMouse: NSScreen? {
        // NSMouseInRect, not contains: the mouse can sit on a screen's top edge (the menu bar),
        // which contains() leaves out.
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

/// The notch at rest: Shhh on standby. The same size as the active band, with a still ✦ on the
/// left and nothing moving. Always there in notch mode, just under the listening band and the
/// answer island, which cover it while they're up. The pill takes over while listening,
/// and the island while Claude works and when it's done.
@MainActor
final class RestingNotch {
    static var ear: CGFloat { RecordingPanel.ear }
    private let model = RestingModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show() {
        hideWork?.cancel()
        guard panel?.isVisible != true else { return }
        // The built-in display's notch (or the top centre of the main screen).
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let notch = Notch.rect(on: screen)
        // A new window each time: a reused one can stay hidden behind a full-screen app.
        panel?.orderOut(nil)
        let panel = NotchPanel(contentRect: NSRect(x: notch.minX - Self.ear, y: notch.minY,
                                                width: notch.width + 2 * Self.ear, height: notch.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // the menu bar around it stays clickable
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: RestingView(model: model, notchWidth: notch.width))
        self.panel = panel
        place = panel.frame
        model.open = true // the bands swap in place: no growing out of the notch
        panel.orderFrontRegardless()
        NotchSpace.pin(panel)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Where it belongs: macOS has been seen moving it down the screen (while the assistant
    /// was working the Mac), so it's checked every second and put back.
    private var place: NSRect?

    func keepInPlace() {
        guard let panel, panel.isVisible, let place, panel.frame != place else { return }
        panel.setFrame(place, display: true)
    }

    /// Back in its place and in front (after Joe switches between a Dock and a menu-bar app),
    /// without making a new window: that flashed the bare notch.
    func reseat() {
        guard let panel, panel.isVisible, let place else { return show() }
        if panel.frame != place { panel.setFrame(place, display: true) }
        panel.orderFrontRegardless()
        NotchSpace.pin(panel)
    }
}

final class RestingModel: ObservableObject {
    @Published var open = false
}

private struct RestingView: View {
    @ObservedObject var model: RestingModel
    let notchWidth: CGFloat

    var body: some View {
        ZStack {
            NotchShape(top: NotchShape.shoulder, bottom: model.open ? 13 : 10)
                .fill(Color.black)
                .frame(width: model.open ? notchWidth + 2 * RestingNotch.ear : notchWidth)
            HStack(spacing: 0) {
                JoeMark()
                    .frame(width: RestingNotch.ear)
                Spacer()
            }
            .opacity(model.open ? 1 : 0)
            .animation(model.open ? .easeOut(duration: 0.14).delay(0.03) : .easeIn(duration: 0.08), value: model.open)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(model.open ? NotchShape.opening : NotchShape.closing, value: model.open)
    }
}

/// A short line from Joe that grows out of the notch band and tucks back in: the onboarding's
/// greetings. Same width as the band (wider for a longer line), centred on the notch, its own
/// window, so it never fights the answer card or shows the "done" tick.
@MainActor
final class NotchGreeting {
    private let model = GreetingModel()
    private var panel: NotchPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ line: String, for seconds: TimeInterval = 4) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let notch = Notch.rect(on: screen)
        let band = notch.width + 2 * RestingNotch.ear
        let width = max(band, min(520, CGFloat(line.count) * 8.2 + 72))
        let height = notch.height + 46
        let frame = NSRect(x: notch.midX - width / 2, y: notch.maxY - height, width: width, height: height)
        if panel == nil {
            let panel = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .aboveResting
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: GreetingView(model: model, notchHeight: notch.height, band: band))
            self.panel = panel
        }
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
        if let panel { NotchSpace.pin(panel) }
        model.line = line
        model.open = true
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        model.open = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { if self?.model.open == false { self?.panel?.orderOut(nil) } }
        }
    }
}

final class GreetingModel: ObservableObject {
    @Published var line = ""
    @Published var open = false
}

private struct GreetingView: View {
    @ObservedObject var model: GreetingModel
    let notchHeight: CGFloat
    let band: CGFloat

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Color.clear.frame(height: notchHeight)
                HStack(spacing: 9) {
                    JoeMark()
                    Text(model.line).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(model.open ? 1 : 0)
                .animation(model.open ? .easeOut(duration: 0.16).delay(0.05) : .easeIn(duration: 0.08), value: model.open)
            }
            .frame(width: model.open ? geometry.size.width : band, height: model.open ? geometry.size.height : notchHeight)
            .background(Color.black, in: NotchShape(top: NotchShape.shoulder, bottom: model.open ? 20 : 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(model.open ? NotchShape.opening : NotchShape.closing, value: model.open)
        }
    }
}

/// The notch's own outline, like the iPhone's: a body with rounded bottom corners, and at the top
/// two small inward curves ("shoulders") where it meets the edge of the screen, so it reads as
/// part of the bezel rather than a box hung under it. Both radii animate.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    /// The shoulders' size, the same on every band so they line up as one swaps for another.
    static let shoulder: CGFloat = 10
    /// One motion for everything that comes out of the notch, like the Dynamic Island: a spring
    /// with a little give opening, a firmer, quicker one going back in.
    static let opening = Animation.spring(response: 0.28, dampingFraction: 0.8)
    static let closing = Animation.spring(response: 0.2, dampingFraction: 0.95)
    /// Following content as it grows (an answer streaming in): the same spring, settling sooner.
    static let growing = Animation.spring(response: 0.24, dampingFraction: 0.85)

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(top, rect.width / 4, rect.height / 2)
        let bottom = min(bottom, (rect.width - 2 * top) / 2, max(0, rect.height - top))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left shoulder: from the screen edge, curving down into the body.
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // Right shoulder, back up to the screen edge.
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Joe's logo, the four-pointed orange star from the app icon, drawn so it stays crisp at any
/// size: points with softly pinched sides, a warm gradient and a faint glow. Used at the notch in
/// place of the system ✦.
struct JoeMark: View {
    var size: CGFloat = 14

    var body: some View {
        JoeStar()
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.28), Color(red: 1, green: 0.52, blue: 0.06)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .shadow(color: Color.orange.opacity(0.55), radius: size * 0.22)
    }
}

/// The star's outline: four points joined by curves pulled in toward the middle.
struct JoeStar: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let pinch = min(rect.width, rect.height) * 0.1 // how far the sides are pulled in
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: c.y), control: CGPoint(x: c.x + pinch, y: c.y - pinch))
        path.addQuadCurve(to: CGPoint(x: c.x, y: rect.maxY), control: CGPoint(x: c.x + pinch, y: c.y + pinch))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: c.y), control: CGPoint(x: c.x - pinch, y: c.y + pinch))
        path.addQuadCurve(to: CGPoint(x: c.x, y: rect.minY), control: CGPoint(x: c.x - pinch, y: c.y - pinch))
        path.closeSubpath()
        return path
    }
}
