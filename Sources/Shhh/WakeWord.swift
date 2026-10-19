import AVFoundation
import Speech

/// "Hey Joe" instead of holding right ⌥. While it's on and Joe is idle, Apple's on-device speech
/// recognition listens for the phrase (nothing leaves the Mac; if on-device recognition isn't
/// available it stays off). On "Hey Joe" it stops listening and Joe records the request as if
/// right ⌥ were held, until they stop talking. Off by default: the microphone stays open (macOS
/// shows its orange dot) and it costs some battery.
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
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var startedAt = Date.distantPast
    private var asked = false

    private static let phrase = try! NSRegularExpression(pattern: #"\b(hey|hi|okay|ok|yo) (joe|jo)\b"#, options: .caseInsensitive)

    /// Every second: starts or stops listening to match the setting and what Joe is doing, and
    /// starts afresh each 50 seconds (recognition runs in one-minute pieces).
    func update() {
        let wanted = Self.isOn && canListen() && !Self.screenLocked
        if !wanted {
            if engine != nil { stop() }
            return
        }
        if engine == nil || Date().timeIntervalSince(startedAt) > 50 { stop(); start() }
    }

    private func start() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            if !asked { asked = true; SFSpeechRecognizer.requestAuthorization { _ in } }
            return
        default: return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Hey Joe"]
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); return }
        self.engine = engine
        self.request = request
        startedAt = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let heard = Self.phrase.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            guard heard || error != nil || result?.isFinal == true else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.request === request else { return }
                    self.stop()
                    if heard { self.onWake() }
                }
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
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
