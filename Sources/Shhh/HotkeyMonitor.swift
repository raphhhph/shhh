import AppKit

/// Watches the right Command and right Option keys globally.
///
/// Holding one of them alone fires `onPress`, letting go fires `onRelease`.
/// If another key is pressed while it's held (a normal shortcut like ⌘C),
/// `onCancel` fires instead and the release is ignored.
@MainActor
final class HotkeyMonitor {
    enum Key {
        case rightCommand, rightOption

        fileprivate var keyCode: UInt16 {
            switch self {
            case .rightCommand: 54
            case .rightOption: 61
            }
        }

        fileprivate var deviceMask: UInt {
            switch self {
            case .rightCommand: 0x10 // NX_DEVICERCMDKEYMASK
            case .rightOption: 0x40 // NX_DEVICERALTKEYMASK
            }
        }

        fileprivate var modifier: NSEvent.ModifierFlags {
            switch self {
            case .rightCommand: .command
            case .rightOption: .option
            }
        }
    }

    var onPress: (Key) -> Void = { _ in }
    var onRelease: (Key) -> Void = { _ in }
    var onCancel: (Key) -> Void = { _ in }

    private var monitors: [Any] = []
    /// The key being held, if any.
    private var held: Key?
    private var cancelled = false
    private var releaseCheck: Timer?

    var isRunning: Bool { !monitors.isEmpty }

    /// Needs the Accessibility permission to see keys pressed in other apps.
    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Removes the monitors, e.g. when the Accessibility permission is withdrawn: they stop
    /// receiving keys and have to be set up again once it's back.
    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let held, !cancelled {
            cancelled = true
            onCancel(held)
        }
        release()
    }

    private func handle(_ event: NSEvent) {
        let key = [Key.rightCommand, .rightOption].first { $0.keyCode == event.keyCode }
        switch event.type {
        case .flagsChanged where key != nil && (held == nil || held == key):
            let key = key!
            let down = event.modifierFlags.rawValue & key.deviceMask != 0
            if down, held == nil {
                held = key
                cancelled = false
                watchForMissedRelease(of: key)
                onPress(key)
            } else if !down {
                release()
            }
        case .flagsChanged, .keyDown:
            // Any other key while one is held means the user is doing a shortcut.
            if let held, !cancelled {
                cancelled = true
                onCancel(held)
            }
        default:
            break
        }
    }

    private func release() {
        releaseCheck?.invalidate()
        releaseCheck = nil
        guard let key = held else { return }
        held = nil
        if !cancelled { onRelease(key) }
    }

    /// The release event can go missing (the Mac sleeping mid-hold, the keyboard grabbed by
    /// another app). Without this the microphone would stay on and the next press be ignored.
    private func watchForMissedRelease(of key: Key) {
        releaseCheck?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if !NSEvent.modifierFlags.contains(key.modifier) { self?.release() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseCheck = timer
    }
}
