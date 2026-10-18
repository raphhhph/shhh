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
