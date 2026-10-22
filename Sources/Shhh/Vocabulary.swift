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

    /// IB words every student says, built in so nobody has to add them: names the speech models
    /// mishear ("Manage BO", "manageBok") and acronyms they write in lower case ("tok", "cas").
    /// Only exact, whole-word swaps (plus ManageBac by sound): fuzzy matching on everyday-sounding
    /// names turned "turning in" into Turnitin. The user's own lines come first and win.
    static let builtInTerms = ["ManageBac"]
    static let builtInSwaps: [(String, String)] = [
        ("manage back", "ManageBac"), ("manage bac", "ManageBac"), ("manage bag", "ManageBac"),
        ("ib", "IB"), ("i b", "IB"), ("dp", "DP"), ("dp1", "DP1"), ("dp 1", "DP1"), ("dp2", "DP2"), ("dp 2", "DP2"),
        ("myp", "MYP"), ("tok", "TOK"), ("t o k", "TOK"), ("cas", "CAS"), ("ias", "IAs"), ("ia", "IA"),
        ("ee", "EE"), ("hl", "HL"), ("sl", "SL"), ("atl", "ATL"), ("atls", "ATLs"), ("ess", "ESS"),
        ("math aa", "Math AA"), ("math ai", "Math AI"), ("maths aa", "Maths AA"), ("maths ai", "Maths AI"),
        // Spelled out letter by letter, the way students say them.
        ("h l", "HL"), ("s l", "SL"), ("e e", "EE"), ("i a", "IA"), ("m y p", "MYP"), ("d p 1", "DP1"), ("d p 2", "DP2"),
        ("math a a", "Math AA"), ("math a i", "Math AI"), ("maths a a", "Maths AA"), ("maths a i", "Maths AI"),
        // Heard short, put right only where the next word gives it away ("CA" and "MP" are real elsewhere).
        ("ca hours", "CAS hours"), ("ca project", "CAS project"), ("ca experience", "CAS experience"),
        ("ca reflection", "CAS reflection"), ("ca reflections", "CAS reflections"), ("ca portfolio", "CAS portfolio"),
        ("tok sa", "TOK essay"), ("extended sa", "extended essay"),
        ("mp coordinator", "MYP coordinator"), ("mp personal project", "MYP personal project"),
    ]

    /// The transcript with the user's words spelled their way.
    static func apply(_ text: String) -> String {
        let file = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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
        // Built in after the user's: an exact swap they wrote for the same words wins. Not with the
        // European languages, where "cas" and "ee" are ordinary words.
        if Transcriber.languages != .european {
            let mine = Set(swaps.map { $0.0.lowercased() })
            swaps += builtInSwaps.filter { !mine.contains($0.0) }
            let written = Set(terms.map { $0.lowercased() })
            terms += builtInTerms.filter { !written.contains($0.lowercased()) }
        }
        var text = withoutStutters(text)
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
            // Fewest words first: "ManageBac To" is the name and then "To", not one sloppy ManageBac
            // that swallows the next word (the nightly test lost "tonight" that way).
            for n in 1...min(3, words.count - i) where !matched {
                let span = words[i].lowerBound..<words[i + n - 1].upperBound
                let heard = normalize(String(text[span]))
                for target in targets {
                    guard let first = target.key.first, heard.first == first else { continue }
                    let tolerance = target.key.count <= 4 ? 0 : (target.key.count >= 8 ? 2 : 1)
                    guard abs(heard.count - target.key.count) <= tolerance,
                          distance(heard, target.key) <= tolerance else { continue }
                    let exact = heard == target.key
                    if exact, text[span] == target.term { // already right: keep it, and its neighbours
                        i += n
                        matched = true
                        break
                    }
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

    /// SenseVoice sometimes writes the end of a word twice: "knowledgege", "internalnal" (seen with
    /// `say` recordings on the nightly, 21 Oct). Latin letters only: repeats are normal in Chinese ("谢谢"). A word that ends in a repeated piece of 2 to 4 letters,
    /// isn't a word itself, and is one without the repeat, loses the repeat. "banana" stays: it's a word.
    static func withoutStutters(_ text: String) -> String {
        var text = text
        for match in text.matches(of: #/\b[A-Za-z]*([A-Za-z]{2,4})\1\b/#).reversed() {
            let word = String(text[match.range])
            let repeated = match.output.1.count
            let fixed = String(word.dropLast(repeated))
            guard fixed.count >= 4, !isWord(word), isWord(fixed) else { continue }
            text.replaceSubrange(match.range, with: fixed)
        }
        return text
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
