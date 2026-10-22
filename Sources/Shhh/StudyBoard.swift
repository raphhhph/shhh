import AppKit
import SwiftUI

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
        // Another "draw…" while Joe is already explaining this subject: the next question on the same board.
        if subject == model.subject, mode == .explain, model.mode == .explain, model.isActive, let request {
            model.submit(request, spoken: true)
        } else if let subject {
            model.start(subject: subject, request: request, mode: mode)
        }
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
    /// `explain`: no quiz, they ask and Joe answers at the board, drawing the diagrams as he goes.
    enum Mode: String { case quiz, exam, cards, explain }

    enum Item: Identifiable, Equatable {
        case question(n: Int, marks: Int, topic: String, source: String, text: String)
        case answer(text: String, spoken: Bool, image: Data? = nil)
        case feedback(score: Int, total: Int, text: String, model: String)
        case summary(score: Int, total: Int, text: String)
        /// A short lesson before the questions ("teach me…", or a topic they keep losing marks on).
        case lesson(title: String, text: String)
        /// Definitions to learn word for word, after the summary: saved to their flashcards.
        case cards([Flashcards.Card])
        /// A diagram Joe draws as the reply streams in: supply and demand, a tax, cost curves…
        case diagram(BoardDiagram)
        case note(String)

        var id: String {
            switch self {
            case let .question(n, _, _, _, text): "q\(n)\(text.prefix(20))"
            case let .answer(text, _, image): "a\(text.hashValue)\(image?.count ?? 0)"
            case let .feedback(score, total, text, _): "f\(score)/\(total)\(text.prefix(20))"
            case let .summary(_, _, text): "s\(text.prefix(20))"
            case let .lesson(title, text): "l\(title)\(text.prefix(20))"
            case let .cards(cards): "c\(cards.count)\(cards.first?.term ?? "")"
            case let .diagram(diagram): "d\(diagram.title)\(diagram.pieces.count)"
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
    /// What they said for this card (right ⌥), shown above the definition to compare.
    @Published private(set) var said: String?

    var speak: (String) -> Void = { _ in }
    var stopSpeaking: () -> Void = {}

    private var assistant: Assistant?
    private var reply = ""
    private var startedAt = Date()

    var isActive: Bool { assistant != nil || (mode == .cards && !deck.isEmpty) }

    /// Marks so far this session.
    var score: (Int, Int) {
        items.reduce((0, 0)) { total, item in
            if case let .feedback(score, out, _, _) = item { return (total.0 + score, total.1 + out) }
            return total
        }
    }

    func start(subject: String, request: String?, mode: Mode) {
        end()
        UserDefaults.standard.set(subject, forKey: "lastStudySubject")
        self.subject = subject
        self.mode = mode
        items = []
        live = []
        draft = ""
        startedAt = Date()
        DiagramClock.drawn = []
        questionSince = nil
        if mode == .cards { shuffleDeck(); return }
        let assistant = Assistant()
        assistant.tutorPrompt = Self.tutorPrompt(subject: subject, mode: mode)
        // New or changed past papers are read in the background, for the next session's index.
        PastPapers.refreshInBackground(pack: StudyBuddy.pack(for: subject))
        self.assistant = assistant
        assistant.prepare { [weak self] event in self?.handle(event) }
        let opening = request ?? (mode == .exam
            ? "Give me one full exam-style question."
            : mode == .explain ? "I'm at the whiteboard. In one line, ask what I'd like explained."
            : "Start the quiz: five questions, focusing on my weak spots if you know them.")
        send(opening)
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
    func submit(_ text: String, spoken: Bool = false, image: Data? = nil, onYourDiagram: Bool = false) {
        if mode == .cards { said = text; flipped = true; return }
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Said while Joe is still marking: kept in the box to send, not lost.
        if isBusy, spoken, !text.isEmpty { draft = draft.isEmpty ? text : draft + " " + text; return }
        guard !text.isEmpty || image != nil, assistant != nil, !isBusy else { return }
        items.append(.answer(text: text, spoken: spoken, image: image))
        draft = ""
        if image != nil {
            text = (text.isEmpty ? "" : text + "\n\n") + (onYourDiagram
                ? "[I drew on your diagram: my strokes are in black, red or blue over yours. Mark what I added as part of my answer.]"
                : "[My diagram is attached: mark it as part of my answer.]")
        }
        send(text, image: image)
    }

    func command(_ text: String) {
        guard assistant != nil, !isBusy else { return }
        items.append(.note(text))
        send(text)
    }

    /// From explaining to testing, in the same session: the tutor already knows what was covered.
    func quizOnThis() {
        guard assistant != nil, !isBusy else { return }
        mode = .quiz
        items.append(.note("Quiz me on this"))
        send("Now quiz me on what we just went through: quiz mode, five questions, easier to harder, then the summary.")
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
        let date = Date().formatted(.iso8601.year().month().day())
        var lines: [String] = []
        var topic = items.reversed().compactMap { if case let .question(_, _, topic, _, _) = $0 { return topic } else { return nil } }.first ?? ""
        var question = items.reversed().compactMap { if case let .question(_, _, _, _, text) = $0 { return text } else { return nil } }.first ?? ""
        var lost: [Mistakes.Entry] = []
        for item in parsed {
            if case let .question(_, _, next, _, text) = item { topic = next; question = text }
            if case let .feedback(score, total, text, model) = item, total > 0, score < total {
                lost.append(Mistakes.Entry(date: date, topic: topic, score: score, total: total, question: question,
                                           missing: Mistakes.missing(in: text), model: model))
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
        while let open = rest.range(of: #"<(question|feedback|model|summary|lesson|cards|diagram|ms)\b[^>]*>"#, options: .regularExpression) {
            let before = rest[..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { flushFeedback(); items.append(.note(before)) }
            let tag = String(rest[open])
            let name = String(tag.dropFirst().prefix { $0.isLetter })
            let after = rest[open.upperBound...]
            let close = after.range(of: "</\(name)>")
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
                pendingFeedback = (Int(attribute("score")) ?? 0, Int(attribute("total")) ?? 0, body)
            case "lesson":
                flushFeedback()
                items.append(.lesson(title: attribute("title"), text: body))
            case "diagram":
                flushFeedback()
                // Drawn line by line while it streams; a half-written last line waits for the rest.
                let diagram = BoardDiagram.parse(body, title: attribute("title"), complete: close != nil)
                if !diagram.pieces.isEmpty || close == nil { items.append(.diagram(diagram)) }
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
        let coverage = StudyReview.coverage(subject: subject)
        let untouched = coverage.untouched.isEmpty ? "" : "\n\n# Never practised yet (\(coverage.done) of \(coverage.total) subtopics done; when nothing is due and they name no topic, mix these in; \"something new\" means these)\n" + coverage.untouched.prefix(20).map { "- " + $0 }.joined(separator: "\n")
        let notes = StudyBuddy.schoolFolder?.appendingPathComponent("Subjects").path
        let quizRules = "Quiz mode: five questions, easier to harder, IB command terms and marks in brackets, a mix of definitions, application to a short context, calculations where the subject has them, and one exam-style question. Cover the topic they ask for; otherwise the topics due for review below first (they're about to forget them), then their weakest topics from the results. After the fifth, the summary."
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
            - They can draw: a diagram sent as an image with their answer. You see it. Mark what's drawn (axes, labels, curves, shifts, areas) \
            as an examiner would, then draw the correct version yourself in a <diagram> (below) so they can compare.
            - You draw on the board too, live: it draws each line of a <diagram> as you write it, like a teacher at a whiteboard. \
            Draw whenever a diagram is part of the answer: every economics diagram (supply and demand, shifts, taxes and subsidies, \
            price controls, externalities and welfare loss, elasticity, PPC, AD/AS, cost and revenue curves, market structures, \
            Lorenz curve, J-curve), graphs in maths and the sciences, flows and cycles. Put the diagram first, before the text \
            that explains it, so it builds while they read. Never inside another tag. The format, one command per line, \
            positions as x,y from 0 to 100 inside the axes (0,0 is the origin, 100,100 the top right):
            <diagram title="Specific tax">
            axes "Quantity" "Price"
            line D 10,90 90,15
            line S1 10,15 90,80 blue
            line S2 10,35 75,90 red dashed
            arrow 66,62 66,78 red
            point E1 53,50 x="Q1" y="P1"
            point E2 41,61 x="Q2" y="Pc"
            point "" 41,40 y="Pp"
            area 0,61 41,61 41,40 0,40 orange "Tax revenue"
            area 41,61 53,50 41,40 gray
            text 76,38 "Welfare loss"
            arrow 68,40 48,50 gray
            text 80,30 "Excess supply"
            </diagram>
            Commands: axes "x label" "y label"; line <label> x,y x,y [more points make a smooth curve, e.g. MC or AC]; \
            arrow x,y x,y [label] for a shift or movement; point <label> x,y [x="Q1"] [y="P1"] (dashed guides to the axes with \
            those marks); area x,y x,y x,y… [label] to shade (tax revenue, welfare loss, \
            surplus; a small one like a welfare-loss triangle gets no label: a text beside it and an arrow to it); text x,y "words"; \
            box x,y "label" for flow diagrams (with arrows between boxes, no axes). Colours: blue, red, green, orange, purple, \
            gray (black by default); add dashed for a curve after a shift. Draw in the order you'd explain: axes, the original \
            curves and equilibrium, then the shift (new curve in a colour, an arrow), the new equilibrium, then shaded areas. \
            Compute the coordinates so the lines really cross where the points say. Label every curve and axis as the IB expects \
            (P and Q or the real names, D, S, S+tax, MSC, MPB, AD, SRAS, LRAS…). Up to about 14 lines.
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
            \(mode == .explain
                ? "Explain mode: no quiz. They ask questions, by voice or typing, and you answer like a teacher at a whiteboard: first the <diagram> when one helps (always for an economics diagram), then <lesson title=\"…\">the explanation in Markdown: definitions word for word, the steps of the diagram, what to write in an exam to get the marks</lesson>. Before it, at most two short sentences outside the tags, said aloud. Follow-ups build on what's on the board (\"now add a subsidy\": draw the whole diagram again with it). When they say \"quiz me\", switch to quiz mode: " + quizRules
                : mode == .exam
                ? "Exam mode: one full question in the style of a real paper for this subject (with parts (a), (b)…, a stimulus or data where the paper has one, marks per part), with time=\"<minutes>\" in the question tag: the time the real paper allows for those marks. Mark it part by part; long parts with markbands. Then the summary, saying whether they'd have finished in time."
                : quizRules)
            - "hint": a hint, not the answer. "skip": the model answer and 0 marks (a feedback tag with score 0), then go on. "end": the summary now. \
            Any other question from them: answer it briefly, then carry on.
            - Mark strictly but fairly, like an IB examiner: the command term sets the depth, partial marks are fine, follow-through for \
            a slip carried correctly. Diagrams: they draw them or describe them in words; mark what they gave. Model answers to \
            diagram questions get a <diagram> after the <model>.
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
            \(mistakes.isEmpty ? "None yet." : mistakes)\(untouched)

            # Syllabus map
            \(map)

            # Command terms and marking
            \(terms)
            \(paperIndex)
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
    /// Joe's diagram under the sketch pad, to draw the shift or the labels on.
    @State private var base: BoardDiagram?
    @State private var padSize = CGSize(width: 600, height: 220)

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
                    ForEach(Array((model.items + model.live).enumerated()), id: \.offset) { index, item in
                        row(item, at: index)
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
                VStack(spacing: 14) {
                    Text(card.term).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
                    if model.flipped {
                        if let said = model.said, !said.isEmpty {
                            Text("You said: \(said)").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        Divider()
                        BoardText(card.definition, size: 16, spacing: 3)
                    } else {
                        Text("Hold right ⌥ and say the definition, or think it, then turn the card").font(.system(size: 12.5)).foregroundStyle(.tertiary)
                    }
                }
                .padding(28)
                .frame(maxWidth: 560, minHeight: 240)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(accent.opacity(0.35)))
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.flipped.toggle() } }
                HStack(spacing: 12) {
                    if model.flipped {
                        Button("Again") { model.mark(gotIt: false) }.keyboardShortcut("1", modifiers: [])
                        Button("Got it") { model.mark(gotIt: true) }.keyboardShortcut("2", modifiers: []).buttonStyle(.borderedProminent)
                    } else {
                        Button("Turn over") { withAnimation(.easeOut(duration: 0.15)) { model.flipped = true } }
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
                Text(model.mode == .cards ? "Flashcards" + (model.deck.isEmpty ? "" : " · \(model.deck.count) to go") : model.mode == .exam ? "Exam question" : model.mode == .explain ? "Ask anything: Joe draws it" : "Quiz").font(.system(size: 11.5)).foregroundStyle(.secondary)
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
            Text("Pick a subject on the Study page, or say “quiz me on…” or “draw me a diagram of…”.").font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    @ViewBuilder
    private func row(_ item: StudyBoardModel.Item, at index: Int) -> some View {
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
                Text(total > 0 ? "Session: \(score)/\(total)" : "Session summary").font(.system(size: 16, weight: .bold))
                BoardText(text, size: 13.5, spacing: 0)
                // What next, without typing: the session's own advice, as buttons.
                if !model.isBusy {
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
        case let .diagram(diagram):
            BoardDiagramView(diagram: diagram, key: "\(index)", onDrawOn: model.isActive && !model.isBusy ? {
                withAnimation(.easeOut(duration: 0.15)) { base = diagram; strokes = []; sketching = true }
            } : nil)
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
                // The picture sent to Joe is the pad at its size on screen, so the strokes stay on his curves.
                GeometryReader { geometry in
                    SketchPad(strokes: $strokes, ink: $ink, base: base)
                        .onAppear { padSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in padSize = size }
                }
                    .frame(height: base == nil ? 220 : 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text(model.mode == .explain ? "Ask a question… (⌘↩ to send) or hold right ⌥ and say it" : "Type your answer… (⌘↩ to submit) or hold right ⌥ and say it")
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
                    if base != nil { Button("Blank page") { base = nil; strokes = [] } }
                }
                if model.mode == .explain {
                    Button("Quiz me on this") { model.quizOnThis() }.disabled(model.items.isEmpty)
                } else {
                    Button("Hint") { model.command("hint") }
                    Button("Skip") { model.command("skip") }
                    Button("End") { model.command("end") }
                }
                Spacer()
                Button {
                    model.submit(model.draft, image: strokes.isEmpty ? nil : SketchPad.jpeg(strokes, base: base, size: padSize), onYourDiagram: base != nil && !strokes.isEmpty)
                    strokes = []
                    base = nil
                } label: { Label(model.mode == .explain ? "Ask" : "Submit", systemImage: "arrow.up") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled((model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && strokes.isEmpty) || model.isBusy)
            }
            .buttonStyle(.bordered)
            .disabled(!model.isActive)
        }
        .padding(16)
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

// MARK: - Sketch pad

/// Drawing a diagram with the trackpad or mouse: a supply-and-demand shift, a food web, a graph.
/// Sent to Joe as a picture with the answer.
struct SketchPad: View {
    struct Stroke { var points: [CGPoint]; var color: Color }

    @Binding var strokes: [Stroke]
    @Binding var ink: Color
    /// Joe's diagram to draw on, under the strokes.
    var base: BoardDiagram?
    @State private var drawing = false

    var body: some View {
        ZStack {
            if let base { DiagramDrawing(diagram: base, animated: false) }
            Canvas { context, size in Self.draw(strokes, in: &context, size: size) }
        }
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .contentShape(Rectangle())
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
                if strokes.isEmpty && base == nil {
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
    /// On Joe's diagram, the picture is the pad at its size, so the strokes land where they were drawn.
    @MainActor static func jpeg(_ strokes: [Stroke], base: BoardDiagram? = nil, size: CGSize? = nil) -> Data? {
        let points = strokes.flatMap(\.points)
        var width = max(400, (points.map(\.x).max() ?? 400) + 20), height = max(260, (points.map(\.y).max() ?? 260) + 20)
        if base != nil, let size { width = size.width; height = size.height }
        let renderer = ImageRenderer(content: ZStack {
            if let base { DiagramDrawing(diagram: base, animated: false) }
            Canvas { context, size in draw(strokes, in: &context, size: size) }
        }
            .frame(width: width, height: height).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

// MARK: - Preview

extension StudyBoard {
    /// `Joe --board-preview <file.png> [sketch|deck|diagram]`: the whiteboard with a sample question and mark (diagram: Joe explaining with a drawn diagram).
    static func preview(to file: URL, sketch: Bool, deck: Bool = false, diagram: Bool = false, done: @escaping () -> Void) {
        DiagramClock.instant = true
        let board = StudyBoard()
        board.model.preview(StudyBoardModel.parse("""
            Let's go. <question n="1" marks="4" topic="2.7 Indirect taxes" source="IB-style">**Draw** a diagram to show the effect of a specific tax on a market. [4]</question><ms>hidden</ms>
            """) + [.answer(text: "Supply shifts up by the tax, price rises, quantity falls.", spoken: true)] + StudyBoardModel.parse("""
            <feedback n="1" score="3" total="4">✓ Supply shifts up by the tax
            ✓ Higher price, lower quantity
            ✗ missing: the price producers receive</feedback><model>S shifts vertically by the tax; consumers pay Pc, producers get Pp.</model>
            <diagram title="Specific tax">
            axes "Quantity" "Price"
            line D 10,90 90,15
            line S 10,15 90,80 blue
            line "S + tax" 10,40 70,89 red dashed
            arrow 64,61 64,80 red
            point E1 53,50 x="Q1" y="P1"
            point E2 38,63 x="Q2" y="Pc"
            point "" 38,38 y="Pp"
            area 0,63 38,63 38,38 0,38 orange "Tax revenue"
            </diagram>
            <summary score="3" total="4">Good diagram; label the price producers receive.</summary>
            <cards>
            Specific tax :: a fixed amount of tax per unit of a good, shifting supply up by the tax
            **Tax incidence** :: how the burden of a tax is split between consumers and producers
            </cards>
            """), subject: "Economics HL", sketching: sketch)
        // `diagram`: explain mode, with Joe's diagram at the top where the snapshot sees it (in the quiz
        // sample it's below the window's height).
        if diagram {
            board.model.preview(StudyBoardModel.parse("""
                Here's a specific tax: supply shifts up by the tax.
                <diagram title="Specific tax">
                axes "Quantity" "Price"
                line D 10,90 90,15
                line S 10,15 90,80 blue
                line "S + tax" 10,40 70,89 red dashed
                arrow 64,61 64,80 red
                point E1 53,50 x="Q1" y="P1"
                point E2 38,63 x="Q2" y="Pc"
                point "" 38,38 y="Pp"
                area 0,63 38,63 38,38 0,38 orange "Tax revenue"
                area 38,63 53,50 38,38 gray
                text 76,38 "Welfare loss"
                arrow 68,40 47,50 gray
                </diagram>
                <lesson title="2.7 Indirect taxes">A **specific tax** is a fixed amount per unit. Supply shifts up by the tax: consumers pay Pc, producers keep Pp.</lesson>
                """), subject: "Economics HL", sketching: false, mode: .explain)
        }
        if deck {
            board.model.previewDeck([Flashcards.Card(term: "Specific tax", definition: "A fixed amount of tax per unit of a good, shifting supply up by the amount of the tax."),
                                     Flashcards.Card(term: "Tax incidence", definition: "How the burden of a tax is split between consumers and producers.")])
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
    func preview(_ items: [Item], subject: String, sketching: Bool, mode: Mode = .quiz) {
        self.mode = mode
        self.subject = subject
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
