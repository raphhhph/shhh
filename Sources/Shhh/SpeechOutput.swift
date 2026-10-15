import AVFoundation
import NaturalLanguage

/// Reads the assistant's replies aloud with macOS's own voices, a sentence at a time as they
/// stream in. Turned on and off from the menu; it stops as soon as a key goes down, so it never
/// talks into the microphone.
@MainActor
final class SpeechOutput {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "speakReplies") }
        set { UserDefaults.standard.set(newValue, forKey: "speakReplies") }
    }

    private let synthesizer = AVSpeechSynthesizer()
    /// The current reply as it will be spoken, and how much of it is already queued.
    private var reply = ""
    private var queued = 0

    /// The reply so far. Speaks the sentences that are now complete.
    func update(_ text: String) {
        guard Self.isEnabled else { return }
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
        guard Self.isEnabled else { return }
        say(String(reply.dropFirst(queued)))
        reply = ""
        queued = 0
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        reply = ""
        queued = 0
    }

    private func say(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: \.isLetter) else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        synthesizer.speak(utterance)
    }

    /// The best installed voice for the text's language, preferring the user's chosen system voice.
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
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
            (#"(?m)([^.!?:\s])[ \t]*$"#, "$1."),       // a line without an ending gets a pause
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }
}
