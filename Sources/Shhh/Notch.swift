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
            UnevenRoundedRectangle(bottomLeadingRadius: model.open ? 13 : 10, bottomTrailingRadius: model.open ? 13 : 10,
                                   style: .continuous)
                .fill(Color.black)
                .frame(width: model.open ? notchWidth + 2 * RestingNotch.ear : notchWidth)
            HStack(spacing: 0) {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: RestingNotch.ear)
                Spacer()
            }
            .opacity(model.open ? 1 : 0)
            .animation(model.open ? .easeOut(duration: 0.2).delay(0.08) : .easeIn(duration: 0.12), value: model.open)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(model.open ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.46) : .timingCurve(0.5, 0, 0.75, 0, duration: 0.22),
                   value: model.open)
    }
}
