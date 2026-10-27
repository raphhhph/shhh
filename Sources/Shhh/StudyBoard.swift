import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The study whiteboard: a window where Joe sets IB questions one at a time, the student answers by
/// typing (or holding right ⌥ and talking), and Joe marks each answer like an examiner, with what
/// earned the marks, what was missing and a model answer. It runs its own quick tutor session
/// (no browser or connectors), with the subject's syllabus map and their recent results built in.
@MainActor
final class StudyBoard: NSObject, NSWindowDelegate {
    let model = StudyBoardModel()
    private var window: NSWindow?

    /// Reads Joe's short spoken line and the question aloud (when the voice is on).
    var speak: (String) -> Void = { _ in }
    var stopSpeaking: () -> Void = {}

    override init() {
        super.init()
        model.speak = { [weak self] in self?.speak($0) }
        model.stopSpeaking = { [weak self] in self?.stopSpeaking() }
    }

    /// Open on the window, and start a session when a subject (and maybe a request) is given.
    func show(subject: String? = nil, request: String? = nil, mode: StudyBoardModel.Mode = .quiz) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Study"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 620, height: 520)
            window.delegate = self
            window.contentView = NSHostingView(rootView: StudyBoardView(model: model))
            window.center()
            window.setFrameAutosaveName("JoeStudyBoard")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let subject { model.start(subject: subject, request: request, mode: mode) }
    }

    /// Open and in front: a voice answer (right ⌥) goes here, not to the notch.
    var isTakingAnswers: Bool { NSApp.isActive && window?.isKeyWindow == true && model.isActive }

    func answer(byVoice text: String) {
        window?.makeKeyAndOrderFront(nil)
        model.submit(text, spoken: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.end()
    }

    /// "Quiz me on econ externalities" → ("Economics HL", the request), from their subjects.
    static func subject(in request: String) -> String? {
        let subjects = Profile.subjects.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } + ["TOK"]
        let lower = request.lowercased()
        let keys: [String: [String]] = [
            "Mathematics AI": ["math", "maths", "calculus", "statistic", "probability"],
            "Economics": ["econ"],
            "Business Management": ["business", "bm "],
            "Environmental Systems and Societies": ["ess", "environmental"],
            "English A Language and Literature": ["english", "lang and lit", "lang & lit"],
            "Chinese B": ["chinese", "mandarin", "中文"],
            "Theory of Knowledge": ["tok", "theory of knowledge"],
            "Mathematics AA": ["math", "maths", "calculus", "statistic", "probability", "integra", "derivative", "vector"],
            "Physics": ["physic", "kinematic", "momentum", "circuit"],
            "Chemistry": ["chem", "organic", "titration", "enthalpy"],
            "Biology": ["bio", "cell", "enzyme", "genetic"],
            "History": ["histor", "cold war", "authoritarian"],
            "Psychology": ["psych"],
            "English B": ["english"],
            "Spanish": ["spanish", "español", "espanol"],
            "Geography": ["geog"],
            "Computer Science": ["computer", "coding", "programming", "algorithm", "sql"],
            "Global Politics": ["politic", "sovereignty", "human rights"],
        ]
        // Their own name for the subject ("quiz me on Geography") wins, with or without a map.
        if let named = subjects.first(where: {
            lower.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: $0.lowercased()) + #"\b"#, options: .regularExpression) != nil
        }) { return named }
        for subject in subjects {
            guard let pack = StudyBuddy.pack(for: subject), let words = keys[pack] else { continue }
            if words.contains(where: { lower.contains($0) }) { return subject }
        }
        return nil
    }
}

// MARK: - Model

@MainActor
final class StudyBoardModel: ObservableObject {
    /// review: going through a returned test's lost marks; feedback: a draft against the IB criteria.
    enum Mode: String { case quiz, exam, cards, review, feedback }

    enum Item: Identifiable, Equatable {
        case question(n: Int, marks: Int, topic: String, source: String, text: String)
        case answer(text: String, spoken: Bool, image: Data? = nil)
        case feedback(score: Int, total: Int, text: String, model: String)
        case summary(score: Int, total: Int, text: String)
        /// A short lesson before the questions ("teach me…", or a topic they keep losing marks on).
        case lesson(title: String, text: String)
        /// Definitions to learn word for word, after the summary: saved to their flashcards.
        case cards([Flashcards.Card])
        /// A returned mark, logged in "School/Marks.md" (mark review).
        case returned(assessment: String, mark: String, boundary: String)
        /// One criterion of draft feedback: its mark, band, quoted evidence and what lifts it a band.
        case criterion(name: String, score: Int, total: Int, band: String, text: String)
        case note(String)

        var id: String {
            switch self {
            case let .question(n, _, _, _, text): "q\(n)\(text.prefix(20))"
            case let .answer(text, _, image): "a\(text.hashValue)\(image?.count ?? 0)"
            case let .feedback(score, total, text, _): "f\(score)/\(total)\(text.prefix(20))"
            case let .summary(_, _, text): "s\(text.prefix(20))"
            case let .lesson(title, text): "l\(title)\(text.prefix(20))"
            case let .cards(cards): "c\(cards.count)\(cards.first?.term ?? "")"
            case let .returned(assessment, mark, _): "r\(assessment)\(mark)"
            case let .criterion(name, score, _, _, _): "k\(name)\(score)"
            case let .note(text): "n\(text.hashValue)"
            }
        }
    }

    @Published fileprivate(set) var subject = ""
    @Published private(set) var mode = Mode.quiz
    @Published fileprivate(set) var items: [Item] = []
    /// The reply still coming in, already laid out.
    @Published private(set) var live: [Item] = []
    @Published private(set) var status: String?
    @Published private(set) var isBusy = false
    @Published var draft = ""
    @Published var readAloud = UserDefaults.standard.object(forKey: "studyReadAloud") as? Bool ?? true {
        didSet { UserDefaults.standard.set(readAloud, forKey: "studyReadAloud") }
    }

    // Reviewing their flashcards: the cards still to go (the next one first), and how it's going.
    @Published private(set) var deck: [Flashcards.Card] = []
    @Published private(set) var deckSize = 0
    @Published private(set) var known = 0
    @Published private(set) var again: Set<String> = []
    @Published var flipped = false {
        didSet { if flipped, !oldValue, readAloud, let card = deck.first { speak(BoardMath.speakable(card.definition)) } }
    }
    /// The question they're on in exam mode: when it was set, and the time the real paper gives it.
    @Published private(set) var questionSince: Date?
    @Published private(set) var questionMinutes: Int?
    /// Goes up with each card marked, so the next one comes in as a new card.
    @Published private(set) var turn = 0
    /// What they said for this card (right ⌥), shown above the definition to compare.
    @Published private(set) var said: String?

    var speak: (String) -> Void = { _ in }
    var stopSpeaking: () -> Void = {}

    private var assistant: Assistant?
    private var reply = ""
    private var startedAt = Date()
    /// Draft feedback: the items already saved to their notes (each check is saved once).
    private var savedUpTo = 0

    var isActive: Bool { assistant != nil || (mode == .cards && !deck.isEmpty) }

    /// Questions set so far this session.
    var questionCount: Int {
        items.filter { if case .question = $0 { return true } else { return false } }.count
    }

