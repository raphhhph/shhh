import AppKit
import Foundation

/// Getting Claude ready without Terminal: one button installs Claude Code (Anthropic's own
/// installer, no Homebrew or Node), runs its sign-in in the browser, takes the code the page shows
/// if it asks for one, and checks it worked. Like Plip's "Connect".
@MainActor
final class ClaudeSetup: ObservableObject {
    enum State: Equatable {
        case checking, notInstalled, signedOut, installing, signingIn, ready
        case failed(String)
    }

    @Published private(set) var state = State.checking
    /// The sign-in page asked for a code to paste back.
    @Published private(set) var needsCode = false
    @Published private(set) var detail = ""

    private var login: Process?
    private var input: Pipe?

    init() { Task { await refresh() } }

    var isReady: Bool { state == .ready }

    func refresh() async {
        guard let claude = Assistant.executable else { state = .notInstalled; return }
        let output = await Self.run(claude.path, ["auth", "status"])
        let signedIn = output.range(of: #""loggedIn"\s*:\s*true"#, options: .regularExpression) != nil
        if state != .installing, state != .signingIn { state = signedIn ? .ready : .signedOut }
        else if signedIn { finish() }
    }

    /// Install if needed, then sign in.
    func connect() {
        Task {
            if Assistant.executable == nil {
                state = .installing
                detail = "Installing Claude Code… (about a minute)"
                let output = await Self.run("/bin/bash", ["-c", "set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash"])
                guard Assistant.executable != nil else {
                    state = .failed("Couldn't install Claude Code. Check the internet (a VPN in mainland China) and try again.\n" + output.suffix(200))
                    return
                }
            }
            await refresh()
            if state != .ready { signIn() }
        }
    }

    private func signIn() {
        guard let claude = Assistant.executable else { return }
        login?.terminate()
        state = .signingIn
        needsCode = false
        detail = "Finish signing in to Claude in your browser…"
        let process = Process()
        process.executableURL = claude
        process.arguments = ["auth", "login", "--claudeai"]
        process.environment = Session.environment()
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input
        var opened = false
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Its sign-in link, in case it didn't open the browser itself.
                    if !opened, let range = text.range(of: #"https://\S+"#, options: .regularExpression),
                       let url = URL(string: String(text[range])) {
                        opened = true
                        NSWorkspace.shared.open(url)
                    }
                    if text.range(of: "code", options: .caseInsensitive) != nil, text.range(of: "paste", options: .caseInsensitive) != nil {
                        self.needsCode = true
                        self.detail = "Copy the code the Claude page shows, and paste it here."
                    }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        do { try process.run() } catch {
            state = .failed("Couldn't start the sign-in: \(error.localizedDescription)")
            return
        }
        login = process
        self.input = input
        // Checks every few seconds, for sign-ins that finish in the browser alone.
        Task {
            for _ in 0..<180 where state == .signingIn {
                try? await Task.sleep(for: .seconds(2))
                await refresh()
            }
        }
    }

    func send(code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let input else { return }
        input.fileHandleForWriting.write(Data((code + "\n").utf8))
        detail = "Checking the code…"
    }

    private func finish() {
        login?.terminate()
        login = nil
        input = nil
        needsCode = false
        state = .ready
        detail = ""
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.environment = Session.environment()
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                guard (try? process.run()) != nil else { continuation.resume(returning: ""); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
