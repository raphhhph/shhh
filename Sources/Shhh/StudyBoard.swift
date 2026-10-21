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
        ]
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
    enum Mode: String { case quiz, exam }

    enum Item: Identifiable, Equatable {
        case question(n: Int, marks: Int, topic: String, source: String, text: String)
        case answer(text: String, spoken: Bool, image: Data? = nil)
        case feedback(score: Int, total: Int, text: String, model: String)
        case summary(score: Int, total: Int, text: String)
        case note(String)

        var id: String {
            switch self {
            case let .question(n, _, _, _, text): "q\(n)\(text.prefix(20))"
            case let .answer(text, _, image): "a\(text.hashValue)\(image?.count ?? 0)"
            case let .feedback(score, total, text, _): "f\(score)/\(total)\(text.prefix(20))"
            case let .summary(_, _, text): "s\(text.prefix(20))"
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

    var speak: (String) -> Void = { _ in }
    var stopSpeaking: () -> Void = {}

    private var assistant: Assistant?
    private var reply = ""
    private var startedAt = Date()

    var isActive: Bool { assistant != nil }

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
        let assistant = Assistant()
        assistant.tutorPrompt = Self.tutorPrompt(subject: subject, mode: mode)
        self.assistant = assistant
        assistant.prepare { [weak self] event in self?.handle(event) }
        let opening = request ?? (mode == .exam
            ? "Give me one full exam-style question."
            : "Start the quiz: five questions, focusing on my weak spots if you know them.")
        send(opening)
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
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        for item in parsed {
            if case let .question(_, _, next, _, _) = item { topic = next }
            if case let .feedback(score, total, text, _) = item, total > 0 {
                let missing = text.components(separatedBy: "\n").first { $0.lowercased().contains("missing") || $0.contains("✗") } ?? ""
                let note = missing.replacingOccurrences(of: #"^[-•*✗\s]+"#, with: "", options: .regularExpression).prefix(80)
                lines.append("- \(date) · \(subject) · \(topic) · \(score)/\(total) · \(note)")
            }
        }
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
            case let .note(text): parts.append(text)
            case let .question(_, marks, _, _, text):
                parts.append(text.replacingOccurrences(of: #"\|.*\|"#, with: "", options: .regularExpression) + " For \(marks) mark\(marks == 1 ? "" : "s").")
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
        while let open = rest.range(of: #"<(question|feedback|model|summary|ms)\b[^>]*>"#, options: .regularExpression) {
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
        let history = StudyBuddy.results().filter { StudyBuddy.pack(for: $0.subject) == pack }.suffix(25)
            .map { "- \($0.topic): \($0.score)/\($0.total) \($0.note)" }.joined(separator: "\n")
        let exe = Bundle.main.executablePath ?? "Joe"
        let papers = Self.pastPapers(for: pack)
        let notes = StudyBuddy.schoolFolder?.appendingPathComponent("Subjects").path
        return """
            You are Joe, an IB Diploma tutor running a practice session on a whiteboard for \(Profile.name.isEmpty ? "a student" : Profile.name). \
            \(Profile.description) Subject: \(subject).

            # How to write (the whiteboard reads these tags)
            - A question: <question n="1" marks="4" topic="2.8 Externalities" source="IB-style">the question in Markdown</question>. \
            Data as Markdown tables; maths in plain text (x², √, ≤, fractions as a/b). One question at a time. Never put the answer in it.
            - Right after each question, its markscheme, hidden from them: <ms>each mark point as the IB would write it (M1, A1, \
            or one point per mark; for markband questions, what each band needs), and acceptable alternatives</ms>. Mark their answer \
            strictly against it, so the same answer always gets the same mark.
            - They can draw: a diagram sent as an image with their answer. Mark what's drawn (axes, labels, curves, shifts, areas) as an examiner would.
            - After they answer: <feedback n="1" score="3" total="4">✓ what earned marks, one bullet each; ✗ missing: what was missing, one bullet each</feedback> \
            then <model>the answer a markscheme would credit, concise</model>, then the next <question>.
            - Outside the tags, at most one short sentence, said aloud ("Nice, three out of four."). No other chatter.
            - At the end: <summary score="x" total="y">strengths, the weakest topic, the one thing to revise next</summary>.

            \(myp ? "# MYP\nThey're in the MYP (\(Profile.programme)). Name the criterion each question targets, and mark on that criterion's band and level out of 8 (score=\"6\" total=\"8\"), using the descriptors below. No DP papers.\n" : "")
            # The session
            \(mode == .exam
                ? "Exam mode: one full question in the style of a real paper for this subject (with parts (a), (b)…, a stimulus or data where the paper has one, marks per part). Mark it part by part; long parts with markbands. Then the summary."
                : "Quiz mode: five questions, easier to harder, IB command terms and marks in brackets, a mix of definitions, application to a short context, calculations where the subject has them, and one exam-style question. Cover the topic they ask for, or their weakest topics from the results below. After the fifth, the summary.")
            - "hint": a hint, not the answer. "skip": the model answer and 0 marks (a feedback tag with score 0), then go on. "end": the summary now. \
            Any other question from them: answer it briefly, then carry on.
            - Mark strictly but fairly, like an IB examiner: the command term sets the depth, partial marks are fine, follow-through for \
            a slip carried correctly. Diagrams: they describe them in words; mark the description.
            \(pack == "Chinese B" ? "- Chinese B: questions in simplified Chinese; corrections as 原句 → 改正; explanations in English.\n" : "")
            # Material
            - Real past-paper questions beat invented ones. \(papers.isEmpty ? "No past papers are saved for this subject yet; write questions in the exact style of the real papers described below." : "Past papers saved for this subject: \(papers.joined(separator: "; ")). Prefer real questions from them: find one with \"\(exe)\" --pdf-find \"<pdf>\" \"<topic>\", read it with \"\(exe)\" --pdf-text \"<pdf>\" \"<pages>\", ask it as printed (with its data) and source=\"<paper, year, question>\", and mark with its markscheme when there is one.")
            \(notes.map { "- Their class notes are in \($0), for when they ask for questions \"from my notes\"." } ?? "")
            - Speed matters: they're waiting. Ask the first question straight away, with no tools, unless you're taking it from a past paper. Never use tools to mark.

            # Their recent results in this subject
            \(history.isEmpty ? "None yet." : history)

            # Syllabus map
            \(map)

            # Command terms and marking
            \(terms)
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
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.items.isEmpty && model.live.isEmpty && !model.isBusy {
                            empty
                        }
                        ForEach(model.items + model.live) { item in
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
                .onChange(of: model.items.count) { withAnimation { scroll.scrollTo("end", anchor: .bottom) } }
                .onChange(of: model.live) { scroll.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            composer
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { if !started { started = true; sketching = startSketching; strokes = demoStrokes } }
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "graduationcap.fill").foregroundStyle(accent).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.subject.isEmpty ? "Study" : model.subject).font(.system(size: 16, weight: .bold))
                Text(model.mode == .exam ? "Exam question" : "Quiz · five questions").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
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
            Text("Pick a subject on the Study page, or say “quiz me on…”.").font(.system(size: 14)).foregroundStyle(.secondary)
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
                Text(Self.markdown(text)).font(.system(size: 15.5)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Text(Self.markdown(text)).font(.system(size: 13.5)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                if !modelAnswer.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MODEL ANSWER").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
                        Text(Self.markdown(modelAnswer)).font(.system(size: 13.5)).lineSpacing(2).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
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
                Text(Self.markdown(text)).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case let .note(text):
            Text(Self.markdown(text)).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Button("Hint") { model.command("hint") }
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

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private static func color(_ score: Int, _ total: Int) -> Color {
        let ratio = Double(score) / Double(max(total, 1))
        return ratio >= 0.7 ? .green : ratio >= 0.45 ? .orange : .red
    }

    /// Markdown for bold, italics and lists; tables and the rest shown as written.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
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
    /// `Joe --board-preview <file.png> [sketch]`: the whiteboard with a sample question and mark.
    static func preview(to file: URL, sketch: Bool, done: @escaping () -> Void) {
        let board = StudyBoard()
        board.model.preview(StudyBoardModel.parse("""
            Let's go. <question n="1" marks="4" topic="2.7 Indirect taxes" source="IB-style">**Draw** a diagram to show the effect of a specific tax on a market. [4]</question><ms>hidden</ms>
            """) + [.answer(text: "Supply shifts up by the tax, price rises, quantity falls.", spoken: true)] + StudyBoardModel.parse("""
            <feedback n="1" score="3" total="4">✓ Supply shifts up by the tax\\n✓ Higher price, lower quantity\\n✗ missing: the price producers receive</feedback><model>S shifts vertically by the tax; consumers pay Pc, producers get Pp.</model>
            """), subject: "Economics HL", sketching: sketch)
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
}
