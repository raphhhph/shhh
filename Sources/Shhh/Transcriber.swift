import AVFoundation
import CoreML
import FluidAudio

/// On-device speech-to-text with NVIDIA Parakeet: English-only (v2) by default, or the
/// multilingual one (Redux, ~180 MB: English, French and 23 other European languages). The multilingual
/// one guesses the language, and on short or mumbled English it sometimes guessed Russian.
actor Transcriber {
    /// "Languages" in Settings: English only; 25 European languages; or English and Chinese
    /// (Mandarin and Cantonese, mixed in one sentence too).
    enum Languages: String, CaseIterable {
        case english, european, chinese
    }

    nonisolated static var languages: Languages {
        get {
            if let raw = UserDefaults.standard.string(forKey: "speechLanguages"), let value = Languages(rawValue: raw) { return value }
            return UserDefaults.standard.object(forKey: "speechEnglishOnly") as? Bool ?? true ? .english : .european
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "speechLanguages") }
    }

    nonisolated static var englishOnly: Bool { languages == .english }

    private var manager: AsrManager?
    /// For "English and Chinese": SenseVoice hears everything first and says which language it was.
    private var chinese: SenseVoiceManager?

    var isReady: Bool { manager != nil || chinese != nil }

    /// Downloads the model on first use (~500 MB, cached afterwards) and loads it.
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        // On the GPU, not the Neural Engine: after every update macOS recompiles a Neural Engine model
        // from scratch, which took minutes, and the keys waited. The GPU is ready in seconds and fast
        // enough for a few seconds of speech.
        let gpu = MLModelConfiguration()
        gpu.computeUnits = .cpuAndGPU
        ModelGuard.willLoad(.speech)
        let models: AsrModels
        do { models = try await AsrModels.downloadAndLoad(configuration: gpu, version: Self.languages == .european ? .redux : .v2,
                                                         encoderComputeUnits: .cpuAndGPU,
                                                         progressHandler: { progress($0.fractionCompleted) }) }
        catch { ModelGuard.didFail(.speech, error); throw error }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        ModelGuard.didLoad(.speech)
        self.manager = manager
        // Warm up so the first real dictation is fast.
        _ = try? await transcribe([Float](repeating: 0, count: 16_000))
        // Chinese comes after, without holding up the keys: after an update macOS recompiles it for
        // the Neural Engine, which can take minutes. Until then everything goes to Parakeet.
        if Self.languages == .chinese { Task { await self.loadChinese() } } else { warmedUp = true }
    }

    /// Every speech model loaded and run once (Chinese too, when it's on), or given up on.
    private(set) var warmedUp = false

    /// Returns once `warmedUp` (or after `seconds`): for starting other GPU models (voices, noise
    /// filter) only after these, so they don't all compile and warm up at once after an install.
    func waitUntilWarmedUp(seconds: Double = 120) async {
        for _ in 0..<Int(seconds * 10) where !warmedUp { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private var loadingChinese = false
    /// Transcriptions running on Parakeet right now (it mustn't be freed under them).
    private var parakeetRunning = 0

    private func loadChinese() async {
        guard chinese == nil, !loadingChinese else { return }
        loadingChinese = true
        // Text-norm 14 ("withitn"): punctuation and numbers as digits, like Parakeet's output.
        ModelGuard.willLoad(.chinese)
        let loaded: SenseVoiceModels?
        do { loaded = try await Self.loadSenseVoiceOnGPU() } catch { ModelGuard.didFail(.chinese, error); loaded = nil }
        if let models = loaded {
            ModelGuard.didLoad(.chinese)
            let manager = SenseVoiceManager(models: models, textNorm: 14)
            // Its first run is when macOS compiles it for the Neural Engine (minutes after an
            // update). Done here, on silence, before it's used: a real request used to wait behind it,
            // and every request after that one.
            _ = try? await manager.transcribeDetailed(audio: [Float](repeating: 0, count: 16_000))
            chinese = manager
            // SenseVoice hears English about as well, so Parakeet (1.2 GB on the GPU) goes: it was only
            // there for the first seconds after launch. Not under a transcription still running on it:
            // the actor lets this run while that one awaits, and freeing its GPU buffers mid-prediction
            // aborted Joe a few seconds after launch (a Metal assertion in CoreML, no Joe frames).
            if let parakeet = self.manager {
                self.manager = nil // nothing new starts on it
                for _ in 0..<600 where parakeetRunning > 0 { try? await Task.sleep(for: .milliseconds(50)) }
                if parakeetRunning == 0 { await parakeet.cleanup() } // still busy after 30 s: let it be freed with the Transcriber
            }
        }
        loadingChinese = false
        warmedUp = true // or failed: either way, nothing more is coming
    }

    /// SenseVoice with its encoder on the GPU. FluidAudio puts it on the Neural Engine, where each
    /// new length of recording can mean another compile by macOS (one ran for over an hour after an
    /// update), and requests hung behind it. The GPU needs no such compile.
    private static func loadSenseVoiceOnGPU() async throws -> SenseVoiceModels {
        let directory = try await SenseVoiceModels.download() // already there: returns at once
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly // the preprocessor needs fp32 on the CPU
        let gpu = MLModelConfiguration()
        gpu.computeUnits = .cpuAndGPU
        let preprocessor = try MLModel(contentsOf: directory.appendingPathComponent("SenseVoicePreprocessor.mlmodelc"), configuration: cpu)
        let encoder = try MLModel(contentsOf: directory.appendingPathComponent("SenseVoiceSmall.mlmodelc"), configuration: gpu)
        let data = try Data(contentsOf: directory.appendingPathComponent("vocab.json"))
        var vocabulary: [Int: String] = [:]
        if let tokens = try JSONSerialization.jsonObject(with: data) as? [String] {
            for (index, token) in tokens.enumerated() { vocabulary[index] = token }
        } else if let tokens = try JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (key, token) in tokens { if let index = Int(key) { vocabulary[index] = token } }
        }
        return SenseVoiceModels(preprocessor: preprocessor, encoder: encoder, vocabulary: vocabulary)
    }

    /// Whether Chinese is ready too (it loads after English).
    var chineseReady: Bool { chinese != nil }

    func transcribe(_ samples: [Float]) async throws -> String {
        // Chinese still loading (just after launch): wait for it rather than have Parakeet turn
        // Chinese into made-up English.
        for _ in 0..<250 where Self.languages == .chinese && chinese == nil && loadingChinese {
            try await Task.sleep(for: .milliseconds(100))
        }
        // English and Chinese: SenseVoice hears everything once it's loaded (Parakeet only covers the
        // first seconds after launch). It takes up to ~100 s at a time, so longer audio goes in pieces.
        if let chinese, manager == nil, samples.count >= 16_000 * 100 {
            var parts: [String] = []
            for start in stride(from: 0, to: samples.count, by: 16_000 * 90) {
                let piece = Array(samples[start..<min(start + 16_000 * 90, samples.count)])
                if let heard = try? await chinese.transcribeDetailed(audio: piece) { parts.append(heard.text) }
            }
            return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Padded with silence to a whole number of 5-second blocks: on the GPU each new length of
        // audio is prepared once (about a second), so a handful of lengths keeps it fast.
        // At least half a second of it after the last word: speech that runs right up to the end
        // lost its last word ("…to ManageBac tonight" came out "…to manage back To").
        let block = 16_000 * 5
        let tailed = samples + [Float](repeating: 0, count: 8_000)
        let blocked = tailed + [Float](repeating: 0, count: (block - tailed.count % block) % block)
        if let chinese, samples.count < 16_000 * 100,
           let heard = try? await chinese.transcribeDetailed(audio: blocked) {
            let text = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // English and Chinese: SenseVoice hears both (Parakeet is unloaded once it's ready).
            if manager == nil || ["zh", "yue"].contains(heard.language ?? "") || SpeechOutput.isChinese(text) { return text }
        }
        guard let manager else { throw TranscriberError.notLoaded }
        // The model wants at least one second of audio.
        var padded = samples
        if padded.count < 16_000 { padded += [Float](repeating: 0, count: 16_000 - padded.count) }
        parakeetRunning += 1
        defer { parakeetRunning -= 1 }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(padded, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A file, through the same path as a recording (so the language choice applies).
    func transcribe(fileURL: URL) async throws -> String {
        try await transcribe(AudioConverter(sampleRate: 16_000).resampleAudioFile(fileURL))
    }

    enum TranscriberError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "Speech model is not loaded yet" }
    }
}

/// Background noise taken out of a recording before it's transcribed: fans, chatter, a busy
/// classroom (LocalVQE, ~5 MB, Apache-2.0, on the Mac). Settings → General → Reduce background
/// noise. If it isn't ready or fails, the recording is used as it is.
actor NoiseFilter {
    static let shared = NoiseFilter()

    nonisolated static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "reduceNoise") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "reduceNoise") }
    }

    private var manager: LocalVqeManager?
    private var loading: Task<LocalVqeManager?, Never>?

    /// Loads the model (downloading it the first time); call early so the first recording isn't held up.
    func prepare() async {
        guard Self.isOn, manager == nil else { return }
        if loading == nil { loading = Task { try? await LocalVqeManager() } }
        manager = await loading?.value
        if manager == nil { loading = nil } // offline: try again later
    }

    /// The recording with the noise taken out, or as it was.
    func clean(_ samples: [Float]) async -> [Float] {
        guard Self.isOn, samples.count >= 16_000 / 2 else { return samples }
        await prepare()
        guard let manager, let cleaned = try? await manager.process(mic: samples), !cleaned.isEmpty else { return samples }
        // The output lags the input by one hop: line it back up and keep the length.
        let delay = LocalVqeManager.outputDelaySamples
        let aligned = Array(cleaned.dropFirst(min(delay, cleaned.count)))
        return aligned.count >= samples.count - delay ? aligned + [Float](repeating: 0, count: max(0, samples.count - aligned.count)) : samples
    }
}

