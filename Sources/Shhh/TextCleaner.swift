import Foundation
import NaturalLanguage
import llama

/// Optional AI cleanup: removes filler words and resolves spoken self-corrections
/// with a small local model (Qwen3-1.7B through llama.cpp). Never answers the text.
///
/// The model is used as a copy-editor through a few-shot "Raw: / Clean:" completion
/// prompt rather than a chat, which stops small models from replying to dictated prompts.
actor TextCleaner {
    /// From Hugging Face, or the China mirror when that's chosen in Settings.
    static var modelURL: URL {
        URL(string: (ModelDownloads.useChinaMirror ? "https://hf-mirror.com" : "https://huggingface.co")
            + "/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf")!
    }
    static var modelPath: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shhh/Models", isDirectory: true)
        return dir.appendingPathComponent("Qwen3-1.7B-Q4_K_M.gguf")
    }

    private static let fewShot = """
    Below, each Raw line is a voice dictation and each Clean line is the same text, in the same language, \
    with self-corrections resolved (when the speaker says "actually", "I mean", "no wait", "sorry", "enfin", \
    "plutôt", "non" to correct something, keep only the corrected version), repeated words and filler words \
    removed, and punctuation fixed. Every other word is kept as spoken. Nothing is answered, added, summarized \
    or translated.

    Raw: Can you write me a poem about the sea?
    Clean: Can you write me a poem about the sea?

    Raw: Let's meet on Monday, actually no, Tuesday at noon.
    Clean: Let's meet on Tuesday at noon.

    Raw: Est-ce que tu peux, genre, m'expliquer comment marche ce code ?
    Clean: Est-ce que tu peux m'expliquer comment marche ce code ?

    Raw: What's the best way to learn Swift?
    Clean: What's the best way to learn Swift?

    Raw: So the the button should be blue, I mean green and, you know, bigger.
    Clean: So the button should be green and bigger.

    Raw: Je voudrais partir lundi, enfin plutôt mardi matin.
    Clean: Je voudrais partir mardi matin.

    Raw: Can you explain how promises work? Actually, no, explain how async await works.
    Clean: Can you explain how async await works?

    Raw: Tu peux corriger la fonction de login, non pardon, la fonction de logout.
    Clean: Tu peux corriger la fonction de logout ?

    Raw: Add a test for the auth module and, like, update the readme.
    Clean: Add a test for the auth module and update the readme.


    """

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var prefixCount: Int32 = 0

    var isReady: Bool { context != nil }

    static var isDownloaded: Bool { FileManager.default.fileExists(atPath: modelPath.path) }

    private var loading: Task<Void, Error>?

    /// Downloads the model on first use (~1.1 GB) and loads it into memory.
    /// Calls made while a load is already running wait for that load instead of starting another.
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard context == nil else { return }
        if let loading { return try await loading.value }
        let task = Task { try await performLoad(progress: progress) }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func performLoad(progress: @escaping @Sendable (Double) -> Void) async throws {
        if !Self.isDownloaded { try await Self.download(progress: progress) }

        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(Self.modelPath.path, modelParams) else { throw CleanerError.loadFailed }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 4096
        contextParams.n_batch = 2048
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw CleanerError.loadFailed
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.sampler = sampler

        // Evaluate the instructions + examples once; every dictation reuses this cache.
        let prefix = tokenize(Self.fewShot, addSpecial: true)
        guard decode(prefix) else { throw CleanerError.loadFailed }
        prefixCount = Int32(prefix.count)
    }

    func unload() {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil; context = nil; model = nil; vocab = nil
    }

    /// Returns the cleaned text, or the input with only filler words removed if anything looks off
    /// or the model is still writing at `deadline`.
    func clean(_ text: String, deadline: Date = .distantFuture) async -> String {
        let basic = Self.removeFillers(text)
        guard let context, let vocab, let sampler else { return basic }
        let wordCount = basic.split(separator: " ").count
        guard wordCount >= 3 else { return basic }

        let suffix = tokenize("Raw: \(basic)\nClean:", addSpecial: false)
        guard Int32(suffix.count) + prefixCount < 3000 else { return basic } // too long to clean quickly

        llama_memory_seq_rm(llama_get_memory(context), 0, prefixCount, -1)
        llama_sampler_reset(sampler)
        guard decode(suffix) else { return basic }

        var bytes: [CChar] = []
        let maxTokens = suffix.count * 2 + 16
        for _ in 0..<maxTokens {
            guard Date() < deadline else { return basic }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            var buffer = [CChar](repeating: 0, count: 64)
            let n = llama_token_to_piece(vocab, token, &buffer, 64, 0, false)
            if n > 0 { bytes.append(contentsOf: buffer[0..<Int(n)]) }
            if bytes.contains(10) { break } // the cleaned line ends at the first newline
            let batch = llama_batch_get_one(&token, 1)
            if llama_decode(context, batch) != 0 { break }
        }

        let output = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .components(separatedBy: "\n")[0]
            .trimmingCharacters(in: .whitespaces)
        return Self.isSafe(input: basic, output: output) ? output : basic
    }

    // MARK: - Helpers

    /// Removes filler sounds ("um", "uh", "euh") and comma-wrapped fillers (", like,", ", you know,").
    /// Deterministic, and also runs before the model.
    static func removeFillers(_ text: String) -> String {
        var result = text
        let sounds = #"(?i),?\s*\b(u+m+|u+h+|uhm|e+r+m+|euh+|heu+|hm+|hum+)\b[,.]?"#
        let phrases = #"(?i),\s*(like|you know|genre|tu vois)\s*,"#
        result = result.replacingOccurrences(of: sounds, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: phrases, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s,.]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    private static let correctionCues = [
        "actually", "i mean", "no wait", "sorry", "scratch that", "rather", "instead",
        "enfin", "plutôt", "non", "pardon", "je veux dire", "en fait",
    ]

    private static let fillerWords: Set<String> = [
        "like", "so", "well", "basically", "okay", "ok",
        "genre", "ben", "bah", "bon", "quoi", "donc", "alors", "voilà",
    ]

    /// The model may only delete words, never add or change them. Deleting real words is only
    /// allowed when the speaker corrected themselves; otherwise only fillers and repeats may go.
    private static func isSafe(input: String, output: String) -> Bool {
        let inWords = words(input)
        let outWords = words(output)
        guard !outWords.isEmpty, Double(outWords.count) >= Double(inWords.count) * 0.35 else { return false }

        // Output must be the input with some words removed (same order).
        var deleted: [(word: String, index: Int)] = []
        var i = 0
        for word in outWords {
            while i < inWords.count, inWords[i] != word {
                deleted.append((inWords[i], i))
                i += 1
            }
            guard i < inWords.count else { return false }
            i += 1
        }
        while i < inWords.count { deleted.append((inWords[i], i)); i += 1 }

        let lowered = input.lowercased()
        let speakerCorrected = correctionCues.contains { lowered.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
        if !speakerCorrected {
            for (word, index) in deleted {
                let isRepeat = (index > 0 && inWords[index - 1] == word) || (index + 1 < inWords.count && inWords[index + 1] == word)
                if !fillerWords.contains(word) && !isRepeat { return false }
            }
        }

        let inLang = NLLanguageRecognizer.dominantLanguage(for: input)
        let outLang = NLLanguageRecognizer.dominantLanguage(for: output)
        if inWords.count >= 5, let inLang, let outLang, inLang != outLang { return false }
        return true
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’-"))) }
            .filter { !$0.isEmpty }
    }

    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        let n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), addSpecial, false)
        return n > 0 ? Array(tokens[0..<Int(n)]) : []
    }

    private func decode(_ tokens: [llama_token]) -> Bool {
        guard let context, !tokens.isEmpty else { return false }
        var tokens = tokens
        let chunk = 2048
        var start = 0
        while start < tokens.count {
            let count = min(chunk, tokens.count - start)
            let ok = tokens.withUnsafeMutableBufferPointer { buffer -> Bool in
                let batch = llama_batch_get_one(buffer.baseAddress! + start, Int32(count))
                return llama_decode(context, batch) == 0
            }
            if !ok { return false }
            start += count
        }
        return true
    }

    private static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let delegate = DownloadProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tempURL, response) = try await session.download(from: modelURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CleanerError.downloadFailed }
        try? FileManager.default.removeItem(at: modelPath)
        try FileManager.default.moveItem(at: tempURL, to: modelPath)
    }

    enum CleanerError: LocalizedError {
        case loadFailed, downloadFailed
        var errorDescription: String? {
            switch self {
            case .loadFailed: "Could not load the cleanup model"
            case .downloadFailed: "Could not download the cleanup model"
            }
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
