import AppKit

/// Joe on a ChatGPT plan: one `codex app-server` process (OpenAI's Codex CLI, signed in with
/// ChatGPT), talking JSON-RPC lines over stdin and stdout. It does what `Session` does for Claude
/// Code: streams the reply, keeps the conversation open for follow-ups, and sends every action
/// Codex wants approved through Joe's `ToolPolicy` and approval card.
///
/// Codex has no Chrome control, and the user's Claude connectors aren't in Codex's settings, so
/// those aren't available in this mode. Commands Codex knows are read-only (ls, cat, grep…) run
/// without asking it, so they never reach Joe either.
@MainActor
final class CodexSession: Engine {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let onEvent: @MainActor (Assistant.Event) -> Void
    private(set) var launchError: String?
    private var stopped = false
    private var buffer = Data()
    private var outputEnded = false
    private var exitStatus: Int32?

    private let policy: ToolPolicy
    private let folder: URL
    private let instructions: String
    private let effort: String
    private var modelName = "chatgpt"

    // JSON-RPC: our request IDs, and the conversation once Codex has started it.
    private var nextID = 1
    private var waiting: [Int: String] = [:] // request ID → method
    private var threadID: String?
    /// A request sent before the conversation was ready goes as soon as it is.
    private var queued: (text: String, screenshot: Data?)?

    private var turnDone = true
    private var turnStarted = Date()
    private var requestsSent = 0
    private var lastSent = ""
    // The reply is the text of Codex's last message; earlier ones lead up to a command.
    private var answer = ""
    private var answerItem: String?
    private var turnError: String?
    private var usage: [String: Any] = [:]
    private var lastAction: String?
    private var plan: [Assistant.PlanStep] = []
    /// File changes by item ID: their approval request names only the item.
    private var fileChanges: [String: [String]] = [:]
    // Actions waiting for the user's OK, shown one at a time.
    private var pending: [(id: Any, tool: String, action: ToolPolicy.Action, input: [String: Any])] = []
    private var allowedForTask: Set<String> = []

    var isRunning: Bool { !stopped && process.isRunning }

