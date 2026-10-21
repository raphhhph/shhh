import SwiftUI
import WebKit

/// Maths on the study whiteboard. LaTeX between \( \), \[ \], $$ $$ or $ $ is typeset with KaTeX,
/// which ships in the app (Resources/KaTeX, with the page that draws a card: board.html), so it
/// works offline. Text without maths stays a plain SwiftUI Text, which is lighter.
enum BoardMath {
    /// KaTeX and board.html: in the app, or in the repo for the dev binary.
    static let folder: URL? = {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("KaTeX", isDirectory: true),
                          URL(fileURLWithPath: "Resources/KaTeX", isDirectory: true)].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("board.html").path) }
    }()

    /// A single $…$ counts only when it hugs its content and isn't followed by a digit, so
    /// "$5 and $10" stays money (the same rule as board.html).
    private static let pattern = #"\\\(|\\\[|\$\$|(?<![\\$])\$(?=\S)[^$\n]+?(?<=\S)\$(?!\d)"#

    /// Each typeset text's last height, so a card scrolled away and back (the board is lazy) comes
    /// back at its size instead of growing from one line.
    static var heights: [String: CGFloat] = [:]

    static func hasMath(_ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Markdown for bold, italics and lists; tables and the rest shown as written.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// What the voice reads: "\(\frac{dy}{dx} = 3x^2\)" → "dy over dx = 3x squared".
    static func speakable(_ text: String) -> String {
        guard hasMath(text) else { return text }
        var s = text
        func replace(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        replace(#"\$\$|\\\[|\\\]|\\\(|\\\)"#, " ")
        replace(#"(?<![\\$])\$(?=\S)([^$\n]+?)(?<=\S)\$(?!\d)"#, "$1")
        replace(#"\\(left|right|displaystyle|mathrm|text|mathbf|operatorname)\b"#, "")
        replace(#"\\[,;:! ]"#, " ")
        // Innermost first, so nested fractions and roots read in order.
        for _ in 0..<4 {
            replace(#"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#, " $1 over $2 ")
            replace(#"\\sqrt\[([^\]]*)\]\{([^{}]*)\}"#, " the $1th root of $2 ")
            replace(#"\\sqrt\{([^{}]*)\}"#, " the square root of $1 ")
        }
        replace(#"\\int_\{?([^{}\s^]+)\}?\^\{?([^{}\s]+)\}?"#, " the integral from $1 to $2 of ")
        replace(#"\\(sum|prod)_\{([^{}]*)\}\^\{?([^{}\s]+)\}?"#, " the $1 from $2 to $3 of ")
        replace(#"\^(\{2\}|2)(?![0-9])"#, " squared ")
        replace(#"\^(\{3\}|3)(?![0-9])"#, " cubed ")
        replace(#"\^\{([^{}]*)\}"#, " to the power $1 ")
        replace(#"\^(\S)"#, " to the power $1 ")
        replace(#"_\{([^{}]*)\}"#, " sub $1 ")
        replace(#"_(\w)"#, " sub $1 ")
        let words: [(String, String)] = [
            ("times", "times"), ("cdot", "times"), ("div", "divided by"), ("pm", "plus or minus"), ("mp", "minus or plus"),
            ("leq?", "is less than or equal to"), ("geq?", "is greater than or equal to"), ("neq?", "is not equal to"),
            ("approx", "is approximately"), ("equiv", "is equivalent to"), ("infty", "infinity"), ("to", "tends to"),
            ("rightarrow", "gives"), ("Rightarrow", "implies"), ("int", "the integral of"), ("sum", "the sum of"),
            ("prod", "the product of"), ("lim", "the limit"), ("in", "in"), ("degree", "degrees"), ("circ", "degrees"),
            ("partial", "partial"), ("Delta", "delta"), ("ln", "ln"), ("log", "log"),
        ]
        for (command, word) in words { replace(#"\\"# + command + #"(?![A-Za-z])"#, " \(word) ") }
        replace(#"\\([A-Za-z]+)"#, " $1 ") // \pi, \theta, \sin…: their names
        replace(#"[{}]"#, "")
        replace(#"\s{2,}"#, " ")
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// A card's text on the whiteboard: typeset when it has maths, a plain Text otherwise.
struct BoardText: View {
    let text: String
    var size: CGFloat
    var spacing: CGFloat = 2
    var secondary = false

    init(_ text: String, size: CGFloat, spacing: CGFloat = 2, secondary: Bool = false) {
        self.text = text
        self.size = size
        self.spacing = spacing
        self.secondary = secondary
    }

    var body: some View {
        if BoardMath.folder != nil, BoardMath.hasMath(text) {
            MathText(text: text, size: size, secondary: secondary)
        } else {
            Text(BoardMath.markdown(text)).font(.system(size: size)).lineSpacing(spacing)
                .foregroundStyle(secondary ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MathText: View {
    let text: String
    let size: CGFloat
    let secondary: Bool
    @State private var height: CGFloat

    init(text: String, size: CGFloat, secondary: Bool) {
        self.text = text
        self.size = size
        self.secondary = secondary
        _height = State(initialValue: BoardMath.heights["\(size)|\(text)"] ?? 0)
    }

    var body: some View {
        MathWeb(text: text, size: size, secondary: secondary, height: $height)
            .onChange(of: height) { BoardMath.heights["\(size)|\(text)"] = height }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: max(height, ceil(size * 1.45)))
    }
}

/// The web view under one card's text. It doesn't scroll itself: the wheel goes to the board.
final class BoardWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private struct MathWeb: NSViewRepresentable {
    let text: String
    let size: CGFloat
    let secondary: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BoardWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakHandler(context.coordinator), name: "height")
        let web = BoardWebView(frame: .zero, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        if let folder = BoardMath.folder {
            web.loadFileURL(folder.appendingPathComponent("board.html"), allowingReadAccessTo: folder)
        }
        update(context.coordinator, web)
        return web
    }

    func updateNSView(_ web: BoardWebView, context: Context) {
        update(context.coordinator, web)
    }

    private func update(_ coordinator: Coordinator, _ web: WKWebView) {
        let binding = $height
        coordinator.onHeight = { binding.wrappedValue = $0 }
        let payload: [String: Any] = ["text": text, "size": Double(size), "secondary": secondary]
        if let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) {
            coordinator.show(json, in: web)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var onHeight: (CGFloat) -> Void = { _ in }
        private var loaded = false
        private var pending: String?
        private var shown: String?

        func show(_ json: String, in web: WKWebView) {
            guard json != shown else { return }
            guard loaded else { pending = json; return }
            shown = json
            web.evaluateJavaScript("render(\(json))", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let pending {
                self.pending = nil
                show(pending, in: webView)
            }
        }

        func heightChanged(_ value: Double) {
            let height = CGFloat(value)
            DispatchQueue.main.async { self.onHeight(height) }
        }
    }

    /// The page's height reports, without the web view keeping the card's coordinator alive.
    @MainActor
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?
        init(_ coordinator: Coordinator) { self.coordinator = coordinator }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = (message.body as? NSNumber)?.doubleValue else { return }
            coordinator?.heightChanged(value)
        }
    }
}
