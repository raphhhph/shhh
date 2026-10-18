import AppKit

/// The user's own words: names, products and acronyms the speech model gets wrong ("Amiel",
/// "manage back"). Kept in a text file, one per line, and applied to every transcript, dictated or
/// asked. A line is either a term, matched loosely against what was heard, or `heard -> Written`,
/// replaced exactly.
@MainActor
enum Vocabulary {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/Dictionary.txt")

    static func open() {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? """
            # Your dictionary: names and words Joe should spell your way.
            # One per line. Close misses are fixed ("Amiel" → Ammiel, "manage back" → ManageBac).
            # Words of 4 letters or fewer are only fixed when heard exactly.
            # For a fixed swap, write: what it hears -> what you want

            """.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    /// The transcript with the user's words spelled their way.
    static func apply(_ text: String) -> String {
        guard let file = try? String(contentsOf: url, encoding: .utf8) else { return text }
        var terms: [String] = []
        var swaps: [(String, String)] = []
        for line in file.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                swaps.append((parts[0], parts[1]))
            } else {
                terms.append(line)
            }
        }
        var text = text
        for (heard, written) in swaps {
            let pattern = #"(?<![\w])"# + NSRegularExpression.escapedPattern(for: heard) + #"(?![\w])"#
            text = text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: written),
                                             options: [.regularExpression, .caseInsensitive])
        }
        return terms.isEmpty ? text : fix(text, terms: terms)
    }

    /// Replaces runs of one to three words that sound like a term: the same letters give or take one
    /// (two for long terms), the same first letter, and not a real word in their own right.
    private static func fix(_ text: String, terms: [String]) -> String {
        let words = text.matches(of: #/[\p{L}\p{N}'’]+/#).map(\.range)
        guard !words.isEmpty else { return text }
        let targets = terms.map { (term: $0, key: normalize($0)) }.filter { !$0.key.isEmpty }
        var replacements: [(Range<String.Index>, String)] = []
        var i = 0
        while i < words.count {
            var matched = false
            for n in stride(from: min(3, words.count - i), through: 1, by: -1) where !matched {
                let span = words[i].lowerBound..<words[i + n - 1].upperBound
                let heard = normalize(String(text[span]))
                for target in targets {
                    guard let first = target.key.first, heard.first == first else { continue }
                    let tolerance = target.key.count <= 4 ? 0 : (target.key.count >= 8 ? 2 : 1)
                    guard abs(heard.count - target.key.count) <= tolerance,
                          distance(heard, target.key) <= tolerance else { continue }
                    let exact = heard == target.key
                    if exact, text[span] == target.term { continue } // already right
                    // A near miss that's an ordinary word ("postures") is more likely what was said.
                    // A capitalised one is a name, and a name this close to theirs is theirs.
                    let word = String(text[span])
                    if !exact, n == 1, word.first?.isLowercase == true, isWord(word) { continue }
                    replacements.append((span, target.term))
                    i += n
                    matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }
        var result = text
        for (range, term) in replacements.reversed() { result.replaceSubrange(range, with: term) }
        return result
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func isWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    /// Edit distance (Levenshtein).
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return a.isEmpty ? b.count : previous[b.count]
    }
}
