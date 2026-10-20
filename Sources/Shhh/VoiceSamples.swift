import AVFoundation
import FluidAudio

/// `Joe --voice-samples <folder>`: one sentence in each on-device voice FluidAudio offers, saved as
/// WAV files to compare by ear, with how long each took. For choosing Joe's voice.
enum VoiceSamples {
    static let line = "Good morning, Raphael. You have Economics at nine, and your ESS formative is due tomorrow. Want me to block an hour for it after school?"

    static func run(_ folderPath: String) async {
        let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await sample("1 Kokoro Heart (current)", folder) {
            let version: KokoroAneVersion = if #available(macOS 15, *) { .v3 } else { .legacy }
            let kokoro = KokoroAneManager(defaultVoice: "af_heart", version: version)
            try await kokoro.initialize(preloadVoices: ["af_heart"])
            let result = try await kokoro.synthesizeDetailed(text: line, voice: "af_heart")
            return (result.samples, result.sampleRate)
        }
        for voice in ["alba", "marius"] {
            await sample("2 PocketTTS \(voice)", folder) {
                let pocket = PocketTtsManager(defaultVoice: voice)
                try await pocket.initialize()
                return try decodeWAV(await pocket.synthesize(text: line, voice: voice))
            }
        }
        for speaker in ["emily", "paul"] {
            await sample("3 NeuTTS \(speaker)", folder) {
                let neu = NeuTtsManager()
                try await neu.initialize()
                let audio = try await neu.synthesize(text: line, speaker: speaker, seed: 7)
                return (audio.samples, audio.sampleRate)
            }
        }
        for voice in [Supertonic3Voice.f1, .m1] {
            await sample("4 Supertonic \(voice.rawValue)", folder) {
                let supertonic = Supertonic3Manager()
                try await supertonic.initialize()
                let style = try await Supertonic3ResourceDownloader.loadVoiceStyle(voice)
                let result = try await supertonic.synthesize(text: line, language: "en", style: style)
                return (result.samples, Supertonic3Constants.sampleRate)
            }
        }
        await sample("5 Chatterbox multilingual", folder) {
            let chatterbox = ChatterboxManager()
            try await chatterbox.initialize()
            let audio = try await chatterbox.synthesize(text: line, language: "en", seed: 7)
            return (audio.samples, audio.sampleRate)
        }
        print("Saved to \(folder.path)")
    }

    private static func sample(_ name: String, _ folder: URL, _ make: () async throws -> ([Float], Int)) async {
        let start = Date()
        do {
            let (samples, rate) = try await make()
            try write(samples, rate: rate, to: folder.appendingPathComponent("\(name).wav"))
            print(String(format: "%@: %.1fs to make %.1fs of speech (incl. first-time download)", name,
                         Date().timeIntervalSince(start), Double(samples.count) / Double(rate)))
        } catch {
            print("\(name): failed: \(error.localizedDescription)")
        }
    }

    private static func decodeWAV(_ data: Data) throws -> ([Float], Int) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: file.fileFormat.sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))), Int(file.fileFormat.sampleRate))
    }

    private static func write(_ samples: [Float], rate: Int, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
}
