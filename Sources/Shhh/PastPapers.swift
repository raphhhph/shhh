import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The past-paper importer. The papers and markschemes they've saved (in their notes under
/// _files/School/<subject>/, or added from the Study page) are read once and split into questions:
/// each with its pages, its marks, the syllabus topic it's most likely on, and the pages of the same
/// question in its markscheme. The whiteboard's tutor picks real questions from this index by topic,
/// instead of searching every PDF while they wait.
///
///     Joe --past-papers "<subject>"     reads that subject's papers and prints the index
///
/// Scanned papers (no text layer) are read with text recognition, like textbooks. Kept in
/// "Past papers index.json" in Joe's folder; a PDF is read again only when it changes.
enum PastPapers {
    struct Question: Codable, Hashable {
        var number: Int
        /// PDF pages, from 1, as `--pdf-text` takes them.
        var pages: [Int]
        var marks: Int?
        /// The syllabus subtopic it's most likely on ("2.8 Market failure").
        var topic: String?
        var preview: String
        /// The same question's pages in the paired markscheme.
        var markscheme: [Int]?
    }

    struct Paper: Codable {
        var path: String
        var modified: Date
        var pack: String
        /// "Paper 2 · May 2023 · HL · TZ1".
        var title: String
        /// Paper number, year, session, level, time zone: what pairs a paper with its markscheme.
        var key: String
        var isMarkscheme: Bool
        var questions: [Question]
        var readByOCR: Bool
        var markschemePath: String?
    }

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh", isDirectory: true)
    private static var storeURL: URL { folder.appendingPathComponent("Past papers index.json") }

    /// Where papers added from the Study page go: their notes when they have them, else Joe's folder.
    static func importFolder(for subject: String) -> URL {
        if let root = Daybook.root { return root.appendingPathComponent("_files/School/\(subject)/Past papers", isDirectory: true) }
        return folder.appendingPathComponent("Past papers/\(subject)", isDirectory: true)
    }

    // MARK: Finding the PDFs

    /// Past papers and markschemes for a subject's map: PDFs in a folder named for the subject (or
    /// named for it themselves) that look like papers.
    static func files(for pack: String) -> [URL] {
        let roots = [Daybook.root?.appendingPathComponent("_files/School", isDirectory: true),
                     folder.appendingPathComponent("Past papers", isDirectory: true)].compactMap { $0 }
        var found: [URL] = []
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in files where url.pathExtension.lowercased() == "pdf" {
                let relative = String(url.path.dropFirst(root.path.count)).lowercased()
                let parts = relative.split(separator: "/").map(String.init)
                guard parts.contains(where: { StudyBuddy.pack(for: $0) == pack }),
                      relative.range(of: #"paper|markscheme|mark scheme|specimen|past|questionbank|\bms\b"#, options: .regularExpression) != nil,
                      relative.range(of: #"guidance|guide|technique|checklist|textbook|notes"#, options: .regularExpression) == nil else { continue }
                found.append(url)
            }
        }
        return found
    }

    // MARK: The index

    private static let lock = NSLock()
    private static var cache: [String: Paper]?
    private static let reader = DispatchQueue(label: "Joe.PastPapers", qos: .utility)

    private static func stored() -> [String: Paper] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let index = (try? Data(contentsOf: storeURL)).flatMap { try? JSONDecoder().decode([String: Paper].self, from: $0) } ?? [:]
        cache = index
        return index
    }

    private static func save(_ index: [String: Paper]) {
        lock.lock(); defer { lock.unlock() }
        cache = index
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(index).write(to: storeURL, options: .atomic)
    }

    /// Reads the subject's new or changed papers (slow the first time: off the main thread) and
    /// returns its index.
    @discardableResult
    static func refresh(pack: String) -> [Paper] {
        reader.sync {
            var index = stored()
            let files = files(for: pack)
            let sections = sections(pack)
            var changed = false
            for url in files {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let paper = index[url.path], paper.pack == pack, abs(paper.modified.timeIntervalSince(modified)) < 1 { continue }
                if let paper = autoreleasepool(invoking: { read(url, pack: pack, modified: modified, sections: sections) }) {
                    index[url.path] = paper
                    changed = true
                }
            }
            // Forget papers that were moved or deleted.
            let paths = Set(files.map(\.path))
            for (path, paper) in index where paper.pack == pack && !paths.contains(path) {
                index[path] = nil
                changed = true
            }
            if changed { save(index) }
        }
        return papers(pack)
    }

