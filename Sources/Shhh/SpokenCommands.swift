import Foundation

/// Layout said out loud while dictating: "new line", "new paragraph", "new bullet", and "scratch
/// that" to take back the sentence just said. For essays, emails and notes, where the breaks matter.
/// Dictation only: Claude understands the words as they are.
enum SpokenCommands {
    /// The words, what they become, and what a comma the model put just before them turns into.
    /// The models put commas around the words ("on Friday, new paragraph, I still…"): a paragraph
    /// ends its sentence, a bullet needs nothing, and a new line keeps it ("Dear Ms Lee,").
    private static let commands: [(words: String, insert: String, comma: String)] = [
        ("new paragraph|next paragraph", "\n\n", "."),
        ("new line|next line", "\n", ","),
        ("(?:new|next) bullet(?: point)?", "\n- ", ""),
    ]

    /// The text with the spoken breaks made real. Other punctuation before the words stays; the
    /// punctuation after them goes.
    static func apply(_ text: String, capitalize: Bool) -> String {
        var text = scratched(text, capitalize: capitalize)
        for (words, insert, comma) in commands {
            let after = #")\b[,.;:!?]?[ \t]*"#
            text = text.replacingOccurrences(of: #",[ \t]*\b(?:"# + words + after, with: comma + insert,
                                             options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: #"[ \t]*\b(?:"# + words + after, with: insert,
                                             options: [.regularExpression, .caseInsensitive])
        }
        guard capitalize, text.contains("\n") else { return text }
        // A new line or bullet starts with a capital, like a sentence.
        var result = ""
        var startOfLine = false
        for character in text {
            if character == "\n" {
                startOfLine = true
            } else if startOfLine, character.isLetter {
                result += character.uppercased()
                startOfLine = false
                continue
            } else if startOfLine, character != " ", character != "-" {
                startOfLine = false
            }
            result.append(character)
        }
        return result
    }

    /// "…, scratch that": the sentence just said goes, the words themselves too. Back to the last
    /// sentence end or line break before it; said first thing, there's nothing to take back.
    private static func scratched(_ text: String, capitalize: Bool) -> String {
        let pattern = #"(?i)[,;:]?\s*\b(?:scratch that|delete that)\b[,.;:!?]?\s*"#
        var text = text
        while let found = text.range(of: pattern, options: .regularExpression) {
            // "It ended in 1920. Scratch that.": the full stop before it ends the sentence to take back.
            var before = text[..<found.lowerBound]
            while before.last == " " { before = before.dropLast() }
            if let last = before.last, ".!?".contains(last) { before = before.dropLast() }
            let cut = before.lastIndex { ".!?\n".contains($0) }.map { before.index(after: $0) } ?? before.startIndex
            let kept = String(text[..<cut])
            var rest = String(text[found.upperBound...])
            // What comes next starts a sentence now ("Keynes, scratch that the essay…").
            if capitalize, let first = rest.first, first.isLowercase,
               kept.trimmingCharacters(in: .whitespaces).last.map({ ".!?\n".contains($0) }) ?? true {
                rest = first.uppercased() + rest.dropFirst()
            }
            text = kept.isEmpty || kept.hasSuffix("\n") ? kept + rest : kept + (rest.isEmpty ? "" : " ") + rest
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