    /// Marks so far this session.
    var score: (Int, Int) {
        items.reduce((0, 0)) { total, item in
            if case let .feedback(score, out, _, _) = item { return (total.0 + score, total.1 + out) }
            return total
        }
    }

    func start(subject: String, request: String?, mode: Mode) {
        end()
        // Feedback's "subject" is the project ("Extended Essay"), not a subject to quiz next time.
        if mode != .feedback { UserDefaults.standard.set(subject, forKey: "lastStudySubject") }
        self.subject = subject
        self.mode = mode
        items = []
        live = []
        draft = ""
        startedAt = Date()
        questionSince = nil
        savedUpTo = 0
        if mode == .cards { shuffleDeck(); return }
        let assistant = Assistant()
        assistant.tutorPrompt = mode == .feedback ? Self.feedbackPrompt(project: subject) : Self.tutorPrompt(subject: subject, mode: mode)
        // New or changed past papers are read in the background, for the next session's index.
        if mode != .feedback { PastPapers.refreshInBackground(pack: StudyBuddy.pack(for: subject)) }
        self.assistant = assistant
        assistant.prepare { [weak self] event in self?.handle(event) }
        var opening = request ?? { () -> String in
            switch mode {
            case .exam: return "Give me one full exam-style question."
            case .review: return "I've had a marked test back in \(subject). Start the mark review."
            case .feedback: return "Give me feedback on my \(subject) draft against the IB criteria."
            default: return "Start the quiz: five questions, focusing on my weak spots if you know them."
            }
        }()
        // The draft named in the project's note (its `doc:` line) comes with the first request.
        if mode == .feedback, let file = Marks.projectDraft(for: subject),
           let text = Marks.text(of: file), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(.answer(text: "Draft from the project note: \(file.lastPathComponent) · \(Marks.words(text)) words", spoken: false))
            opening += "\n\n" + Self.attachment(name: file.lastPathComponent, text: text)
        }
        send(opening)
    }

    // MARK: Files dropped on the board (a marked paper, a draft)

    /// The text of a dropped file as it goes to the tutor, with Joe's word count.
    private static func attachment(name: String, text: String) -> String {
        let body = text.count > 60_000 ? String(text.prefix(60_000)) + "\n[… cut at 60,000 characters]" : text
        return "[Attached file: \(name). Word count (Joe counted it): \(Marks.words(text)).]\n<file>\n\(body)\n</file>"
    }

    /// A paper or a draft: a photo goes as a picture; Word, Pages, PDF and text files as their text.
    func attach(_ url: URL) {
        guard assistant != nil, !isBusy else { return }
        let name = url.lastPathComponent
        if Marks.imageTypes.contains(url.pathExtension.lowercased()) {
            guard let image = Marks.jpeg(of: url) else { items.append(.note("Couldn't open \(name).")); return }
            items.append(.answer(text: name, spoken: false, image: image))
            send("[A photo of my paper or draft is attached: \(name). Read it, including any marks and comments written on it.]", image: image)
            return
        }
        isBusy = true
        status = "Reading \(name)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = Marks.text(of: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isBusy = false
                    self.status = nil
                    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.items.append(.note("Couldn't read any text in \(name). Try a PDF, a Word or Pages file, or paste the text."))
                        return
                    }
                    self.items.append(.answer(text: "\(name) · \(Marks.words(text)) words", spoken: false))
                    self.send(Self.attachment(name: name, text: text) + "\n\n" + (self.draft.isEmpty ? "" : self.draft))
                    self.draft = ""
                }
            }
        }
    }

    // MARK: Flashcards

    /// The subject's cards, shuffled, with the ones they missed last time first.
    private func shuffleDeck() {
        let cards = Flashcards.cards(subject)
        let missed = Set(Flashcards.missed(subject))
        deck = cards.filter { missed.contains($0.id) }.shuffled() + cards.filter { !missed.contains($0.id) }.shuffled()
        deckSize = deck.count
        known = 0
        again = []
        flipped = false
        said = nil
        sayTerm()
    }

    private func sayTerm() {
        stopSpeaking()
        if readAloud, let card = deck.first { speak(card.term) }
    }

    func reviewCards() {
        start(subject: subject, request: nil, mode: .cards)
    }

    /// "Got it", or "Again": the card comes back at the end of the deck.
    func mark(gotIt: Bool) {
        guard !deck.isEmpty else { return }
        let card = deck.removeFirst()
        turn += 1
        flipped = false
        said = nil
        if gotIt { known += 1 } else { deck.append(card); again.insert(card.id) }
        if deck.isEmpty { Flashcards.setMissed(Array(again), subject: subject) } else { sayTerm() }
    }

    /// A quiz on the cards they needed another go at (or the whole deck).
    func quizOnCards() {
        let all = Flashcards.cards(subject)
        let missed = all.filter { again.contains($0.id) }
        let terms = (missed.isEmpty ? all : missed).prefix(8).map(\.term)
        let request = terms.isEmpty ? nil : "Quiz me on these definitions: define questions first, then applying them. \(terms.joined(separator: "; "))."
        start(subject: subject, request: request, mode: .quiz)
    }

    func end() {
        assistant?.cancel()
        assistant = nil
        isBusy = false
        status = nil
        stopSpeaking()
    }

    /// Their answer (typed or said), or "hint", "skip", "end".
    func submit(_ text: String, spoken: Bool = false, image: Data? = nil) {
        if mode == .cards { said = text; flipped = true; return }
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Said while Joe is still marking: kept in the box to send, not lost.
        if isBusy, spoken, !text.isEmpty { draft = draft.isEmpty ? text : draft + " " + text; return }
        guard !text.isEmpty || image != nil, assistant != nil, !isBusy else { return }
        items.append(.answer(text: text, spoken: spoken, image: image))
        draft = ""
        if image != nil { text = (text.isEmpty ? "" : text + "\n\n") + "[My diagram is attached: mark it as part of my answer.]" }
        send(text, image: image)
    }

    func command(_ text: String) {
        guard assistant != nil, !isBusy else { return }
        items.append(.note(text))
        send(text)
    }

    private func send(_ text: String, image: Data? = nil) {
        stopSpeaking()
        reply = ""
        isBusy = true
        status = "Thinking…"
        assistant?.ask(text, screenshot: image)
    }

    private func handle(_ event: Assistant.Event) {
        switch event {
        case .status(let text):
            status = text
        case .answer(let text):
            reply = text
            live = Self.parse(text)
        case .approval(let approval):
            // Only reading notes and PDFs is allowed here; anything else is refused.
            approval?.decide(.deny)
        case .turnFinished:
            let parsed = Self.parse(reply)
            items += parsed
            // The exam clock: from the new question until it's marked.
            if parsed.contains(where: { if case .question = $0 { return true } else { return false } }) {
                questionSince = Date()
                questionMinutes = reply.range(of: #"<question\b[^>]*\btime="\d+""#, options: .regularExpression)
                    .flatMap { Int(reply[$0].components(separatedBy: "time=\"").last?.dropLast() ?? "") }
            } else if parsed.contains(where: { switch $0 { case .feedback, .summary: true; default: false } }) {
                questionSince = nil
            }
            live = []
            isBusy = false
            status = nil
            record(parsed)
            if readAloud { speak(Self.spoken(parsed)) }
        case .failed(let message):
            items.append(.note("Something went wrong: \(message)"))
            live = []
            isBusy = false
            status = nil
        default:
            break
        }
    }

    /// Each marked answer goes to the quiz log, like the notch's quizzes.
    private func record(_ parsed: [Item]) {
        for case let .returned(assessment, mark, boundary) in parsed {
            Marks.log(subject: subject, assessment: assessment, mark: mark, boundary: boundary)
        }
        if mode == .feedback { saveFeedback(); return }
        let date = Date().formatted(.iso8601.year().month().day())
        var lines: [String] = []
        var topic = items.reversed().compactMap { if case let .question(_, _, topic, _, _) = $0 { return topic } else { return nil } }.first ?? ""
        var question = items.reversed().compactMap { if case let .question(_, _, _, _, text) = $0 { return text } else { return nil } }.first ?? ""
        var lost: [Mistakes.Entry] = []
        for item in parsed {
            if case let .question(_, _, next, _, text) = item { topic = next; question = text }
            if case let .feedback(score, total, text, model) = item, total > 0, score < total {
                var entry = Mistakes.Entry(date: date, topic: topic, score: score, total: total, question: question,
                                           missing: Mistakes.missing(in: text), model: model)
                // A returned test's lost marks: why, and fresh redo questions on it in 1, 3 and 7 days.
                if mode == .review {
                    entry.cause = text.range(of: #"(?<=\*\*Cause:\*\* )[^\n]+"#, options: .regularExpression).map { String(text[$0]) } ?? ""
                    entry.redo = StudyReview.redoDates()
                }
                lost.append(entry)
            }
            if case let .feedback(score, total, text, _) = item, total > 0 {
                let missing = text.components(separatedBy: "\n").first { $0.lowercased().contains("missing") || $0.contains("✗") } ?? ""
                var note = missing.replacingOccurrences(of: #"^[-•*✗\s]+"#, with: "", options: .regularExpression)
                // Cut at a word, not mid-word ("the price producers rec").
                if note.count > 90 { note = String(note.prefix(90)).replacingOccurrences(of: #"\s+\S*$"#, with: "", options: .regularExpression) + "…" }
                lines.append("- \(date) · \(subject) · \(topic) · \(score)/\(total) · \(note)")
            }
        }
        Mistakes.record(lost, subject: subject)
        for case let .cards(cards) in parsed { Flashcards.save(cards, subject: subject) }
        guard !lines.isEmpty else { return }
        let url = StudyBuddy.logURL
        var log = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Quiz log\n"
        if !log.hasSuffix("\n") { log += "\n" }
        log += lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? log.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A finished draft check (its summary has come): the criteria and summary since the last one,
    /// dated, into the project's note under "## Feedback".
    private func saveFeedback() {
        guard savedUpTo < items.count,
              items[savedUpTo...].contains(where: { if case .summary = $0 { return true } else { return false } }) else { return }
        var lines: [String] = []
        for item in items[savedUpTo...] {
            switch item {
            case let .criterion(name, score, total, band, text):
                let mark = total > 0 ? " \(score)/\(total)" : ""
                lines.append("- **\(name)**\(mark)\(band.isEmpty ? "" : " (band \(band))"): " + text.replacingOccurrences(of: "\n", with: " "))
            case let .summary(score, total, text):
                lines.append("\n**Predicted:** \(score)/\(total)\n\n" + text)
            default: break
            }
        }
        savedUpTo = items.count
        guard !lines.isEmpty else { return }
        Marks.saveFeedback(lines.joined(separator: "\n"), project: subject)
    }

    /// What's read aloud: the short spoken line and the question.
    private static func spoken(_ parsed: [Item]) -> String {
        var parts: [String] = []
        for item in parsed {
            switch item {
            case let .note(text): parts.append(BoardMath.speakable(text))
            case let .lesson(title, text):
                // The title and the first sentence; the rest is for reading.
                let first = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? ""
                parts.append(BoardMath.speakable(title + ". " + first + "."))
            case let .question(_, marks, _, _, text):
                parts.append(BoardMath.speakable(text).replacingOccurrences(of: #"\|.*\|"#, with: "", options: .regularExpression) + " For \(marks) mark\(marks == 1 ? "" : "s").")
            default: break
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: Parsing the tags

    /// The reply's tagged parts in order: <question>, <feedback>, <model>, <summary>, and short
    /// text outside them. An unfinished tag (still streaming) is shown as far as it's got.
    static func parse(_ text: String) -> [Item] {
        var items: [Item] = []
        var rest = Substring(text)
        var pendingFeedback: (Int, Int, String)?
        func flushFeedback(model: String = "") {
            if let (score, total, body) = pendingFeedback { items.append(.feedback(score: score, total: total, text: body, model: model)) }
            pendingFeedback = nil
        }
        while let open = rest.range(of: #"<(question|feedback|model|summary|lesson|cards|ms|returned|criterion)\b[^>]*>"#, options: .regularExpression) {
            let before = rest[..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { flushFeedback(); items.append(.note(before)) }
            let tag = String(rest[open])
            let name = String(tag.dropFirst().prefix { $0.isLetter })
            let after = rest[open.upperBound...]
            // A self-closing tag (<returned … />) has no body.
            let close: Range<Substring.Index>? = tag.hasSuffix("/>") ? after.startIndex..<after.startIndex : after.range(of: "</\(name)>")
            let body = String(close.map { after[..<$0.lowerBound] } ?? after).trimmingCharacters(in: .whitespacesAndNewlines)
            func attribute(_ key: String) -> String {
                guard let match = tag.range(of: key + #"="([^"]*)""#, options: .regularExpression) else { return "" }
                return String(tag[match].dropFirst(key.count + 2).dropLast())
            }
            switch name {
            case "ms":
                break // the markscheme: Joe's, not shown
            case "question":
                flushFeedback()
                items.append(.question(n: Int(attribute("n")) ?? 0, marks: Int(attribute("marks")) ?? 0,
                                       topic: attribute("topic"), source: attribute("source"), text: body))
            case "feedback":
                flushFeedback()
                // Mark review: why the marks went, shown on the card and kept in the mistake book.
                let cause = attribute("cause")
                pendingFeedback = (Int(attribute("score")) ?? 0, Int(attribute("total")) ?? 0, cause.isEmpty ? body : "**Cause:** \(cause)\n" + body)
            case "returned":
                flushFeedback()
                items.append(.returned(assessment: attribute("assessment"), mark: attribute("mark"), boundary: attribute("boundary")))
            case "criterion":
                flushFeedback()
                items.append(.criterion(name: attribute("name"), score: Int(attribute("score")) ?? 0, total: Int(attribute("total")) ?? 0,
                                        band: attribute("band"), text: body))
            case "lesson":
                flushFeedback()
                items.append(.lesson(title: attribute("title"), text: body))
            case "cards":
                flushFeedback()
                let cards = body.components(separatedBy: "\n").compactMap(Flashcards.parse)
                if !cards.isEmpty { items.append(.cards(cards)) }
            case "model":
                if pendingFeedback != nil { flushFeedback(model: body) } else { items.append(.feedback(score: 0, total: 0, text: "", model: body)) }
            default:
                flushFeedback()
                items.append(.summary(score: Int(attribute("score")) ?? 0, total: Int(attribute("total")) ?? 0, text: body))
            }
            guard let close else { rest = ""; break }
            rest = after[close.upperBound...]
        }
        flushFeedback()
        // Text after the last tag, unless it's the start of a tag still coming in.
        var tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = tail.range(of: "<", options: .backwards), !tail[open.lowerBound...].contains(">") { tail = String(tail[..<open.lowerBound]) }
        tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { items.append(.note(tail)) }
        return items
    }

    // MARK: The tutor's instructions

    static func tutorPrompt(subject: String, mode: Mode) -> String {
        // MYP students are marked on criteria A–D, out of 8, not on DP marks.
        let myp = Profile.programme.uppercased().contains("MYP")
        let pack = myp ? "MYP" : StudyBuddy.pack(for: subject)
        let map = pack.flatMap { try? String(contentsOf: StudyBuddy.syllabus.appendingPathComponent($0 + ".md"), encoding: .utf8) } ?? ""
        let terms = (try? String(contentsOf: StudyBuddy.syllabus.appendingPathComponent("Command terms.md"), encoding: .utf8)) ?? ""
        // Their results in this subject: by its map, or by name when it has none (and for MYP, whose map is the framework).
        let subjectPack = StudyBuddy.pack(for: subject)
        let history = StudyBuddy.results().filter { subjectPack == nil ? $0.subject == subject : StudyBuddy.pack(for: $0.subject) == subjectPack }.suffix(25)
            .map { "- \($0.topic): \($0.score)/\($0.total) \($0.note)" }.joined(separator: "\n")
        let due = StudyReview.lines(StudyReview.due(subject: subject), limit: 10)
        let exe = Bundle.main.executablePath ?? "Joe"
        let papers = Self.pastPapers(for: subjectPack)
        // Weak and due topics first, so a real question on what they need comes up.
        let weak = Dictionary(grouping: StudyBuddy.results().filter { StudyBuddy.pack(for: $0.subject) == subjectPack }, by: \.topic)
            .filter { Double($0.value.reduce(0) { $0 + $1.score }) / Double(max(1, $0.value.reduce(0) { $0 + $1.total })) < 0.6 }.keys
        let focus: [String] = StudyReview.due(subject: subject).map(\.topic) + Array(weak)
        let indexed: String? = myp ? nil : subjectPack.flatMap { PastPapers.promptIndex(pack: $0, focus: focus) }
        let material: String
        if indexed != nil {
            material = "Their saved past papers are indexed below, question by question (topic, marks, pages). Prefer a real question on the topic they want (or a due or weak one): read its pages with \"\(exe)\" --pdf-text \"<file>\" \"<pages>\", ask it as printed (with its data, parts and marks; LaTeX for maths) and source=\"<paper title> Q<n>\". When it has markscheme pages, read them in the same step and put the real mark points in <ms>; mark with those."
        } else if papers.isEmpty {
            material = "No past papers are saved for this subject yet; write questions in the exact style of the real papers described below."
        } else {
            material = "Past papers saved for this subject: \(papers.joined(separator: "; ")). Prefer real questions from them: find one with \"\(exe)\" --pdf-find \"<pdf>\" \"<topic>\", read it with \"\(exe)\" --pdf-text \"<pdf>\" \"<pages>\", ask it as printed (with its data) and source=\"<paper, year, question>\", and mark with its markscheme when there is one."
        }
        let paperIndex = indexed.map { "\n# Their past papers, indexed\n" + $0 } ?? ""
        let mistakes = Mistakes.recent(subject).joined(separator: "\n\n")
        // Lost marks from a returned test, due for a fresh question today (1, 3 and 7 days after the review).
        let redos = StudyReview.redos(subject: subject)
        let redoLines = redos.isEmpty ? "" : "\n\n# Redo questions due (lost marks on a returned test; ask these first, a fresh question on the same point, topic=\"<the same topic>\" so it counts as done)\n"
            + redos.map { "- \($0.heading) · cause: \($0.cause.isEmpty ? "?" : $0.cause) · redo \($0.step) of \($0.steps)" }.joined(separator: "\n")
        let coverage = StudyReview.coverage(subject: subject)
        let untouched = coverage.untouched.isEmpty ? "" : "\n\n# Never practised yet (\(coverage.done) of \(coverage.total) subtopics done; when nothing is due and they name no topic, mix these in; \"something new\" means these)\n" + coverage.untouched.prefix(20).map { "- " + $0 }.joined(separator: "\n")
        let notes = StudyBuddy.schoolFolder?.appendingPathComponent("Subjects").path
        let reviewSession = """
            Mark review: they've had a marked test or paper back ("I got a 4 in maths") and want to sort out the lost marks. \
            No new quiz: work through their paper.
            1. If they haven't said, ask in one short line for the assessment's name, their mark (out of what, and the grade if they know it), the \
            grade boundary if they know it, and the paper: drop it on the whiteboard (a PDF or a photo) or type the questions they lost marks on.
            2. As soon as you know the mark, log it once: <returned assessment="Unit 3 test" mark="23/40 (4)" boundary="5 from 26/40"></returned> \
            (boundary empty when they don't know; never guess it).
            3. Then the questions that lost marks, one at a time, most marks lost first: <question n="3" marks="6" topic="<syllabus number and name \
            from the map>" source="<assessment> Q3">the question as printed</question>, and ask what they wrote and where the marks went. When the \
            marking is visible on the paper, say what you see and ask them to confirm instead.
            4. Then <feedback n="3" score="<marks they got>" total="<marks available>" cause="didn't know|command term|careless">✓ what earned \
            marks; ✗ missing: each lost mark point</feedback><model>the answer that gets full marks</model>, then the next lost question. cause: \
            didn't know = the content wasn't there; command term = they knew it but didn't answer what the command term asks (described when \
            asked to explain, no judgment on evaluate, too short for the marks); careless = a slip, misread, units, arithmetic, ran out of time. \
            When you can't tell, ask which it was before the feedback tag. Each one goes in their mistake book, and a fresh redo question on \
            it comes back tomorrow, in 3 days and in a week: say so once.
            5. When the lost questions are done (or on "end"): <summary score="<their total>" total="<marks available>">the mark; how the lost \
            marks split by cause (e.g. 9 didn't know, 4 command term, 3 careless); then **3 things to fix** as a numbered list, each concrete \
            (a topic to relearn with its syllabus number, a command-term habit, a checking habit)</summary>. No <cards> unless definitions were lost.
            """
        return """
            You are Joe, an IB Diploma tutor running a practice session on a whiteboard for \(Profile.name.isEmpty ? "a student" : Profile.name). \
            \(Profile.description) Subject: \(subject).

            # How to write (the whiteboard reads these tags)
            - A question: <question n="1" marks="4" topic="2.8 Externalities" source="IB-style">the question in Markdown</question>. \
            Data as Markdown tables; maths in LaTeX, inline as \\( \\frac{dy}{dx} = 3x^2 \\) and on its own line as \\[ \\int_0^1 x^2\\,dx \\] (the whiteboard \
            typesets it; plain numbers and money like $5 stay plain text). Same in feedback and model answers. One question at a time. Never put the answer in it.
            - Right after each question, its markscheme, hidden from them: <ms>each mark point as the IB would write it (M1, A1, \
            or one point per mark; for markband questions, what each band needs), and acceptable alternatives</ms>. Mark their answer \
            strictly against it, so the same answer always gets the same mark.
            - They can draw: a diagram sent as an image with their answer. Mark what's drawn (axes, labels, curves, shifts, areas) as an examiner would.
            - After they answer: <feedback n="1" score="3" total="4">✓ what earned marks, one bullet each; ✗ missing: what was missing, one bullet each</feedback> \
            then <model>the answer a markscheme would credit, concise</model>, then the next <question>.
            - Outside the tags, at most one short sentence, said aloud ("Nice, three out of four."). No other chatter.
            - At the end: <summary score="x" total="y">strengths, the weakest topic, the one thing to revise next</summary>.
            - Right after the summary, flashcards of what they must know word for word: <cards>one per line, term :: the definition as the \
            markscheme words it</cards>. One for every define question in the session, plus the key terms they got wrong or left out; at most 12, \
            none when there were none. They're saved to their deck for review. When they ask you to make flashcards on a topic, give the <cards> \
            tag straight away (8 to 15 cards, from the syllabus map and their notes) and no questions.
            - To teach before testing: <lesson title="2.9 Public goods">a short lesson in Markdown: the key definitions word for word, the idea in \
            3 to 6 bullets, the diagram described (axes, curves, the shift), one worked example or real-world case, and the mistakes that lose \
            marks (theirs first, from their mistake book)</lesson>, then the first question on it. Give a lesson when they ask to be taught or to \
            "explain" a topic, and before the first question on a topic they scored under 40% on twice or more. At most about 180 words.

            \(myp ? "# MYP\nThey're in the MYP (\(Profile.programme)). Name the criterion each question targets, and mark on that criterion's band and level out of 8 (score=\"6\" total=\"8\"), using the descriptors below. No DP papers.\n" : "")
            # The session
            \(mode == .review ? reviewSession : mode == .exam
                ? "Exam mode: one full question in the style of a real paper for this subject (with parts (a), (b)…, a stimulus or data where the paper has one, marks per part), with time=\"<minutes>\" in the question tag: the time the real paper allows for those marks. Mark it part by part; long parts with markbands. Then the summary, saying whether they'd have finished in time."
                : "Quiz mode: five questions, easier to harder, IB command terms and marks in brackets, a mix of definitions, application to a short context, calculations where the subject has them, and one exam-style question. Cover the topic they ask for; otherwise the topics due for review below first (they're about to forget them), then their weakest topics from the results. After the fifth, the summary.")
            - "hint": a hint, not the answer. "skip": the model answer and 0 marks (a feedback tag with score 0), then go on. "end": the summary now. \
            Any other question from them: answer it briefly, then carry on.
            - Mark strictly but fairly, like an IB examiner: the command term sets the depth, partial marks are fine, follow-through for \
            a slip carried correctly. Diagrams: they describe them in words; mark the description.
            \(pack == "Chinese B" ? "- Chinese B: questions in simplified Chinese; corrections as 原句 → 改正; explanations in English.\n" : "")
            # Material
            - Real past-paper questions beat invented ones. \(material)
            \(notes.map { "- Their class notes are in \($0), for when they ask for questions \"from my notes\"." } ?? "")
            - Speed matters: they're waiting. Ask the first question straight away, with no tools, unless you're taking it from a past paper. Never use tools to mark.

            # Due for review (spaced repetition: a topic comes back sooner when they scored low)
            \(due.isEmpty ? "Nothing due." : due)

            # Their recent results in this subject
            \(history.isEmpty ? "None yet." : history)

            # Their recent mistakes (from their mistake book: re-test these with a fresh question on the same point, never the same wording; "redo my mistakes" means only these)
            \(mistakes.isEmpty ? "None yet." : mistakes)\(redoLines)\(untouched)

            # Syllabus map
            \(map)

            # Command terms and marking
            \(terms)
            \(paperIndex)
            """
    }

    /// Draft feedback: the coursework criteria (Rubrics.md) and how to mark a draft against them.
    static func feedbackPrompt(project: String) -> String {
        let rubrics = (try? String(contentsOf: StudyBuddy.syllabus.appendingPathComponent("Rubrics.md"), encoding: .utf8)) ?? ""
        let saved = Marks.feedbackURL(for: project)
        let earlier = (try? String(contentsOf: saved, encoding: .utf8))
            .flatMap { $0.components(separatedBy: "### ").dropFirst().last }
            .map { "\n# Their last feedback on this (say what improved and what didn't)\n### " + String($0.prefix(2500)) } ?? ""
        return """
            You are Joe, an IB Diploma coach checking a draft against the IB assessment criteria, like an experienced moderator, \
            for \(Profile.name.isEmpty ? "a student" : Profile.name). \(Profile.description) Subjects: \(Profile.subjects). The work: \(project).

            # How to write (the whiteboard reads these tags)
            - Until the draft has come, ask for it in one short line: drop the file on the whiteboard (Word, Pages, PDF or text) or paste it. \
            Work out which assessment it is (an IA of which subject, the EE and its subject, the TOK essay or exhibition, the IO) from what \
            they said and the draft; ask only if you can't tell. A dropped file arrives as <file>…</file> with Joe's word count: use that number.
            - Then one card per criterion of that assessment, in order: <criterion name="A · Focus and method" score="4" total="6" band="3–4">**Evidence:** \
            a short quote from the draft in quotation marks (or what's missing)
            **To lift it a band:** one or two concrete changes</criterion>. TOK essay and exhibition: one holistic criterion out of 10. \
            Mark honestly against the descriptors below (best fit; most drafts sit mid-band), never inflate.
            - Then <summary score="<predicted total>" total="<maximum>">**Predicted:** the total, and the grade when the rubric gives bands
            **Word count:** n of the limit, and what to cut or add when it's over or well under
            **The three biggest fixes:** a numbered list, most marks first</summary>
            - Outside the tags, at most one short sentence, said aloud. Quote only their words; never invent quotes.
            - Academic honesty: give advice, never rewritten paragraphs or text to paste in. Short examples of a structure are fine.
            - Follow-up questions: answer briefly. A new version of the draft: the whole set of cards again, saying what improved.
            - The feedback is saved to \(saved.path) with today's date; don't write files yourself. Never use tools to mark.
            \(earlier)

            # The criteria (Joe's summary of the IB guides)
            \(rubrics)
            """
    }

    /// PDFs in their notes that look like past papers or markschemes for this subject.
    static func pastPapers(for pack: String?) -> [String] {
        guard let pack, let root = Daybook.root?.appendingPathComponent("_files/School", isDirectory: true),
              let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        let subjectWords = pack.lowercased().split(separator: " ").map(String.init)
        return files.compactMap { $0 as? URL }.filter { url in
            let name = url.path.lowercased()
            return url.pathExtension.lowercased() == "pdf"
                && name.range(of: #"paper|markscheme|mark scheme|specimen|past"#, options: .regularExpression) != nil
                && subjectWords.contains { name.contains($0.prefix(5)) }
                && !name.contains("guidance") && !name.contains("guide") && !name.contains("technique") && !name.contains("checklist")
        }.map(\.path).prefix(12).map { $0 }
    }
}

// MARK: - View

private let accent = Color(red: 1, green: 0.58, blue: 0.12)

private struct StudyBoardView: View {
    @ObservedObject var model: StudyBoardModel
    var startSketching = false
    /// For the preview: a diagram already drawn.
    var demoStrokes: [SketchPad.Stroke] = []
    @FocusState private var typing: Bool
    @State private var sketching = false
    @State private var started = false
    @State private var strokes: [SketchPad.Stroke] = []
    @State private var ink = Color.black // the pad is white whatever the theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.mode == .cards {
                deckView
            } else {
                session
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { if !started { started = true; sketching = startSketching; strokes = demoStrokes } }
        .tint(accent)
    }

    @ViewBuilder
    private var session: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.items.isEmpty && model.live.isEmpty && !model.isBusy {
                        empty
                    }
                    // By position: two rows can be alike ("Nice." twice), and SwiftUI needs unique ids.
                    ForEach(Array((model.items + model.live).enumerated()), id: \.offset) { _, item in
                        row(item)
                    }
                    if model.isBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.status ?? "Thinking…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            // A marked paper or a draft dropped on the board.
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, url.isFileURL, model.isActive else { return false }
                model.attach(url)
                return true
            }
            .onChange(of: model.items.count) { withAnimation { scroll.scrollTo("end", anchor: .bottom) } }
            .onChange(of: model.live) { scroll.scrollTo("end", anchor: .bottom) }
        }
        Divider()
        composer
    }

    // MARK: Flashcards

    private var deckView: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            if let card = model.deck.first {
                Text("\(model.known) of \(model.deckSize) known").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                FlipCard(angle: model.flipped ? 180 : 0) {
                    VStack(spacing: 14) {
                        Text(card.term).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                        Text("Hold right ⌥ and say the definition, or think it, then click to flip")
                            .font(.system(size: 12.5)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }
                    .cardFace(tint: accent)
                } back: {
                    VStack(spacing: 12) {
                        Text(card.term).font(.system(size: 15, weight: .bold)).foregroundStyle(accent).multilineTextAlignment(.center)
                        if let said = model.said, !said.isEmpty {
                            Text("You said: \(said)").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        Divider()
                        BoardText(card.definition, size: 16, spacing: 3)
                    }
                    .cardFace(tint: accent, back: true)
                }
                // A springy turn, whether clicked, spaced or said; each new card slides in from the right.
                .animation(.spring(response: 0.55, dampingFraction: 0.68), value: model.flipped)
                .id(model.turn)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .contentShape(Rectangle())
                .onTapGesture { model.flipped.toggle() }
                HStack(spacing: 12) {
                    if model.flipped {
                        Button("Again") { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { model.mark(gotIt: false) } }
                            .keyboardShortcut("1", modifiers: [])
                        Button("Got it") { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { model.mark(gotIt: true) } }
                            .keyboardShortcut("2", modifiers: []).buttonStyle(.borderedProminent)
                    } else {
                        Button("Turn over") { model.flipped = true }
                            .keyboardShortcut(.space, modifiers: [])
                    }
                }
                .buttonStyle(.bordered).controlSize(.large)
            } else if model.deckSize == 0 {
                Text("No \(model.subject) flashcards yet").font(.system(size: 16, weight: .bold))
                Text("Joe makes them after each quiz, from the definitions it asked you.").font(.system(size: 13)).foregroundStyle(.secondary)
                Button("Quiz me on \(model.subject)") { model.quizOnCards() }.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.green)
                Text("Deck done").font(.system(size: 18, weight: .bold))
                Text(model.again.isEmpty ? "All \(model.deckSize) known first time."
                     : "\(model.deckSize) cards, \(model.again.count) needed another go. Those come first next time.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Go again") { model.reviewCards() }
                    Button(model.again.isEmpty ? "Quiz me on these" : "Quiz me on the hard ones") { model.quizOnCards() }.buttonStyle(.borderedProminent)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "graduationcap.fill").foregroundStyle(accent).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.subject.isEmpty ? "Study" : model.subject).font(.system(size: 16, weight: .bold))
                Text(model.mode == .cards ? "Flashcards" + (model.deck.isEmpty ? "" : " · \(model.deck.count) to go")
                     : model.mode == .exam ? "Exam question"
                     : model.mode == .review ? "Mark review" + (model.questionCount > 0 ? " · question \(model.questionCount)" : "")
                     : model.mode == .feedback ? "Draft feedback against the IB criteria"
                     : "Quiz" + (model.questionCount > 0 ? " · question \(model.questionCount)" : "")).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.mode == .exam, let since = model.questionSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(since))
                    let over = model.questionMinutes.map { seconds > $0 * 60 } ?? false
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60) + (model.questionMinutes.map { " / \($0) min" } ?? ""))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(over ? Color.orange : Color.secondary)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .help("Time on this question, and what the real paper allows")
                }
            }
            let (score, total) = model.score
            if total > 0 {
                Text("\(score)/\(total)").font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(Double(score) / Double(total) >= 0.7 ? .green : Double(score) / Double(total) >= 0.45 ? .orange : .red)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Toggle(isOn: $model.readAloud) { Image(systemName: model.readAloud ? "speaker.wave.2" : "speaker.slash") }
                .toggleStyle(.button).buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Read questions aloud")
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.mode == .review || model.mode == .feedback
                 ? "Drop your \(model.mode == .review ? "marked paper" : "draft") here (PDF, photo, Word, Pages or text), or paste it below."
                 : "Pick a subject on the Study page, or say “quiz me on…”.").font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    @ViewBuilder
    private func row(_ item: StudyBoardModel.Item) -> some View {
        switch item {
        case let .question(n, marks, topic, source, text):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(n > 0 ? "Question \(n)" : "Question").font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
                    if !topic.isEmpty { chip(topic) }
                    if !source.isEmpty, source.lowercased() != "ib-style" { chip(source) }
                    Spacer()
                    if marks > 0 { Text("[\(marks)]").font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(.secondary) }
                }
                // The marks are in the corner; a "[4]" at the end of the text would say it twice.
                BoardText(marks > 0 ? text.replacingOccurrences(of: #"\s*\[\d{1,2}\]\s*$"#, with: "", options: .regularExpression) : text,
                          size: 15.5, spacing: 3)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(accent.opacity(0.35)))
        case let .answer(text, spoken, image):
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 4) {
                    if let image, let picture = NSImage(data: image) {
                        Image(nsImage: picture).resizable().scaledToFit().frame(maxWidth: 320, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if !text.isEmpty {
                        Text(text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if spoken { Label("said", systemImage: "waveform").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case let .feedback(score, total, text, modelAnswer):
            VStack(alignment: .leading, spacing: 10) {
                if total > 0 {
                    HStack(spacing: 8) {
                        Text("\(score)/\(total)").font(.system(size: 20, weight: .bold).monospacedDigit()).foregroundStyle(Self.color(score, total))
                        Text("marks").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if !text.isEmpty {
                    BoardText(text, size: 13.5)
                }
                if !modelAnswer.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MODEL ANSWER").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
                        BoardText(modelAnswer, size: 13.5)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Self.color(score, max(total, 1)).opacity(total > 0 ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case let .summary(score, total, text):
            VStack(alignment: .leading, spacing: 8) {
                let label = model.mode == .review ? "Mark" : model.mode == .feedback ? "Predicted" : "Session"
                Text(total > 0 ? "\(label): \(score)/\(total)" : model.mode == .feedback ? "Feedback summary" : "\(label) summary").font(.system(size: 16, weight: .bold))
                BoardText(text, size: 13.5, spacing: 0)
                // What next, without typing: the session's own advice, as buttons.
                if !model.isBusy, model.mode == .review {
                    HStack(spacing: 8) {
                        Button("Redo questions now") { model.start(subject: model.subject, request: "Quiz me on the questions I just lost marks on: a fresh question on each point, same topics.", mode: .quiz) }
                        Button("Mistake book") { Mistakes.open(model.subject) }
                        Button("Marks log") { NSWorkspace.shared.open(Marks.logURL) }
                    }
                    .buttonStyle(.bordered).controlSize(.small).padding(.top, 4)
                } else if !model.isBusy, model.mode == .feedback {
                    HStack(spacing: 8) {
                        Button("Open saved feedback") { NSWorkspace.shared.open(Marks.feedbackURL(for: model.subject)) }
                        Text("Drop a new version to check it again.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.bordered).controlSize(.small).padding(.top, 4)
                } else if !model.isBusy {
                    HStack(spacing: 8) {
                        Button("Another quiz") { model.start(subject: model.subject, request: "Another quiz: five new questions, starting with what I just got wrong.", mode: .quiz) }
                        Button("Teach me my weakest topic") { model.start(subject: model.subject, request: "Teach me the weakest topic from my last session with a short lesson, then test me on it.", mode: .quiz) }
                        if model.mode != .exam { Button("Exam question") { model.start(subject: model.subject, request: nil, mode: .exam) } }
                    }
                    .buttonStyle(.bordered).controlSize(.small).padding(.top, 4)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case let .note(text):
            BoardText(text, size: 13, spacing: 0, secondary: true)
        case let .cards(cards):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(cards.count) flashcard\(cards.count == 1 ? "" : "s") saved", systemImage: "rectangle.on.rectangle.angled")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(accent)
                    Spacer()
                    Button("Review them") { model.reviewCards() }.buttonStyle(.bordered).disabled(model.isBusy)
                }
                ForEach(cards) { card in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(card.term).font(.system(size: 13, weight: .semibold))
                        Text(card.definition).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case let .returned(assessment, mark, boundary):
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 18)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text([assessment.isEmpty ? "Returned mark" : assessment, mark].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 14, weight: .bold))
                    Text(boundary.isEmpty ? "Logged in Marks.md" : "Boundary: \(boundary) · logged in Marks.md")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case let .criterion(name, score, total, band, text):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(name.isEmpty ? "Criterion" : name).font(.system(size: 13.5, weight: .bold))
                    if !band.isEmpty { chip("band \(band)") }
                    Spacer()
                    if total > 0 {
                        Text("\(score)/\(total)").font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(Self.color(score, total))
                    }
                }
                BoardText(text, size: 13.5)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .leading) { Rectangle().fill(Self.color(score, max(total, 1))).frame(width: 3).padding(.vertical, 12) }
        case let .lesson(title, text):
            VStack(alignment: .leading, spacing: 8) {
                Label(title.isEmpty ? "Lesson" : title, systemImage: "book.closed.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(accent)
                BoardText(text, size: 14, spacing: 3)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 3).padding(.vertical, 14) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sketching {
                SketchPad(strokes: $strokes, ink: $ink)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text("Type your answer… (⌘↩ to submit) or hold right ⌥ and say it")
                        .font(.system(size: 14)).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $model.draft)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($typing)
                    .frame(minHeight: 70, maxHeight: 160)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(typing ? 0.25 : 0.1)))
            HStack(spacing: 8) {
                Button { withAnimation(.easeOut(duration: 0.15)) { sketching.toggle() } } label: {
                    Label(sketching ? "Hide sketch" : "Draw a diagram", systemImage: "pencil.and.scribble")
                }
                if sketching {
                    ForEach([Color.black, Color.red, Color.blue], id: \.self) { color in
                        Circle().fill(color).frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: ink == color ? 2 : 0).padding(-3))
                            .onTapGesture { ink = color }
                    }
                    Button("Clear") { strokes = [] }
                }
                if model.mode == .review || model.mode == .feedback {
                    Button { choose() } label: { Label(model.mode == .review ? "Add paper" : "Add draft", systemImage: "paperclip") }
                        .help("A PDF or photo of the paper, or the draft as Word, Pages, PDF or text. Or drop it on the board.")
                } else {
                    Button("Hint") { model.command("hint") }
                }
                Button("Skip") { model.command("skip") }
                Button("End") { model.command("end") }
                Spacer()
                Button {
                    model.submit(model.draft, image: strokes.isEmpty ? nil : SketchPad.jpeg(strokes))
                    strokes = []
                } label: { Label("Submit", systemImage: "arrow.up") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled((model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && strokes.isEmpty) || model.isBusy)
            }
            .buttonStyle(.bordered)
            .disabled(!model.isActive)
        }
        .padding(16)
    }

    /// A file for the tutor: the marked paper, or the draft.
    private func choose() {
        let panel = NSOpenPanel()
        let types: [UTType] = [.pdf, .image, .plainText, .rtf, .html, .text]
        panel.allowedContentTypes = types + ["docx", "doc", "pages", "odt", "md"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.attach(url) }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private static func color(_ score: Int, _ total: Int) -> Color {
        let ratio = Double(score) / Double(max(total, 1))
        return ratio >= 0.7 ? .green : ratio >= 0.45 ? .orange : .red
    }

}

// MARK: - Flip card

/// A flashcard that turns over in 3D: the front until halfway, then the back (drawn mirrored so
/// it reads the right way round), lifting a little mid-turn so it feels like a card in the hand.
private struct FlipCard<Front: View, Back: View>: View, Animatable {
    var angle: Double
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let showingBack = angle.truncatingRemainder(dividingBy: 360) > 90 && angle.truncatingRemainder(dividingBy: 360) < 270
        ZStack {
            front.opacity(showingBack ? 0 : 1)
            back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0)).opacity(showingBack ? 1 : 0)
        }
        .frame(maxHeight: 380) // both sides the same size
        .scaleEffect(1 + 0.06 * sin(angle * .pi / 180))
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .shadow(color: .black.opacity(0.12 + 0.12 * sin(angle * .pi / 180)), radius: 10 + 10 * sin(angle * .pi / 180), y: 6)
    }
}

private extension View {
    /// One side of a flashcard: the same size front and back, so the turn doesn't jump.
    func cardFace(tint: Color, back: Bool = false) -> some View {
        padding(28)
            .frame(maxWidth: 560, minHeight: 260, maxHeight: .infinity)
            .background(back ? Color(nsColor: .textBackgroundColor) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(tint.opacity(back ? 0.6 : 0.35), lineWidth: back ? 1.5 : 1))
    }
}

// MARK: - Sketch pad

/// Drawing a diagram with the trackpad or mouse: a supply-and-demand shift, a food web, a graph.
/// Sent to Joe as a picture with the answer.
struct SketchPad: View {
    struct Stroke { var points: [CGPoint]; var color: Color }

    @Binding var strokes: [Stroke]
    @Binding var ink: Color
    @State private var drawing = false

    var body: some View {
        Canvas { context, size in Self.draw(strokes, in: &context, size: size) }
            .background(Color.white)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if drawing, !strokes.isEmpty {
                        strokes[strokes.count - 1].points.append(value.location)
                    } else {
                        drawing = true
                        strokes.append(Stroke(points: [value.location], color: ink))
                    }
                }
                .onEnded { _ in drawing = false })
            .overlay(alignment: .topLeading) {
                if strokes.isEmpty {
                    Text("Draw here: axes, curves, labels, arrows").font(.system(size: 12)).foregroundStyle(.gray).padding(10)
                }
            }
    }

    static func draw(_ strokes: [Stroke], in context: inout GraphicsContext, size: CGSize) {
        for stroke in strokes where stroke.points.count > 1 {
            var path = Path()
            path.addLines(stroke.points)
            // Black ink stays black on the white page, whatever the app's theme.
            let color = stroke.color == .primary ? Color.black : stroke.color
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }

    /// The drawing as a JPEG, on white, for Claude to look at.
    @MainActor static func jpeg(_ strokes: [Stroke]) -> Data? {
        let points = strokes.flatMap(\.points)
        let width = max(400, (points.map(\.x).max() ?? 400) + 20), height = max(260, (points.map(\.y).max() ?? 260) + 20)
        let renderer = ImageRenderer(content: Canvas { context, size in draw(strokes, in: &context, size: size) }
            .frame(width: width, height: height).background(Color.white))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

// MARK: - Preview

extension StudyBoard {
    /// `Joe --board-preview <file.png> [sketch|deck|review|feedback]`: the whiteboard with a sample
    /// question and mark (or a flashcard, a mark review, draft feedback).
    static func preview(to file: URL, sketch: Bool, deck: Bool = false, sample: String? = nil, done: @escaping () -> Void) {
        let board = StudyBoard()
        board.model.preview(StudyBoardModel.parse("""
            Let's go. <question n="1" marks="4" topic="2.7 Indirect taxes" source="IB-style">**Draw** a diagram to show the effect of a specific tax on a market. [4]</question><ms>hidden</ms>
            """) + [.answer(text: "Supply shifts up by the tax, price rises, quantity falls.", spoken: true)] + StudyBoardModel.parse("""
            <feedback n="1" score="3" total="4">✓ Supply shifts up by the tax
            ✓ Higher price, lower quantity
            ✗ missing: the price producers receive</feedback><model>S shifts vertically by the tax; consumers pay Pc, producers get Pp.</model>
            <summary score="3" total="4">Good diagram; label the price producers receive.</summary>
            <cards>
            Specific tax :: a fixed amount of tax per unit of a good, shifting supply up by the tax
            **Tax incidence** :: how the burden of a tax is split between consumers and producers
            </cards>
            """), subject: "Economics HL", sketching: sketch)
        if deck {
            board.model.previewDeck([Flashcards.Card(term: "Specific tax", definition: "A fixed amount of tax per unit of a good, shifting supply up by the amount of the tax."),
                                     Flashcards.Card(term: "Tax incidence", definition: "How the burden of a tax is split between consumers and producers.")])
        }
        if sample == "review" {
            board.model.previewSession(StudyBoardModel.parse("""
                Ouch, let's sort it. <returned assessment="Unit 3 test" mark="23/40 (4)" boundary="5 from 26/40"></returned>
                <question n="3" marks="6" topic="4.9 Normal distribution" source="Unit 3 test Q3">The masses of apples are normally distributed with mean 150 g and standard deviation 12 g. Find the probability that an apple weighs more than 170 g, and the mass exceeded by 90% of apples. [6]</question>
                """) + [.answer(text: "I got 0.048 for the first part but used 0.9 instead of 0.1 for the second.", spoken: true)] + StudyBoardModel.parse("""
                <feedback n="3" score="3" total="6" cause="careless">✓ P(X > 170) = 0.0478, correct with working
                ✗ missing: inverse normal with the lower tail (0.1), giving 134.6 g
                ✗ missing: the answer to 3 significant figures</feedback><model>P(X > 170) = 0.0478; invNorm(0.1, 150, 12) = 134.6 g (3 s.f.: 135 g).</model>
                <summary score="23" total="40">23/40, a 4. Lost 17: 9 didn't know, 5 command term, 3 careless.
                **3 things to fix**
                1. Relearn 4.9 inverse normal: sketch the curve and shade before using the calculator.
                2. "Justify" needs a reason tied to the numbers, not just the answer.
                3. Check the tail and the rounding on every probability answer.</summary>
                """), subject: "Mathematics AI", mode: .review)
        } else if sample == "feedback" {
            board.model.previewSession([StudyBoardModel.Item.answer(text: "Extended Essay draft.docx · 3,912 words", spoken: false)] + StudyBoardModel.parse("""
                Here's where it stands. <criterion name="A · Focus and method" score="4" total="6" band="3–4">**Evidence:** "To what extent did the 2015 RMB devaluation affect Shenzhen electronics exporters?" is focused, but the method section only lists sources.
                **To lift it a band:** say why the firm interviews and the trade data were chosen, and what each can't show.</criterion>
                <criterion name="C · Critical thinking" score="6" total="12" band="5–8">**Evidence:** sections 3 and 4 describe the export figures ("exports rose by 8%") without weighing other causes.
                **To lift it a band:** separate the exchange rate effect from demand changes, and evaluate the reliability of the interview data.</criterion>
                <summary score="21" total="34">**Predicted:** 21/34, a B (low)
                **Word count:** 3,912 of 4,000, fine
                **The three biggest fixes:**
                1. Turn description into analysis in sections 3 and 4.
                2. Justify the method and its limits in the introduction.
                3. A conclusion that answers "to what extent" with a clear judgment.</summary>
                """), subject: "Extended Essay", mode: .feedback)
        }
        // A tax diagram in the three inks: black axes and demand, blue supply, red supply after the tax.
        func line(_ a: CGPoint, _ b: CGPoint, _ color: Color) -> SketchPad.Stroke {
            SketchPad.Stroke(points: (0...20).map { t in CGPoint(x: a.x + (b.x - a.x) * Double(t) / 20, y: a.y + (b.y - a.y) * Double(t) / 20) }, color: color)
        }
        let demo = sketch ? [
            line(CGPoint(x: 60, y: 20), CGPoint(x: 60, y: 200), .black), line(CGPoint(x: 60, y: 200), CGPoint(x: 520, y: 200), .black),
            line(CGPoint(x: 100, y: 40), CGPoint(x: 460, y: 190), .black),
            line(CGPoint(x: 100, y: 185), CGPoint(x: 460, y: 45), .blue),
            line(CGPoint(x: 100, y: 145), CGPoint(x: 440, y: 12), .red),
            line(CGPoint(x: 236, y: 132), CGPoint(x: 236, y: 92), .red),
        ] : []
        let host = NSHostingView(rootView: StudyBoardView(model: board.model, startSketching: sketch, demoStrokes: demo))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 860, height: 760), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                }
                _ = board
                done()
            }
        }
    }
}

extension StudyBoardModel {
    func preview(_ items: [Item], subject: String, sketching: Bool) {
        self.subject = subject
        self.items = items
    }

    /// A mark review or draft feedback session: for `--board-preview <png> review|feedback`.
    func previewSession(_ items: [Item], subject: String, mode: Mode) {
        self.subject = subject
        self.mode = mode
        self.items = items
    }

    /// The deck, turned over, with a spoken answer: for `--board-preview <png> deck`.
    func previewDeck(_ cards: [Flashcards.Card]) {
        mode = .cards
        deck = cards
        deckSize = cards.count + 3
        known = 3
        said = "a tax of a set amount on each unit"
        flipped = true
    }
}