    /// Where `codex` is installed (npm, Homebrew or OpenAI's installer).
    nonisolated static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                "\(home)/.npm-global/bin/codex", "\(home)/.codex/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    init(executable: URL, model: Assistant.Model? = nil, effort: Assistant.Effort? = nil, tutor: String? = nil,
         onEvent: @escaping @MainActor (Assistant.Event) -> Void) {
        self.onEvent = onEvent
        let vault = Assistant.vaultURL
        let notes = Instructions(vault: vault)
        let autonomy = Assistant.autonomy
        let chosen = effort ?? Assistant.effort
        policy = ToolPolicy(vault: vault, readOnly: notes.readOnly, allowedCommands: notes.allowedCommands, autonomy: autonomy)
        instructions = tutor ?? Session.systemPrompt(chosen, autonomy: autonomy, instructions: notes.text, vault: vault) + Self.codexNotes
        // Codex picks the model (the ChatGPT plan's default, or the one set in Settings); Joe's
        // model choice becomes how hard it thinks. Haiku means quick; "Opus for big jobs" comes
        // with its own effort.
        self.effort = model == nil && Assistant.model == .haiku ? "low" : (chosen == .max ? "xhigh" : chosen.rawValue)
        folder = vault ?? FileManager.default.temporaryDirectory.appendingPathComponent("shhh-ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        signal(SIGPIPE, SIG_IGN)
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = Self.environment()
        process.currentDirectoryURL = folder
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data) }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exited(status) }
            }
        }

        do {
            try process.run()
        } catch {
            stopped = true
            launchError = "Couldn't start Codex: \(error.localizedDescription)"
            return
        }
        request("initialize", ["clientInfo": ["name": "joe", "title": "Joe", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"]])
    }

    /// Added to Joe's instructions: they're written for Claude Code's tools.
    private static let codexNotes = """


        You're running in Codex on the user's ChatGPT plan. Where these instructions name Claude \
        Code tools, use your own: shell commands for Bash, reading with cat or rg, apply_patch for \
        Edit and Write, your web search for WebSearch and WebFetch. There's no Chrome control and \
        no clicking or typing on the screen in this mode: if a request needs either, say they can \
        switch Joe to Claude in Settings → Advanced → AI.
        """

    /// The user's settings, without API keys that would bill per request instead of the plan.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !["OPENAI_API_KEY", "CODEX_API_KEY", "CLAUDECODE"].contains(key) && !key.hasPrefix("CLAUDE_CODE_")
        }
        // npm's codex is a Node script, and Finder-launched apps get a bare PATH.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return environment
    }

    func send(_ request: String, screenshot: Data?) {
        guard isRunning else { return }
        answer = ""
        answerItem = nil
        turnError = nil
        lastAction = nil
        turnDone = false
        turnStarted = Date()
        onEvent(.status("Thinking…"))
        guard threadID != nil else {
            queued = (request, screenshot)
            return
        }
        startTurn(request, screenshot: screenshot)
    }

    private func startTurn(_ request: String, screenshot: Data?) {
        guard let threadID else { return }
        requestsSent += 1
        lastSent = request
        let sent = Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().second())
        var text = request + "\n\n(Sent \(sent), \(TimeZone.current.identifier).)"
        if requestsSent == 1 {
            let recent = Daybook.recentRequests
            if !recent.isEmpty { text = "<context>\n\(recent)\n</context>\n\n" + text }
        }
        var items: [[String: Any]] = [["type": "text", "text": text]]
        if let screenshot {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("joe-screen-\(UUID().uuidString).jpg")
            if (try? screenshot.write(to: file)) != nil { items.insert(["type": "localImage", "path": file.path], at: 0) }
        }
        self.request("turn/start", ["threadId": threadID, "input": items, "effort": effort])
    }

    func stop() {
        stopped = true
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    // MARK: - JSON-RPC

    private func request(_ method: String, _ params: [String: Any]) {
        let id = nextID
        nextID += 1
        waiting[id] = method
        write(["method": method, "id": id, "params": params])
    }

    private func write(_ message: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: message) else { return }
        line.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: line)
    }

    private func receive(_ data: Data) {
        guard !stopped else { return }
        if data.isEmpty {
            outputEnded = true
            checkExit()
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !stopped, let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(json)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        let params = message["params"] as? [String: Any] ?? [:]
        let id: Any? = message["id"].flatMap { $0 is NSNull ? nil : Optional($0) }
        if let method = message["method"] as? String {
            if let id { serverRequest(method, id: id, params) } else { notification(method, params) }
        } else if let id = id as? Int {
            response(to: waiting.removeValue(forKey: id), message)
        }
    }

    private func response(to method: String?, _ message: [String: Any]) {
        if let error = message["error"] as? [String: Any] {
            let text = Self.explain(error["message"] as? String ?? "Codex refused the request.")
            if threadID == nil { // it couldn't start: the next request says why
                launchError = text
                let waitingRequest = !turnDone
                stop()
                if waitingRequest { fail(text) }
            } else if method == "turn/start" {
                fail(text)
            }
            return
        }
        let result = message["result"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            write(["method": "initialized"])
            var params: [String: Any] = [
                "cwd": folder.path,
                // Codex asks before anything it doesn't know is read-only, and Joe's rules answer.
                // No sandbox, like Claude Code: the rules and the approval card are the guard.
                "approvalPolicy": "untrusted",
                "sandbox": "danger-full-access",
                "developerInstructions": instructions,
                "ephemeral": true,
                "config": ["web_search": "live"],
            ]
            if let model = AIAccount.chatGPTModel { params["model"] = model }
            request("thread/start", params)
        case "thread/start":
            threadID = (result["thread"] as? [String: Any])?["id"] as? String
            if let model = result["model"] as? String { modelName = "chatgpt:" + model }
            if let queued {
                self.queued = nil
                startTurn(queued.text, screenshot: queued.screenshot)
            }
        default:
            break
        }
    }

    private func notification(_ method: String, _ params: [String: Any]) {
        switch method {
        case "item/agentMessage/delta":
            let item = params["itemId"] as? String
            if item != answerItem { answer = ""; answerItem = item } // a new message: the last one led up to a command
            answer += params["delta"] as? String ?? ""
            onEvent(.status(nil))
            onEvent(.answer(StudyBuddy.withoutMarks(answer)))
        case "item/started":
            started(params["item"] as? [String: Any] ?? [:])
        case "item/completed":
            completed(params["item"] as? [String: Any] ?? [:])
        case "turn/plan/updated":
            let steps = params["plan"] as? [[String: Any]] ?? []
            plan = steps.compactMap { step in
                let state: Assistant.PlanStep.State = switch step["status"] as? String ?? "" {
                case "inProgress": .inProgress
                case "completed": .completed
                default: .pending
                }
                return (step["step"] as? String).map { Assistant.PlanStep(text: $0, state: state) }
            }
            onEvent(.plan(plan))
        case "thread/tokenUsage/updated":
            usage = ((params["tokenUsage"] as? [String: Any])?["last"] as? [String: Any]) ?? usage
        case "error":
            if params["willRetry"] as? Bool != true {
                turnError = ((params["error"] as? [String: Any])?["message"] as? String) ?? turnError
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            recordUsage()
            switch turn["status"] as? String {
            case "failed":
                let message = ((turn["error"] as? [String: Any])?["message"] as? String) ?? turnError ?? ""
                fail(Self.explain(message))
            default:
                finishTurn()
            }
        default:
            break
        }
    }

    private func started(_ item: [String: Any]) {
        switch item["type"] as? String {
        case "reasoning":
            onEvent(.status("Thinking…"))
        case "commandExecution":
            let command = Self.unwrap(item["command"] as? String ?? "")
            if updatePlan(command) { return }
            onEvent(.status(Session.describe(tool: "Bash", input: ["command": command])))
        case "fileChange":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            if let id = item["id"] as? String { fileChanges[id] = paths }
            onEvent(.status(Session.describe(tool: "Edit", input: paths.first.map { ["file_path": $0] } ?? [:])))
        case "mcpToolCall":
            let tool = "mcp__\(item["server"] as? String ?? "")__\(item["tool"] as? String ?? "")"
            onEvent(.status(Session.describe(tool: tool, input: item["arguments"] as? [String: Any] ?? [:])))
        case "webSearch":
            onEvent(.status(Session.describe(tool: "WebSearch", input: (item["query"] as? String).map { ["query": $0] } ?? [:])))
        default:
            break
        }
    }

    private func completed(_ item: [String: Any]) {
        switch item["type"] as? String {
        case "agentMessage":
            // The whole message, in case a delta was missed.
            if let text = item["text"] as? String, !text.isEmpty, item["id"] as? String == answerItem || answerItem == nil {
                answer = text
                onEvent(.answer(StudyBuddy.withoutMarks(text)))
            }
        case "fileChange" where item["status"] as? String == "completed":
            lastAction = Session.actionLabel("Edit")
        case "mcpToolCall" where item["error"] == nil || item["error"] is NSNull:
            let tool = "mcp__\(item["server"] as? String ?? "")__\(item["tool"] as? String ?? "")"
            if let label = Session.actionLabel(tool) { lastAction = label }
        default:
            break
        }
    }

    /// `Joe --plan …`, as in `Session`: Joe's own checklist at the notch.
    private func updatePlan(_ command: String) -> Bool {
        guard let words = ToolPolicy.shellWords(command), words.count >= 3,
              words[0] == Bundle.main.executablePath, words[1] == "--plan" else { return false }
        let rest = Array(words.dropFirst(2))
        if rest.count == 1, let number = Int(rest[0]) {
            plan = plan.enumerated().map { index, step in
                Assistant.PlanStep(text: step.text, state: index + 1 < number ? .completed : index + 1 == number ? .inProgress : .pending)
            }
        } else if rest == ["done"] {
            plan = plan.map { Assistant.PlanStep(text: $0.text, state: .completed) }
        } else {
            plan = rest.enumerated().map { Assistant.PlanStep(text: $1, state: $0 == 0 ? .inProgress : .pending) }
        }
        onEvent(.plan(plan))
        onEvent(.status("Working…"))
        return true
    }

    /// Codex runs commands through the login shell: `/bin/zsh -lc 'ls ~/Desktop'` → `ls ~/Desktop`.
    private static func unwrap(_ command: String) -> String {
        guard let words = ToolPolicy.shellWords(command), words.count == 3,
              words[0].hasSuffix("sh"), ["-lc", "-c"].contains(words[1]) else { return command }
        return words[2]
    }

    private func recordUsage() {
        var total = 0.0 // the plan's own limits, not dollars
        UsageLog.record(["total_cost_usd": 0.0, "usage": [
            "input_tokens": (usage["inputTokens"] as? Int ?? 0) - (usage["cachedInputTokens"] as? Int ?? 0),
            "output_tokens": usage["outputTokens"] as? Int ?? 0,
            "cache_read_input_tokens": usage["cachedInputTokens"] as? Int ?? 0,
        ]], model: modelName, request: lastSent, total: &total)
        usage = [:]
    }

    private func finishTurn() {
        guard !turnDone else { return }
        turnDone = true
        pending = []
        if answer.contains("<mark") { _ = StudyBuddy.record(answer) }
        ScreenControl.shared.ended()
        onEvent(.approval(nil))
        onEvent(.status(nil))
        if let lastAction { onEvent(.didAct(lastAction)) }
        onEvent(.turnFinished)
        if Date().timeIntervalSince(turnStarted) > 20 { NSSound(named: "Glass")?.play() }
    }

    private func fail(_ message: String) {
        guard !turnDone else { return }
        turnDone = true
        pending = []
        onEvent(.approval(nil))
        onEvent(.failed(message))
    }

    private func exited(_ status: Int32) {
        exitStatus = status
        checkExit()
    }

    private func checkExit() {
        guard outputEnded, let exitStatus, !stopped else { return }
        stopped = true
        guard !turnDone else { return }
        turnDone = true
        onEvent(.approval(nil))
        onEvent(.failed("Codex stopped unexpectedly (exit code \(exitStatus))."))
    }

    // MARK: - Permissions

    /// Codex asks before running a command or changing files. Anything else it asks the client
    /// (a connector's question, more permissions) is declined: Joe has no card for it yet.
    private func serverRequest(_ method: String, id: Any, _ params: [String: Any]) {
        let tool: String
        var input: [String: Any]
        switch method {
        case "item/commandExecution/requestApproval":
            tool = "Bash"
            input = ["command": Self.unwrap(params["command"] as? String ?? "")]
            if let reason = params["reason"] as? String { input["description"] = reason }
        case "item/fileChange/requestApproval":
            let paths = (params["itemId"] as? String).flatMap { fileChanges[$0] } ?? []
            // The strictest rule of the files it changes.
            let actions = paths.map { (path: $0, action: policy.action(tool: "Edit", input: ["file_path": $0, "old_string": ""])) }
            let pick = actions.first { $0.action.verdict == .block } ?? actions.first { $0.action.verdict == .ask } ?? actions.first
            tool = "Edit"
            input = ["file_path": pick?.path ?? "", "old_string": "", "paths": paths]
            if paths.isEmpty { return queue(id, tool, ToolPolicy.Action(key: "Edit:?", verdict: .ask, title: "Change files"), input) }
        default:
            write(["id": id, "error": ["code": -32601, "message": "Not supported by Joe"]])
            return
        }
        let action = policy.action(tool: tool, input: input)
        // Codex runs the command as asked: Joe can't adjust it (clicks mapped to the screen).
        if let changed = action.input?["command"] as? String, changed != input["command"] as? String {
            return reply(id, accept: false)
        }
        switch action.verdict {
        case .block:
            reply(id, accept: false)
        case .allow:
            allow(id, input)
        case .ask where allowedForTask.contains(action.key):
            allow(id, input)
        case .ask:
            queue(id, tool, action, input)
        }
    }

    private func queue(_ id: Any, _ tool: String, _ action: ToolPolicy.Action, _ input: [String: Any]) {
        pending.append((id, tool, action, input))
        if pending.count == 1 { showNextApproval() }
    }

    private func showNextApproval() {
        guard let next = pending.first else {
            onEvent(.approval(nil))
            return
        }
        NSSound(named: "Tink")?.play()
        onEvent(.status("Waiting for your OK…"))
        onEvent(.approval(Assistant.Approval(
            title: next.action.title,
            detail: ToolPolicy.detail(description: next.input["description"] as? String, input: next.input.filter { !["description", "old_string", "paths"].contains($0.key) }),
            tool: next.tool,
            preview: ToolPolicy.preview(tool: next.tool, input: next.input),
            decide: { [weak self] decision in self?.decide(decision) }
        )))
    }

    private func decide(_ decision: Assistant.Decision) {
        guard !pending.isEmpty else { return }
        let request = pending.removeFirst()
        switch decision {
        case .allow, .allowForTask:
            if decision == .allowForTask { allowedForTask.insert(request.action.key) }
            allow(request.id, request.input)
            for other in pending where allowedForTask.contains(other.action.key) { allow(other.id, other.input) }
            pending.removeAll { allowedForTask.contains($0.action.key) }
        case .deny:
            reply(request.id, accept: false)
        }
        if pending.isEmpty { onEvent(.status("Working…")) }
        showNextApproval()
    }

    private func allow(_ id: Any, _ input: [String: Any]) {
        // Every file of a patch gets a backup, for "undo that".
        let paths = input["paths"] as? [String] ?? []
        for path in paths { UndoJournal.beforeChanging(path) }
        Session.beforeRunning(paths.isEmpty ? input : [:]) { [weak self] in
            self?.stop()
            self?.onEvent(.failed("Stopped: you pressed Esc."))
        }
        reply(id, accept: true)
    }

    private func reply(_ id: Any, accept: Bool) {
        write(["id": id, "result": ["decision": accept ? "accept" : "decline"]])
    }

    /// Turns Codex's errors into something the user can act on.
    private static func explain(_ error: String) -> String {
        let lowered = error.lowercased()
        if lowered.contains("login") || lowered.contains("log in") || lowered.contains("unauthorized") || lowered.contains("401") {
            return "Codex isn't signed in to ChatGPT. Sign in from Settings → Advanced → AI, then try again."
        }
        if lowered.contains("usage limit") || lowered.contains("rate limit") {
            return "You've reached your ChatGPT plan's limit for now. \(error)"
        }
        return error.isEmpty ? "Something went wrong." : error
    }
}

/// Signing Codex in to ChatGPT, from Settings.
enum CodexAccount {
    /// "Signed in with ChatGPT", "Not signed in", or "Codex isn't installed yet".
    static func status() async -> String {
        guard let codex = CodexSession.executable else { return "Codex isn't installed yet" }
        let output = await run(codex, ["login", "status"])
        if output.localizedCaseInsensitiveContains("chatgpt") { return "Signed in with ChatGPT" }
        if output.localizedCaseInsensitiveContains("api key") { return "Signed in with an API key, not ChatGPT: sign in again" }
        return "Not signed in"
    }

    /// Installs Codex if needed (no Terminal, no Node), then `codex login`, which opens the
    /// ChatGPT sign-in page in the browser and waits for it.
    static func connect() async -> String {
        if CodexSession.executable == nil {
            _ = await run(URL(fileURLWithPath: "/bin/bash"), ["-c", installScript])
            guard CodexSession.executable != nil else {
                return "Couldn't install Codex. Check the internet (a VPN in mainland China) and try again."
            }
        }
        guard let codex = CodexSession.executable else { return await status() }
        if await status().hasPrefix("Signed in with ChatGPT") { return await status() }
        _ = await run(codex, ["login"])
        return await status()
    }

    /// OpenAI's own build for Apple Silicon, from Codex's GitHub releases, into ~/.local/bin.
    private static let installScript = """
        set -eo pipefail
        dir=$(mktemp -d)
        curl -fsSL https://github.com/openai/codex/releases/latest/download/codex-aarch64-apple-darwin.tar.gz | tar -xz -C "$dir"
        mkdir -p "$HOME/.local/bin"
        mv "$dir/codex-aarch64-apple-darwin" "$HOME/.local/bin/codex"
        chmod +x "$HOME/.local/bin/codex"
        """

    private static func run(_ executable: URL, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = CodexSession.environment()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try process.run() } catch { continuation.resume(returning: "") }
        }
    }
}
