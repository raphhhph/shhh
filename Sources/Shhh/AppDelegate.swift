import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

/// Owns the menu-bar item and runs the dictation flow:
/// hold right ⌘ → record → transcribe → (cleanup) → writing style → paste.
/// Holding right ⌥ instead asks the Claude assistant, which replies (and asks before acting) in a
/// card. While the card is open, right ⌥ follows up in the same conversation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private var transcriber = Transcriber()
    private let cleaner = TextCleaner()
    private let panel = RecordingPanel()
    private let assistant = Assistant()
    private let answerPanel = AnswerPanel()

    private var statusItem: NSStatusItem!
    private var state: State = .idle {
        didSet { stayAwake(state != .idle) }
    }
    private var activity: NSObjectProtocol?
    private var pressedAt = Date()
    /// Which key started the current recording: right ⌘ dictates, right ⌥ asks Claude.
    private var key = HotkeyMonitor.Key.rightCommand
    /// Whether the current right ⌥ recording continues the open conversation.
    private var followingUp = false
    private var showPanelWork: DispatchWorkItem?
    private var startTask: Task<AudioRecorder.Recording?, Never>?
    /// Bumped on every press, so a late result from an earlier dictation can't touch this one.
    private var dictation = 0

    // Last known microphones, for the menu. Read off the main thread (see refreshMicrophones).
    private var microphones = AudioDevices.Snapshot.empty
    private var deviceQueue = DispatchQueue(label: "shhh.devices")
    private var deviceQueryStarted: Date?
    private var lastTranscript: String?

    private var speechReady = false
    private var speechLoading = false
    private var speechStatus = "Loading speech model…"
    private var cleanupStatus: String?

    private enum State { case idle, recording, processing }

    // MARK: - Settings

    private var aiCleanup: Bool {
        get { UserDefaults.standard.bool(forKey: "aiCleanup") }
        set { UserDefaults.standard.set(newValue, forKey: "aiCleanup") }
    }

    private var writingStyle: WritingStyle {
        get { WritingStyle(rawValue: UserDefaults.standard.string(forKey: "writingStyle") ?? "") ?? .casual }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "writingStyle") }
    }

    /// The microphone the user picked, or nil for Automatic.
    private var microphoneUID: String? {
        get { UserDefaults.standard.string(forKey: "microphoneUID") }
        set { UserDefaults.standard.set(newValue, forKey: "microphoneUID") }
    }

    private var askDepth: Assistant.Depth {
        get { Assistant.Depth(rawValue: UserDefaults.standard.string(forKey: "askDepth") ?? "") ?? .quick }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "askDepth") }
    }

    // MARK: - Launch and quit

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Shhh")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        hotkey.onPress = { [weak self] in self?.startRecording($0) }
        hotkey.onRelease = { [weak self] _ in self?.finishRecording() }
        hotkey.onCancel = { [weak self] _ in self?.cancelRecording() }
        answerPanel.onClose = { [weak self] in
            self?.assistant.cancel()
            self?.answerPanel.hide()
        }
        recorder.onLevel = { [panel] in panel.push(level: $0) }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        watchAccessibility()
        refreshMicrophones(wait: 0)
        loadSpeechModel()
        if aiCleanup { loadCleanupModel() }
    }

    /// Opening Shhh again (from Spotlight or Applications) shows its menu at the mouse, since
    /// the menu-bar icon can end up hidden behind the notch when the menu bar is crowded.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let menu = statusItem.menu else { return false }
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // llama.cpp must release its GPU resources before the process exits. If the model is
        // stuck mid-cleanup, quit anyway rather than hang.
        Task {
            _ = try? await withTimeout(2) { [cleaner] in await cleaner.unload() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Keyboard monitoring only works with the Accessibility permission. Keep checking: monitors
    /// stop receiving keys when it's withdrawn (or reset by macOS) and must be set up again once
    /// it's back, otherwise the key stays dead until a relaunch.
    private func watchAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options) // asks once, at launch
        syncHotkey()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncHotkey() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
    }

    private func syncHotkey() {
        if AXIsProcessTrusted() {
            hotkey.start()
        } else if hotkey.isRunning {
            hotkey.stop()
        }
    }

    /// Loads the speech model, retrying every 30 s if that fails (e.g. offline at login).
    private func loadSpeechModel() {
        guard !speechReady, !speechLoading else { return }
        speechLoading = true
        let transcriber = self.transcriber
        Task {
            do {
                try await transcriber.load { fraction in
                    Task { @MainActor in self.speechStatus = "Downloading speech model… \(Int(fraction * 100))%" }
                }
                guard transcriber === self.transcriber else { return } // replaced meanwhile
                speechLoading = false
                speechReady = true
                speechStatus = "Hold right ⌘ to dictate"
            } catch {
                guard transcriber === self.transcriber else { return }
                speechLoading = false
                speechStatus = "Speech model failed to load. Retrying…"
                try? await Task.sleep(for: .seconds(30))
                loadSpeechModel()
            }
        }
    }

    /// A transcription that never finished leaves the model stuck: start over with a fresh one.
    private func reloadSpeechModel() {
        transcriber = Transcriber()
        speechReady = false
        speechLoading = false
        speechStatus = "Loading speech model…"
        loadSpeechModel()
    }

    private func loadCleanupModel() {
        cleanupStatus = TextCleaner.isDownloaded ? "loading…" : "downloading…"
        Task {
            do {
                try await cleaner.load { fraction in
                    Task { @MainActor in
                        guard self.cleanupStatus != nil else { return }
                        self.cleanupStatus = "downloading \(Int(fraction * 100))%"
                    }
                }
                cleanupStatus = nil
                // Turned off while it was loading: free the memory again.
                if !aiCleanup { await cleaner.unload() }
            } catch {
                cleanupStatus = aiCleanup ? "failed to load" : nil
            }
        }
    }

    // MARK: - Dictation

    private func startRecording(_ key: HotkeyMonitor.Key) {
        guard state == .idle else { return }
        guard speechReady, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            loadSpeechModel() // retry now if an earlier load failed
            NSSound.beep() // the menu explains what's missing
            return
        }
        state = .recording
        self.key = key
        pressedAt = Date()
        dictation += 1
        let current = dictation
        followingUp = key == .rightOption && answerPanel.isVisible && assistant.isActive
        if key == .rightOption, !followingUp {
            // Start Claude Code now: it warms up while the user is still talking.
            answerPanel.reset()
            assistant.prepare(depth: askDepth) { [weak self] in self?.answerPanel.update($0) }
        }

        // The microphone starts on a background queue so the app never freezes on Core Audio.
        let preferredUID = microphoneUID
        startTask = Task {
            do {
                return try await recorder.start(preferredUID: preferredUID)
            } catch {
                NSSound.beep() // no microphone, or the audio system didn't respond
                if state == .recording, dictation == current {
                    showPanelWork?.cancel()
                    panel.hide()
                    dropNewConversation()
                    state = .idle
                }
                return nil
            }
        }
        // Show the pill only for a real hold, not a quick tap of ⌘.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording else { return }
                self.panel.showRecording()
            }
        }
        showPanelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// A right ⌥ recording that went nowhere: stop the conversation it started. A failed
    /// follow-up leaves the open one alone.
    private func dropNewConversation() {
        guard key == .rightOption, !followingUp else { return }
        assistant.cancel()
        answerPanel.hide()
    }

    /// Shhh sits idle with no windows, so macOS puts it in App Nap and lets its timers run late.
    /// The pill waits on a 0.15 s timer: delayed past the release, only the text would show up.
    /// Opting out while dictating keeps timers and the pill's fade on time.
    private func stayAwake(_ awake: Bool) {
        if awake, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Dictating")
        } else if !awake, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        showPanelWork?.cancel()
        panel.hide()
        dropNewConversation()
        state = .idle
        let start = startTask
        Task { if let recording = await start?.value { recorder.cancel(recording) } }
    }

    private func finishRecording() {
        guard state == .recording else { return }
        showPanelWork?.cancel()
        let heldFor = Date().timeIntervalSince(pressedAt)

        guard heldFor >= 0.3 else {
            cancelRecording()
            return
        }

        state = .processing
        panel.showProcessing()
        let asking = key == .rightOption
        let followingUp = self.followingUp
        let useCleanup = aiCleanup && !asking // Claude copes with "um"s and corrections itself
        let style = writingStyle
        let start = startTask
        let transcriber = self.transcriber

        Task {
            var asked = false
            defer {
                panel.hide()
                state = .idle
                if asking, !asked, !followingUp { dropNewConversation() }
            }
            guard let recording = await start?.value else { return } // already beeped
            let samples = await recorder.stop(recording, covering: heldFor)
            guard samples.count >= 16_000 / 4 else {
                NSSound.beep() // the microphone sent no audio
                return
            }

            var text: String
            do {
                // Normally well under a second. Far longer means the model is stuck.
                let seconds = Double(samples.count) / 16_000
                text = try await withTimeout(15 + seconds) { try await transcriber.transcribe(samples) }
            } catch {
                NSSound.beep()
                if error is WatchdogError, transcriber === self.transcriber { reloadSpeechModel() }
                return
            }
            if useCleanup, !text.isEmpty {
                let raw = text
                let deadline = Date().addingTimeInterval(5)
                text = (try? await withTimeout(6) { [cleaner] in
                    await cleaner.isReady ? await cleaner.clean(raw, deadline: deadline) : raw
                }) ?? TextCleaner.removeFillers(raw)
            }
            if asking {
                guard !text.isEmpty else { return }
                lastTranscript = text
                answerPanel.beginTurn(question: text)
                assistant.ask(text)
                asked = true
                return
            }
            text = style.apply(text)
            guard !text.isEmpty else { return }
            lastTranscript = text
            TextInserter.insert(text)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMicrophones(wait: 0.25)
        menu.removeAllItems()

        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility access…", #selector(openAccessibilitySettings)))
        } else if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            menu.addItem(item("Grant Microphone access…", #selector(openMicrophoneSettings)))
        } else {
            let noMicrophone = speechReady && microphones.pick(preferredUID: microphoneUID) == nil
            let title = if let blocker = Self.secureInputApp() {
                "\(blocker) is blocking the keyboard"
            } else if noMicrophone {
                "No microphone available"
            } else {
                speechStatus
            }
            let status = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        menu.addItem(.separator())

        menu.addItem(submenu("Writing style", items: WritingStyle.allCases.map { style in
            let item = item(style.title, #selector(selectWritingStyle(_:)))
            item.representedObject = style.rawValue
            item.state = style == writingStyle ? .on : .off
            return item
        }))
        menu.addItem(microphoneMenu())

        let cleanup = item(cleanupStatus.map { "AI cleanup (\($0))" } ?? "AI cleanup", #selector(toggleCleanup))
        cleanup.state = aiCleanup ? .on : .off
        menu.addItem(cleanup)

        menu.addItem(askMenu())

        let copy = item("Copy last transcript", #selector(copyLastTranscript))
        copy.isEnabled = lastTranscript != nil
        menu.addItem(copy)

        menu.addItem(.separator())
        let login = item("Launch at login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit Shhh", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    /// "Automatic (AirPods Pro)" followed by every connected microphone.
    private func microphoneMenu() -> NSMenuItem {
        let inputs = microphones.inputs
        let active = microphones.pick(preferredUID: microphoneUID)
        let chosenIsAvailable = inputs.contains { $0.uid == microphoneUID && microphones.isAvailable($0) }

        let automatic = item("Automatic (\(active?.name ?? "no microphone"))", #selector(selectMicrophone(_:)))
        automatic.state = chosenIsAvailable ? .off : .on

        var items = [automatic, .separator()]
        for input in inputs {
            let unavailable = !microphones.isAvailable(input)
            let item = item(unavailable ? "\(input.name) (lid closed)" : input.name, #selector(selectMicrophone(_:)))
            item.representedObject = input.uid
            item.isEnabled = !unavailable
            item.state = chosenIsAvailable && input.uid == microphoneUID ? .on : .off
            items.append(item)
        }
        return submenu("Microphone", items: items)
    }

    /// "Assistant": how to use it, how hard it should work, and the user's notes for it.
    private func askMenu() -> NSMenuItem {
        let hint = NSMenuItem(title: Assistant.executable == nil ? "Claude Code not found" : "Hold right ⌥ to ask or delegate",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        var items = [hint, .separator()]
        for depth in Assistant.Depth.allCases {
            let item = item(depth.title, #selector(selectAskDepth(_:)))
            item.representedObject = depth.rawValue
            item.state = depth == askDepth ? .on : .off
            items.append(item)
        }
        items.append(.separator())
        for autonomy in Assistant.Autonomy.allCases {
            let item = item(autonomy.title, #selector(selectAutonomy(_:)))
            item.representedObject = autonomy.rawValue
            item.state = autonomy == Assistant.autonomy ? .on : .off
            items.append(item)
        }
        items.append(.separator())
        items.append(item("Memory: \(Assistant.vaultURL?.lastPathComponent ?? "none")…", #selector(chooseMemoryVault)))
        items.append(item("Edit instructions…", #selector(editAssistantInstructions)))
        return submenu("Assistant", items: items)
    }

    /// Reads the microphone list on a background queue and waits at most `wait` for it, so a
    /// misbehaving audio device can never freeze the menu. Falls back to the last known list.
    private func refreshMicrophones(wait: TimeInterval) {
        if let started = deviceQueryStarted {
            guard Date().timeIntervalSince(started) > 5 else { return } // a read is already running
            deviceQueue = DispatchQueue(label: "shhh.devices") // that one is stuck: start over
        }
        deviceQueryStarted = Date()
        let result = SnapshotBox()
        let done = DispatchSemaphore(value: 0)
        deviceQueue.async {
            result.set(AudioDevices.snapshot())
            done.signal()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let snapshot = result.get() { self.microphones = snapshot }
                    self.deviceQueryStarted = nil
                }
            }
        }
        if done.wait(timeout: .now() + wait) == .success, let snapshot = result.get() {
            microphones = snapshot
        }
    }

    /// While an app has Secure Input on (a password field, some terminals and password managers),
    /// macOS hides keys from other apps and right ⌘ does nothing. Returns that app's name.
    private static func secureInputApp() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
        return pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "Another app"
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    // MARK: - Menu actions

    @objc private func selectWritingStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = WritingStyle(rawValue: raw) {
            writingStyle = style
        }
    }

    @objc private func selectAskDepth(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let depth = Assistant.Depth(rawValue: raw) {
            askDepth = depth
        }
    }

    @objc private func selectAutonomy(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let autonomy = Assistant.Autonomy(rawValue: raw) {
            Assistant.autonomy = autonomy
        }
    }

    @objc private func chooseMemoryVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Memory"
        panel.message = "Choose the notes vault (for example an Obsidian vault) the assistant keeps its memory in."
        panel.directoryURL = Assistant.vaultURL
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            Assistant.vaultURL = url
        }
    }

    @objc private func editAssistantInstructions() {
        Assistant.openInstructions()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        microphoneUID = sender.representedObject as? String
    }

    @objc private func toggleCleanup() {
        aiCleanup.toggle()
        if aiCleanup {
            loadCleanupModel()
        } else {
            cleanupStatus = nil
            Task { await cleaner.unload() } // free the memory while it's off
        }
    }

    @objc private func copyLastTranscript() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

/// Hands a snapshot from the device queue to the main thread.
private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AudioDevices.Snapshot?

    func set(_ snapshot: AudioDevices.Snapshot) { lock.lock(); value = snapshot; lock.unlock() }
    func get() -> AudioDevices.Snapshot? { lock.lock(); defer { lock.unlock() }; return value }
}
