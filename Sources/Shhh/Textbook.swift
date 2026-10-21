import AppKit
import PDFKit
import Vision

/// Tools for the assistant to work from a textbook PDF (the Tragakes Economics coursebook):
/// finding a topic, reading pages, and building a week's pre-reading page out of the book's own
/// pages. The pages are rendered here, the same way every time; Claude writes what goes around
/// them (what each lesson is about, the terms, the diagrams, questions to answer).
///
///     Shhh --pdf-index <pdf>                 reads every page once (text recognition), for the others
///     Shhh --pdf-find <pdf> "<words>"        where they appear, by the book's page numbers
///     Shhh --pdf-text <pdf> <pages>          the text of pages ("98-101,104")
///     Shhh --prereading <spec.json>          the page, built next to the spec, then opened
///
/// Some textbook PDFs have a broken text layer (the Tragakes one drops letters: "eplain"), so the
/// book is read once with Vision's text recognition and kept in `<pdf>.index.json`: each page's
/// text and its printed page number, so "pp. 98–101" means the book's pages, not the PDF's.
enum Textbook {
    // MARK: - The index

    struct Index: Codable {
        /// Per PDF page: the printed page number, if one was found, and the text.
        var printed: [String?]
        var text: [String]
    }

    private static func indexURL(_ pdf: String) -> URL { URL(fileURLWithPath: pdf + ".index.json") }

    private static var indexes: [String: Index] = [:]
    private static func index(for pdf: String) -> Index? {
        if let index = indexes[pdf] { return index }
        let index = (try? Data(contentsOf: indexURL(pdf))).flatMap { try? JSONDecoder().decode(Index.self, from: $0) }
        indexes[pdf] = index
        return index
    }

