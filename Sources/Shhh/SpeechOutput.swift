import AVFoundation
@preconcurrency import FluidAudio
import NaturalLanguage

/// Reads the assistant's replies aloud, a sentence at a time as they stream in: English in Alba's
/// voice (PocketTTS by Kyutai), Chinese in Kokoro's Mandarin voice, both open models that run on the
/// Mac and download the first time. Any other language goes to macOS's own voices. It stops as soon
/// as a key goes down, so it never talks into the microphone.
@MainActor
final class SpeechOutput {
    enum Engine: String, CaseIterable {
        case off, lifelike

        var title: String {
            switch self {
            case .off: "Off"
            case .lifelike: "On: Alba"
            }
        }
    }

    // MARK: - Settings (all in the menu)

    static var engine: Engine {
        get {
            // Any voice that was on before (Natural, Expressive, Apple) is Alba now.
            if let raw = UserDefaults.standard.string(forKey: "voiceEngine") { return raw == "off" ? .off : .lifelike }
            return UserDefaults.standard.bool(forKey: "speakReplies") ? .lifelike : .off // the old on/off switch
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "voiceEngine") }
    }

    static var isEnabled: Bool { engine != .off }

    /// The English voice: PocketTTS's Alba.
    static let lifelikeVoice = "alba"

    /// The voice for sentences in Chinese (Kokoro's Mandarin model); English stays Alba's.
    static var chineseVoice: String {
        get { UserDefaults.standard.string(forKey: "chineseVoice") ?? "zf_001" }
        set { UserDefaults.standard.set(newValue, forKey: "chineseVoice") }
    }

    static let chineseVoices: [(id: String, name: String)] = [
        ("zf_001", "Female 1"), ("zf_002", "Female 2"), ("zf_003", "Female 3"),
        ("zm_009", "Male 1"), ("zm_010", "Male 2"), ("zm_011", "Male 3"),
    ]

    /// Mostly Chinese characters: read with the Mandarin voice.
    nonisolated static func isChinese(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let han = letters.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }.count
        return Double(han) / Double(letters.count) > 0.4
    }

    /// The morning briefing is read aloud even with the voice off.
    static var speakBriefing: Bool {
        get { UserDefaults.standard.object(forKey: "speakBriefing") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speakBriefing") }
    }

    /// Sounds an older voice could make (`[chuckle]`…), taken out if a reply still has one.
    static let soundTags = ["laugh", "chuckle", "sigh"]

    // MARK: - Speaking

    /// What's happening with a model download, for the menu ("Getting the voice ready…").
    var status: String? { neural.status }

    private let apple = AVSpeechSynthesizer()
    private let neural = NeuralVoices()
    private let player = VoicePlayer()
    /// The current reply as it will be spoken, and how much of it is already queued.
    private var reply = ""
    private var queued = 0
    /// Sentences waiting for a model, in order, and the task working through them.
    private var pending: [String] = []
    private var worker: Task<Void, Never>?
    /// For one reply, a voice other than the chosen one (the morning briefing with the voice off).
    private var oneOff: Engine?
    private var current: Engine { oneOff ?? Self.engine }

    /// Speak the current reply in `engine`, whatever's chosen (until it's finished or stopped).
    func useForThisReply(_ engine: Engine) {
        oneOff = engine
    }

    /// The reply so far. Speaks the sentences that are now complete.
    func update(_ text: String) {
        guard current != .off else { return }
        let speakable = Self.speakable(text)
        if !speakable.hasPrefix(reply.prefix(queued)) {
            queued = 0 // a new message replaced the text (the earlier one led up to a tool call)
        }
        reply = speakable
        let rest = reply.dropFirst(queued)
        // Up to the last sentence end: ". " "! " "? " or a line break.
        guard let end = rest.range(of: #"[.!?…:](?=\s)|\n"#, options: [.regularExpression, .backwards]) else { return }
        let sentences = rest[..<end.upperBound]
        queued += sentences.count
        say(String(sentences))
    }

    /// The reply is complete: speak whatever is left.
    func finish() {
        guard current != .off else { return }
        say(String(reply.dropFirst(queued)))
        reply = ""
        queued = 0
        oneOff = nil
    }

    /// Anything still to say or being said.
    var isSpeaking: Bool { worker != nil || !pending.isEmpty || player.isPlaying || apple.isSpeaking }

    func stop() {
        apple.stopSpeaking(at: .immediate)
        worker?.cancel()
        worker = nil
        pending = []
        player.stop()
        reply = ""
        queued = 0
        oneOff = nil
    }

    /// Gets the chosen model ready (downloading it the first time), or lets go of the others.
    func prepare() {
        let engine = Self.engine
        Task { await neural.prepare(engine) }
    }

    /// Loads Alba even with the voice off, for the welcome tour, so she's ready when Joe speaks.
    func prepareForTour() {
        Task { await neural.prepare(.lifelike) }
    }

    /// For `Shhh --get-voice`: downloads and loads a voice, and says whether it worked.
    func prepareNow(_ engine: Engine) async -> String? {
        await neural.prepare(engine)
        return neural.status
    }

    private func say(_ text: String) {
        let engine = current
        // Sentence by sentence, so the first one starts soon and the queue stays short.
        let sentences = text.components(separatedBy: .newlines)
            .flatMap { Self.sentences(in: $0) }
            .filter { $0.contains(where: \.isLetter) }
        for sentence in sentences {
            // Alba speaks English, Kokoro Chinese; anything else goes to macOS's own voices.
            let english = (NLLanguageRecognizer.dominantLanguage(for: Self.withoutSounds(sentence)) ?? .english) == .english
            if !english && !Self.isChinese(sentence) {
                let utterance = AVSpeechUtterance(string: Self.withoutSounds(sentence))
                utterance.voice = Self.appleVoice(for: sentence)
                apple.speak(utterance)
            } else {
                pending.append(Self.withoutSounds(sentence))
            }
        }
        startWorking(engine)
    }

    /// Makes each waiting sentence's audio and queues it to play: the next one is made while the
    /// last one plays, so there are no gaps.
    private func startWorking(_ engine: Engine) {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.pending.isEmpty {
                let sentence = self.pending.removeFirst()
                let started = Date()
                var first: TimeInterval?
                var seconds = 0.0
                do {
                    // Audio is played as it's made, a fraction of a second at a time, so speech
                    // starts almost at once instead of after the whole sentence.
                    try await self.neural.speak(sentence) { audio in
                        guard !Task.isCancelled else { return }
                        if first == nil { first = Date().timeIntervalSince(started) }
                        seconds += Double(audio.samples.count) / Double(audio.sampleRate)
                        self.player.play(audio.samples, sampleRate: audio.sampleRate)
                    }
                } catch {
                    if ProcessInfo.processInfo.environment["SHHH_VOICE_LOG"] != nil { print("voice error:", error) }
                    continue
                }
                guard !Task.isCancelled else { break }
                if ProcessInfo.processInfo.environment["SHHH_VOICE_LOG"] != nil { // `Joe --say` timing
                    print(String(format: "%@: first sound after %.2fs, %.1fs of speech made in %.2fs: %@", engine.rawValue,
                                 first ?? 0, seconds, Date().timeIntervalSince(started), sentence))
                }
            }
            self?.worker = nil
        }
    }

    // MARK: - Text

    /// "One. Two? Three!" → ["One.", "Two?", "Three!"]. Long ones are split at commas too, so a
    /// voice never gets more than it can say in one go.
    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return }
            if sentence.count <= 220 {
                sentences.append(sentence)
            } else {
                var piece = ""
                for part in sentence.split(separator: ",", omittingEmptySubsequences: false) {
                    if !piece.isEmpty, piece.count + part.count > 200 {
                        sentences.append(piece.trimmingCharacters(in: .whitespaces) + ",")
                        piece = ""
                    }
                    piece += piece.isEmpty ? String(part) : "," + part
                }
                if !piece.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(piece.trimmingCharacters(in: .whitespaces)) }
            }
        }
        return sentences
    }

    /// The text without `[chuckle]`-style sounds, for the screen and for voices that can't make them.
    static func withoutSounds(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\[(?:\#(soundTags.joined(separator: "|")))\]"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
    }

    /// The best installed Apple voice for the text's language, preferring the user's chosen one.
    private static func appleVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let preferred = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        if let preferred, preferred.language.hasPrefix(language) { return preferred }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    /// The reply as it should sound: no sources list, no markdown, links read as their titles,
    /// and a pause at the end of each line.
    static func speakable(_ text: String) -> String {
        var text = text
        if let sources = text.range(of: #"(^|\n)\s*\**Sources:?\**"#, options: .regularExpression) {
            text = String(text[..<sources.lowerBound])
        }
        let replacements: [(String, String)] = [
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),         // [title](url) → title
            (#"https?://\S+"#, ""),                    // bare links
            (#"(\*\*|__|`|\*)"#, ""),                  // bold, code, italics
            (#"(?m)^\s*([-•*]|\d+\.)\s+"#, ""),        // list markers
            (#"(?m)([^.!?:\s\]])[ \t]*$"#, "$1."),     // a line without an ending gets a pause
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }
}

/// The open voice models: Alba (PocketTTS) for English, loaded when the voice is on and let go
/// when it's off, and Kokoro's Mandarin model, loaded the first time a sentence in Chinese is read.
@MainActor
private final class NeuralVoices {
    private(set) var status: String?
    private var pocket: PocketTtsManager?
    private var kokoroChinese: KokoroAneManager?
    private var kokoroChineseVoice: String?

    struct Audio {
        let samples: [Float]
        let sampleRate: Int
    }

    func prepare(_ engine: SpeechOutput.Engine) async {
        guard engine == .lifelike else { pocket = nil; return }
        do { _ = try await englishManager() } catch { status = "Couldn't load the voice: \(error.localizedDescription)" }
    }

    /// Says `text`, handing over the audio as it's made: Alba streams it in small pieces, the
    /// Mandarin voice in one go.
    func speak(_ text: String, onAudio: (Audio) -> Void) async throws {
        if SpeechOutput.isChinese(text) {
            let chinese = SpeechOutput.chineseVoice
            let result = try await chineseManager(voice: chinese).synthesizeDetailed(text: text, voice: chinese)
            onAudio(Audio(samples: result.samples, sampleRate: result.sampleRate))
            return
        }
        // Pieces of about a quarter of a second, so playback starts soon without a flood of tiny buffers.
        var buffer: [Float] = []
        for try await frame in try await englishManager().synthesizeStreaming(text: text, voice: SpeechOutput.lifelikeVoice) {
            try Task.checkCancellation() // stopped: don't keep making audio no one will hear
            buffer += frame.samples
            if buffer.count >= 6_000 { onAudio(Audio(samples: buffer, sampleRate: 24_000)); buffer = [] }
        }
        if !buffer.isEmpty { onAudio(Audio(samples: buffer, sampleRate: 24_000)) }
    }

    private func englishManager() async throws -> PocketTtsManager {
        if let pocket { return pocket }
        status = "Getting the voice ready…"
        defer { status = nil }
        let manager = PocketTtsManager(defaultVoice: SpeechOutput.lifelikeVoice)
        try await manager.initialize()
        pocket = manager
        return manager
    }

    private func chineseManager(voice: String) async throws -> KokoroAneManager {
        if let kokoroChinese, kokoroChineseVoice == voice { return kokoroChinese }
        status = "Getting the Chinese voice ready…"
        defer { status = nil }
        let version: KokoroAneVersion = if #available(macOS 15, *) { .v3 } else { .legacy }
        let manager = kokoroChinese ?? KokoroAneManager(variant: .mandarin, defaultVoice: voice, version: version)
        try await manager.initialize(preloadVoices: [voice])
        kokoroChinese = manager
        kokoroChineseVoice = voice
        return manager
    }
}

/// Plays the voices' audio one piece after another, without gaps.
@MainActor
private final class VoicePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    /// Buffers scheduled and not yet played out.
    private var inFlight = 0
    var isPlaying: Bool { inFlight > 0 }

    func play(_ samples: [Float], sampleRate: Int) {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if self.format != format {
            engine.stop()
            if engine.attachedNodes.contains(node) { engine.detach(node) }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.format = format
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                if ProcessInfo.processInfo.environment["SHHH_VOICE_LOG"] != nil { print("audio error:", error) }
                return
            }
        }
        inFlight += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if let self { self.inFlight = max(0, self.inFlight - 1) } } }
        }
        if !node.isPlaying { node.play() }
    }

    func stop() {
        node.stop()
        inFlight = 0
    }
}
