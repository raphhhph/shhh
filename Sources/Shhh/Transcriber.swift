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

    var isReady: Bool { manager != nil }

    /// Downloads the model on first use (~500 MB, cached afterwards) and loads it.
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        // On the GPU, not the Neural Engine: after every update macOS recompiles a Neural Engine model
        // from scratch, which took minutes, and the keys waited. The GPU is ready in seconds and fast
        // enough for a few seconds of speech.
        let gpu = MLModelConfiguration()
        gpu.computeUnits = .cpuAndGPU
        let models = try await AsrModels.downloadAndLoad(configuration: gpu, version: Self.languages == .european ? .redux : .v2,
                                                         encoderComputeUnits: .cpuAndGPU,
                                                         progressHandler: { progress($0.fractionCompleted) })
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        // Warm up so the first real dictation is fast.
        _ = try? await transcribe([Float](repeating: 0, count: 16_000))
        // Chinese comes after, without holding up the keys: after an update macOS recompiles it for
        // the Neural Engine, which can take minutes. Until then everything goes to Parakeet.
        if Self.languages == .chinese { Task { await self.loadChinese() } }
    }

    private var loadingChinese = false

    private func loadChinese() async {
        guard chinese == nil, !loadingChinese else { return }
        loadingChinese = true
        // Text-norm 14 ("withitn"): punctuation and numbers as digits, like Parakeet's output.
        if let models = try? await Self.loadSenseVoiceOnGPU() {
            let manager = SenseVoiceManager(models: models, textNorm: 14)
            // Its first run is when macOS compiles it for the Neural Engine (minutes after an
            // update). Done here, on silence, before it's used: a real request used to wait behind it,
            // and every request after that one.
            _ = try? await manager.transcribeDetailed(audio: [Float](repeating: 0, count: 16_000))
            chinese = manager
        }
        loadingChinese = false
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
        guard let manager else { throw TranscriberError.notLoaded }
        // Chinese still loading (just after launch): wait for it rather than have Parakeet turn
        // Chinese into made-up English.
        for _ in 0..<250 where Self.languages == .chinese && chinese == nil && loadingChinese {
            try await Task.sleep(for: .milliseconds(100))
        }
        // English and Chinese: Chinese (or mixed) speech is SenseVoice's; English stays with
        // Parakeet, which is more accurate on English. SenseVoice takes up to ~100 s at a time.
        if let chinese, samples.count < 16_000 * 100,
           let heard = try? await chinese.transcribeDetailed(audio: samples) {
            let text = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["zh", "yue"].contains(heard.language ?? "") || SpeechOutput.isChinese(text) { return text }
        }
        // The model wants at least one second of audio.
        var padded = samples
        if padded.count < 16_000 { padded += [Float](repeating: 0, count: 16_000 - padded.count) }
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
