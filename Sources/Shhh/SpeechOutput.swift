import AVFoundation
@preconcurrency import FluidAudio
import NaturalLanguage

/// Reads the assistant's replies aloud, a sentence at a time as they stream in, in the voice chosen
/// in the menu: **Natural** (Kokoro, clear and quick), **Expressive** (Chatterbox Nano, warm, can
/// laugh and sigh) or **Apple** (macOS's own voices). Natural and Expressive are open models that
/// run on the Mac and download the first time they're picked. It stops as soon as a key goes
/// down, so it never talks into the microphone.
@MainActor
final class SpeechOutput {
    enum Engine: String, CaseIterable {
        case off, natural, expressive, apple

        var title: String {
            switch self {
            case .off: "Off"
            case .natural: "Natural: clear, gets to work"
            case .expressive: "Expressive: warm and friendly"
            case .apple: "Apple voice"
            }
        }
    }

    // MARK: - Settings (all in the menu)

    static var engine: Engine {
        get {
            if let raw = UserDefaults.standard.string(forKey: "voiceEngine"), let engine = Engine(rawValue: raw) { return engine }
            return UserDefaults.standard.bool(forKey: "speakReplies") ? .apple : .off // the old on/off switch
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "voiceEngine") }
    }

    static var isEnabled: Bool { engine != .off }

    /// Natural's voice: a Kokoro voice pack.
    static var naturalVoice: String {
        get { UserDefaults.standard.string(forKey: "naturalVoice") ?? "af_heart" }
        set { UserDefaults.standard.set(newValue, forKey: "naturalVoice") }
    }

    static let naturalVoices: [(id: String, name: String)] = [
        ("af_heart", "Heart: US, female"), ("af_bella", "Bella: US, female"), ("af_nicole", "Nicole: US, female, soft"),
        ("am_michael", "Michael: US, male"), ("am_adam", "Adam: US, male"), ("am_fenrir", "Fenrir: US, male, deep"),
        ("bf_emma", "Emma: UK, female"), ("bf_isabella", "Isabella: UK, female"),
        ("bm_george", "George: UK, male"), ("bm_lewis", "Lewis: UK, male"),
    ]

    /// The voice for sentences in Chinese (Kokoro's Mandarin model); English stays in `naturalVoice`.
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

    /// Expressive: whether the assistant may laugh, chuckle or sigh now and then.
    static var expressiveSounds: Bool {
        get { UserDefaults.standard.object(forKey: "expressiveSounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "expressiveSounds") }
    }

    /// The morning briefing is read aloud even with the voice off (in Natural's voice then).
    static var speakBriefing: Bool {
        get { UserDefaults.standard.object(forKey: "speakBriefing") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speakBriefing") }
    }

    /// The sounds Expressive can make, written in the reply as `[chuckle]` and so on.
    static let soundTags = ["laugh", "chuckle", "sigh"]

    // MARK: - Speaking

    /// What's happening with a model download, for the menu ("Downloading Expressive… 40%").
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
        Task { await neural.prepare(engine, voice: Self.naturalVoice) }
    }

    /// For `Shhh --get-voice`: downloads and loads a voice, and says whether it worked.
    func prepareNow(_ engine: Engine) async -> String? {
        await neural.prepare(engine, voice: Self.naturalVoice)
        return neural.status
    }

    private func say(_ text: String) {
        let engine = current
        // Sentence by sentence, so the models (Expressive takes about ten seconds of speech per
        // go) and the queue both stay short.
        let sentences = text.components(separatedBy: .newlines)
            .flatMap { Self.sentences(in: $0) }
            .filter { $0.contains(where: \.isLetter) }
        for sentence in sentences {
            // The new voices speak English, and Natural also Chinese (Kokoro's Mandarin model);
            // anything else goes to Apple's.
            let english = (NLLanguageRecognizer.dominantLanguage(for: Self.withoutSounds(sentence)) ?? .english) == .english
            let chinese = engine == .natural && Self.isChinese(sentence)
            if engine == .apple || (!english && !chinese) {
                let utterance = AVSpeechUtterance(string: Self.withoutSounds(sentence))
                utterance.voice = Self.appleVoice(for: sentence)
                apple.speak(utterance)
            } else {
                pending.append(engine == .expressive && Self.expressiveSounds ? sentence : Self.withoutSounds(sentence))
            }
        }
        startWorking(engine)
    }

    /// Makes each waiting sentence's audio and queues it to play: the next one is made while the
    /// last one plays, so there are no gaps.
    private func startWorking(_ engine: Engine) {
        guard worker == nil, !pending.isEmpty else { return }
        let voice = Self.naturalVoice
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.pending.isEmpty {
                var sentence = self.pending.removeFirst()
                // Expressive is slower than the speech itself, with a second and a half each go on
                // top, and long pieces are slower still. So the first sentence goes alone, to start
                // soon, and after it short sentences waiting are said together, up to a line or so.
                while engine == .expressive, self.player.isPlaying, let next = self.pending.first,
                      sentence.count + next.count < 120 {
                    sentence += " " + self.pending.removeFirst()
                }
                let started = Date()
                let audio: NeuralVoices.Audio
                do {
                    audio = try await self.neural.speak(sentence, engine: engine, voice: voice)
                } catch {
                    if ProcessInfo.processInfo.environment["SHHH_VOICE_LOG"] != nil { print("voice error:", error) }
                    continue
                }
                guard !Task.isCancelled else { break }
                if ProcessInfo.processInfo.environment["SHHH_VOICE_LOG"] != nil { // `Joe --say` timing
                    print(String(format: "%@: %.1fs of speech made in %.2fs: %@", engine.rawValue,
                                 Double(audio.samples.count) / Double(audio.sampleRate), Date().timeIntervalSince(started), sentence))
                }
                self.player.play(audio.samples, sampleRate: audio.sampleRate)
            }
            self?.worker = nil
        }
    }

    // MARK: - Text

    /// "One. Two? Three!" → ["One.", "Two?", "Three!"]. Long ones are split at commas too, so
    /// Expressive never gets more than it can say in one go.
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

/// The open voice models, loaded when picked and let go when not, so only the one in use takes
/// memory (Expressive takes about a gigabyte).
@MainActor
private final class NeuralVoices {
    private(set) var status: String?
    private var kokoro: KokoroAneManager?
    private var kokoroVoice: String?
    /// Kokoro's Mandarin model, loaded the first time a sentence in Chinese is read.
    private var kokoroChinese: KokoroAneManager?
    private var kokoroChineseVoice: String?
    /// A `ChatterboxNanoManager`, which needs macOS 15.
    private var nano: AnyObject?

    struct Audio {
        let samples: [Float]
        let sampleRate: Int
    }

    func prepare(_ engine: SpeechOutput.Engine, voice: String) async {
        if engine != .natural, let kokoro {
            await kokoro.cleanup()
            self.kokoro = nil
        }
        if engine != .expressive { nano = nil }
        do {
            switch engine {
            case .natural: _ = try await naturalManager(voice: voice)
            case .expressive:
                guard #available(macOS 15, *) else {
                    status = "The Expressive voice needs macOS 15 or later"
                    return
                }
                _ = try await expressiveManager()
            case .off, .apple: break
            }
        } catch {
            status = "Couldn't load the voice: \(error.localizedDescription)"
        }
    }

    func speak(_ text: String, engine: SpeechOutput.Engine, voice: String) async throws -> Audio {
        switch engine {
        case .expressive:
            guard #available(macOS 15, *) else { throw CancellationError() }
            let audio = try await expressiveManager().synthesize(text: text)
            return Audio(samples: audio.samples, sampleRate: audio.sampleRate)
        default:
            if SpeechOutput.isChinese(text) {
                let chinese = SpeechOutput.chineseVoice
                let result = try await chineseManager(voice: chinese).synthesizeDetailed(text: text, voice: chinese)
                return Audio(samples: result.samples, sampleRate: result.sampleRate)
            }
            let result = try await naturalManager(voice: voice).synthesizeDetailed(text: text, voice: voice)
            return Audio(samples: result.samples, sampleRate: result.sampleRate)
        }
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

    private func naturalManager(voice: String) async throws -> KokoroAneManager {
        if let kokoro, kokoroVoice == voice { return kokoro }
        status = "Getting the Natural voice ready…"
        defer { status = nil }
        // The faster v3 pipeline needs macOS 15.
        let version: KokoroAneVersion = if #available(macOS 15, *) { .v3 } else { .legacy }
        let manager = kokoro ?? KokoroAneManager(defaultVoice: voice, version: version)
        try await manager.initialize(preloadVoices: [voice])
        kokoro = manager
        kokoroVoice = voice
        return manager
    }

    @available(macOS 15, *)
    private func expressiveManager() async throws -> ChatterboxNanoManager {
        if let nano = nano as? ChatterboxNanoManager { return nano }
        status = "Getting the Expressive voice ready…"
        defer { status = nil }
        let manager = ChatterboxNanoManager()
        try await manager.initialize { [weak self] progress in
            let percent = Int(progress.fractionCompleted * 100)
            Task { @MainActor in self?.status = "Downloading the Expressive voice… \(percent)%" }
        }
        nano = manager
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
