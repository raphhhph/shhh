import Foundation

/// Dictating into ChatGPT, Claude or Cursor and ending with "… make it a prompt": what was said,
/// rewritten as a clear prompt (the goal, the context, constraints, the output wanted) before it's
/// typed. Like Vovy, for any app. A quick Haiku call with no tools; the words as said if it fails.
enum PromptPolish {
    /// "…, make it a prompt", "… as a prompt", "… prompt it": the request without the phrase.
    static func request(in text: String) -> String? {
        let pattern = #"[,.\s]*(and\s+)?(make (it|this|that) (into )?a (good |proper |better )?prompt|as a prompt|prompt it|turn (it|this) into a prompt)[.!\s]*$"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let rest = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    static func polish(_ said: String) async -> String {
        guard let claude = Assistant.executable else { return said }
        let system = """
            Rewrite what the user dictated as a clear prompt for an AI assistant (ChatGPT, Claude, Cursor), in their \
            voice ("I", "my"). Keep every fact and request they gave; invent nothing. Structure: the goal in one line; \
            the context; constraints or requirements as a short list if there are several; the output format they \
            want. Plain text, no headings unless it's long, no preamble. Reply with the prompt only.
            """
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = claude
                process.arguments = ["-p", "--model", Assistant.Model.haiku.rawValue, "--tools", "", "--strict-mcp-config",
                                     "--no-session-persistence", "--system-prompt", system, said]
                process.environment = Session.environment()
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continuation.resume(returning: said); return }
                // Fifteen seconds at most: then the words as said.
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                let prompt = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: process.terminationStatus == 0 && !prompt.isEmpty ? prompt : said)
            }
        }
    }
}
