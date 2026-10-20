import AppKit
import WebKit

/// `Joe --math-pdf <spec.json> [out.pdf]`: worked maths solutions as a PDF that reads like a good
/// handwritten answer: every step typeset (KaTeX, through Resources/mathdoc.js), a short "why"
/// beside it, the answer boxed, one question per page. The spec's format is in mathdoc.js.
@MainActor
enum MathDoc {
    static func run(_ arguments: [String]) {
        let spec = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath)
        let pdf = arguments.count > 1 ? URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
            : spec.deletingPathExtension().appendingPathExtension("pdf")
        guard let script = Bundle.main.url(forResource: "mathdoc", withExtension: "js") else { return finish("The maths template is missing from the app.") }
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first(where: FileManager.default.isExecutableFile) else {
            return finish("Needs Node.js (brew install node).")
        }
        // The page and KaTeX's files go in a folder of their own beside the PDF's build.
        let build = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shhh/MathDocs/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let html = build.appendingPathComponent("page.html")
        if !FileManager.default.fileExists(atPath: Slides.nodeModules + "/katex") {
            _ = shell("/usr/bin/env", ["npm", "install", "--silent", "--prefix", (Slides.nodeModules as NSString).deletingLastPathComponent, "katex@0.16.11"])
        }
        let made = shell(node, [script.path, spec.path, html.path], environment: ["NODE_PATH": Slides.nodeModules])
        guard made.ok, FileManager.default.fileExists(atPath: html.path) else { return finish("Couldn't build the page: \(made.output)") }
        printer = Printer(html, pdf) { ok in
            try? FileManager.default.removeItem(at: build) // the page and KaTeX copy were only for printing
            finish(ok ? "Made \(pdf.path) and opened it."
                      : "Couldn't print the PDF.")
            if ok { NSWorkspace.shared.open(pdf) }
        }
    }

    private static var printer: Printer?

    private static func finish(_ message: String) {
        print(message)
        exit(message.hasPrefix("Made") ? 0 : 1)
    }

    private static func shell(_ path: String, _ arguments: [String], environment: [String: String] = [:]) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (false, "couldn't run \(path)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// Prints a page to an A4 PDF with WebKit, off screen.
    private final class Printer: NSObject, WKNavigationDelegate {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 794, height: 1123), styleMask: [.borderless], backing: .buffered, defer: false)
        let out: URL
        let done: (Bool) -> Void

        init(_ page: URL, _ out: URL, done: @escaping (Bool) -> Void) {
            self.out = out
            self.done = done
            super.init()
            window.contentView = web
            web.navigationDelegate = self
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { self.printPage() } } // fonts settle
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done(false) }

        private func printPage() {
            let info = NSPrintInfo()
            info.paperSize = NSSize(width: 595.28, height: 841.89)
            info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 36; info.rightMargin = 36
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
            let operation = web.printOperation(with: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.view?.frame = web.bounds
            operation.runModal(for: window, delegate: self, didRun: #selector(printed(_:success:contextInfo:)), contextInfo: nil)
        }

        @objc func printed(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            done(success && FileManager.default.fileExists(atPath: out.path))
        }
    }
}
