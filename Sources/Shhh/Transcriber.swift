import AVFoundation
import FluidAudio

/// On-device speech-to-text with NVIDIA Parakeet: English-only (v2) by default, or the
/// multilingual one (Ultra: English, French and 23 other European languages). The multilingual
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
        let models = try await AsrModels.downloadAndLoad(version: Self.englishOnly ? .v2 : .ultra,
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
