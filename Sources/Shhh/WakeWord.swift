import AVFoundation
import Speech

/// "Hey Joe" instead of holding right ⌥. While it's on and Joe is idle, the microphone is watched
/// for sound, and only while someone is talking does Apple's on-device speech recognition listen for
/// the phrase (nothing leaves the Mac; if on-device recognition isn't available it stays off). On
/// "Hey Joe" it stops listening and Joe records the request as if right ⌥ were held, until they stop
/// talking. Off by default: the microphone stays open (macOS shows its orange dot).
///
/// Recognition used to run all the time, started afresh every 50 seconds and again at once whenever
/// it ended, all day. Apple's recognition service (speechrecognitiond) kept memory from every one of
/// those sessions and reached 25 GB. Now a session starts only on sound, ends after a few quiet
/// seconds, and one that fails waits before the next.
@MainActor
final class WakeWord {
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: "wakeWord") }
        set { UserDefaults.standard.set(newValue, forKey: "wakeWord") }
    }

    var onWake: () -> Void = {}
    /// Whether Joe is free to be woken (not recording, thinking or talking).
    var canListen: () -> Bool = { false }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let feed = Feed()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var startedAt = Date.distantPast
    /// After a session that failed straight away: not before this.
    private var nextTry = Date.distantPast
    private var failures = 0
    private var asked = false

    private static let phrase = try! NSRegularExpression(pattern: #"\b(hey|hi|okay|ok|yo) (joe|jo)\b"#, options: .caseInsensitive)

    /// Every second: the microphone open or closed to match the setting and what Joe is doing, and a
    /// recognition session only while there's sound (at most 30 s at a time).
    func update() {
        let wanted = Self.isOn && canListen() && !Self.screenLocked
        guard wanted else {
            if engine != nil { stop() }
            return
        }
        if engine == nil { startMicrophone() }
        guard engine != nil else { return }
        let quietFor = Date().timeIntervalSince(feed.lastSound)
        if task == nil {
            if quietFor < 1, Date() >= nextTry { startRecognition() }
        } else if quietFor > 3 || Date().timeIntervalSince(startedAt) > 30 {
            endRecognition()
        }
    }

    /// The microphone only: its level is watched, and the last second and a half is kept so "Hey"
    /// isn't lost before recognition starts.
    private func startMicrophone() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            if !asked { asked = true; SFSpeechRecognizer.requestAuthorization { _ in } }
            return
        default: return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        let feed = self.feed
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in feed.push(buffer) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); return }
        self.engine = engine
    }

    private func startRecognition() {
        guard let recognizer, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Hey Joe"]
        self.request = request
        startedAt = Date()
        feed.begin(request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let heard = Self.phrase.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            guard heard || error != nil || result?.isFinal == true else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.request === request else { return }
                    if heard {
                        self.failures = 0
                        self.stop()
                        self.onWake()
                        return
                    }
                    // Ended by itself within seconds: something's wrong, so wait longer each time.
                    if error != nil, Date().timeIntervalSince(self.startedAt) < 5 {
                        self.failures += 1
                        self.nextTry = Date().addingTimeInterval(min(300, 5 * pow(2, Double(self.failures - 1))))
                    } else {
                        self.failures = 0
                    }
                    self.endRecognition()
                }
            }
        }
    }

    private func endRecognition() {
        feed.end()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
    }

    private func stop() {
        endRecognition()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        feed.reset()
    }

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Between the audio thread (the tap) and the main actor: when there was last sound, the recent
    /// audio, and the request it goes to while one is listening.
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var recent: [AVAudioPCMBuffer] = []
        private var soundAt = Date.distantPast

        /// Louder than a quiet room (about -40 dBFS).
        private static let threshold: Float = 0.01

        var lastSound: Date { lock.withLock { soundAt } }

        func push(_ buffer: AVAudioPCMBuffer) {
            let loud = Self.level(buffer) > Self.threshold
            lock.withLock {
                if loud { soundAt = Date() }
                if let request {
                    request.append(buffer)
                } else if let copy = Self.copy(buffer) {
                    recent.append(copy)
                    while recent.count > 36 { recent.removeFirst() } // ~1.5 s at 48 kHz
                }
            }
        }

        func begin(_ request: SFSpeechAudioBufferRecognitionRequest) {
            lock.withLock {
                for buffer in recent { request.append(buffer) }
                recent = []
                self.request = request
            }
        }

        func end() { lock.withLock { request = nil } }

        func reset() {
            lock.withLock {
                request = nil
                recent = []
                soundAt = .distantPast
            }
        }

        private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            return (sum / Float(buffer.frameLength)).squareRoot()
        }

        /// The tap's buffers can be reused once it returns, so the kept ones are copies.
        private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
                  let from = buffer.floatChannelData, let to = copy.floatChannelData else { return nil }
            copy.frameLength = buffer.frameLength
            for channel in 0..<Int(buffer.format.channelCount) {
                to[channel].update(from: from[channel], count: Int(buffer.frameLength))
            }
            return copy
        }
    }
}

/// While a "Hey Joe" request is being recorded: follows the words as they're said (Apple's
/// on-device recognition, alongside the recording), to know when the request is over. It ends when
/// they say an end phrase ("end prompt", "send it", "that's it", "over and out", "thanks Joe") or
/// when no new words have come for a moment, which background noise can't fake the way it fakes
/// loudness. The real transcript still comes from Joe's own speech model; the end phrase is taken
/// off it (`withoutEndPhrase`).
@MainActor
final class EndListener {
    /// No new words for this long, after some words: the request is over.
    static let pause: TimeInterval = 1.4

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var words = 0
    private var lastWord = Date()
    private var timer: Timer?
    private var onEnd: (() -> Void)?

    static let endPhrase = try! NSRegularExpression(
        pattern: #"[\s,.!?]*\b((end|and) (of )?(the )?prompt|send it|that'?s it|that is it|over and out|thanks?,? joe|thank you,? joe)[\s,.!?]*$"#,
        options: .caseInsensitive)

    /// Starts following; `onEnd` is called once, on an end phrase or a pause after some words.
    func start(onEnd: @escaping () -> Void) {
        stop()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized, let recognizer, recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); return }
        self.engine = engine
        self.request = request
        self.onEnd = onEnd
        words = 0
        lastWord = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let count = result.bestTranscription.segments.count
            let ended = Self.endPhrase.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.request === request else { return }
                    if count != self.words { self.words = count; self.lastWord = Date() }
                    if ended { self.end() }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.words >= 2, Date().timeIntervalSince(self.lastWord) > Self.pause { self.end() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onEnd = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func end() {
        let call = onEnd
        stop()
        call?()
    }

    /// The request without the end phrase they said to finish it.
    static func withoutEndPhrase(_ text: String) -> String {
        endPhrase.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