extension NoiseFilter {
    /// The filter for a recording that's still being made: it cleans the audio as it comes in, so
    /// when the key is let go only the last half second is left. Nil when the filter is off or not
    /// loaded yet: then `clean` does the whole recording afterwards, as before.
    func live() async -> LiveNoiseFilter? {
        guard Self.isOn, let manager, let stream = try? await manager.makeStream() else { return nil }
        return LiveNoiseFilter(stream: stream)
    }
}

/// `NoiseFilter.live()`: the same filter as `clean`, run piece by piece while they talk (the stream
/// gives the same samples as one pass over the whole recording). Its pieces go through one at a
/// time, in order.
actor LiveNoiseFilter {
    private let stream: LocalVqeStream
    /// How many samples of the recording it has been given.
    private(set) var fed = 0
    private var cleaned: [Float] = []
    private var failed = false
    private var working: Task<Void, Never>?

    init(stream: LocalVqeStream) {
        self.stream = stream
    }

    /// The recording from sample `start` on (anything already given is skipped).
    func feed(_ samples: [Float], from start: Int) {
        guard !failed, start <= fed, start + samples.count > fed else { return }
        let new = Array(samples.dropFirst(fed - start))
        fed += new.count
        let before = working
        working = Task {
            await before?.value
            guard !failed else { return }
            do { cleaned += try await stream.enhance(mic: new, reference: [Float](repeating: 0, count: new.count)) }
            catch { failed = true }
        }
    }

    /// The whole recording, cleaned and lined up as `NoiseFilter.clean` returns it; nil if it didn't
    /// work (then it's cleaned the usual way).
    func finish(_ samples: [Float]) async -> [Float]? {
        guard samples.count >= 16_000 / 2 else { return samples } // `clean` leaves these as they are
        guard samples.count >= fed else { return nil }
        feed(Array(samples[fed...]), from: fed)
        await working?.value
        guard !failed, let tail = try? await stream.flush() else { return nil }
        let output = cleaned + tail
        let delay = LocalVqeManager.outputDelaySamples
        let aligned = Array(output.dropFirst(min(delay, output.count)))
        guard !aligned.isEmpty else { return nil }
        return aligned.count >= samples.count - delay ? aligned + [Float](repeating: 0, count: max(0, samples.count - aligned.count)) : samples
    }
}

/// Where Joe downloads its speech and voice models: Hugging Face, or HF-Mirror (hf-mirror.com),
/// which works from mainland China without a VPN. Settings → Advanced.
enum ModelDownloads {
    nonisolated static var useChinaMirror: Bool {
        get { UserDefaults.standard.bool(forKey: "modelMirrorChina") }
        set { UserDefaults.standard.set(newValue, forKey: "modelMirrorChina"); apply() }
    }

    nonisolated static func apply() {
        ModelRegistry.baseURL = useChinaMirror ? "https://hf-mirror.com" : "https://huggingface.co"
    }
}
