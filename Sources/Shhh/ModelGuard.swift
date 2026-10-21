import Foundation

/// Joe's downloaded models (speech, voices): where they live, how big they should be, whether they
/// loaded, and a guard against crashing on a broken download. A beta tester's Wi-Fi dropped while
/// the voice downloaded, Joe loaded the half-finished files and quit. Now Joe notes which model it's
/// loading; if it never finishes (a crash), the next launch removes that model's files so they
/// download again cleanly, instead of crashing again.
enum ModelGuard {
    enum Model: String, CaseIterable, Identifiable {
        case speech, chinese, voice, mandarin
        var id: String { rawValue }

        var title: String {
            switch self {
            case .speech: "Speech recognition (English)"
            case .chinese: "Speech recognition (Chinese)"
            case .voice: "Joe's voice (Alba)"
            case .mandarin: "Joe's Mandarin voice"
            }
        }

        /// About how big the download is, for the progress bar.
        var megabytes: Double {
            switch self {
            case .speech: 445
            case .chinese: 451
            case .voice: 505
            case .mandarin: 420
            }
        }

        var folders: [URL] {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/fluidaudio/Models", isDirectory: true)
            switch self {
            case .speech: return [support.appendingPathComponent("parakeet-tdt-0.6b-v2"), support.appendingPathComponent("parakeet-redux")]
            case .chinese: return [support.appendingPathComponent("sensevoice-small")]
            case .voice: return [cache.appendingPathComponent("pocket-tts")]
            case .mandarin: return [cache.appendingPathComponent("kokoro-82m-coreml")]
            }
        }
    }

    private static let defaults = UserDefaults.standard

    // MARK: Loading

    static func willLoad(_ model: Model) {
        defaults.set(model.rawValue, forKey: "modelLoading")
        defaults.removeObject(forKey: "modelFailed.\(model.rawValue)")
    }

    static func didLoad(_ model: Model) {
        if defaults.string(forKey: "modelLoading") == model.rawValue { defaults.removeObject(forKey: "modelLoading") }
        defaults.set(true, forKey: "modelReady.\(model.rawValue)")
    }

    static func didFail(_ model: Model, _ error: Error) {
        if defaults.string(forKey: "modelLoading") == model.rawValue { defaults.removeObject(forKey: "modelLoading") }
        defaults.set(error.localizedDescription, forKey: "modelFailed.\(model.rawValue)")
    }

    /// At launch: a model that was loading when Joe last stopped (it crashed on it). Its files are
    /// removed so it downloads again; returns it to say so.
    static func recoverFromCrash() -> Model? {
        guard let raw = defaults.string(forKey: "modelLoading"), let model = Model(rawValue: raw) else { return nil }
        defaults.removeObject(forKey: "modelLoading")
        defaults.removeObject(forKey: "modelReady.\(raw)")
        for folder in model.folders { try? FileManager.default.removeItem(at: folder) }
        defaults.set("The download was broken, so it was removed. Download it again.", forKey: "modelFailed.\(raw)")
        return model
    }

    // MARK: Status, for the onboarding's "Get Joe ready"

    enum Status: Equatable {
        case notDownloaded, downloading(Double), ready, failed(String)
    }

    static func status(_ model: Model) -> Status {
        if defaults.bool(forKey: "modelReady.\(model.rawValue)") { return .ready }
        if let message = defaults.string(forKey: "modelFailed.\(model.rawValue)") { return .failed(message) }
        let bytes = model.folders.reduce(0) { $0 + size(of: $1) }
        guard bytes > 0 else { return .notDownloaded }
        return .downloading(min(0.99, Double(bytes) / (model.megabytes * 1_048_576)))
    }

    private static func size(of folder: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)
    }
}
