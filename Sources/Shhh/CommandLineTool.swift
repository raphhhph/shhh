import AVFoundation
import FluidAudio
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
        case ("--denoise", 3):
            // Joe --denoise in.wav out.wav: the noise filter on a file, for testing it.
            run {
                let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(URL(fileURLWithPath: args[1]))
                let cleaned = await NoiseFilter.shared.clean(samples)
                let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(cleaned.count))!
                buffer.frameLength = AVAudioFrameCount(cleaned.count)
                cleaned.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: cleaned.count) }
                let file = try AVAudioFile(forWriting: URL(fileURLWithPath: args[2]), settings: format.settings)
                try file.write(from: buffer)
                print(cleaned == samples ? "Unchanged (filter not ready or off)." : "Cleaned: \(args[2])")
            }
        case ("--transcribe", 2...):
            run { try await transcribe(files: Array(args.dropFirst())) }
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
            let engine = args.count > 2 ? SpeechOutput.Engine(rawValue: args[2]) ?? .lifelike : .lifelike
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
                case let .add(alarm)?: print("Set: \(alarm.kind.rawValue) \(alarm.fireAt.formatted(.dateTime.weekday(.abbreviated).hour().minute().second())) “\(alarm.title)” · \(text)")
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
            for text in args.dropFirst() { print(Spotify.command(in: text).map { "Spotify: \($0)" } ?? "→ Claude", "·", text) }
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
        case ("--voice-similarity", 3...):
            // Joe --voice-similarity a.wav b.wav …: how alike the voices sound (CAM++), for tuning.
            run {
                guard let model = try? await CampPlusEmbedder.load() else { print("Couldn't load the voice model."); return }
                let files = Array(args.dropFirst())
                var embeddings: [[Float]] = []
                for file in files { embeddings.append((try? await model.embed(audioURL: URL(fileURLWithPath: file))) ?? []) }
                for i in 0..<files.count { for j in (i + 1)..<files.count where !embeddings[i].isEmpty && !embeddings[j].isEmpty {
                    let score = zip(embeddings[i], embeddings[j]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    print(String(format: "%.3f  %@ ~ %@", score, (files[i] as NSString).lastPathComponent, (files[j] as NSString).lastPathComponent))
                } }
            }
        case ("--speakers", 2):
            // Joe --speakers file.wav: who speaks when (the notepad's speaker labels), for tuning.
            run {
                let samples = (try? AudioConverter(sampleRate: 16_000).resampleAudioFile(URL(fileURLWithPath: args[1]))) ?? []
                for turn in await SpeakerTracker().split(samples) {
                    print(String(format: "%@  %.1f s", turn.label, Double(turn.samples.count) / 16_000))
                }
            }
        case ("--math-pdf", 2...):
            // Joe --math-pdf <spec.json> [out.pdf]: worked maths solutions, typeset.
            MainActor.assumeIsolated { MathDoc.run(Array(args.dropFirst())) }
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApplication.shared.run()
        case ("--whatsapp", 2...):
            // Joe --whatsapp chats | unread | read "<chat>" [n] | search "<text>": read-only.
            print(WhatsAppLog.run(Array(args.dropFirst())))
            exit(0)
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
        case ("--snapshot", 3...):
            // Joe --snapshot <page> <file.png> [width height] [dark]: a dashboard page, drawn off screen.
            guard let page = DashboardModel.Page(rawValue: args[1]) else { fail("Pages: " + DashboardModel.Page.allCases.map(\.rawValue).joined(separator: ", ")) }
            let size = args.count > 4 ? NSSize(width: Double(args[3]) ?? 1080, height: Double(args[4]) ?? 720) : NSSize(width: 1080, height: 720)
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.accessory)
                Dashboard.snapshot(page: page, to: URL(fileURLWithPath: args[2]), size: size, dark: args.last == "dark") { exit(0) }
            }
            NSApplication.shared.run()
            exit(0)
        case ("--alarm-preview", 2...):
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.accessory)
                AlarmClock.preview(to: URL(fileURLWithPath: args[1]), missed: args.count > 2) { exit(0) }
            }
            NSApplication.shared.run()
            exit(0)
        case ("--calendar-link", 2...):
            // Joe --calendar-link add <link> | remove <link> | list | refresh | parse <file.ics>
            switch args[1] {
            case "add" where args.count > 2: CalendarFeed.links = Array(Set(CalendarFeed.links + [args[2]]))
            case "remove" where args.count > 2: CalendarFeed.links.removeAll { $0 == args[2] }
            case "parse" where args.count > 2:
                let text = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
                for item in CalendarFeed.parseICS(text, deadlines: true) { print(item) }
                exit(0)
            default: break
            }
            if args[1] == "list" { print(CalendarFeed.links.joined(separator: "\n")); exit(0) }
            run { print(await CalendarFeed.refreshLinks()) }
        case ("--prompt", 2...3) where ["brief", "shutdown", "sunday"].contains(args[1]):
            // Joe --prompt brief|shutdown|sunday [<vault>]: the study lines Joe adds to the morning brief,
            // the night shutdown's study steps, or the Sunday week-plan card (nothing is written).
            if args.count > 2 { useFolder(args[2]) }
            switch args[1] {
            case "brief":
                let facts = StudyLoop.briefFacts()
                print(facts.isEmpty ? "(no study lines today: nothing overdue, no Plan, no milestone this week)" : facts)
            case "shutdown":
                print(StudyLoop.shutdownSteps())
            default:
                let calendar = Calendar.current
                let monday = calendar.nextDate(after: Date(), matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? Date()
                let reply = StudyLoop.weekReply(WeekPlan.text(from: monday), sunday: true)
                print("\(reply.subject)\n\(reply.card)\n\nSpoken: \(reply.spoken)")
            }
            exit(0)
        case ("--local", 2...3):
            // Joe --local "<request>" [<vault>]: does a local study request ("start my EE", "plan my week", "done
            // with Paper 2", "how's my EE going") as Joe would, and prints the card. It writes, like the real
            // thing, so give a copy of the vault to test on.
            if args.count > 2 { useFolder(args[2]) }
            guard let intent = StudyIntent.parse(args[1]) else { print("Not a local study request: it goes to Claude."); exit(0) }
            guard let reply = intent.run() else { print("\(intent.route): couldn't settle it here, so it goes to Claude."); exit(0) }
            print("\(intent.route)\n\(reply.subject)\n\(reply.card)\n\nSpoken: \(reply.spoken)")
            exit(0)
        case ("--focus-preview", 2...3):
            // Joe --focus-preview "<request>" [<vault>]: what a focus request would start (title, minutes, the Plan
            // block, whether the "Joe Focus On" shortcut exists, the music), without starting anything.
            if args.count > 2 { useFolder(args[2]) }
            print(FocusPlan.preview(args[1]))
            exit(0)
        case ("--mark-done", 2...3):
            // Joe --mark-done "<title>" [<vault>]: ticks it in the Daybook, Week.md and its project milestone, and adds it to Done.md.
            if args.count > 2 { useFolder(args[2]) }
            let title = StudyLoop.resolve(args[1]) ?? args[1]
            print("Ticked \(title): " + StudyLoop.markDone(title).joined(separator: ", "))
            exit(0)
        case ("--week-replan", 1...2):
            // Joe --week-replan [<vault>]: the night shutdown's re-plan: today's unticked blocks that are over (and
            // earlier days') move to free slots later this week. Prints what moved and tomorrow's first block.
            if args.count > 1 { useFolder(args[1]) }
            print(StudyLoop.replanTonight())
            exit(0)
        case ("--prompt", 2):
            // Joe --prompt "<dictation ending in make it a prompt>": what would be typed.
            guard let said = PromptPolish.request(in: args[1]) else { print("(no \"make it a prompt\" at the end)"); exit(0) }
            run { print(await PromptPolish.polish(said)) }
        case ("--onboarding-snapshot", 3):
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.accessory)
                Onboarding.snapshot(step: args[1], to: URL(fileURLWithPath: args[2])) { exit(0) }
            }
            NSApplication.shared.run()
            exit(0)
        case ("--route", 2...):
            // Joe --route "<request>"…: what each request would do (testing the routing).
            for request in args.dropFirst() {
                var route = MainActor.assumeIsolated { Assistant.needsStrongModel(request) } ? "Claude (Opus)" : "Claude (Haiku)"
                if AlarmRequest.parse(request) != nil { route = "alarm" }
                else if let focus = FocusRequest.parse(request) { route = focus.route }
                else if Spotify.command(in: request) != nil { route = "Spotify" }
                else if PromptPolish.request(in: request) != nil { route = "prompt rewrite (dictation)" }
                else if let intent = StudyIntent.parse(request) { route = intent.route }
                print("\(route.padding(toLength: 26, withPad: " ", startingAt: 0)) \(request)")
            }
            exit(0)
        case ("--board-preview", 2...):
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.accessory)
                StudyBoard.preview(to: URL(fileURLWithPath: args[1]), sketch: args.count > 2) { exit(0) }
            }
            NSApplication.shared.run()
            exit(0)
        case ("--memory-test", 1):
            // Joe --memory-test: memory after loading each model in turn.
            run {
                func footprint() -> Int {
                    var info = task_vm_info_data_t()
                    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
                    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
                    return Int(info.phys_footprint) / 1_048_576
                }
                print("start: \(footprint()) MB")
                // English and Chinese, as Joe runs it: Parakeet first, then SenseVoice, then Parakeet goes.
                Transcriber.languages = .chinese
                let both = Transcriber()
                try await both.load { _ in }
                print("+ English speech (Parakeet, while Chinese loads): \(footprint()) MB")
                for _ in 0..<600 where !(await both.chineseReady) { try await Task.sleep(for: .milliseconds(100)) }
                try await Task.sleep(for: .seconds(2))
                print("+ Chinese speech (SenseVoice), Parakeet let go: \(footprint()) MB")
                await NoiseFilter.shared.prepare()
                try await Task.sleep(for: .seconds(3))
                print("+ noise filter: \(footprint()) MB")
                let speech = await SpeechOutput()
                _ = await speech.prepareNow(.lifelike)
                print("+ Alba voice (PocketTTS): \(footprint()) MB")
            }
        case ("--overview-preview", 2):
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.accessory)
                let model = DashboardModel(actions: .init(ask: { _ in }, askInBackground: { _ in }, status: { "" }, setVoice: { _ in },
                    setNotch: { _ in }, setCleanup: { _ in }, setScreenControl: { _ in }, chooseVault: {}, showOnboarding: {},
                    openNotepad: {}, microphones: { [] }, setSpeechLanguages: { _ in }, cancelAlarm: { _ in }, addAlarm: { _ in }))
                let overview = NotchOverview(data: model)
                overview.preview(to: URL(fileURLWithPath: args[1])) { _ = overview; exit(0) }
            }
            NSApplication.shared.run()
            exit(0)
        case ("--challenge", 1...):
            // Joe --challenge [seed] ["what I said"]: a wake-up challenge, and whether that answer passes.
            let seed = args.count > 1 ? Int(args[1]) ?? 0 : 0
            let challenge = MainActor.assumeIsolated { WakeChallenge.today(seed: seed) }
            print("\(challenge.kind.rawValue) · \(challenge.source)\n\(challenge.prompt)\nanswers: \(challenge.answers)")
            if args.count > 2 { print(challenge.check(args[2]) ? "PASS" : "FAIL") }
            exit(0)
        case ("--speech-parts", 2):
            // Joe --speech-parts "<text>": which voice says which part.
            for part in SpeechOutput.hasHan(args[1]) ? SpeechOutput.chineseParts(args[1]) : [args[1]] {
                print(SpeechOutput.isChinese(part) ? "Mandarin: " + part : SpeechOutput.isOtherLanguage(part) ? "Mac voice: " + part : "Alba: " + part)
            }
            exit(0)
        case ("--study", 3...):
            // Joe --study "<subject>" "<request>" ["<answer>" …]: a whiteboard session, without the window.
            MainActor.assumeIsolated { study(subject: args[1], turns: Array(args.dropFirst(2))) }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
            exit(0)
        case ("--system-prompt", 1):
            // Joe --system-prompt: what Claude is told before every conversation.
            MainActor.assumeIsolated { print(Session.currentSystemPrompt()) }
            exit(0)
        case ("--daybook", 1):
            // Shhh --daybook: what the assistant is told about the user's day.
            print(Daybook.instructions)
            print("\n--- If it had to build today's:\n" + Daybook.buildRules)
            exit(0)
        case ("--timetable-import", 2...):
            // Joe --timetable-import <photo or pdf> ["Day 3"]: reads a timetable and saves timetable.json.
            let file = URL(fileURLWithPath: args[1])
            run { print(await Daybook.importTimetable(from: file, dayToday: args.count > 2 ? args[2] : nil)) }
        case ("--daybook-preview", 1...3):
            // Joe --daybook-preview [<vault>] [yyyy-mm-dd]: the Daybook Joe would build this morning by
            // himself, from that vault and for that day (nothing is written).
            var day = Date()
            for arg in args.dropFirst() {
                if let date = IBProjects.isoDate(arg), arg.count == 10 {
                    if !Calendar.current.isDateInToday(date) { day = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: date) ?? date }
                } else {
                    useFolder(arg)
                }
            }
            print(Daybook.localText(day) ?? "No notes vault set.")
            exit(0)
        case ("--classify", 1...2):
            // Joe --classify [<vault>]: each deadline of the next two weeks as an exam (sat in class,
            // gets revision blocks), take-home (gets work blocks) or an errand (gets none).
            if args.count > 1 { useFolder(args[1]) }
            for item in CalendarFeed.items(from: Calendar.current.startOfDay(for: Date()), days: 14) where item.kind == .deadline {
                let kind = Assessment.needsStudy(item) ? Assessment.kind(item).rawValue : "errand"
                print("\(kind.padding(toLength: 9, withPad: " ", startingAt: 0)) \(Daybook.when(item, Date())) · \(item.title)" + (item.subject.map { " · \($0)" } ?? ""))
            }
            exit(0)
        case ("--projects", 1...2):
            // Joe --projects [<vault or School folder>]: each IB project's progress, and what it adds to today's Daybook.
            if args.count > 1 { useFolder(args[1]) }
            print(IBProjects.report())
            exit(0)
        case ("--project-new", 2...5):
            // Joe --project-new <ee|ia|tok-essay|tok-exhibition|io|cas> ["<subject>"] [yyyy-mm-dd] ["<supervisor>"]:
            // makes the project's note from its template (or finds the one already there).
            guard let kind = IBProjects.Kind(loose: args[1]) else { fail("Kinds: ee, ia, tok-essay, tok-exhibition, io, cas") }
            var subject = "", supervisor = ""
            var finalDate: Date?
            for arg in args.dropFirst(2) {
                if let date = IBProjects.isoDate(arg), arg.count == 10 { finalDate = date }
                else if subject.isEmpty { subject = arg } else { supervisor = arg }
            }
            guard let url = IBProjects.create(kind, subject: subject, finalDate: finalDate, supervisor: supervisor),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { fail("Couldn't make the note: is the notes vault set?") }
            print(url.path)
            print(text)
            exit(0)
        case ("--week-preview", 1...2):
            // Joe --week-preview [<vault>]: the week plan Joe would write from today, and what a re-plan
            // of the saved Week.md would move (nothing is written).
            if args.count > 1 { useFolder(args[1]) }
            print(WeekPlan.text(from: Date()))
            if let url = WeekPlan.url, let saved = try? String(contentsOf: url, encoding: .utf8) {
                let moves = WeekPlan.replanned(saved)?.moves ?? []
                print("--- Re-plan of the saved \(url.lastPathComponent): " + (moves.isEmpty ? "nothing to move." : "\n" + moves.joined(separator: "\n")))
            }
            exit(0)
        case ("--week-plan", 1):
            // Joe --week-plan: writes Daybook/Week.md for the seven days from today (for "plan my week").
            guard let url = WeekPlan.build(), let text = try? String(contentsOf: url, encoding: .utf8) else { fail("No notes vault set.") }
            print("Wrote \(url.path)\n")
            print(text)
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

    /// Points the Daybook, projects and week plan at a folder given on the command line: a vault (its
    /// Brain folder is used when it has one), a Brain folder, or a School folder.
    private static func useFolder(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let manager = FileManager.default
        let brain = url.appendingPathComponent("Brain", isDirectory: true)
        if manager.fileExists(atPath: brain.path) {
            Daybook.rootOverride = brain
        } else if url.lastPathComponent == "School" {
            Daybook.rootOverride = url.deletingLastPathComponent()
        } else {
            Daybook.rootOverride = url
            let projects = url.appendingPathComponent("Projects", isDirectory: true)
            if !manager.fileExists(atPath: url.appendingPathComponent("School").path), manager.fileExists(atPath: projects.path) {
                IBProjects.folderOverride = projects
            }
        }
        Daybook.timetableChanged()
    }

    private static func transcribe(files: [String]) async throws {
        let transcriber = Transcriber()
        let loading = Date()
        try await transcriber.load { _ in }
        if Transcriber.languages == .chinese {
            for _ in 0..<1200 where !(await transcriber.chineseReady) { try await Task.sleep(for: .milliseconds(100)) }
            print(String(format: "(Chinese ready %.1fs after loading began)", Date().timeIntervalSince(loading)))
        }
        for file in files { // several: the later ones show the warm speed
            let start = Date()
            let text = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: file))
            print(String(format: "[%.2fs] %@", Date().timeIntervalSince(start), text))
        }
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
    @MainActor private static let board = StudyBoardModel()

    @MainActor private static func study(subject: String, turns: [String]) {
        var turns = turns
        let start = Date()
        var printed = 0
        board.readAloud = false
        var check: Timer?
        check = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !board.isBusy else { return }
                for item in board.items.dropFirst(printed) { print(String(format: "[%.1fs] ", Date().timeIntervalSince(start)) + "\(item)") }
                printed = board.items.count
                guard turns.count > 0 else { check?.invalidate(); exit(0) }
                let next = turns.removeFirst()
                if printed == 0 { board.start(subject: subject, request: next, mode: next.lowercased().contains("exam") ? .exam : .quiz) }
                else if next.hasPrefix("@"), let image = FileManager.default.contents(atPath: String(next.dropFirst())) { board.submit("", image: image) }
                else { board.submit(next) }
                printed = board.items.count
            }
        }
    }

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
