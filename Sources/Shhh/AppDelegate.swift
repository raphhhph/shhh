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
    private let answerPanel = AnswerPanel()
    private let pointer = ScreenPointer()
    private let speech = SpeechOutput()
    private let toast = Toast()
    private let shelf = TaskShelf()
    private let notepad = Notepad()
    private let noteSaver = NoteSaver()
    private let alarms = AlarmClock()
    private let phone = PhoneRemote()
    private let wake = WakeWord()
    private let endListener = EndListener()
    /// Recording because of "Hey Joe": it ends by itself when they stop talking.
    private var handsFree = false
    private var heardSpeech = false
    private var quietSince: Date?
    /// Double-tapped: recording without holding the key, through pauses, until the key is tapped
    /// again (or five minutes pass). For long requests, where a held key slips.
    private var locked = false
    private var lockTimeout: DispatchWorkItem?
    /// The last quick tap of a key, to spot a double tap.
    private var lastTap: (key: HotkeyMonitor.Key, at: Date)?
    /// This recording came from "Hey Joe": cut down to their voice before it's transcribed.
    private var handsFreeTake = false
    /// With a voiceprint: when their own voice was last heard (checked every ¾ s).
    private var voiceprintReady = false
    private var lastOwnVoice: Date?
    private var voiceCheckAt = Date.distantPast
    private var checkingVoice = false
    /// The first-launch tour (and its replay from Settings).
    private lazy var onboarding: Onboarding = Onboarding(actions: Onboarding.Actions(
        greet: { [weak self] subject, line in self?.greetAtNotch(subject, line) },
        narrate: { [weak self] subject, line in
            guard let self, self.state == .idle else { return }
            self.speech.stop()
            guard !line.isEmpty else { self.greeting.hide(); return }
            // Shown at the notch for about as long as it takes to say.
            self.greeting.show(subject, for: max(4, Double(line.split(separator: " ").count) / 2.6 + 1.5))
            self.speech.useForThisReply(.lifelike)
            self.speech.update(line)
            self.speech.finish()
        },
        isSpeaking: { [weak self] in self?.speech.isSpeaking ?? false },
        prepareVoice: { [weak self] in if SpeechOutput.engine == .off { self?.speech.prepareForTour() } },
        download: { [weak self] model in
            guard let self else { return }
            switch model {
            case .speech, .chinese: if ModelGuard.status(model) == .ready { return }; self.speechReady ? self.reloadSpeechModel() : self.loadSpeechModel()
            case .voice: self.speech.prepareForTour()
            case .mandarin: self.speech.prepareMandarin()
            }
        },
        chooseVault: { [weak self] in self?.chooseMemoryVault() },
        finished: { [weak self] in
            Profile.isSetUp = true
            self?.onboarding.close()
            self?.dashboard.show()
        }))

    private let greeting = NotchGreeting()
    private let studyBoard = StudyBoard()
    private lazy var overview = NotchOverview(data: dashboard.model)
    private let pen = ScreenPen()

    /// Silence while Claude works feels like nothing's happening: after 2.5 s with no answer yet, Joe
    /// says what he's doing ("Checking your calendar.") or just "One sec.", once.
    private func acknowledgeIfSlow(_ task: AssistantTask) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, task === self.focused, task.reply.isEmpty, !task.isDone, !task.background,
                      SpeechOutput.engine != .off, !self.speech.isSpeaking, self.state == .idle else { return }
                let status = (task.status ?? "").replacingOccurrences(of: "…", with: "")
                let line = status.range(of: #"^(Checking|Reading|Searching|Looking|Opening|Finding)\b"#, options: .regularExpression) != nil
                    ? status + "." : "One sec."
                self.speech.update(line)
                self.speech.finish()
            }
        }
    }

    /// macOS keeps a compiled copy of each Neural Engine model per build of Joe, and never clears the
    /// old ones (1.8 GB after a day of updates). Anything compiled before this build was installed
    /// belongs to an old build and goes; this build's own copies are made after it was installed.
    nonisolated private static func pruneModelCache() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundle = Bundle.main.bundleIdentifier else { return }
        let root = caches.appendingPathComponent(bundle).appendingPathComponent("com.apple.e5rt.e5bundlecache")
        let installed = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } ?? .distantPast
        let cutoff = installed.addingTimeInterval(-60)
        let keys: [URLResourceKey] = [.contentAccessDateKey, .contentModificationDateKey]
        for version in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for entry in (try? FileManager.default.contentsOfDirectory(at: version, includingPropertiesForKeys: keys)) ?? [] {
                let values = try? entry.resourceValues(forKeys: Set(keys))
                if (values?.contentModificationDate ?? .distantPast) < cutoff { try? FileManager.default.removeItem(at: entry) }
            }
        }
    }

    /// "Let me draw on the screen", "annotate my screen", "pen": the drawing overlay.
    private func openPen(_ request: String) -> Bool {
        guard request.range(of: #"\b(draw|drawing|annotate|scribble|pen)\b[^.?!]{0,30}\b(screen|this|it)\b|^\W*(screen )?pen\W*$|^\W*(let me )?(draw|annotate)\W*$"#,
                            options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        pen.show()
        return true
    }

    /// "Quiz me on econ externalities", "test me on…": the study whiteboard, not the notch.
    private func openStudy(_ request: String) -> Bool {
        // "Quiz me on…", "let's start a quiz", "study session", "open (up) the whiteboard"…
        let quiz = #"^\W*((hey|ok|okay|yo),?\s+)?(joe,?\s+)?(can you\s+)?(quiz|test) me\b|give me (a|an|one) (full )?exam(-style)? question|\b(start|do|begin|run)\b[^.?!]{0,12}\b(quiz|study session|revision session|practice session)\b|\b(open|pull|bring|start|show|get)\b[^.?!]{0,15}\bwhite ?board\b|^\W*(the )?white ?board\W*$"#
        guard request.range(of: quiz, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        // The subject: said now, or in the conversation on the card ("let's start a quiz on econ",
        // then "open the whiteboard"), or the one studied last.
        let context = [request, focused?.question ?? ""] + tasks.suffix(3).map(\.question)
        let subject = context.lazy.compactMap { StudyBoard.subject(in: $0) }.first
            ?? UserDefaults.standard.string(forKey: "lastStudySubject")
            ?? Profile.subjects.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "Economics"
        if let task = focused, task.question.isEmpty || task.question.range(of: "quiz|whiteboard", options: [.regularExpression, .caseInsensitive]) != nil {
            end(task) // the quiz moves to the whiteboard
        }
        let exam = request.range(of: "exam", options: .caseInsensitive) != nil
        studyBoard.show(subject: subject, request: request, mode: exam ? .exam : .quiz)
        return true
    }

    /// A study request done here, without Claude ("start my Econ IA", "plan my week", "done with
    /// Paper 2", "how's my EE going"): its one-line answer on the card, read aloud when the voice is on.
    private func showLocalAnswer(_ reply: StudyLoop.Reply, question: String, in task: AssistantTask) {
        task.beginTurn(question)
        answerPanel.beginTurn(question: question)
        task.reply = "Subject: \(reply.subject)\n\(reply.card)"
        task.isDone = true
        task.doneAt = Date()
        task.canFollowUp = true
        answerPanel.setSubject(reply.subject)
        answerPanel.update(.answer(reply.card))
        answerPanel.update(.turnFinished)
        Daybook.log(question: question, reply: task.reply)
        ActivityLog.record(.ask, question, answer: reply.subject, reply: reply.card)
        if SpeechOutput.engine != .off, !reply.spoken.isEmpty {
            speech.update(reply.spoken)
            speech.finish()
        }
        refreshShelf()
    }

    /// Sunday evening's week plan was just written: on the card when Joe's free (read aloud when
    /// the voice is on, with its first clash question), else a toast. Its questions stay in Week.md.
    private func announceWeekPlan(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let reply = StudyLoop.weekReply(text, sunday: true)
        guard state == .idle, !answerPanel.isVisible, !alarms.isRinging, !studyBoard.isTakingAnswers else {
            toast.show(reply.subject + ": open Week.md", symbol: "calendar", tint: .orange)
            return
        }
        let task = newTask()
        focused = task
        answerPanel.reset()
        showLocalAnswer(reply, question: "Next week's plan", in: task)
        answerPanel.holdOpen(for: 10)
    }

    /// Joe at the notch, saying a line out loud: for the tour, with no conversation behind it.
    private func greetAtNotch(_ subject: String, _ line: String) {
        guard state == .idle else { return }
        greeting.show(subject)
        if SpeechOutput.engine == .off { speech.useForThisReply(.lifelike) }
        speech.update(line)
        speech.finish()
    }

    private lazy var dashboard: Dashboard = Dashboard(actions: DashboardModel.Actions(
        ask: { [weak self] in self?.askTyped($0) },
        askInBackground: { [weak self] in self?.startInBackground($0) },
        status: { [weak self] in self?.speechStatus ?? "" },
        setVoice: { [weak self] engine in
            self?.speech.stop()
            SpeechOutput.engine = engine
            self?.speech.prepare()
        },
        setNotch: { [weak self] on in
            Notch.isEnabled = on
            self?.refreshResting()
        },
        setCleanup: { [weak self] on in if self?.aiCleanup != on { self?.toggleCleanup() } },
        setScreenControl: { [weak self] on in if ScreenControl.isEnabled != on { self?.toggleScreenControl() } },
        chooseVault: { [weak self] in self?.chooseMemoryVault() },
        showOnboarding: { [weak self] in self?.onboarding.show() },
        openNotepad: { [weak self] in self?.notepad.show() },
        microphones: { [weak self] in self?.microphones.inputs.map { ($0.uid, $0.name) } ?? [] },
        setSpeechLanguages: { [weak self] raw in
            guard let languages = Transcriber.Languages(rawValue: raw), Transcriber.languages != languages else { return }
            Transcriber.languages = languages
            self?.reloadSpeechModel() // downloads the other model the first time
        },
        cancelAlarm: { [weak self] id in self?.alarms.cancel(id: id) },
        addAlarm: { [weak self] request in self?.alarms.handle(request) }
    ))
    private let resting = RestingNotch()
    /// Every conversation with the assistant: the one on the card (`focused`) and the ones carrying
    /// on in the side notch.
    private var tasks: [AssistantTask] = []
    private var focused: AssistantTask?
    /// The morning briefing's conversation, held open for a moment when it's ready.
    private var briefing: AssistantTask?

    private var statusItem: NSStatusItem!
    private var state: State = .idle {
        didSet {
            stayAwake(state != .idle)
            refreshResting()
        }
    }
    private var activity: NSObjectProtocol?
    private var pressedAt = Date()
    /// Which key started the current recording: right ⌘ dictates, right ⌥ asks Claude.
    private var key = HotkeyMonitor.Key.rightCommand
    /// Whether the current right ⌥ recording continues the open conversation.
    private var followingUp = false
    private var showPanelWork: DispatchWorkItem?
    private var startTask: Task<AudioRecorder.Recording?, Never>?
    /// Live words while a key is held (Settings → Live words).
    private let caption = LiveCaption()
    private var liveTimer: Timer?
    private var livePartial = false
    /// The screen when right ⌥ went down, in case the request turns out to be about it.
    private var screenTask: Task<ScreenCapture.Screenshot?, Never>?
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


    // MARK: - Launch and quit

    func applicationDidFinishLaunching(_ notification: Notification) {
        ModelDownloads.apply() // Hugging Face or the China mirror, before any model loads
        // Stopped while a model was downloading or loading last time: an unfinished download carries
        // on, a broken one starts over (ModelGuard decides).
        if let broken = ModelGuard.recoverFromCrash() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.toast.show("\(broken.title) didn't finish last time, so it's downloading again", symbol: "arrow.down.circle", tint: .orange) }
            }
        }
        AppAppearance.apply() // light, dark or the Mac's
        phone.run = { [weak self] request, done in self?.startInBackground(request, onFinished: done) }
        wake.canListen = { [weak self] in
            guard let self else { return false }
            return self.state == .idle && !self.speech.isSpeaking && !self.notepad.isListening && !self.alarms.isRinging
        }
        wake.onWake = { [weak self] in self?.startHandsFree() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Joe")
        // Click: the dashboard. Right-click (or ⌃-click): the quick menu.
        quickMenu.autoenablesItems = false
        quickMenu.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        NSApp.mainMenu = Self.mainMenu(target: self)
        // First, before the models and the rest load: the tour on a first launch, else the dashboard.
        if !Profile.isSetUp { onboarding.show() } else if !launchedAtLogin { dashboard.show() }
        dashboard.onModeChange = { [weak self] in if Notch.isEnabled { self?.resting.reseat() } }
        // Opened by the person (Finder, Spotlight, the Dock): the dashboard. At login: quietly.

        hotkey.onPress = { [weak self] in self?.startRecording($0) }
        hotkey.onRelease = { [weak self] _ in self?.finishRecording() }
        hotkey.onCancel = { [weak self] _ in self?.cancelRecording() }
        answerPanel.onClose = { [weak self] in self?.closeCard() }
        answerPanel.onStopSpeaking = { [weak self] in
            self?.speech.stop()
            self?.answerPanel.setSpeaking(false)
        }
        watchForMorning()
        alarms.onNotice = { [weak self] text in self?.toast.show(text, symbol: "alarm.fill", tint: .orange) }
        studyBoard.speak = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.speech.stop()
            if SpeechOutput.engine == .off { self.speech.useForThisReply(.lifelike) }
            self.speech.update(text)
            self.speech.finish()
        }
        studyBoard.stopSpeaking = { [weak self] in self?.speech.stop() }
        pen.ask = { [weak self] request, screenshot in self?.askTyped(request, screenshot: screenshot) }
        alarms.onChange = { [weak self] in self?.refreshShelf() }
        // The wake-up challenge done: straight into the morning briefing.
        alarms.onWokeUp = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated { self?.greetIfMorning(afterAlarm: true) }
            }
        }
        // A focus session over: Joe asks what got done, to tick it off.
        alarms.onStopped = { [weak self] alarm in
            guard alarm.title.hasPrefix("Focus"), Assistant.vaultURL != nil else { return }
            self?.startInBackground("[Focus session over: \(alarm.title).] In one or two short lines: well done, and ask me what I finished so you can tick it in my Daybook.")
        }
        // Memory: the voices go after ten quiet minutes; compiled models from old builds after a week.
        let trim = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.speech.trimMemory() } }
        RunLoop.main.add(trim, forMode: .common)
        Task.detached(priority: .background) { Self.pruneModelCache() }
        // The notch overview: rest the pointer on the notch while Joe's idle.
        overview.runningTasks = { [weak self] in self?.tasks.filter(\.isWorking).map(\.question) ?? [] }
        overview.canShow = { [weak self] in
            guard let self else { return false }
            return self.state == .idle && !self.answerPanel.isVisible && !self.alarms.isRinging && !self.pen.isOpen
        }
        overview.start()
        // ManageBac and Google calendar links: read at launch and every half hour.
        Task { await CalendarFeed.refreshLinks() }
        let calendarLinks = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in
            Task {
                await CalendarFeed.refreshLinks()
                // Next week's plan, once, on Sunday evening: Joe says so, with its clash questions.
                if let week = WeekPlan.buildIfSundayEvening() {
                    await MainActor.run { self?.announceWeekPlan(week) }
                }
            }
        }
        RunLoop.main.add(calendarLinks, forMode: .common)
        let alarmTicks = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.alarms.tick()
                self?.moveLongTaskAside()
                self?.phone.check()
                if let self { self.answerPanel.setSpeaking(self.speech.isSpeaking) } // the card's stop button
                self?.wake.update()
                self?.resumeMusicIfDone()
                self?.resting.keepInPlace() // the notch band stays at the notch
                self?.unstickProcessing()
            }
        }
        RunLoop.main.add(alarmTicks, forMode: .common)
        let clearing = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearOldTasks()
                self?.shutDownIfNight()
                self?.eveningCheckIfTime()
            }
        }
        RunLoop.main.add(clearing, forMode: .common)
        notepad.show(kind: noteSaver.kind)
        notepad.onHidden = { [weak self] in self?.saveNotes() }
        notepad.onCleared = { [weak self] in
            // Cleared after it was saved: what comes next is a new note, not a change to that one.
            guard let self, self.noteSaver.isSaved else { return }
            self.noteSaver.begin(nil)
            self.notepad.show(kind: nil)
        }
        notepad.onKind = { [weak self] kind in self?.noteSaver.kind = kind }
        // A lecture or meeting note, once saved: Joe adds a summary, key terms and recall questions.
        noteSaver.onTitled = { [weak self] url, kind, body in
            guard kind != .notes, body.split(whereSeparator: \.isWhitespace).count >= 120 else { return }
            self?.startInBackground("""
                [My \(kind == .lecture ? "lecture" : "meeting") notes were just saved: \(url.path).] Structure that note, keeping \
                every word of my notes: under the title add ## Summary (3–5 bullets), ## Key terms (term: one-line \
                meaning), \(kind == .lecture ? "## Recall questions (5, for revising)" : "## Actions (who does what, by when)"), then \
                ## Notes with my original notes unchanged. Fix obvious speech-recognition mistakes in the summary only. \
                Lines start with who said them ("You:", "Speaker 1:"): keep that, and where it's clear who a speaker is \
                (the teacher, a named classmate), say so in the summary. \
                \(kind == .meeting ? "Add the actions that are mine to my Daybook. " : "")Reply in one line.
                """)
        }
        notepad.listen = { [weak self] in
            guard let self, self.speechReady else { return nil }
            return (self.recorder, self.transcriber, self.microphoneUID)
        }
        shelf.onOpen = { [weak self] id in
            guard let self, let task = self.tasks.first(where: { $0.id == id }) else { return }
            self.focus(task)
        }
        shelf.onStop = { [weak self] id in
            guard let self else { return }
            if self.alarms.pending.contains(where: { $0.id == id }) { self.alarms.cancel(id: id); return }
            guard let task = self.tasks.first(where: { $0.id == id }) else { return }
            self.end(task)
        }
        recorder.onLevel = { [panel, weak self] level in
            panel.push(level: level)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handsFreeLevel(level) } }
        }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        watchAccessibility()
        refreshMicrophones(wait: 0)
        loadSpeechModel()
        if aiCleanup { loadCleanupModel() }
        refreshResting()
    }

    /// Opening Joe again (from Spotlight, Applications or the Dock) shows the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dashboard.show()
        return false
    }

    private let quickMenu = NSMenu()
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // Opened by the person: a proper app (Dock icon, "Joe" at the top left) from the first
        // moment, not once everything else has loaded.
        if !launchedAtLogin { NSApp.setActivationPolicy(.regular) }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = quickMenu
            statusItem.button?.performClick(nil) // shows the menu
            statusItem.menu = nil
        } else {
            dashboard.show()
        }
    }

    @objc private func openDashboard() {
        dashboard.show()
    }

    @objc private func openSettings() {
        dashboard.show(.settings)
    }

    /// Joe's own menu bar, shown while the dashboard is in front: "Joe" at the top left, and the
    /// Edit menu that gives text boxes ⌘A, ⌘C, ⌘V and ⌘Z.
    private static func mainMenu(target: AppDelegate) -> NSMenu {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            holder.submenu = submenu
            bar.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, to: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = to
            return item
        }
        menu("Joe", [
            item("About Joe", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", to: NSApp),
            .separator(),
            item("Settings…", #selector(openSettings), ",", to: target),
            .separator(),
            item("Hide Joe", #selector(NSApplication.hide(_:)), "h", to: NSApp),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], to: NSApp),
            .separator(),
            item("Quit Joe", #selector(NSApplication.terminate(_:)), "q", to: NSApp),
        ])
        // No target: these go to whatever text box has focus.
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            item("Joe", #selector(openDashboard), "0", to: target),
        ])
        return bar
    }

    /// A request typed in the dashboard: like one said with right ⌥ (alarms and music at once,
    /// anything else to Joe, with its card at the notch).
    private func askTyped(_ text: String, screenshot: Data? = nil) {
        if let request = AlarmRequest.parse(text) { alarms.handle(request); return }
        if openStudy(text) { return }
        if screenshot == nil, openPen(text) { return }
        if screenshot == nil, let intent = StudyIntent.parse(text), let reply = intent.run() {
            if let current = focused { sendToBackground(current) }
            let task = newTask()
            focused = task
            answerPanel.reset()
            showLocalAnswer(reply, question: text, in: task)
            return
        }
        if let music = Spotify.command(in: text) {
            Task.detached { [weak self] in
                let result = Spotify.run(music)
                await MainActor.run { self?.toast.show(result, symbol: "music.note", tint: .green) }
            }
            return
        }
        if let current = focused { sendToBackground(current) }
        let task = newTask()
        focused = task
        answerPanel.reset()
        task.beginTurn(text)
        answerPanel.beginTurn(question: text)
        if Assistant.needsStrongModel(text) { task.assistant.useStrongModel() }
        if Self.wantsBackground(text) { task.background = true }
        task.assistant.ask(text, screenshot: screenshot)
    }

    /// "… in the background", "… while I do something else".
    private static func wantsBackground(_ text: String) -> Bool {
        text.range(of: #"\b(in the background|background task|while i (do|work on|use)|as a (side )?task)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
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
                    // Also reported while macOS prepares a model it already has (after an update).
                    Task { @MainActor in
                        self.speechStatus = fraction < 1 ? "Getting speech ready… \(Int(fraction * 100))%" : "Getting speech ready…"
                    }
                }
                guard transcriber === self.transcriber else { return } // replaced meanwhile
                speechLoading = false
                let first = !speechReady
                speechReady = true
                speechStatus = "Hold right ⌘ to dictate"
                // Then the rest, so the keys never wait behind them: the voice and the noise filter.
                if first {
                    speech.prepare()
                    Task.detached(priority: .utility) { await NoiseFilter.shared.prepare() }
                }
            } catch {
                guard transcriber === self.transcriber else { return }
                speechLoading = false
                speechStatus = "Speech model failed to load. Retrying…"
                try? await Task.sleep(for: .seconds(30))
                loadSpeechModel()
            }
        }
    }

    /// A transcription that never finished may have left the model stuck: a fresh one loads in the
    /// background and takes over when it's ready. The keys keep working meanwhile (a timeout is
    /// usually the Neural Engine busy with something else, and the next try works).
    private func reloadSpeechModel() {
        guard speechReady, !speechLoading else {
            transcriber = Transcriber()
            speechReady = false
            speechLoading = false
            speechStatus = "Getting speech ready…"
            loadSpeechModel()
            return
        }
        speechLoading = true
        let fresh = Transcriber()
        Task {
            if (try? await fresh.load { _ in }) != nil { transcriber = fresh }
            speechLoading = false
        }
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

    /// "Hey Joe": an Ask, as if right ⌥ were held.
    private func startHandsFree() {
        guard state == .idle else { return }
        startRecording(.rightOption)
        guard state == .recording else { return }
        handsFree = true
        handsFreeTake = true
        heardSpeech = false
        quietSince = nil
        lastOwnVoice = nil
        voiceprintReady = false
        Task { [weak self] in self?.voiceprintReady = await VoicePrint.shared.isReady }
        // Their words, as they say them: an end phrase or a pause in the words ends it.
        endListener.start { [weak self] in
            guard let self, self.handsFree, self.state == .recording else { return }
            self.handsFree = false
            self.finishRecording()
        }
        // The pill now, rather than after the usual hold delay.
        showPanelWork?.perform()
    }

    /// Ends a hands-free recording 1.3 seconds after they stop talking (or after 5 silent seconds,
    /// or 40 seconds in all).
    private func handsFreeLevel(_ level: Float) {
        guard handsFree, state == .recording else { return }
        let elapsed = Date().timeIntervalSince(pressedAt)
        if level > 0.15 {
            heardSpeech = true
            quietSince = nil
        } else if quietSince == nil {
            quietSince = Date()
        }
        let quiet = quietSince.map { Date().timeIntervalSince($0) } ?? 0
        if voiceprintReady {
            // Their voice, checked every ¾ s: other people talking around them don't keep it open.
            if !checkingVoice, Date().timeIntervalSince(voiceCheckAt) > 0.75, level > 0.05, let start = startTask {
                checkingVoice = true
                voiceCheckAt = Date()
                Task { [weak self] in
                    guard let recording = await start.value, let self else { self?.checkingVoice = false; return }
                    let tail = self.recorder.tail(recording, seconds: 1.5)
                    let own = await VoicePrint.shared.isOwnVoice(tail) ?? false
                    self.checkingVoice = false
                    if own { self.lastOwnVoice = Date() }
                }
            }
            if lastOwnVoice == nil, elapsed > 6 {
                handsFree = false
                cancelRecording() // never heard them: someone else said it, or they didn't go on
            } else if let last = lastOwnVoice, Date().timeIntervalSince(last) > 1.8 || quiet > 1.3 {
                handsFree = false
                finishRecording()
            } else if elapsed > 40 {
                handsFree = false
                finishRecording()
            }
            return
        }
        if !heardSpeech, elapsed > 5 {
            handsFree = false
            cancelRecording()
        } else if (heardSpeech && quiet > 1.3) || elapsed > 40 {
            handsFree = false
            finishRecording()
        }
    }

    private func startRecording(_ key: HotkeyMonitor.Key) {
        // Locked: a tap of the same key ends it and sends it.
        if locked, state == .recording {
            if key == self.key { unlock(); finishRecording() }
            return
        }
        guard state == .idle else { return }
        // A quick tap and then a press: lock it on (released keys are ignored until the next tap).
        let doubleTap = lastTap.map { $0.key == key && Date().timeIntervalSince($0.at) < 0.45 } ?? false
        lastTap = nil
        unlock() // left over from a recording that ended some other way (no microphone)
        handsFree = false
        handsFreeTake = false
        guard speechReady, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            loadSpeechModel() // retry now if an earlier load failed
            NSSound.beep() // the menu explains what's missing
            return
        }
        state = .recording
        self.key = key
        alarms.quiet(true) // answering the wake-up challenge: the beeping waits
        speech.stop() // never talk into the microphone
        pauseMusic() // nor over music
        if notepad.isListening { notepad.stopListening() } // one recording at a time
        pressedAt = Date()
        dictation += 1
        let current = dictation
        followingUp = key == .rightOption && answerPanel.isVisible && focused?.assistant.isActive == true
        if followingUp { answerPanel.setListening(true) } // folds into the notch at once, under the pill to come
        screenTask = key == .rightOption ? Task { await ScreenCapture.capture() } : nil
        if key == .rightOption { pointer.hide() }
        if key == .rightOption, !followingUp {
            // A new conversation. Start Claude Code now: it warms up while the user is still talking.
            // One still working on the card carries on in the side notch.
            if let current = focused { sendToBackground(current) }
            // Each one keeps a Claude Code process: past five, the oldest finished one goes.
            focused = newTask()
            answerPanel.reset()
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
            answerPanel.setListening(false)
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
                self.answerPanel.setListening(true)
                self.panel.showRecording(assistant: self.key == .rightOption)
            }
        }
        showPanelWork = work
        // A follow-up shows it at once: the answer has just folded into the notch beneath it.
        DispatchQueue.main.asyncAfter(deadline: .now() + (followingUp ? 0 : 0.15), execute: work)
        startLiveWords()
        if doubleTap {
            locked = true
            work.perform() // the pill at once
            toast.show("Listening. Tap \(key == .rightOption ? "right ⌥" : "right ⌘") again to finish", symbol: "lock.fill", tint: .orange)
            let timeout = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.locked, self.state == .recording else { return }
                    self.unlock()
                    self.finishRecording()
                }
            }
            lockTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timeout)
        }
    }

    /// About once a second while recording: what's been said so far, transcribed and shown under the
    /// pill. One at a time; the final text still comes from the whole recording.
    private func startLiveWords() {
        liveTimer?.invalidate()
        guard LiveCaption.isEnabled else { return }
        let timer = Timer(timeInterval: 0.9, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording, !self.livePartial, let start = self.startTask else { return }
                let elapsed = Date().timeIntervalSince(self.pressedAt)
                guard elapsed > 1 else { return }
                self.livePartial = true
                let transcriber = self.transcriber
                Task {
                    defer { self.livePartial = false }
                    guard let recording = await start.value else { return }
                    let samples = self.recorder.tail(recording, seconds: min(elapsed, 30))
                    guard let text = try? await withTimeout(4, { try await transcriber.transcribe(samples) }),
                          self.state == .recording else { return }
                    self.caption.show(text)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLiveWords() {
        liveTimer?.invalidate()
        liveTimer = nil
        caption.hide()
    }

    private func unlock() {
        locked = false
        lockTimeout?.cancel()
        lockTimeout = nil
    }

    /// A task's events. Its state is kept either way; the focused one's also go to the card (point
    /// tags on screen, the reply read aloud when that's on), and a background one says when it's
    /// done or needs an OK.
    private func handle(_ event: Assistant.Event, for task: AssistantTask) {
        switch event {
        case .status(let status):
            task.status = status
            if let status { task.addStep(status) }
        case .plan(let plan): task.plan = plan
        case .answer(let text): task.reply = text
        case .approval(let approval): task.approval = approval
        case .didAct: break
        case .turnFinished:
            task.isDone = true
            task.doneAt = Date()
            task.canFollowUp = true
            Daybook.log(question: task.question, reply: task.reply) // memory across days
            ActivityLog.record(.ask, task.question, answer: task.subject, // the dashboard's history
                               reply: SpeechOutput.withoutSounds(ScreenContext.display(Subject.split(task.reply).body)))
            if let finished = task.onFinished {
                task.onFinished = nil
                let parts = Subject.split(task.reply)
                let body = parts.body.replacingOccurrences(of: #"\[[A-Z_]+[^\]]*\]"#, with: "", options: .regularExpression)
                finished([parts.subject ?? "Done", body].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case .failed(let message):
            task.onFinished?("Couldn't do it: \(message)")
            task.onFinished = nil
            task.error = message
            task.status = nil
            task.approval = nil
            task.isDone = true
            task.canFollowUp = false
        }

        guard task === focused else {
            switch event {
            case .didAct(let action):
                toast.show(action)
            case .approval(let approval?):
                task.unseen = true
                toast.show("Needs your OK: " + approval.title, symbol: "hand.raised.fill", tint: .orange)
            case .turnFinished:
                task.unseen = true
                NSSound(named: "Glass")?.play()
                toast.show("Ready: " + task.question)
            case .failed:
                task.unseen = true
            default:
                break
            }
            refreshShelf()
            return
        }
        switch event {
        case .answer(let text):
            let (subject, body) = Subject.split(text)
            let (reply, points) = ScreenPointer.split(body)
            if let screenshot = task.screenshot { pointer.show(points, on: screenshot) }
            answerPanel.setSubject(subject)
            answerPanel.update(.answer(SpeechOutput.withoutSounds(ScreenContext.display(reply))))
            speech.update(ScreenContext.spoken(reply))
        case .didAct(let action):
            toast.show(action)
        case .turnFinished:
            replaceSelection(for: task)
            answerPanel.update(event)
            speech.finish()
            if task === briefing {
                briefing = nil
                answerPanel.holdOpen(for: 10)
            }
        case .failed:
            answerPanel.update(event)
            speech.stop()
        default:
            answerPanel.update(event)
        }
    }

    // MARK: - Tasks

    /// A new conversation with its Claude Code process started. Each keeps one, so past six the
    /// oldest finished one goes.
    private func newTask() -> AssistantTask {
        if tasks.count >= 6, let oldest = tasks.first(where: { !$0.isWorking && $0 !== focused }) { end(oldest) }
        let task = AssistantTask()
        tasks.append(task)
        task.assistant.prepare { [weak self, weak task] event in
            guard let self, let task else { return }
            self.handle(event, for: task)
        }
        return task
    }

    /// One of several jobs given at once: straight to the side notch, working in parallel.
    private func startInBackground(_ request: String, onFinished: ((String) -> Void)? = nil) {
        let task = newTask()
        task.beginTurn(request)
        task.onFinished = onFinished
        task.assistant.ask(request)
        refreshShelf()
    }

    // MARK: - Morning briefing

    private var morningBriefing: Bool {
        get { UserDefaults.standard.object(forKey: "morningBriefing") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "morningBriefing") }
    }

    /// The first time the Mac is opened or unlocked on a school-day morning, the assistant greets
    /// the user with the start of their day. Checked a few seconds after waking (so the network is
    /// back) and at launch, for when Shhh opens at login.
    private func watchForMorning() {
        let check = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                MainActor.assumeIsolated { self?.greetIfMorning() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                          object: nil, queue: .main) { _ in check() }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                            object: nil, queue: .main) { _ in check() }
        check()
    }

    private func greetIfMorning(afterAlarm: Bool = false) {
        let now = Date()
        let calendar = Calendar.current
        let today = now.formatted(.localDay)
        guard morningBriefing, Assistant.executable != nil,
              // School days from 5:00; a day off from 7:00 (a lie-in shouldn't wake to a briefing).
              // Woken by their alarm: whenever it is.
              afterAlarm || (Daybook.isSchoolDay(now) ? 5..<12 : 7..<13).contains(calendar.component(.hour, from: now)),
              UserDefaults.standard.string(forKey: "lastMorningBriefing") != today,
              state == .idle, !answerPanel.isVisible else { return }
        UserDefaults.standard.set(today, forKey: "lastMorningBriefing")
        let task = newTask()
        focused = task
        briefing = task
        answerPanel.reset()
        task.beginTurn("Good morning")
        answerPanel.beginTurn(question: "Good morning")
        if SpeechOutput.speakBriefing, SpeechOutput.engine == .off { speech.useForThisReply(.lifelike) }
        Daybook.archiveIfOld()
        Daybook.buildLocally() // classes, events, deadlines and carried tasks, without Claude
        task.assistant.ask(Assistant.vaultURL == nil ? """
            [Morning briefing: I've just opened my Mac.] Greet me by name: "Good morning, <my name>." Then, \
            from my calendars, in a few short lines: my first period today (subject, time, room), anything \
            due today or tomorrow on ManageBac, and anything else on my calendar today besides classes. If \
            I have no classes today, just say good morning and that there's no school today.
            """ : """
            [Morning briefing: I've just opened my Mac.] First finish today's Daybook if your instructions \
            say parts of it are still to fill (or build it, if there's none for today). Then greet me by name: \
            "Good morning, <my name>." and in a \
            few short lines: my first period (subject, time, room) or that there's no school today, my top three \
            tasks, anything due today or tomorrow, the emails that need me, and today's regular meetings from my \
            patterns.
            On a day off (a weekend or holiday) it's a lighter brief instead, in a relaxed tone: what's due when \
            school is back (and later this week), anything on today's calendar, \(Profile.project.isEmpty ? "" : "the one \(Profile.project) thing that matters most, ")and one thing from my backlog worth doing today. No classes.\(StudyLoop.briefFacts(now))\(Self.ibQuestion)
            """)
    }

    /// "IB question of the day" (Settings → Automations): the end of the morning brief.
    private static var ibQuestion: String {
        guard UserDefaults.standard.object(forKey: "ibQuestion") as? Bool ?? true,
              let subjects = Daybook.root?.appendingPathComponent("School/Subjects"),
              FileManager.default.fileExists(atPath: subjects.path) else { return "" }
        let log = Daybook.relative(Daybook.root?.appendingPathComponent("School/IB Daily Questions.md"))
        return """

            Last, my IB question of the day. Read \(log) (make it if it's missing) for the subject asked last time, \
            take the next of my subjects in \(Daybook.relative(subjects))/ in turn, and ask me one short question on it \
            in IB style, answerable in 1–3 minutes and drawn from that subject's note: a Math AI calculation, an \
            Economics or Business "explain" with a real example, ESS data to interpret, a short text to analyse for \
            English, a sentence to translate or a word to use for Chinese B. Name the command term. Don't give the \
            answer. Add it to the log (date, subject, topic, question). When I answer later, mark it (right, partly, \
            not yet), give the model answer in two lines, and log the result.
            """
    }

    // MARK: - Night shutdown

    private var nightShutdown: Bool {
        get { UserDefaults.standard.object(forKey: "nightShutdown") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nightShutdown") }
    }

    /// At 21:30 on a school night, while the user is at the Mac: the night shutdown routine, once.
    private func shutDownIfNight() {
        let now = Date()
        let calendar = Calendar.current
        let today = now.formatted(.localDay)
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard nightShutdown, Assistant.executable != nil, Assistant.vaultURL != nil,
              minutes >= 21 * 60 + 30,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), Daybook.isSchoolDay(tomorrow),
              UserDefaults.standard.string(forKey: "lastNightShutdown") != today,
              state == .idle, !answerPanel.isVisible,
              // Only while they're actually using the Mac.
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) < 90
        else { return }
        UserDefaults.standard.set(today, forKey: "lastNightShutdown")
        let task = newTask()
        focused = task
        briefing = task
        answerPanel.reset()
        task.beginTurn("Night shutdown")
        answerPanel.beginTurn(question: "Night shutdown")
        if SpeechOutput.speakBriefing, SpeechOutput.engine == .off { speech.useForThisReply(.lifelike) }
        task.assistant.ask("[Night shutdown: it's \(now.formatted(date: .omitted, time: .shortened)).] Run my Night shutdown routine."
                           + StudyLoop.shutdownSteps(now))
    }

    // MARK: - Never stuck

    private var processingSince: Date?

    /// A request that never finished turning into text (a hung microphone, model or screenshot)
    /// left Joe "busy" for good, ignoring every key press after it. Past 45 seconds, let it go.
    /// A task that's still at it after a while (or was asked to work in the background) moves off
    /// the card to the side notch, where its steps show as it goes, and Joe is free for the next
    /// thing. Not while they're looking at it, talking, or it needs an OK.
    private func moveLongTaskAside() {
        guard let task = focused, task.isWorking, task.approval == nil, state == .idle, !answerPanel.isHovering,
              task.background || (Date().timeIntervalSince(task.startedAt) > 12 && task.steps.count >= 2) else { return }
        sendToBackground(task)
        answerPanel.hide()
        toast.show("Working on it in the background: " + (task.subject ?? task.question), symbol: "square.stack.3d.up", tint: .orange)
    }

    private func unstickProcessing() {
        guard state == .processing, let since = processingSince, Date().timeIntervalSince(since) > 45 else { return }
        processingSince = nil
        panel.hide()
        answerPanel.setListening(false)
        state = .idle
        NSSound.beep()
        toast.show("That one got stuck, so I let it go. Try again.", symbol: "exclamationmark.triangle.fill", tint: .yellow)
    }

    // MARK: - Music while talking

    /// The players paused for this recording, to start again once it's over.
    private var pausedMusic: [String] = []
    private var pausedMusicAt = Date.distantPast

    /// Pauses Spotify and Apple Music if they're playing, when the user starts talking.
    private func pauseMusic() {
        for (id, app) in [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]
        where NSRunningApplication.runningApplications(withBundleIdentifier: id).first != nil && !pausedMusic.contains(app) {
            var error: NSDictionary?
            let playing = NSAppleScript(source: "tell application \"\(app)\" to player state as string")?.executeAndReturnError(&error).stringValue
            guard error == nil, playing == "playing" else { continue }
            NSAppleScript(source: "tell application \"\(app)\" to pause")?.executeAndReturnError(nil)
            pausedMusic.append(app)
            pausedMusicAt = Date()
        }
    }

    /// Plays it again once the user has finished: dictation typed, or the assistant done answering
    /// (and done reading the answer aloud). Checked every second.
    private func resumeMusicIfDone() {
        guard !pausedMusic.isEmpty, state == .idle, !(focused?.isWorking ?? false), !speech.isSpeaking, !alarms.isRinging else { return }
        // The music was steered on purpose meanwhile ("pause it", "play my liked songs"), by the
        // shortcut or by the assistant: leave it as it is.
        UserDefaults.standard.synchronize()
        if Spotify.lastCommand > pausedMusicAt {
            pausedMusic = []
            return
        }
        for app in pausedMusic { NSAppleScript(source: "tell application \"\(app)\" to play")?.executeAndReturnError(nil) }
        pausedMusic = []
    }

    // MARK: - Evening check

    private var eveningCheck: Bool {
        get { UserDefaults.standard.object(forKey: "eveningCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "eveningCheck") }
    }

    /// At 19:30, once a day, while the Mac is in use: the Evening check routine (ManageBac and
    /// school mail into tomorrow's Daybook), quietly, in the side notch.
    private func eveningCheckIfTime() {
        let now = Date()
        let calendar = Calendar.current
        let today = now.formatted(.localDay)
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard eveningCheck, Assistant.executable != nil, Assistant.vaultURL != nil,
              (19 * 60 + 30..<23 * 60).contains(minutes),
              UserDefaults.standard.string(forKey: "lastEveningCheck") != today,
              state == .idle,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) < 300
        else { return }
        UserDefaults.standard.set(today, forKey: "lastEveningCheck")
        startInBackground("[Evening check, \(now.formatted(date: .omitted, time: .shortened)).] Run my Evening check routine.")
    }

    @objc private func toggleNightShutdown() {
        nightShutdown.toggle()
    }

    @objc private func toggleMorningBriefing() {
        morningBriefing.toggle()
    }

    /// The card's ×: a task that's still working carries on in the side notch; a finished one ends.
    private func closeCard() {
        if let task = focused {
            if task.isWorking { sendToBackground(task) } else { end(task) }
        }
        answerPanel.hide()
        pointer.hide()
        speech.stop()
        refreshResting()
    }

    private func sendToBackground(_ task: AssistantTask) {
        guard task === focused else { return }
        focused = nil
        if !task.isWorking { end(task) } // a finished one has nothing left to do
        refreshShelf()
    }

    /// Brings a task from the side notch back onto the card. The one there now steps aside.
    private func focus(_ task: AssistantTask) {
        if let current = focused, current !== task {
            if current.isWorking { focused = nil } else { end(current) }
        }
        focused = task
        task.unseen = false
        let (reply, _) = ScreenPointer.split(Subject.split(task.reply).body)
        answerPanel.show(question: task.question, subject: task.subject,
                         reply: SpeechOutput.withoutSounds(ScreenContext.display(reply)), status: task.status,
                         error: task.error, approval: task.approval, isDone: task.isDone, canFollowUp: task.canFollowUp)
        refreshShelf()
    }

    /// Stops a task (if it's still going) and forgets it.
    /// The notch's resting band: always there in notch mode, under the listening band and the
    /// answer island (which cover it exactly while they're up).
    private func refreshResting() {
        if Notch.isEnabled { resting.show() } else { resting.hide() }
    }

    private func end(_ task: AssistantTask) {
        task.assistant.cancel()
        tasks.removeAll { $0 === task }
        if focused === task {
            focused = nil
            answerPanel.hide()
        }
        refreshShelf()
        refreshResting()
    }

    /// The side notch shows up once something is carrying on in the background, and then lists every
    /// task, the one on the card too, by its subject (or the request, until there is one).
    private func refreshShelf() {
        // Alarms and timers to come: the next time, or a timer's countdown.
        let style = TaskShelf.alarmStyle
        let shown = alarms.pending.filter { alarm in
            style == "off" ? false : style == "soon" ? alarm.kind == .timer || alarm.fireAt.timeIntervalSinceNow < 3600 : true
        }
        let alarmItems = shown.map { alarm in
            let seconds = Int(alarm.fireAt.timeIntervalSinceNow.rounded())
            let label = alarm.kind == .alarm || seconds >= 3600 ? alarm.when
                : String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
            return TaskShelf.Item(id: alarm.id, question: "\(label) · \(alarm.title)", state: .alarm)
        }
        guard tasks.contains(where: { $0 !== focused }) else {
            shelf.update(alarmItems)
            return
        }
        shelf.update(alarmItems + tasks.map { task in
            let state: TaskShelf.Item.State = task.approval != nil ? .needsOK
                : task.error != nil ? .failed
                : task.isWorking ? .working : .done
            let label = task.subject ?? (task.question.isEmpty ? "Listening…" : task.question)
            return TaskShelf.Item(id: task.id, question: label, state: state, steps: task.steps, plan: task.plan,
                                  started: task.isWorking ? task.startedAt : nil)
        })
    }

    /// Answers clear themselves: the one on the card two minutes after it's done, counting from the
    /// last time the pointer was over it; done ones in the side notch after ten (they may not have
    /// been seen yet).
    private func clearOldTasks() {
        guard state == .idle else { return } // not in the middle of a follow-up
        let now = Date()
        if let task = focused, task.isDone, task.approval == nil, let done = task.doneAt, !answerPanel.isHovering,
           now.timeIntervalSince(max(done, answerPanel.lastHover)) > 300 {
            end(task)
            pointer.hide()
            speech.stop()
        }
        for task in tasks where task !== focused && task.isDone && now.timeIntervalSince(task.doneAt ?? now) > 600 {
            end(task)
        }
    }

    /// Pastes Claude's new version of the selection over it, if it wrote one and the user is still
    /// in the same app. ⌘Z there undoes it.
    private func replaceSelection(for task: AssistantTask) {
        if task.notepadTarget, let replacement = ScreenContext.replacement(in: task.reply) {
            task.notepadTarget = false
            notepad.replace(with: replacement)
            toast.show("Notes updated")
            return
        }
        guard let selection = task.selection, let replacement = ScreenContext.replacement(in: task.reply) else { return }
        task.selection = nil
        let reply = ScreenContext.display(ScreenPointer.split(Subject.split(task.reply).body).text)
        guard ScreenContext.frontPID == selection.pid else {
            answerPanel.update(.answer(reply + "\n\n*Not pasted: you've left \(selection.app). Copy it from here.*"))
            return
        }
        TextInserter.insert(replacement)
        toast.show("Pasted over your selection")
        answerPanel.update(.answer(reply + "\n\n*Pasted over your selection in \(selection.app). ⌘Z there undoes it.*"))
    }

    /// The context a request about the screen goes with: the screenshot for anything visual (and
    /// pointing); otherwise the selection, else the window's text, else the screenshot.
    /// `image` is what goes along: the screenshot, or just the area around the pointer.
    private func screenContext(for text: String, screen: Task<ScreenCapture.Screenshot?, Never>?, followingUp: Bool,
                               task: AssistantTask) async -> (request: String, image: Data?, screenshot: ScreenCapture.Screenshot?) {
        if !followingUp { task.screenConversation = false }
        let picture = ScreenCapture.wantsPicture(text)
        let explicit = ScreenCapture.isAbout(text)
        let aboutSelection = ScreenContext.refersToSelection(text)
        let pointing = ScreenCapture.pointsAtSomething(text)
        guard explicit || aboutSelection || pointing || (task.screenConversation && picture) else { return (text, nil, nil) }
        task.screenConversation = true
        // "Find his LinkedIn": just the area around the pointer, a sixth of a screenshot's tokens.
        if pointing, !explicit, !picture, !aboutSelection {
            guard let crop = await screen?.value?.cursorCrop() else {
                ScreenCapture.requestAccess()
                return (text + Self.noScreenshot, nil, nil)
            }
            return (text + "\n\n(Attached: the part of my screen around my mouse pointer, which is on the red ring. "
                + "\"This\", \"him\", \"her\" and so on mean what I'm pointing at.)", crop, nil)
        }
        // Follow-ups already have the earlier context: they get the window again only if they name
        // the screen. "Make it even shorter" with nothing selected means Claude's last version.
        let fresh = explicit || !followingUp
        if !picture, let selection = await ScreenContext.selection(limit: 40_000) {
            task.selection = selection
            return (text + """


                <selected_text app="\(selection.app)">
                \(selection.text)
                </selected_text>
                (That's the text I have selected. If I asked you to change it, put only the new version \
                between [REPLACE] and [/REPLACE]: Joe pastes it over my selection.)
                """, nil, nil)
        }
        if !picture, !fresh { return (text, nil, nil) }
        if !picture, let window = await ScreenContext.windowText(limit: 12_000) {
            return (text + """


                <window_text app="\(window.text.app)" title="\(window.title)">
                \(window.text.text)
                </window_text>
                (That's the text of the window I'm in.)
                """, nil, nil)
        }
        guard let screenshot = await screen?.value else {
            ScreenCapture.requestAccess()
            return (text + Self.noScreenshot, nil, nil)
        }
        let pointer = screenshot.cursor.map { "\n\n(My mouse pointer is at \(Int($0.x)),\(Int($0.y)) in the screenshot.)" } ?? ""
        return (text + pointer, screenshot.jpeg, screenshot)
    }

    /// "Help me take notes", "open a notepad".
    private static func isNotepadRequest(_ text: String) -> Bool {
        text.range(of: #"\b((take|taking|start|make) (some |my )?notes|note ?pad|(open|show) (a |my |the )?notes|(record|transcribe) (this|the|my) (lecture|class|lesson|meeting|call|seminar))\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Email Ammiel. Next task, find revision sites. Next task, …": one request per job (the first
    /// is empty when it starts with "next task"). "Next task" only divides at the start, after
    /// punctuation, or after "and", "then", "okay" or "also"; never as in "my next task on ManageBac".
    static func splitTasks(_ text: String) -> [String] {
        let divider = #"(?:^|(?<=[.!?,;:])\s*|\b(?:and|then|okay|ok|also)\s+)(?:the\s+)?"#
            + #"(?:next|new|another|separate|second|third|fourth|fifth)\s+task\b"#
            + #"(?!\s+(?:on|in|due|for|from|of|is due|is on)\b)[\s:,.\-–—]*(?:is\s+to\s+|is\s+)?"#
        guard let regex = try? NSRegularExpression(pattern: divider, options: .caseInsensitive) else { return [text] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return [text] }
        var jobs: [String] = []
        var start = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            jobs.append(String(text[start..<range.lowerBound]))
            start = range.upperBound
        }
        jobs.append(String(text[start...]))
        let tidy = jobs.map {
            $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ",;:-–—")))
                .replacingOccurrences(of: #"[\s,]+(and|then|and then)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // Keep a leading empty one (it says the first job was new); drop any others.
        return tidy.enumerated().filter { $0.offset == 0 || !$0.element.isEmpty }.map(\.element)
    }

    /// "It's resolved", "remove the green tick", "dismiss it", "that's all". Clear-cut phrases count
    /// whatever else is said; vaguer ones ("clear it") only as a short request of their own, so
    /// "remove that event from my calendar" still goes to Claude.
    static func isDismissRequest(_ text: String) -> Bool {
        let strong = [
            #"\b(it'?s|that'?s|is) resolved\b"#, #"\bresolve (it|this|that|them|everything|all)\b"#,
            #"\b(remove|clear|hide|get rid of)\b[^.?!]{0,12}\b(the |that |this )?(green )?(tick|check ?mark)s?\b"#,
            #"\bdismiss (it|this|that|the answer|everything|all)\b"#,
            #"\b(clear|close|dismiss|hide|remove) (the|this|that|your) (answer|card|reply|notification|notch|island|screen|message|response)s?\b"#,
        ]
        // Whole requests only, give or take "hey Joe", "now", "please", "thanks".
        let name = NSRegularExpression.escapedPattern(for: Assistant.name.lowercased())
        let filler = "(?:hey|hi|yo|ok|okay|cool|great|so|alright|all right|you can|can you|could you|please|now|thanks|thank you|then|just|\(name)|joe)"
        let short = ["(clear|close|dismiss|remove|hide|delete) (it|this|that|them|those)( out| off| away)?", "(clear|dismiss|close)( out)?",
                     "(clear|wipe) (it|this|that) (all|up)", "get rid of (it|this|that)", "(that'?s|it'?s) (all|it)", "all good",
                     "(i'?m|we'?re) done", "got it", "never ?mind", "go away", "done with (it|this|that)"]
            .map { #"^\W*(?:\#(filler)\W+)*(?:\#($0))(?:\W+\#(filler))*\W*$"# }
        let matches = { (patterns: [String]) in
            patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        // About the notepad ("I'm done taking notes"): that's the notepad's to close.
        if text.range(of: #"\bnote"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return matches(strong) || matches(short) || isClearAll(text)
    }

    /// "Clear everything", "dismiss all of them".
    private static func isClearAll(_ text: String) -> Bool {
        text.range(of: #"\b(clear|dismiss|remove|resolve)\b[^.?!]{0,15}\b(all|everything)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Close the notes tab", "hide my notepad", "I'm done taking notes".
    private static func isCloseNotepadRequest(_ text: String) -> Bool {
        let patterns = [
            #"\b(close|hide|dismiss|shut|put away|get rid of|minimi[sz]e)\b[^.?!]{0,25}\b(notes?|note ?pad)\b"#,
            #"\b(notes?|note ?pad)\b[^.?!]{0,15}\b(away|closed?|off)\b"#,
            #"\b(i'?m|i am|we'?re) (done|finished) (taking |with )?(the |my )?notes\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// With the notepad open: whether a request is about the notes ("make these into bullet points").
    private static func refersToNotes(_ text: String) -> Bool {
        text.range(of: #"\b(notes?|notepad|bullet\w*|summar\w*|organi[sz]\w*|tidy|clean|format\w*|rewrite|structure|outline|key points|flash ?cards?|quiz|headings?|sections?)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let noScreenshot = "\n\n(Joe couldn't take a screenshot: it needs Screen Recording access in System "
        + "Settings → Privacy & Security, then Joe quit and reopened. Tell the user.)"

    /// A right ⌥ recording that went nowhere: stop the conversation it started. A failed
    /// follow-up leaves the open one alone.
    private func dropNewConversation() {
        guard key == .rightOption, !followingUp, let task = focused else { return }
        end(task)
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
        if locked { return } // a shortcut typed while it's locked on is just typing; the next tap ends it
        stopLiveWords()
        handsFreeTake = false
        endListener.stop()
        showPanelWork?.cancel()
        panel.hide()
            answerPanel.setListening(false)
        dropNewConversation()
        state = .idle
        alarms.quiet(false)
        let start = startTask
        Task { if let recording = await start?.value { recorder.cancel(recording) } }
    }

    private func finishRecording() {
        guard state == .recording, !locked else { return } // locked on: letting go doesn't end it
        stopLiveWords()
        showPanelWork?.cancel()
        let heldFor = Date().timeIntervalSince(pressedAt)

        guard heldFor >= 0.3 else {
            lastTap = (key, Date()) // the first half of a double tap, maybe
            cancelRecording()
            return
        }

        state = .processing
        processingSince = Date()
        panel.showProcessing()
        let handsFreeTake = self.handsFreeTake
        self.handsFreeTake = false
        endListener.stop()
        let asking = key == .rightOption
        let followingUp = self.followingUp
        let screen = screenTask
        let useCleanup = aiCleanup && !asking // Claude copes with "um"s and corrections itself
        let style = writingStyle
        let start = startTask
        let transcriber = self.transcriber

        Task {
            var asked = false
            defer {
                panel.hide()
            answerPanel.setListening(false)
                state = .idle
                alarms.quiet(false) // still ringing: back to beeping
                if asking, !asked, !followingUp { dropNewConversation() }
            }
            guard let recording = await start?.value else { return } // already beeped
            var samples = await recorder.stop(recording, covering: heldFor)
            guard samples.count >= 16_000 / 4 else {
                NSSound.beep() // the microphone sent no audio
                return
            }
            if handsFreeTake {
                // "Hey Joe": only the parts in their voice (nil: no voiceprint yet, keep it all).
                if let own = await VoicePrint.shared.keepOwnVoice(samples) {
                    guard own.count >= 16_000 / 2 else { return } // none of it was them
                    samples = own
                }
            } else if samples.count >= 32_000 {
                // Holding a key: it's them for certain, so it teaches Joe their voice.
                let theirs = samples
                Task.detached { await VoicePrint.shared.learn(theirs) }
            }

            var text: String
            do {
                // Normally well under a second. Far longer means the model is stuck.
                let seconds = Double(samples.count) / 16_000
                let heard = await NoiseFilter.shared.clean(samples) // background noise out (Settings)
                text = try await withTimeout(40 + seconds) { try await transcriber.transcribe(heard) } // may wait for Chinese just after launch
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
            text = Vocabulary.apply(text) // the user's names and words, spelled their way
            // A morning alarm's challenge: whatever key they held, this is their answer.
            if alarms.challengeActive {
                alarms.answer(text)
                return
            }
            if handsFreeTake { text = EndListener.withoutEndPhrase(text) } // "…, end prompt"
            if asking {
                guard !text.isEmpty else { return }
                lastTranscript = text
                onboarding.heard(text) // the tour's "try it" step
                guard var task = focused else { return }
                // "It's resolved", "remove the tick": the answer on the card is cleared ("clear
                // everything": the side notch's too). Nothing goes to Claude.
                // The whiteboard in front: this is their answer to its question.
                if studyBoard.isTakingAnswers {
                    studyBoard.answer(byVoice: text)
                    return
                }
                if openStudy(text) { return }
                if openPen(text) { return }
                if Self.isDismissRequest(text) {
                    if Self.isClearAll(text) { for other in tasks where other !== task { end(other) } }
                    // Said with nothing on the card: "it" is the finished answers waiting at the notch.
                    if task.question.isEmpty { for other in tasks where other !== task && !other.isWorking { end(other) } }
                    end(task)
                    pointer.hide()
                    toast.show("Cleared", symbol: "checkmark.circle", tint: .green)
                    return
                }
                // "Play Fly Me to the Moon", "pause", "skip", "volume down": Spotify, in about a second.
                // Nothing goes to Claude.
                // An alarm ringing: "stop", "snooze". Nothing goes to Claude.
                if alarms.isRinging, let answer = AlarmRequest.ringingCommand(text) {
                    if task.question.isEmpty { end(task) }
                    if answer.stop { alarms.stop() } else { alarms.snooze(minutes: answer.snoozeMinutes) }
                    return
                }
                // "Set a timer for 5 minutes", "alarm for 6:30 called econ quiz", "remind me in 20
                // minutes to…", "cancel my alarms": set here, at once. Nothing goes to Claude.
                if let request = AlarmRequest.parse(text) {
                    if task.question.isEmpty { end(task) }
                    ActivityLog.record(.ask, text, answer: "Alarm command") // in History, so it can be traced
                    alarms.handle(request)
                    return
                }
                // Anything about the music ("pause it, don't play it"): don't play it again afterwards.
                if text.range(of: #"\b(music|song|spotify|playlist|pause|resume|unpause|track|album|volume)\b"#,
                              options: [.regularExpression, .caseInsensitive]) != nil {
                    pausedMusic = []
                }
                if let music = Spotify.command(in: text) {
                    pausedMusic = [] // they're steering the music themselves now
                    if task.question.isEmpty { end(task) } // the new conversation this press started
                    pointer.hide()
                    Task.detached { [weak self] in
                        let result = Spotify.run(music)
                        await MainActor.run { self?.toast.show(result, symbol: "music.note", tint: .green) }
                    }
                    return
                }
                // "Close the notes tab": the notepad goes away, nothing goes to Claude.
                if notepad.isVisible, Self.isCloseNotepadRequest(text) {
                    notepad.hide()
                    toast.show("Notepad closed: your notes are saved", symbol: "note.text", tint: .orange)
                    return
                }
                // "Help me take notes for Econ": the notepad opens, nothing goes to Claude. The last
                // notes are in the vault already, so these start fresh.
                if !notepad.isVisible, Self.isNotepadRequest(text) {
                    if notepad.text.isEmpty || (NoteSaver.isEnabled && noteSaver.isSaved) {
                        notepad.clear()
                        noteSaver.begin(text)
                    } else {
                        noteSaver.heard(text)
                    }
                    notepad.show(kind: noteSaver.kind)
                    notepad.show()
                    // "Record this lecture": listening hands-free straight away.
                    if text.range(of: #"\b(record|transcribe)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                        notepad.startListening()
                        toast.show("Recording the \(noteSaver.kind == .meeting ? "meeting" : "lecture"). Close the notepad when it's over.",
                                   symbol: "record.circle", tint: .red)
                    } else {
                        toast.show("\(noteSaver.kind?.label ?? "Notepad") open: hold right ⌘ to dictate, or press Listen",
                                   symbol: "note.text", tint: .orange)
                    }
                    return
                }
                // "This is a meeting": what the notes are, for their title and folder in the vault.
                if notepad.isVisible, NoteSaver.isKindStatement(text) {
                    let kind: NoteSaver.Kind = NoteSaver.kind(in: text)
                        ?? (text.range(of: #"\b(meeting|call)\b"#, options: [.regularExpression, .caseInsensitive]) != nil ? .meeting
                            : text.range(of: #"\b(lecture|class|lesson|seminar)\b"#, options: [.regularExpression, .caseInsensitive]) != nil ? .lecture
                            : .notes)
                    noteSaver.heard(text)
                    noteSaver.kind = kind
                    notepad.show(kind: kind)
                    toast.show("Got it: \(kind.label.lowercased())", symbol: "note.text", tint: .orange)
                    return
                }
                // "Start my Econ IA", "plan my week", "done with Paper 2", "how's my EE going", "log CAS: …":
                // done here, with a line on the card. A follow-up (except an answer to the wellbeing
                // check-in), or what Joe can't settle alone, goes to Claude.
                if let intent = StudyIntent.parse(text), !followingUp || intent.isAnswer, let reply = intent.run() {
                    showLocalAnswer(reply, question: text, in: task)
                    asked = true
                    return
                }
                // "Next task, …": each job after the first is a conversation of its own, working in
                // parallel in the side notch. The first carries on as usual: a follow-up, or the new
                // conversation this press started.
                var continuing = followingUp
                var jobs = Self.splitTasks(text)
                if jobs.count > 1 {
                    if jobs[0].isEmpty {
                        jobs.removeFirst()
                        if continuing { // the open one carries on in the side notch; this is new
                            sendToBackground(task)
                            task = newTask()
                            focused = task
                            answerPanel.reset()
                            continuing = false
                        }
                    }
                    text = jobs[0]
                    for job in jobs.dropFirst() { startInBackground(job) }
                    if jobs.count > 1 {
                        toast.show("\(jobs.count) tasks started", symbol: "square.stack.3d.up.fill", tint: .orange)
                    }
                }
                task.beginTurn(text)
                answerPanel.beginTurn(question: text)
                var (request, image, screenshot): (String, Data?, ScreenCapture.Screenshot?)
                if notepad.isVisible, !notepad.text.isEmpty, Self.refersToNotes(text) {
                    noteSaver.heard(text) // it helps title the notes
                    notepad.show(kind: noteSaver.kind)
                    task.notepadTarget = true
                    (request, image, screenshot) = (text + """


                        <notepad>
                        \(notepad.text)
                        </notepad>
                        (That's my notepad. If I asked you to change these notes, put the whole new version \
                        between [REPLACE] and [/REPLACE]: Joe puts it in the notepad. Plain text, "- " bullets.)
                        """, nil, nil)
                } else {
                    (request, image, screenshot) = await screenContext(for: text, screen: screen, followingUp: continuing,
                                                                       task: task)
                }
                task.screenshot = screenshot
                // Designing slides needs the strongest model: a new conversation about it gets Opus.
                if !continuing, Assistant.needsStrongModel(text) { task.assistant.useStrongModel() }
                if Self.wantsBackground(text) { task.background = true }
                task.assistant.ask(request, screenshot: image)
                asked = true
                acknowledgeIfSlow(task)
                return
            }
            // "… make it a prompt": rewritten as a clear prompt for an AI app before it's typed.
            if let said = PromptPolish.request(in: text) {
                panel.showProcessing()
                text = await PromptPolish.polish(said)
            } else {
                text = style.apply(text)
            }
            guard !text.isEmpty else { return }
            lastTranscript = text
            ActivityLog.record(.dictation, text) // the dashboard's history and stats
            if notepad.isVisible {
                notepad.appendDictation(text) // while it's open, dictation is for the notes
            } else {
                TextInserter.insert(text)
            }
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMicrophones(wait: 0.25)
        menu.removeAllItems()
        menu.addItem(item("Open Joe…", #selector(openDashboard)))
        menu.addItem(.separator())

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

        menu.addItem(item("Edit dictionary…", #selector(editDictionary)))
        let notes = item("Notepad", #selector(toggleNotepad))
        notes.state = notepad.isVisible ? .on : .off
        menu.addItem(notes)
        if Assistant.vaultURL != nil {
            let remember = item("Remember conversations", #selector(toggleRemember))
            remember.state = Daybook.remembers ? .on : .off
            menu.addItem(remember)
            let save = item("Save notes to Obsidian", #selector(toggleSaveNotes))
            save.state = NoteSaver.isEnabled ? .on : .off
            save.indentationLevel = 1
            menu.addItem(save)
        }

        let control = item(ScreenControl.cliclick == nil ? "Let \(Assistant.name) click and type (needs cliclick)"
                           : "Let \(Assistant.name) click and type", #selector(toggleScreenControl))
        control.state = ScreenControl.isEnabled ? .on : .off
        control.isEnabled = ScreenControl.cliclick != nil
        menu.addItem(control)

        let notch = item("Show at the notch", #selector(toggleNotch))
        notch.state = Notch.isEnabled ? .on : .off
        menu.addItem(notch)

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
        let quit = NSMenuItem(title: "Quit Joe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    /// "Assistant": how to use it, which model and effort, what it may do alone, and its memory.
    private func askMenu() -> NSMenuItem {
        let hint = NSMenuItem(title: Assistant.executable == nil ? "Claude Code not found" : "Hold right ⌥ to ask or delegate",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        var items = [hint, .separator()]
        items.append(submenu("Model: \(Assistant.model.name)", items: Assistant.Model.allCases.map { model in
            let item = item(model.title, #selector(selectModel(_:)))
            item.representedObject = model.rawValue
            item.state = model == Assistant.model ? .on : .off
            return item
        }))
        items.append(submenu("Effort: \(Assistant.effort.name)", items: Assistant.Effort.allCases.map { effort in
            let item = item(effort.name, #selector(selectEffort(_:)))
            item.representedObject = effort.rawValue
            item.state = effort == Assistant.effort ? .on : .off
            return item
        }))
        items.append(voiceMenu())
        items.append(.separator())
        for autonomy in Assistant.Autonomy.allCases {
            let item = item(autonomy.title, #selector(selectAutonomy(_:)))
            item.representedObject = autonomy.rawValue
            item.state = autonomy == Assistant.autonomy ? .on : .off
            items.append(item)
        }
        let morning = item("Morning briefing", #selector(toggleMorningBriefing))
        morning.state = morningBriefing ? .on : .off
        items.append(morning)
        let night = item("Night shutdown at 21:30 on school nights", #selector(toggleNightShutdown))
        night.state = nightShutdown ? .on : .off
        items.append(night)
        items.append(.separator())
        items.append(item("Memory: \(Assistant.vaultURL?.lastPathComponent ?? "none")…", #selector(chooseMemoryVault)))
        if !CGPreflightScreenCaptureAccess() {
            items.append(item("Allow reading your screen…", #selector(openScreenRecordingSettings)))
        }
        items.append(item("Edit instructions…", #selector(editAssistantInstructions)))
        return submenu(Assistant.name, items: items)
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

    @objc private func toggleNotepad() {
        notepad.toggle()
    }

    /// Into the vault, once the last of a recording is in.
    private func saveNotes() {
        notepad.whenDone { [weak self] in
            guard let self else { return }
            self.noteSaver.save(self.notepad.text) { [weak self] message in
                self?.toast.show(message, symbol: "note.text", tint: .purple)
            }
        }
    }

    @objc private func toggleScreenControl() {
        ScreenControl.isEnabled.toggle()
        for task in tasks where !task.isWorking { end(task) } // new conversations pick up the new tools
    }

    @objc private func toggleRemember() {
        Daybook.remembers.toggle()
    }

    @objc private func toggleSaveNotes() {
        NoteSaver.isEnabled.toggle()
    }

    @objc private func editDictionary() {
        Vocabulary.open()
    }

    @objc private func toggleNotch() {
        Notch.isEnabled.toggle()
        refreshResting()
    }

    /// "Voice": Alba or off, and whether the morning briefing is read aloud.
    private func voiceMenu() -> NSMenuItem {
        var items: [NSMenuItem] = []
        if let status = speech.status {
            let line = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            line.isEnabled = false
            items += [line, .separator()]
        }
        for engine in SpeechOutput.Engine.allCases {
            let item = item(engine.title, #selector(selectVoice(_:)))
            item.representedObject = engine.rawValue
            item.state = engine == SpeechOutput.engine ? .on : .off
            items.append(item)
        }
        items.append(.separator())
        let briefing = item("Read the morning briefing aloud", #selector(toggleSpeakBriefing))
        briefing.state = SpeechOutput.speakBriefing ? .on : .off
        items.append(briefing)
        let title = SpeechOutput.engine == .off ? "Voice: off" : "Voice: \(SpeechOutput.engine.title.components(separatedBy: ":")[0])"
        return submenu(title, items: items)
    }

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let engine = SpeechOutput.Engine(rawValue: raw) else { return }
        speech.stop()
        SpeechOutput.engine = engine
        speech.prepare() // downloads the model the first time; lets go of the other
    }

    @objc private func toggleSpeakBriefing() {
        SpeechOutput.speakBriefing.toggle()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let model = Assistant.Model(rawValue: raw) {
            Assistant.model = model
        }
    }

    @objc private func selectEffort(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let effort = Assistant.Effort(rawValue: raw) {
            Assistant.effort = effort
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

    @objc private func openScreenRecordingSettings() {
        ScreenCapture.requestAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
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
