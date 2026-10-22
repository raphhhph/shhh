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
    /// Any Chinese characters at all.
    nonisolated static func hasHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// Text for macOS's own voices: another script (Cyrillic, Korean, Arabic, Japanese kana…), or,
    /// with European languages on, a Latin-script language other than English that's clearly that.
    /// Latin text otherwise stays with Alba: "HL A310" once came out in a Russian voice.
    nonisolated static func isOtherLanguage(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let latin = letters.filter { $0.value < 0x250 }.count
        if Double(latin) / Double(letters.count) < 0.5 { return true }
        guard Transcriber.languages == .european else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else { return false }
        return language != .english && confidence > 0.8 && text.split(separator: " ").count >= 4
    }

    /// "明天第一节是数学 AI HL，08:30–09:30。" → ["明天第一节是数学", "AI HL", "，八点三十到九点三十。"]:
    /// English words go to Alba, the rest to the Mandarin voice with numbers in Chinese.
    nonisolated static func chineseParts(_ text: String) -> [String] {
        var parts: [String] = []
        var rest = Substring(text)
        let latin = #"[A-Za-z][A-Za-z0-9'’&.+\-]*(?:\s+[A-Za-z0-9][A-Za-z0-9'’&.+\-]*)*"#
        while let range = rest.range(of: latin, options: .regularExpression) {
            parts.append(chineseNumbers(String(rest[..<range.lowerBound])))
            parts.append(String(rest[range]))
            rest = rest[range.upperBound...]
        }
        parts.append(chineseNumbers(String(rest)))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    /// Times, ranges and numbers the way they're said in Chinese: "08:30–09:30" → "八点三十到九点三十".
    nonisolated static func chineseNumbers(_ text: String) -> String {
        var text = text
        text = text.replacingOccurrences(of: #"([0-9])\s*[–—~-]\s*([0-9])"#, with: "$1到$2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([0-9]{1,2})[:：]([0-9]{2})"#, with: "$1点$2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([0-9]+(\.[0-9]+)?)\s*%"#, with: "百分之$1", options: .regularExpression)
        // Each run of digits (with a decimal part) in words. [0-9], not \d: \d also matches 八 and 零.
        while let range = text.range(of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression) {
            let number = String(text[range])
            let parts = number.split(separator: ".")
            var words = chineseInteger(Int(parts[0]) ?? 0)
            if parts.count > 1 { words += "点" + parts[1].map { chineseDigit(Int(String($0)) ?? 0) }.joined() }
            text.replaceSubrange(range, with: words)
        }
        return text
    }

    nonisolated private static func chineseDigit(_ digit: Int) -> String {
        ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"][digit]
    }

    /// 0–99,999 in words (larger numbers digit by digit, like a phone number).
    nonisolated private static func chineseInteger(_ value: Int) -> String {
        guard value >= 10 else { return chineseDigit(value) }
        guard value < 100_000 else { return String(value).map { chineseDigit(Int(String($0)) ?? 0) }.joined() }
        let units = ["", "十", "百", "千", "万"]
        let digits = String(value).map { Int(String($0)) ?? 0 }
        var result = ""
        var zero = false
        for (index, digit) in digits.enumerated() {
            let place = digits.count - 1 - index
            if digit == 0 { zero = true; continue }
            if zero, !result.isEmpty { result += "零" }
            zero = false
            result += (digit == 1 && place == 1 && result.isEmpty ? "" : chineseDigit(digit)) + units[place]
        }
        return result
    }

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

    /// How fast Joe talks: 1 is the voice's own pace. Faster helps when revising by ear.
    static var speed: Double {
        get { UserDefaults.standard.object(forKey: "voiceSpeed") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "voiceSpeed") }
    }

    static let speeds: [(value: Double, name: String)] = [(1, "Normal"), (1.15, "A bit faster"), (1.3, "Fast")]

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
    /// Sentences waiting to be said, in order, and the task working through them. `mac`: another
    /// language, said by the Mac's voice in its turn, so it never talks over Alba.
    private struct Line {
        let text: String
        var mac = false
    }

    private var pending: [Line] = []
    private var worker: Task<Void, Never>?
    /// Short lines already made ("One sec.", "Checking your calendar."), kept so they play at once,
    /// even after the voice has been let go.
    private var clips: [String: NeuralVoices.Audio] = [:]
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
        guard let end = rest.range(of: #"[.!?…:](?=\s)|\n"#, options: [.regularExpression, .backwards]) else {
            // Nothing said yet and a long first sentence: start at its first comma instead of waiting
            // for the end ("Good morning Raphael, you have Economics at nine…").
            if queued == 0, let comma = rest.range(of: #",(?=\s)"#, options: .regularExpression),
               rest[..<comma.lowerBound].split(separator: " ").count >= 6 {
                let clause = rest[..<comma.upperBound]
                queued += clause.count
                say(String(clause))
            }
            return
        }
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

    /// Says a short line in the gaps of a reply ("Opening Gmail."), without touching the reply
    /// being spoken: it joins the queue after whatever is already there.
    func announce(_ line: String) {
        guard current != .off else { return }
        say(line)
    }

    /// What Claude's status says, as Joe would say it while working, or nil for the steps not worth
    /// saying ("Working…", every click): "Searching: IB ESS paper 2" → "Searching for IB ESS paper 2.".
    nonisolated static func spokenStatus(_ status: String) -> String? {
        var line = status.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let quiet = ["Working", "Thinking", "Getting tools ready", "Reading the page", "Using Chrome", "Running a command"]
        // Small browser steps (scrolling, waiting, screenshots) happen many times a task: not news.
        guard !line.isEmpty, !quiet.contains(line), !hasHan(line) || isChinese(line),
              line.range(of: #"^(Scroll|Wait|Tak(e|es|ing) a screenshot|Hover|Press)"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        if line.hasPrefix("Searching: ") {
            line = "Searching for " + line.dropFirst("Searching: ".count).split(separator: " ").prefix(6).joined(separator: " ")
        }
        if line == "Searching your notes" { line = "Checking your notes" }
        // Steps Claude writes as orders ("Click the Compose button", "Start the study routine") or as
        // Chrome's summaries ("Opens the compose window") are said as what Joe is doing; anything else
        // that isn't "…ing" isn't said.
        let doing = ["click": "Clicking", "type": "Typing", "open": "Opening", "fill": "Filling in", "navigate": "Going to",
                     "go": "Going to", "search": "Searching", "send": "Sending", "write": "Writing", "check": "Checking",
                     "read": "Reading", "find": "Finding", "start": "Starting", "select": "Selecting", "upload": "Uploading",
                     "add": "Adding", "create": "Creating", "save": "Saving", "play": "Playing", "set": "Setting",
                     "turn": "Turning", "attach": "Attaching", "reply": "Replying", "draft": "Drafting", "submit": "Submitting",
                     "run": "Running", "look": "Looking", "switch": "Switching", "enter": "Entering", "update": "Updating",
                     "download": "Downloading", "copy": "Copying", "paste": "Pasting", "log": "Logging", "sign": "Signing"]
        let words = line.split(separator: " ", maxSplits: 1).map(String.init)
        let first = words[0].lowercased()
        let order = first.hasSuffix("ies") ? String(first.dropLast(3)) + "y"
            : doing[first] == nil && first.hasSuffix("es") && doing[String(first.dropLast(2))] != nil ? String(first.dropLast(2))
            : doing[first] == nil && first.hasSuffix("s") ? String(first.dropLast()) : first // "Opens" → "open"
        if let verb = doing[order] {
            line = ([verb] + words.dropFirst()).joined(separator: " ").replacingOccurrences(of: "to to ", with: "to ")
        } else if !words[0].hasSuffix("ing") {
            return nil
        }
        // An address as the name in it: "to pat.lee@school.org" → "to Pat Lee".
        while let address = line.range(of: #"[\w.+-]+@[\w-]+(\.[\w-]+)+"#, options: .regularExpression) {
            let name = line[address].split(separator: "@")[0].split(whereSeparator: { ".+_-".contains($0) || $0.isNumber })
            line.replaceSubrange(address, with: name.map(\.capitalized).joined(separator: " "))
        }
        // Long ones are details, not news.
        guard line.split(separator: " ").count <= 9 else { return nil }
        if line.hasPrefix("Opening ") || line.hasPrefix("Reading "), let host = line.split(separator: " ").last,
           line.split(separator: " ").count == 2, host.contains("."), !host.hasSuffix(".md") {
            // "Opening mail.google.com" → "Opening Gmail"; other sites by name.
            let names = ["mail.google.com": "Gmail", "calendar.google.com": "Google Calendar", "docs.google.com": "Google Docs",
                         "drive.google.com": "Google Drive", "www.youtube.com": "YouTube", "chatgpt.com": "ChatGPT"]
            // Otherwise the site's own name: "en.wikipedia.org" → "Wikipedia", "bbc.co.uk" → "BBC".
            let parts = host.split(separator: ".").map(String.init)
            var site = parts.count >= 2 ? parts[parts.count - 2] : String(host)
            if parts.count >= 3, ["co", "com", "ac", "edu", "gov", "org", "net"].contains(site) { site = parts[parts.count - 3] }
            let name = names[String(host)] ?? (host.contains("managebac") ? "ManageBac" : site.count <= 3 ? site.uppercased() : site.capitalized)
            line = String(line.split(separator: " ")[0]) + " " + name
        }
        // Note and file names: "Reading DP_ESS_Bioaccumulation" → "Reading DP ESS Bioaccumulation".
        line = line.replacingOccurrences(of: "_", with: " ")
        return line.hasSuffix(".") || line.hasSuffix("?") || line.hasSuffix("!") ? line : line + "."
    }

    /// Gets the chosen model ready (downloading it the first time), or lets go of the others.
    @discardableResult
    func prepare() -> Task<Void, Never> {
        let engine = Self.engine
        return Task {
            await neural.prepare(engine)
            guard engine != .off else { return }
            // The lines Joe says while Claude works, made now, so even the first one plays at once.
            for line in ["One sec."] where clips[line] == nil {
                var made: [Float] = []
                var rate = 0
                guard (try? await neural.speak(line, onAudio: { made += $0.samples; rate = $0.sampleRate })) != nil,
                      !made.isEmpty else { continue }
                clips[line] = NeuralVoices.Audio(samples: made, sampleRate: rate)
            }
        }
    }

    /// Lets go of the voices after ten quiet minutes (they take about 800 MB); the next sentence
    /// loads them again, a second or two. Called every minute.
    func trimMemory() {
        guard !isSpeaking, Date().timeIntervalSince(lastSpoke) > 600 else { return }
        neural.release()
    }

    private var lastSpoke = Date()

    /// The Mandarin voice, downloaded and loaded now (onboarding's "Get Joe ready").
    func prepareMandarin() {
        Task { _ = try? await neural.loadMandarin() }
    }

    /// The ask key went down: load Alba while they talk and Claude thinks, so the answer isn't held
    /// up by the reload after an idle unload.
    func warmUp() {
        guard Self.engine != .off else { return }
        lastSpoke = Date()
        Task { await neural.prepare(.lifelike) }
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
            let clean = Self.withoutSounds(sentence)
            if Self.hasHan(clean) {
                // Chinese, often with English in it ("数学 AI HL，08:30"): the Chinese parts in the
                // Mandarin voice with numbers said in Chinese, the English words in Alba's.
                pending += Self.chineseParts(Self.mathsInChinese(clean)).map { Line(text: $0) }
            } else if Self.isOtherLanguage(clean) {
                pending.append(Line(text: clean, mac: true))
            } else {
                pending.append(Line(text: Self.spokenMaths(clean)))
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
                var line = self.pending.removeFirst()
                // Sentences already waiting are said together, in one breath: the rhythm and
                // intonation carry across them, with no gap. Only what's already here, so the first
                // sentence of a reply never waits for the next.
                while !line.mac, self.clips[line.text] == nil, !Self.isChinese(line.text), let next = self.pending.first,
                      !next.mac, !Self.isChinese(next.text), line.text.count + next.text.count < 160 {
                    line = Line(text: line.text + " " + next.text)
                    self.pending.removeFirst()
                }
                let sentence = line.text
                let started = Date()
                self.lastSpoke = started
                if line.mac {
                    await self.sayWithMac(sentence)
                    continue
                }
                if let clip = self.clips[sentence] {
                    self.player.play(clip.samples, sampleRate: clip.sampleRate)
                    continue
                }
                var first: TimeInterval?
                var seconds = 0.0
                var made: [Float] = []
                var rate = 0
                do {
                    // Audio is played as it's made, a fraction of a second at a time, so speech
                    // starts almost at once instead of after the whole sentence.
                    try await self.neural.speak(sentence) { audio in
                        guard !Task.isCancelled else { return }
                        if first == nil { first = Date().timeIntervalSince(started) }
                        seconds += Double(audio.samples.count) / Double(audio.sampleRate)
                        if sentence.count <= 40 { made += audio.samples; rate = audio.sampleRate }
                        self.player.play(audio.samples, sampleRate: audio.sampleRate)
                    }
                } catch {
                    if ProcessInfo.processInfo.environment["SHHH_VOICE_LOG"] != nil { print("voice error:", error) }
                    // The voice isn't there (still downloading, or broken): the Mac's own says it.
                    if first == nil { await self.sayWithMac(sentence) }
                    continue
                }
                if !made.isEmpty, !Task.isCancelled {
                    if self.clips.count >= 40, let old = self.clips.keys.first { self.clips[old] = nil }
                    self.clips[sentence] = NeuralVoices.Audio(samples: made, sampleRate: rate)
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

    /// The Mac's voice says it once Alba's audio has played out, and is done before the next line.
    private func sayWithMac(_ text: String) async {
        while player.isPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        guard !Task.isCancelled else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.appleVoice(for: text)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(Self.speed))
        apple.speak(utterance)
        try? await Task.sleep(for: .milliseconds(150)) // until it has started
        while apple.isSpeaking, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
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
        // Tables and code are for reading: not said aloud.
        text = text.replacingOccurrences(of: #"(?m)^\s*\|.*\|\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)```.*?```"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        let replacements: [(String, String)] = [
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),         // [title](url) → title
            (#"https?://\S+"#, ""),                    // bare links
            (#"[\p{Extended_Pictographic}\x{FE0F}\x{200D}]"#, ""), // emoji
            (#"(\*\*|__|`|\*)"#, ""),                  // bold, code, italics
            (#"(?m)^\s*([-•*]|\d+\.)\s+"#, ""),        // list markers
            // Abbreviations said in full; their dots would also end a sentence too early.
            (#"\b[Ee]\.g\.,?"#, "for example,"),
            (#"\b[Ii]\.e\.,?"#, "that is,"),
            (#"\betc\.(?=[,;)])"#, "and so on"),
            (#"\betc\."#, "and so on."),
            (#"\bvs\.?(?=\s)"#, "versus"),
            (#"\bapprox\.(?=\s)"#, "about"),
            (#"(?m)([^.!?:\s\]])[ \t]*$"#, "$1."),     // a line without an ending gets a pause
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }

    /// A Chinese sentence with maths in it ("求 y = 3x² 的导数"): the maths in words first, so the
    /// English parts go to Alba as words, not symbols. Without maths it's left as it is, so times,
    /// numbers and percentages are still said in Chinese.
    nonisolated static func mathsInChinese(_ text: String) -> String {
        text.range(of: #"[=^²³√∫×÷−]|\\[A-Za-z]+"#, options: .regularExpression) != nil ? spokenMaths(text, inChinese: true) : text
    }

    /// Maths, science and units the way a teacher says them, for Alba, who would skip or spell out
    /// the symbols: "v = 3.2 × 10⁻⁴ m/s²" → "v equals 3.2 times 10 to the power of minus 4 metres per
    /// second squared". Study questions and feedback are full of these.
    /// `inChinese`: times, ranges and percentages are left for `chineseNumbers` to say in Chinese.
    nonisolated static func spokenMaths(_ text: String, inChinese: Bool = false) -> String {
        // Bare fractions ("3/4") and " - " are only read as maths in a sentence that is maths, not
        // in a date or a dash between words.
        let isMaths = text.range(of: #"[=+×÷^²³√∫−]|\\(frac|sqrt)"#, options: .regularExpression) != nil
        var text = text.replacingOccurrences(of: "−", with: "-")
        func sub(_ pattern: String, _ template: String) {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        // Clock times as said: "08:30" → "8:30", "9:00 AM" → "9 AM", "9:00" → "9 o'clock".
        if !inChinese {
            sub(#"(?<![0-9:])0([0-9]):([0-9]{2})"#, "$1:$2")
            sub(#"(?<![0-9:])([0-9]{1,2}):00\s?[Aa]\.?[Mm]\b\.?(?=\S)"#, "$1 AM")
            sub(#"(?<![0-9:])([0-9]{1,2}):00\s?[Pp]\.?[Mm]\b\.?(?=\S)"#, "$1 PM")
            sub(#"(?<![0-9:])([0-9]{1,2}):00\s?[Aa]\.?[Mm]\b"#, "$1 AM")
            sub(#"(?<![0-9:])([0-9]{1,2}):00\s?[Pp]\.?[Mm]\b"#, "$1 PM")
            sub(#"(?<![0-9:])([0-9]|1[0-2]):00(?![0-9:])"#, "$1 o'clock")
        }
        // Money, then LaTeX ($x^2$, \(…\), \frac{a}{b}) into plain symbols.
        sub(#"\$([0-9][0-9,]*(\.[0-9]+)?)"#, "$1 dollars")
        sub(#"\\[()\[\]]|\$"#, " ")
        sub(#"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#, " $1 over $2 ")
        sub(#"\\sqrt\{([^{}]*)\}"#, " the square root of $1 ")
        sub(#"\\(?:text|mathrm|mathbf)\{([^{}]*)\}"#, "$1")
        sub(#"\\int_\{?([^{}\s^]+)\}?\^\{?([^{}\s]+)\}?"#, " the integral from $1 to $2 of ")
        let commands: [(String, String)] = [
            ("times|cdot", "×"), ("div", "÷"), ("pm", "±"), ("leq?", "≤"), ("geq?", "≥"), ("neq?", "≠"),
            ("approx", "≈"), ("infty", "∞"), ("int", "∫"), ("sum", "∑"), ("to", " tends to "), ("rightarrow", "→"),
            ("circ|degree", "°"),
            ("(alpha|beta|gamma|delta|epsilon|theta|lambda|mu|pi|rho|sigma|phi|omega|Delta|sin|cos|tan|log|ln|exp)", " $1 "),
            ("(?:left|right|quad|qquad|displaystyle)", " "),
        ]
        for (name, template) in commands { sub(#"\\(?:"# + name + #")(?![A-Za-z])"#, template) }
        sub(#"\\[,;! ]|\\[A-Za-z]+"#, " ")
        sub(#"\^\{([^{}]*)\}"#, "^($1)")
        sub(#"_\{([^{}]*)\}|_([0-9A-Za-z])"#, " $1$2")
        sub(#"[{}]"#, " ")
        // Superscripts and subscripts as plain powers and numbers: x² → x^2, H₂O → H 2 O.
        let superscripts: [Character: String] = ["⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5",
                                                 "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "⁻": "-"]
        while let range = text.range(of: #"[⁰¹²³⁴⁵⁶⁷⁸⁹⁻]+"#, options: .regularExpression) {
            text.replaceSubrange(range, with: "^(" + text[range].map { superscripts[$0] ?? "" }.joined() + ")")
        }
        // Formulas symbol by symbol, as said in class: "6CO₂" → "6 C O 2", "C₆H₁₂O₆" → "C 6 H 12 O 6".
        if let formulas = try? NSRegularExpression(pattern: #"\b([0-9]*)((?:[A-Z][a-z]?[₀-₉]*)+)(?![A-Za-z])"#),
           let element = try? NSRegularExpression(pattern: #"([A-Z][a-z]?)([₀-₉]*)"#) {
            for match in formulas.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let whole = Range(match.range, in: text), let body = Range(match.range(at: 2), in: text),
                      text[body].range(of: "[₀-₉]", options: .regularExpression) != nil,
                      let count = Range(match.range(at: 1), in: text) else { continue }
                let symbols = String(text[body])
                let parts = element.matches(in: symbols, range: NSRange(symbols.startIndex..., in: symbols)).compactMap { part -> String? in
                    guard let symbol = Range(part.range(at: 1), in: symbols), let digits = Range(part.range(at: 2), in: symbols) else { return nil }
                    let number = symbols[digits].unicodeScalars.map { String($0.value - 0x2080) }.joined()
                    return number.isEmpty ? String(symbols[symbol]) : String(symbols[symbol]) + " " + number
                }
                text.replaceSubrange(whole, with: ([String(text[count])] + parts).filter { !$0.isEmpty }.joined(separator: " "))
            }
        }
        while let range = text.range(of: #"[₀₁₂₃₄₅₆₇₈₉]+"#, options: .regularExpression) {
            let digits = text[range].unicodeScalars.map { String($0.value - 0x2080) }.joined()
            text.replaceSubrange(range, with: " \(digits) ")
        }
        sub(#"\^\((-?[0-9a-zA-Z.]+)\)"#, "^$1")
        // Units after a number. Single letters need a space before them ("5 m", not "1990s").
        let units: [(String, String)] = [
            (#"m/s\^2|m s\^-2"#, "metres per second squared"), (#"m/s|m s\^-1"#, "metres per second"),
            ("km/h", "kilometres per hour"), (#"mol/dm\^3|mol dm\^-3"#, "moles per cubic decimetre"),
            ("kJ/mol", "kilojoules per mole"), ("g/mol", "grams per mole"), (#"cm\^3"#, "cubic centimetres"), (#"dm\^3"#, "cubic decimetres"),
            (#"m\^3"#, "cubic metres"), (#"cm\^2"#, "square centimetres"), (#"km\^2"#, "square kilometres"),
            (#"m\^2"#, "square metres"), ("kJ", "kilojoules"), ("kg", "kilograms"), ("mg", "milligrams"),
            ("km", "kilometres"), ("cm", "centimetres"), ("mm", "millimetres"), ("ml|mL", "millilitres"),
            ("kPa", "kilopascals"), ("Hz", "hertz"), ("kW", "kilowatts"), (#"°\s?C"#, "degrees Celsius"),
        ]
        for (unit, words) in units { sub(#"([0-9])\s?(?:"# + unit + #")(?![A-Za-z0-9^])"#, "$1 " + words) }
        let letterUnits = [("m", "metres"), ("s", "seconds"), ("g", "grams"), ("N", "newtons"), ("J", "joules")]
        for (unit, words) in letterUnits { sub(#"([0-9]) "# + unit + #"(?![A-Za-z0-9^'’])"#, "$1 " + words) }
        sub("°", " degrees")
        // Calculus and functions: dy/dx, f'(x), f(x).
        sub(#"\bd([a-zA-Z])/d([a-zA-Z])\b"#, "d $1 by d $2")
        sub(#"\b([fgh])['’]\(([^()]{1,10})\)"#, "$1 prime of $2")
        sub(#"\b([fgh])\(([^()]{1,10})\)"#, "$1 of $2")
        sub(#"√\(([^()]*)\)"#, " the square root of $1 ")
        sub("√", " the square root of ")
        // Powers.
        sub(#"\^\(?2\)?(?![0-9A-Za-z.])"#, " squared")
        sub(#"\^\(?3\)?(?![0-9A-Za-z.])"#, " cubed")
        sub(#"\^\((-?[^()]+)\)"#, " to the power of $1")
        sub(#"\^(-?[0-9a-zA-Z.]+)"#, " to the power of $1")
        sub(#"to the power of -"#, "to the power of minus ") // e^{-x}: the minus is said, not dropped
        // Fractions.
        sub(#"\b([a-z])/([a-z])\b"#, "$1 over $2")
        if isMaths {
            sub(#"(?<![0-9/])([0-9]+)/([0-9]+)(?![0-9/])"#, "$1 over $2")
        } else if let scores = try? NSRegularExpression(pattern: #"(?<![0-9/])([0-9]{1,3})/([0-9]{1,3})(?![0-9/])"#) {
            // A score, "6/7", is "6 out of 7"; a date, "21/10", is left alone.
            for match in scores.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let whole = Range(match.range, in: text), let top = Range(match.range(at: 1), in: text),
                      let bottom = Range(match.range(at: 2), in: text),
                      let mark = Int(text[top]), let total = Int(text[bottom]), mark <= total else { continue }
                text.replaceSubrange(whole, with: "\(mark) out of \(total)")
            }
        }
        // Symbols and operators.
        let symbols: [(String, String)] = [
            ("<=|≤", " is less than or equal to "), (">=|≥", " is greater than or equal to "),
            ("!=|≠", " is not equal to "), ("≈", " is about "), ("±", " plus or minus "), ("×", " times "),
            ("÷", " divided by "), ("∞", " infinity "), ("π", " pi "), ("θ", " theta "), ("Δ", " delta "),
            ("∫", " the integral of "), ("∑", " the sum of "), ("⇌", " is in equilibrium with "),
            (#"\b([a-z])\s*→\s*(?=-?[0-9∞])"#, "$1 tends to "), ("→", " gives "),
            ("=", " equals "),
            (#"(^|[\s(,])-(?=[0-9.])"#, "$1minus "),
        ]
        for (pattern, template) in symbols { sub(pattern, template) }
        if !inChinese {
            sub(#"([0-9])\s?[–—]\s?([0-9])"#, "$1 to $2")
            sub("%", " percent")
        }
        if isMaths {
            sub(#"\s<\s"#, " is less than ")
            sub(#"\s>\s"#, " is greater than ")
            sub(#"(?<=[0-9A-Za-z)])\s*\+\s*(?=[0-9A-Za-z(])"#, " plus ")
            sub(#"(?<=[0-9A-Za-z)])\s+-\s+(?=[0-9A-Za-z(])"#, " minus ")
        }
        sub(#"[ \t]{2,}"#, " ")
        sub(#"\s+([.,!?;:])"#, "$1")
        return text.trimmingCharacters(in: .whitespaces)
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

    /// Both voices out of memory until they're needed again.
    func release() {
        if let pocket { Task { await pocket.cleanup() } }
        pocket = nil
        kokoroChinese = nil
        kokoroChineseVoice = nil
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

    /// Alba being loaded: a sentence asked for while the ask key's warm-up is still loading her
    /// waits for that load instead of starting a second one (another 800 MB).
    private var loadingEnglish: Task<PocketTtsManager, Error>?

    private func englishManager() async throws -> PocketTtsManager {
        if let pocket { return pocket }
        if let loadingEnglish { return try await loadingEnglish.value }
        status = "Getting the voice ready…"
        let load = Task { @MainActor in
            let manager = PocketTtsManager(defaultVoice: SpeechOutput.lifelikeVoice)
            ModelGuard.willLoad(.voice)
            do { try await manager.initialize() } catch { ModelGuard.didFail(.voice, error); throw error }
            ModelGuard.didLoad(.voice)
            return manager
        }
        loadingEnglish = load
        defer { loadingEnglish = nil; status = nil }
        let manager = try await load.value
        pocket = manager
        return manager
    }

    func loadMandarin() async throws { _ = try await chineseManager(voice: SpeechOutput.chineseVoice) }

    private func chineseManager(voice: String) async throws -> KokoroAneManager {
        if let kokoroChinese, kokoroChineseVoice == voice { return kokoroChinese }
        status = "Getting the Chinese voice ready…"
        defer { status = nil }
        let version: KokoroAneVersion = if #available(macOS 15, *) { .v3 } else { .legacy }
        let manager = kokoroChinese ?? KokoroAneManager(variant: .mandarin, defaultVoice: voice, version: version)
        ModelGuard.willLoad(.mandarin)
        do { try await manager.initialize(preloadVoices: [voice]) } catch { ModelGuard.didFail(.mandarin, error); throw error }
        ModelGuard.didLoad(.mandarin)
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
    /// Speeds the voice up (the speed setting) without raising its pitch.
    private let pace = AVAudioUnitTimePitch()
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
            if engine.attachedNodes.contains(pace) { engine.detach(pace) }
            engine.attach(node)
            engine.attach(pace)
            engine.connect(node, to: pace, format: format)
            engine.connect(pace, to: engine.mainMixerNode, format: format)
            self.format = format
        }
        pace.rate = Float(SpeechOutput.speed)
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