    static func refreshInBackground(pack: String?, then done: (() -> Void)? = nil) {
        guard let pack else { return }
        DispatchQueue.global(qos: .utility).async {
            refresh(pack: pack)
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    /// The subject's papers (not markschemes), each question with its markscheme pages when the
    /// paper's markscheme is indexed too.
    static func papers(_ pack: String) -> [Paper] {
        let all = stored().values.filter { $0.pack == pack }
        let schemes = all.filter(\.isMarkscheme)
        return all.filter { !$0.isMarkscheme }.map { paper in
            var paper = paper
            if let scheme = markscheme(for: paper, in: schemes) {
                paper.markschemePath = scheme.path
                for i in paper.questions.indices {
                    paper.questions[i].markscheme = scheme.questions.first { $0.number == paper.questions[i].number }?.pages
                }
            }
            return paper
        }
        .sorted { $0.title < $1.title }
    }

    /// Papers, questions and how many have a markscheme, for the Study page.
    static func summary(_ pack: String?) -> (papers: Int, questions: Int, marked: Int) {
        guard let pack else { return (0, 0, 0) }
        let papers = papers(pack)
        let questions = papers.flatMap(\.questions)
        return (papers.count, questions.count, questions.filter { $0.markscheme != nil }.count)
    }

    /// Its markscheme: the one whose paper, year, session, level and time zone don't disagree with
    /// it and agree on the most (a markscheme in the same folder counts as one more agreement).
    private static func markscheme(for paper: Paper, in schemes: [Paper]) -> Paper? {
        let mine = paper.key.components(separatedBy: "|")
        func agreement(_ scheme: Paper) -> Int {
            var total = 0
            for (a, b) in zip(mine, scheme.key.components(separatedBy: "|")) where !a.isEmpty && !b.isEmpty {
                if a != b { return -1 }
                total += 1
            }
            if (scheme.path as NSString).deletingLastPathComponent == (paper.path as NSString).deletingLastPathComponent { total += 1 }
            return total
        }
        return schemes.map { ($0, agreement($0)) }.filter { $0.1 >= 2 }.max { $0.1 < $1.1 }?.0
    }

    // MARK: Reading a paper

    private static func read(_ url: URL, pack: String, modified: Date, sections: [Section]) -> Paper? {
        guard let document = PDFDocument(url: url) else { return nil }
        var pages: [String] = []
        var ocr = false
        for i in 0..<min(document.pageCount, 80) {
            guard let page = document.page(at: i) else { pages.append(""); continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 25 {
                // A scanned page: read it with text recognition.
                let recognized = Textbook.recognize(page).text
                if recognized.count > text.count { text = recognized; ocr = true }
            }
            pages.append(text)
        }
        let name = url.deletingPathExtension().lastPathComponent
        let head = pages.prefix(2).joined(separator: "\n")
        let both = (name + "\n" + head).lowercased()
        func first(_ pattern: String, in text: String) -> String? {
            guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return String(text[match])
        }
        let isMarkscheme = first(#"markscheme|mark scheme|marking scheme|(^|[^a-z])ms($|[^a-z])"#, in: name) != nil
            || first(#"markscheme|mark scheme"#, in: String(head.prefix(800))) != nil
        let year = first(#"(19|20)\d{2}"#, in: name) ?? first(#"(19|20)\d{2}"#, in: head)
        let session = first(#"specimen"#, in: both).map { _ in "Specimen" }
            ?? first(#"(^|[^a-z])(nov|november)($|[^a-z])"#, in: both).map { _ in "November" }
            ?? first(#"(^|[^a-z])may($|[^a-z])"#, in: both).map { _ in "May" }
        let number = first(#"paper[\s_-]*[1-3]|(^|[^a-z])p[1-3]($|[^0-9])"#, in: name).flatMap { $0.first(where: \.isNumber).map(String.init) }
            ?? first(#"paper\s*[1-3]"#, in: head).flatMap { $0.first(where: \.isNumber).map(String.init) }
        let level = first(#"(^|[^a-z])hl($|[^a-z])|higher level"#, in: both).map { _ in "HL" }
            ?? first(#"(^|[^a-z])sl($|[^a-z])|standard level"#, in: both).map { _ in "SL" }
        let zone = first(#"tz[\s_-]*[0-2]|time zone\s*[0-2]"#, in: both).flatMap { $0.last.map(String.init) }

        let when = [session, year].compactMap { $0 }.joined(separator: " ")
        let parts: [String?] = [number.map { "Paper \($0)" }, when, level, zone.map { "TZ\($0)" }]
        let title = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let questions = split(pages).map { part -> Question in
            Question(number: part.number, pages: part.pages,
                     marks: isMarkscheme ? nil : marks(in: part.text),
                     topic: topic(of: part.text, in: sections),
                     preview: preview(part.text))
        }
        return Paper(path: url.path, modified: modified, pack: pack,
                     title: (title.isEmpty ? name : title) + (isMarkscheme ? " markscheme" : ""),
                     key: [number, year, session, level, zone].map { $0 ?? "" }.joined(separator: "|"),
                     isMarkscheme: isMarkscheme, questions: questions, readByOCR: ocr)
    }

    /// The questions in order: a line starting "1." (or "Question 1") begins question 1, then "2."
    /// begins question 2, and so on; numbers out of order are data or sub-points, not questions.
    static func split(_ pages: [String]) -> [(number: Int, pages: [Int], text: String)] {
        var parts: [(number: Int, pages: [Int], text: String)] = []
        var expected = 1
        for (index, page) in pages.enumerated() {
            for line in page.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let match = trimmed.range(of: #"^(question\s+)?\d{1,2}(\s*\.(\s|$)|\s*$|\s+\()"#, options: [.regularExpression, .caseInsensitive]),
                   Int(trimmed[match].filter(\.isNumber)) == expected,
                   trimmed.lowercased().hasPrefix("question") || trimmed[match].contains(".") || trimmed[match].contains("(") {
                    parts.append((expected, [index + 1], trimmed))
                    expected += 1
                    continue
                }
                guard !parts.isEmpty else { continue }
                if parts[parts.count - 1].pages.last != index + 1 { parts[parts.count - 1].pages.append(index + 1) }
                parts[parts.count - 1].text += "\n" + trimmed
            }
        }
        return parts
    }

    /// "[Maximum mark: 6]" (maths papers), else the sum of the part marks "[4]", "[10]".
    private static func marks(in text: String) -> Int? {
        if let match = text.range(of: #"maximum mark:\s*\d+"#, options: [.regularExpression, .caseInsensitive]) {
            return Int(text[match].filter(\.isNumber))
        }
        var total = 0
        var search = text.startIndex..<text.endIndex
        while let match = text.range(of: #"\[\d{1,2}\]"#, options: .regularExpression, range: search) {
            total += Int(text[match].filter(\.isNumber)) ?? 0
            search = match.upperBound..<text.endIndex
        }
        return total > 0 && total <= 60 ? total : nil
    }

    private static func preview(_ text: String) -> String {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        // Without the question number and "[Maximum mark: n]".
        let joined = words.dropFirst().joined(separator: " ")
            .replacingOccurrences(of: #"\[maximum mark:\s*\d+\]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        return String(joined.prefix(160))
    }

    // MARK: Topics

    struct Section {
        let label: String
        let words: Set<String>
    }

    /// The numbered subtopics of a syllabus map ("- 2.8 Market failure: externalities (…)") with
    /// their words, to match questions against.
    static func sections(_ pack: String) -> [Section] {
        guard let text = try? String(contentsOf: StudyBuddy.syllabus.appendingPathComponent(pack + ".md"), encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").compactMap { line in
            guard let match = line.range(of: #"^- (AHL )?([A-Z]{1,3}\.?)?\d+(\.\d+)* "#, options: .regularExpression) else { return nil }
            let code = line[match].dropFirst(2).trimmingCharacters(in: .whitespaces)
            let rest = String(line[match.upperBound...])
            let name = rest.prefix { $0 != ":" && $0 != "(" && $0 != ";" && $0 != "," }.trimmingCharacters(in: .whitespaces)
            return Section(label: "\(code) \(name)", words: keywords(rest))
        }
    }

    private static let common: Set<String> = ["about", "their", "which", "using", "these", "those", "there", "where", "under", "other",
                                              "including", "between", "within", "without", "different", "explain", "describe",
                                              "evaluate", "discuss", "calculate", "state", "outline", "define", "suggest", "marks",
                                              "maximum", "answer", "question", "following", "figure", "table", "diagram", "shown"]

    /// Words of five letters or more, cut to seven so "externality" and "externalities" match.
    private static func keywords(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 5 && !common.contains($0) }
            .map { String($0.prefix(7)) })
    }

    /// The subtopic sharing the most telling words with the question (rare words count more), when
    /// it shares at least two.
    static func topic(of text: String, in sections: [Section]) -> String? {
        guard !sections.isEmpty else { return nil }
        let words = keywords(text)
        var spread: [String: Int] = [:]
        for section in sections { for word in section.words { spread[word, default: 0] += 1 } }
        let count = Double(sections.count)
        let scored = sections.map { section -> (String, Double, Int) in
            let shared = section.words.intersection(words)
            return (section.label, shared.reduce(0) { $0 + log(count / Double(spread[$1] ?? 1)) + 0.5 }, shared.count)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.2 >= 2 else { return nil }
        return best.0
    }

    // MARK: For the tutor

    /// The indexed questions for the tutor's instructions, those on `focus` topics (due or weak)
    /// first: a numbered list of the PDFs, then one line per question.
    static func promptIndex(pack: String, focus: [String], limit: Int = 40) -> String? {
        let questions = papers(pack).flatMap { paper in paper.questions.map { (paper, $0) } }
        guard !questions.isEmpty else { return nil }
        let wanted = Set(focus.map(StudyReview.key))
        let ordered = questions.enumerated().sorted { a, b in
            let first = a.element.1.topic.map { wanted.contains(StudyReview.key($0)) } ?? false
            let second = b.element.1.topic.map { wanted.contains(StudyReview.key($0)) } ?? false
            return first != second ? first : a.offset < b.offset
        }.map(\.element)
        var files: [String] = []
        func reference(_ path: String) -> Int {
            if let i = files.firstIndex(of: path) { return i + 1 }
            files.append(path)
            return files.count
        }
        var lines: [String] = []
        for (paper, question) in ordered.prefix(limit) {
            var line = "- \(paper.title) Q\(question.number)"
            if let topic = question.topic { line += " · \(topic)" }
            if let marks = question.marks { line += " · [\(marks)]" }
            line += " · paper [\(reference(paper.path))] p.\(pageRange(question.pages))"
            if let pages = question.markscheme, let scheme = paper.markschemePath { line += " · markscheme [\(reference(scheme))] p.\(pageRange(pages))" }
            line += " · \"\(question.preview.prefix(90))…\""
            lines.append(line)
        }
        let list = files.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n")
        let more = questions.count > limit ? "\n(\(questions.count - limit) more questions not listed.)" : ""
        return "Files:\n" + list + "\nQuestions:\n" + lines.joined(separator: "\n") + more
    }

    private static func pageRange(_ pages: [Int]) -> String {
        guard let low = pages.min(), let high = pages.max() else { return "" }
        return low == high ? "\(low)" : "\(low)-\(high)"
    }

    // MARK: Adding papers

    /// Copies the PDFs they pick into the subject's past-papers folder (copies: their own files stay
    /// where they are), then reads them. `done` gets a one-line result.
    @MainActor
    static func add(for subject: String, done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Pick \(subject) past papers and their markschemes (PDF). Joe keeps a copy in your notes."
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let target = importFolder(for: subject)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var added = 0
        for url in panel.urls {
            let copy = target.appendingPathComponent(url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: copy.path) else { continue }
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { added += 1 }
        }
        guard let pack = StudyBuddy.pack(for: subject) else {
            return done("Added \(added) file\(added == 1 ? "" : "s"). Joe has no syllabus map for \(subject), so they aren't split into questions.")
        }
        done("Reading \(added) file\(added == 1 ? "" : "s")…")
        refreshInBackground(pack: pack) {
            let counts = summary(pack)
            done("\(counts.questions) questions from \(counts.papers) paper\(counts.papers == 1 ? "" : "s"), \(counts.marked) with their markscheme.")
        }
    }
}