    /// Reads every page with text recognition, four at a time. Takes a few minutes, once.
    static func buildIndex(pdf: String) -> String {
        guard let count = PDFDocument(url: URL(fileURLWithPath: pdf))?.pageCount else { return "Couldn't open \(pdf)." }
        var printed = [String?](repeating: nil, count: count)
        var text = [String](repeating: "", count: count)
        let lock = NSLock()
        let start = Date()
        let workers = 4
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            guard let document = PDFDocument(url: URL(fileURLWithPath: pdf)) else { return }
            for i in stride(from: worker, to: count, by: workers) {
                autoreleasepool {
                    guard let page = document.page(at: i) else { return }
                    let result = recognize(page)
                    lock.lock()
                    printed[i] = result.printed
                    text[i] = result.text
                    lock.unlock()
                }
            }
        }
        // A page number only counts if its neighbours agree (one up, one down), to drop stray digits.
        var checked = printed
        for i in 0..<count {
            guard let n = printed[i].flatMap(Int.init) else { continue }
            let before = i > 0 ? printed[i - 1].flatMap(Int.init) : nil
            let after = i + 1 < count ? printed[i + 1].flatMap(Int.init) : nil
            if before != n - 1, after != n + 1 { checked[i] = nil }
        }
        // Fill gaps from the nearest good neighbour.
        var anchor: (page: Int, number: Int)?
        for i in 0..<count {
            if let n = checked[i].flatMap(Int.init) { anchor = (i, n) } else if let a = anchor, i - a.page < 6 { checked[i] = String(a.number + i - a.page) }
        }
        let index = Index(printed: checked, text: text)
        do { try JSONEncoder().encode(index).write(to: indexURL(pdf)) } catch { return "Couldn't save the index: \(error.localizedDescription)" }
        indexes[pdf] = index
        let found = checked.compactMap { $0 }.count
        return String(format: "Indexed %d pages in %.0fs; printed page numbers found on %d.", count, Date().timeIntervalSince(start), found)
    }

    static func recognize(_ page: PDFPage) -> (text: String, printed: String?) {
        let bounds = page.bounds(for: .mediaBox)
        let width: CGFloat = 1500
        let image = page.thumbnail(of: CGSize(width: width, height: width * bounds.height / bounds.width), for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return ("", nil) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        let observations = (request.results ?? []).sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.008 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
        }
        var printed: String?
        var lines: [String] = []
        for observation in observations {
            guard let line = observation.topCandidates(1).first?.string else { continue }
            let box = observation.boundingBox
            if (box.minY < 0.07 || box.maxY > 0.93), line.range(of: #"^\d{1,3}$"#, options: .regularExpression) != nil {
                printed = line
                continue
            }
            lines.append(line)
        }
        return (lines.joined(separator: "\n"), printed)
    }

    // MARK: - Pages

    /// The book's printed page numbers ("98") to the PDF's pages: from the index when there is
    /// one, else the PDF's own numbering.
    // Printed page numbers are too rarely readable on the page (21 of 859 in the Tragakes book) to
    // map by, so pages are the PDF's own, as Preview numbers them.
    private static func index(of label: String, in document: PDFDocument) -> Int? {
        if let number = Int(label), number >= 1, number <= document.pageCount { return number - 1 }
        return nil
    }

    private static func label(_ i: Int, in document: PDFDocument) -> String {
        String(i + 1)
    }

    private static func pageText(_ i: Int, in document: PDFDocument) -> String {
        if let path = document.documentURL?.path, let text = index(for: path)?.text, i < text.count { return text[i] }
        return document.page(at: i)?.string ?? ""
    }

    /// "98-101, 104" → those pages' indices, in order.
    private static func pages(_ spec: String, in document: PDFDocument) -> [Int] {
        spec.split(separator: ",").flatMap { part -> [Int] in
            let ends = part.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = ends.first.flatMap({ index(of: $0, in: document) }) else { return [] }
            guard ends.count == 2, let last = index(of: ends[1], in: document), last >= first else { return [first] }
            return Array(first...min(last, first + 40))
        }
    }

    // MARK: - Finding and reading

    static func find(pdf path: String, query: String) -> String {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return "Couldn't open \(path)." }
        if index(for: path) == nil { return "The book isn't indexed yet: run Joe --pdf-index first (a few minutes, once)." }
        let flat = { (text: String) in text.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
        let needle = flat(query)
        var lines = ["“\(query)” appears on these pages (PDF page numbers, as in Preview):"]
        for i in 0..<document.pageCount {
            let text = flat(pageText(i, in: document))
            guard let range = text.range(of: needle) else { continue }
            let from = text.index(range.lowerBound, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
            let to = text.index(range.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
            lines.append("- p. \(label(i, in: document)): …\(text[from..<to])…")
            if lines.count > 15 { break }
        }
        return lines.count == 1 ? "“\(query)” isn't in the book. Try fewer or different words." : lines.joined(separator: "\n")
    }

    static func text(pdf path: String, pages spec: String) -> String {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return "Couldn't open \(path)." }
        let list = pages(spec, in: document)
        guard !list.isEmpty else { return "No pages \(spec) in the book." }
        return list.prefix(12).map { i in
            "=== p. \(label(i, in: document)) ===\n" + pageText(i, in: document)
        }.joined(separator: "\n\n") + (list.count > 12 ? "\n\n(First 12 pages only: ask for the rest separately.)" : "")
    }

    // MARK: - The pre-reading page

    struct Spec: Decodable {
        struct Lesson: Decodable {
            let day: String
            let title: String
            let pages: String
            var summary: [String]?
            var terms: [String]?
            var diagrams: [String]?
            var questions: [String]?
        }
        var title: String?
        let week: String
        var pdf: String?
        let lessons: [Lesson]
        var notes: [String]?
    }

    /// The textbook to use when the spec doesn't name one.
    static var defaultPDF: String? {
        let file = NoteSaver.root?.appendingPathComponent("_files/School/Economics/IB Economics Coursebook (Tragakes).pdf")
        return file.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
    }

    /// Builds the page: a folder next to the spec with the book's pages as images and an
    /// index.html, which then opens in the browser. Returns what happened, for Claude.
    @MainActor
    static func buildPreReading(spec path: String) -> String {
        let specURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let spec: Spec
        do {
            spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: specURL))
        } catch {
            return "Couldn't read \(path): \(error.localizedDescription). It needs week, lessons [{day, title, pages, summary, terms, diagrams, questions}]."
        }
        guard let pdf = spec.pdf ?? defaultPDF, let document = PDFDocument(url: URL(fileURLWithPath: pdf)) else {
            return "Couldn't open the textbook PDF."
        }
        let folder = specURL.deletingPathExtension()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rendered = 0
        var sections: [String] = []
        for lesson in spec.lessons {
            var images: [String] = []
            for i in pages(lesson.pages, in: document) {
                let name = "p\(label(i, in: document)).jpg"
                let file = folder.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: file.path) {
                    guard let page = document.page(at: i) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    let width: CGFloat = 1400
                    let image = page.thumbnail(of: CGSize(width: width, height: width * bounds.height / bounds.width), for: .mediaBox)
                    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                          let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { continue }
                    try? jpeg.write(to: file)
                    rendered += 1
                }
                images.append("<figure><img loading=\"lazy\" src=\"\(name)\" alt=\"Page \(label(i, in: document))\"><figcaption>p. \(label(i, in: document))</figcaption></figure>")
            }
            sections.append(section(lesson, images: images))
        }
        let html = page(title: spec.title ?? "Econ pre-reading", week: spec.week, notes: spec.notes ?? [], sections: sections)
        let index = folder.appendingPathComponent("index.html")
        do { try html.write(to: index, atomically: true, encoding: .utf8) } catch { return "Couldn't save the page: \(error.localizedDescription)" }
        NSWorkspace.shared.open(index)
        return "Built \(index.path) (\(spec.lessons.count) lessons, \(rendered) pages rendered) and opened it."
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func list(_ items: [String]?, title: String, chips: Bool = false) -> String {
        guard let items, !items.isEmpty else { return "" }
        let body = chips
            ? "<div class=\"chips\">" + items.map { "<span>\(escape($0))</span>" }.joined() + "</div>"
            : "<ul>" + items.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
        return "<div class=\"block\"><h3>\(title)</h3>\(body)</div>"
    }

    private static func section(_ lesson: Spec.Lesson, images: [String]) -> String {
        """
        <section>
          <header><span class="day">\(escape(lesson.day))</span><h2>\(escape(lesson.title))</h2><span class="pages">Tragakes pp. \(escape(lesson.pages))</span></header>
          <div class="grid">
            \(list(lesson.summary, title: "What it's about"))
            \(list(lesson.diagrams, title: "Diagrams to draw"))
            \(list(lesson.questions, title: "Answer before class"))
            \(list(lesson.terms, title: "Terms to know cold", chips: true))
          </div>
          <details open><summary>The pages (\(images.count))</summary><div class="pagesgrid">\(images.joined())</div></details>
        </section>
        """
    }

    private static func page(title: String, week: String, notes: [String], sections: [String]) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escape(title)) · \(escape(week))</title>
        <style>
        :root{--bg:#f6f4ee;--card:#fff;--ink:#16181d;--muted:#5f6470;--line:#e2ded3;--accent:#1f5fbf;--chip:#eef3fb}
        @media (prefers-color-scheme:dark){:root{--bg:#121318;--card:#1b1d24;--ink:#e9ebf0;--muted:#9aa0ad;--line:#2b2e38;--accent:#7aa7ff;--chip:#232a3a}}
        *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
        main{max-width:1100px;margin:0 auto;padding:28px 16px 60px}
        h1{font-size:30px;margin:0 0 4px;letter-spacing:-.01em}.sub{color:var(--muted);margin:0 0 22px}
        .notes{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 16px;margin-bottom:22px}
        section{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px;margin-bottom:22px}
        section header{display:flex;flex-wrap:wrap;align-items:baseline;gap:6px 14px;margin-bottom:12px}
        .day{font-weight:700;color:var(--accent);text-transform:uppercase;font-size:12px;letter-spacing:.08em}
        h2{margin:0;font-size:21px;flex:1 1 300px}.pages{color:var(--muted);font-size:13px;font-variant-numeric:tabular-nums}
        .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px 22px}
        h3{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:6px 0 6px}
        ul{margin:0;padding-left:18px}li{margin:3px 0}
        .chips{display:flex;flex-wrap:wrap;gap:6px}.chips span{background:var(--chip);border-radius:999px;padding:3px 10px;font-size:13px}
        details{margin-top:14px}summary{cursor:pointer;font-weight:600;color:var(--muted)}
        .pagesgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px;margin-top:12px}
        figure{margin:0}img{width:100%;border:1px solid var(--line);border-radius:8px;background:#fff}
        figcaption{font-size:12px;color:var(--muted);text-align:center;margin-top:4px}
        </style></head><body><main>
        <h1>\(escape(title))</h1><p class="sub">\(escape(week)) · built by Joe from the Tragakes coursebook</p>
        \(notes.isEmpty ? "" : "<div class=\"notes\"><ul>" + notes.map { "<li>\(escape($0))</li>" }.joined() + "</ul></div>")
        \(sections.joined(separator: "\n"))
        </main></body></html>
        """
    }
}
