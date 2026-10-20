import AVFoundation
import FluidAudio

/// On-device speech-to-text with NVIDIA Parakeet: English-only (v2) by default, or the
/// multilingual one (Redux, ~180 MB: English, French and 23 other European languages). The multilingual
/// one guesses the language, and on short or mumbled English it sometimes guessed Russian.
actor Transcriber {
    /// "Speech languages" in Settings: English only, or 25 languages.
    nonisolated static var englishOnly: Bool {
        get { UserDefaults.standard.object(forKey: "speechEnglishOnly") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speechEnglishOnly") }
    }

    private var manager: AsrManager?

    var isReady: Bool { manager != nil }

    /// Downloads the model on first use (~500 MB, cached afterwards) and loads it.
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: Self.englishOnly ? .v2 : .redux,
                                                         progressHandler: { progress($0.fractionCompleted) })
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        // Warm up so the first real dictation is fast.
        _ = try? await transcribe([Float](repeating: 0, count: 16_000))
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriberError.notLoaded }
        // The model wants at least one second of audio.
        var padded = samples
        if padded.count < 16_000 { padded += [Float](repeating: 0, count: 16_000 - padded.count) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(padded, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let manager else { throw TranscriberError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(fileURL, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
