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
      Shhh --transcribe <audio-file>
      Shhh --clean "<text>"
      Shhh --style <veryFormal|casual|veryCasual> "<text>"
      Shhh --microphones
      Shhh --record <seconds>
      Shhh --ask "<request>" ["<follow-up>" …]
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
            guard let seconds = Double(args[1]) else { fail("Usage: Shhh --record <seconds>") }
            run { try await record(seconds: seconds) }
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

    @MainActor private static let panel = AnswerPanel()
    @MainActor private static let assistant = Assistant()

    /// Shows the answer card as the app would, and prints its height as the reply streams in.
    /// Actions that need the user's OK are denied (set SHHH_ALLOW=1 to allow them).
    @MainActor
    private static func ask(_ requests: [String]) {
        var requests = requests
        let start = Date()
        var lastHeight: CGFloat = 0
        panel.onClose = { exit(0) }
        panel.reset()
        assistant.prepare(depth: .quick) { event in
            panel.update(event)
            switch event {
            case .status(let status?): print(String(format: "[%.1fs] %@", Date().timeIntervalSince(start), status))
            case .failed(let message): fail("Error: \(message)")
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
                        print(String(format: "[%.1fs] Reply: %@\nDone. Card %.0f pt tall, content needs %.0f pt",
                                     Date().timeIntervalSince(start), panel.answer, panel.frame.height, panel.contentHeight))
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
        assistant.ask(requests[0])
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
