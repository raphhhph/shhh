import AppKit

/// Terminal test modes, to check each part of the pipeline without the app:
///
///     Shhh --transcribe <audio-file>   transcribe a file with the on-device model
///     Shhh --clean "<text>"            run the AI cleanup pass (one line per input line)
///     Shhh --style <style> "<text>"    apply a writing style: veryFormal, casual, veryCasual
///     Shhh --microphones               list microphones and show what Automatic picks
///     Shhh --record <seconds>          record from the Automatic microphone and transcribe
///     Shhh --ask "<request>" […]       ask the assistant (later requests follow up) and show the card
enum CommandLineTool {
    private static let usage = """
    Usage:
      Joe --transcribe <audio-file>
      Joe --clean "<text>"
      Joe --style <veryFormal|casual|veryCasual> "<text>"
      Joe --microphones
      Joe --record <seconds>
      Joe --ask "<request>" ["<follow-up>" …]
    """

    /// Runs a test mode and exits if one was requested; returns otherwise.
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first, mode.hasPrefix("--") else { return }

        switch (mode, args.count) {
        case ("--microphones", 1):
            print("Lid closed:", AudioDevices.isLidClosed)
            for input in AudioDevices.inputs() { print("-", input.name, "[\(input.kind)]") }
            print("Automatic picks:", AudioDevices.resolve(preferredUID: nil)?.name ?? "nothing")
            exit(0)
        case ("--style", 3):
            guard let style = WritingStyle(rawValue: args[1]) else { fail("Unknown style: \(args[1])") }
            print(style.apply(args[2]))
            exit(0)
        case ("--transcribe", 2):
            run { try await transcribe(file: args[1]) }
        case ("--clean", 2):
            run { try await clean(args[1]) }
        case ("--record", 2):
            guard let seconds = Double(args[1]) else { fail("Usage: Joe --record <seconds>") }
            run { try await record(seconds: seconds) }
        case ("--get-voice", 2):
            // Shhh --get-voice natural|expressive: downloads and loads it, silently.
            guard let engine = SpeechOutput.Engine(rawValue: args[1]) else { fail("natural or expressive") }
            run {
                let start = Date()
                let problem = await SpeechOutput().prepareNow(engine)
                print(problem ?? String(format: "%@ voice ready (%.0fs)", engine.rawValue, Date().timeIntervalSince(start)))
            }
        case ("--say", 2...):
            // Shhh --say "<text>" [natural|expressive|apple]: speaks it in that voice, timing it.
            let engine = args.count > 2 ? SpeechOutput.Engine(rawValue: args[2]) ?? .natural : .natural
            setvbuf(stdout, nil, _IOLBF, 0) // timings show up as they happen
            let start = Date()
            MainActor.assumeIsolated {
                // Just for this, so the voice chosen in the menu stays as it is.
                let speech = SpeechOutput()
                sayer = speech
                speech.useForThisReply(engine)
                speech.update(args[1])
                speech.finish()
            }
            // Done when it's all been said (or after five minutes, whatever happens).
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed > 300 || (elapsed > 1 && sayer?.isSpeaking == false) {
                        print(String(format: "Done in %.1fs", elapsed))
                        exit(0)
                    }
                }
            }
            RunLoop.main.run()
            exit(0)
        case ("--check", 2...):
            // Shhh --check "<bash command>"…: what Shhh would do with each (for testing the rules).
            MainActor.assumeIsolated { for command in args.dropFirst() { print(Assistant.check(command)) } }
            exit(0)
        case ("--is-dismiss", 2...):
            // Shhh --is-dismiss "<request>"…: whether each would clear the answer (testing the phrases).
            MainActor.assumeIsolated { for text in args.dropFirst() { print(AppDelegate.isDismissRequest(text) ? "clears  " : "→ Claude", text) } }
            exit(0)
        case ("--alarm", 2...):
            // Shhh --alarm "timer for 5 minutes" | "alarm at 6:30 called econ quiz" | list | "cancel all".
            // Shhh --alarm at <YYYY-MM-DDTHH:MM | HH:MM | +minutes> "<title>" [alarm|timer|reminder]
            if args[1] == "at", args.count >= 4 {
                let when = args[2]
                let now = Date()
                var date: Date?
                if when.hasPrefix("+"), let minutes = Double(when.dropFirst()) { date = now.addingTimeInterval(minutes * 60) }
                else if when.count == 5, when.contains(":") {
                    let parts = when.split(separator: ":").compactMap { Int($0) }
                    if parts.count == 2, var d = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now) {
                        if d <= now { d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d }
                        date = d
                    }
                } else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
                        formatter.dateFormat = format
                        if let d = formatter.date(from: when) { date = d; break }
                    }
                }
                guard let date else { print("Couldn't read the time “\(when)”: use YYYY-MM-DDTHH:MM, HH:MM or +minutes."); exit(1) }
                let kind = Alarm.Kind(rawValue: args.count > 4 ? args[4] : "alarm") ?? .alarm
                var alarm = Alarm(fireAt: date, title: args[3], kind: kind, repeats: args.count > 5 ? args[5] : nil)
                if alarm.repeatDays != nil, !(alarm.repeatDays!.contains(Calendar.current.component(.weekday, from: date))),
                   let first = alarm.next(after: date.addingTimeInterval(-1)) { alarm.fireAt = first }
                AlarmStore.add(alarm)
                print("Set: \(kind.rawValue) at \(alarm.when) (\(alarm.fireAt.formatted(.dateTime.weekday(.wide).day().month())))\(alarm.repeats.map { ", repeating \($0)" } ?? ""): \(alarm.title). Joe rings it, if the Mac is awake.")
                exit(0)
            }
            let text = args.dropFirst().joined(separator: " ")
            let request = AlarmRequest.parse(text) ?? AlarmRequest.parse("set an alarm " + text)
                ?? (["list", "show"].contains(text) ? .list : nil) ?? (text.hasPrefix("cancel") ? .cancel(nil, nil) : nil)
            switch request {
            case let .add(alarm)?:
                AlarmStore.add(alarm)
                print("Set: \(alarm.kind.rawValue) at \(alarm.when): \(alarm.title)")
            case .list?: print(AlarmStore.summary)
            case let .cancel(words, kind)?: print("Cancelled \(AlarmStore.cancel(matching: words, kind: kind)).")
            case nil: print("Couldn't read that. Use: Joe --alarm at <YYYY-MM-DDTHH:MM | HH:MM | +minutes> \"<title>\" [alarm|timer|reminder]"); exit(1)
            }
            exit(0)
        case ("--alarm-check", 2...):
            // Shhh --alarm-check "<request>"…: what each would set (testing the phrases).
            for text in args.dropFirst() {
                switch AlarmRequest.parse(text) {
                case let .add(alarm)?: print("⏰ \(alarm.kind.rawValue) \(alarm.fireAt.formatted(.dateTime.weekday(.abbreviated).hour().minute().second())) “\(alarm.title)” · \(text)")
                case .list?: print("list · \(text)")
                case let .cancel(words, kind)?: print("cancel \(kind?.rawValue ?? "any") \(words ?? "all") · \(text)")
                case nil: print("→ Claude · \(text)")
                }
            }
            exit(0)
        case ("--spotify-login", 1):
            // Shhh --spotify-login: connects the user's own Spotify account (liked songs, playlists).
            print(Spotify.Account.login())
            exit(0)
        case ("--music-check", 2...):
            // Shhh --music-check "<request>"…: whether each would go straight to Spotify (testing the phrases).
            for text in args.dropFirst() { print(Spotify.command(in: text).map { "♪ \($0)" } ?? "→ Claude", "·", text) }
            exit(0)
        case ("--spotify", 2...):
            // Shhh --spotify "play fly me to the moon" | pause | next | "volume 40" …: music in Spotify.
            let request = args.dropFirst().joined(separator: " ")
            guard let command = Spotify.command(in: request) ?? Spotify.command(in: "play " + request) else {
                print("Say it as: play <song, artist, album or playlist>, pause, resume, next, previous, volume <0–100>, shuffle on/off, what's playing.")
                exit(1)
            }
            print(Spotify.run(command))
            exit(0)
        case ("--workspace-reset", 1):
            print(Workspace.reset())
            exit(0)
        case ("--recap", 1):
            print(ActivityLog.recap())
            exit(0)
        case ("--math-pdf", 2...):
            // Joe --math-pdf <spec.json> [out.pdf]: worked maths solutions, typeset.
            MainActor.assumeIsolated { MathDoc.run(Array(args.dropFirst())) }
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApplication.shared.run()
        case ("--plan", 2...):
            // Joe --plan "<step>" "<step>" … | <number> | done: the assistant's checklist. The app
            // reads it from the command itself and shows it at the notch; nothing to do here.
            print("Plan updated.")
            exit(0)
        case ("--message", 4...):
            // Joe --message send|draft whatsapp|wechat "<chat>" "<text>", or --message open <app> "<chat>"
            run { print(await Messaging.run(Array(args.dropFirst()))) }
        case ("--slides", 3...):
            // Joe --slides inspect <deck.pptx> | apply <deck.pptx> <plan.json>: edits a copy of a deck.
            print(Slides.run(Array(args.dropFirst())))
            exit(0)
        case ("--workspace", 2):
            // Shhh --workspace "<name>": switches Vivaldi to that workspace (for routines).
            print(Workspace.switchTo(args[1]))
            exit(0)
        case ("--pdf-index", 2):
            print(Textbook.buildIndex(pdf: args[1]))
            exit(0)
        case ("--pdf-find", 3):
            print(Textbook.find(pdf: args[1], query: args[2]))
            exit(0)
        case ("--pdf-text", 3):
            print(Textbook.text(pdf: args[1], pages: args[2]))
            exit(0)
        case ("--prereading", 2):
            MainActor.assumeIsolated { print(Textbook.buildPreReading(spec: args[1])) }
            exit(0)
        case ("--daybook", 1):
            // Shhh --daybook: what the assistant is told about the user's day.
            print(Daybook.instructions)
            print("\n--- If it had to build today's:\n" + Daybook.buildRules)
            exit(0)
        case ("--look", 1):
            // Shhh --look: for the assistant, a screenshot and the front window's controls.
            run { print(await ScreenControl.look()) }
        case ("--save-notes", 3):
            // Shhh --save-notes "<what the user said>" <notes.txt>: saves them as the notepad would.
            let notes = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
            MainActor.assumeIsolated {
                let saver = NoteSaver()
                noteSaver = saver
                saver.begin(args[1])
                saver.save(notes) { print($0); if $0.hasPrefix("Saved to Obsidian:") { exit(0) } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("No title in time"); exit(1) }
            RunLoop.main.run()
        case ("--show-approval", 2...):
            // Shhh --show-approval email|event|bash|chrome [out.png]: a sample OK card, to look at.
            MainActor.assumeIsolated { showApproval(args[1], saveTo: args.count > 2 ? args[2] : nil) }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        case ("--ask", 2...):
            MainActor.assumeIsolated { ask(Array(args.dropFirst())) }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
            exit(0)
        default:
            fail(usage)
        }
    }

    private static func transcribe(file: String) async throws {
        let transcriber = Transcriber()
        try await transcriber.load { _ in }
        let start = Date()
        let text = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: file))
        print(String(format: "[%.2fs] %@", Date().timeIntervalSince(start), text))
    }

    private static func clean(_ input: String) async throws {
        let cleaner = TextCleaner()
        try await cleaner.load { _ in }
        for line in input.components(separatedBy: "\n") where !line.isEmpty {
            let start = Date()
            let text = await cleaner.clean(line)
            print(String(format: "[%.2fs] %@", Date().timeIntervalSince(start), text))
        }
        await cleaner.unload()
    }

    @MainActor
    private static func record(seconds: Double) async throws {
        let recorder = AudioRecorder()
        let start = Date()
        let recording = try await recorder.start(preferredUID: nil)
        print(String(format: "Recording %.0fs from %@ (started in %.2fs)…", seconds, recording.input.name, Date().timeIntervalSince(start)))
        try await Task.sleep(for: .seconds(seconds))
        let samples = await recorder.stop(recording, covering: seconds)
        let peak = samples.reduce(0) { max($0, abs($1)) }
        print(String(format: "Captured %.1fs, peak level %.2f", Double(samples.count) / 16_000, peak))
        let transcriber = Transcriber()
        try await transcriber.load { _ in }
        print("Text:", try await transcriber.transcribe(samples))
    }

    @MainActor private static var sayer: SpeechOutput?
    @MainActor private static var noteSaver: NoteSaver?
    @MainActor private static let panel = AnswerPanel()
    @MainActor private static let assistant = Assistant()

    @MainActor
    private static func showApproval(_ kind: String, saveTo path: String?) {
        let preview: Assistant.Preview? = switch kind {
        case "email": .email(to: "David Chen", cc: "", subject: "Running late",
                             body: "I'll be ten minutes late. Can we move our 3pm to Thursday?")
        case "event": .event(title: "Econ study group", when: "Thu 16 Oct, 16:00–17:00", location: "Library, room 2", guests: "david@example.com")
        default: nil
        }
        let (title, tool, detail) = kind == "bash"
            ? ("Run a command", "Bash", "Counts the notes in your vault\ncommand: ls ~/Vault | wc -l")
            : ("Click in Chrome: this may send or submit something", "mcp__claude-in-chrome__computer",
               "Clicks Submit on the Econ IA draft page")
        panel.onClose = { exit(0) }
        panel.reset()
        panel.beginTurn(question: "test")
        panel.update(.answer("Subject: Waiting for your OK\nHere's what I'm about to do."))
        panel.update(.approval(Assistant.Approval(title: title, detail: detail, tool: tool, preview: preview,
                                                  decide: { print("Chose \($0)"); exit(0) })))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                if let path, let screen = NSScreen.screens.first {
                    let f = panel.frame
                    let rect = "\(Int(f.minX)),\(Int(screen.frame.maxY - f.maxY)),\(Int(f.width)),\(Int(f.height))"
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    task.arguments = ["-x", "-R", rect, path]
                    try? task.run()
                    task.waitUntilExit()
                    exit(0)
                }
            }
        }
    }

    /// Shows the answer card as the app would, and prints its height as the reply streams in.
    /// Actions that need the user's OK are denied (set SHHH_ALLOW=1 to allow them).
    @MainActor
    private static func ask(_ requests: [String]) {
        var requests = requests
        let start = Date()
        var lastHeight: CGFloat = 0
        panel.onClose = { exit(0) }
        panel.reset()
        assistant.prepare { event in
            panel.update(event)
            switch event {
            case .status(let status?): print(String(format: "[%.1fs] %@", Date().timeIntervalSince(start), status))
            case .failed(let message): fail("Error: \(message)")
            case .didAct(let action): print(String(format: "[%.1fs] Did: %@", Date().timeIntervalSince(start), action))
            case .approval(let approval?):
                // Denied unless SHHH_ALLOW=1, so a test can't send or change anything by accident.
                let allow = ProcessInfo.processInfo.environment["SHHH_ALLOW"] == "1"
                print("Wants to: \(approval.title)\n\(approval.detail)\n→ \(allow ? "allowed" : "denied")")
                approval.decide(allow ? .allow : .deny)
            case .turnFinished where requests.count > 1:
                requests.removeFirst()
                print(String(format: "[%.1fs] Reply: %@\n[%.1fs] Follow-up: %@", Date().timeIntervalSince(start),
                             panel.answer, Date().timeIntervalSince(start), requests[0]))
                panel.beginTurn(question: requests[0])
                assistant.ask(requests[0])
            case .turnFinished:
                // Give the card a moment to settle before the final measurement.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        print(String(format: "[%.1fs] Reply: %@\nDone. Card %.0f pt tall (top at y=%.0f), content needs %.0f pt",
                                     Date().timeIntervalSince(start), panel.answer, panel.frame.height, panel.frame.maxY, panel.contentHeight))
                        exit(0)
                    }
                }
            default: break
            }
            if panel.frame.height != lastHeight {
                lastHeight = panel.frame.height
                print(String(format: "[%.1fs] card height %.0f", Date().timeIntervalSince(start), lastHeight))
            }
        }
        panel.beginTurn(question: requests[0])
        // SHHH_IMAGE=<jpeg> stands in for the screenshot the app would take.
        let image = ProcessInfo.processInfo.environment["SHHH_IMAGE"].flatMap { FileManager.default.contents(atPath: $0) }
        assistant.ask(requests[0], screenshot: ScreenCapture.isAbout(requests[0]) ? image : nil)
    }

    private static func run(_ work: @escaping () async throws -> Void) -> Never {
        Task {
            do {
                try await work()
                exit(0)
            } catch {
                fail("Error: \(error.localizedDescription)")
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
