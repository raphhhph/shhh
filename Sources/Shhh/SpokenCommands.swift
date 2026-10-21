import Foundation

/// Layout said out loud while dictating: "new line", "new paragraph", "new bullet", and "scratch
/// that" to take back the sentence just said. For essays, emails and notes, where the breaks matter. Dictation only: Claude understands the words as they are.
enum SpokenCommands {
    private static let commands: [(words: String, insert: String)] = [
        ("new paragraph|next paragraph", "\n\n"),
        ("new line|next line", "\n"),
        ("(?:new|next) bullet(?: point)?", "\n- "),
    ]

    /// The text with the spoken breaks made real. The punctuation the model put before the words
    /// stays ("Dear Ms Lee, new line" keeps its comma); the one after them goes.
    static func apply(_ text: String, capitalize: Bool) -> String {
        var text = scratched(text)
        for (words, insert) in commands {
            let pattern = #"[ \t]*\b(?:"# + words + #")\b[,.;:!?]?[ \t]*"#
            text = text.replacingOccurrences(of: pattern, with: insert, options: [.regularExpression, .caseInsensitive])
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
    private static func scratched(_ text: String) -> String {
        let pattern = #"(?i)[,;:]?\s*\b(?:scratch that|delete that)\b[,.;:!?]?\s*"#
        var text = text
        while let found = text.range(of: pattern, options: .regularExpression) {
            // "It ended in 1920. Scratch that.": the full stop before it ends the sentence to take back.
            var before = text[..<found.lowerBound]
            while before.last == " " { before = before.dropLast() }
            if let last = before.last, ".!?".contains(last) { before = before.dropLast() }
            let cut = before.lastIndex { ".!?\n".contains($0) }.map { before.index(after: $0) } ?? before.startIndex
            let kept = String(text[..<cut])
            let rest = String(text[found.upperBound...])
            text = kept.isEmpty || kept.hasSuffix("\n") ? kept + rest : kept + (rest.isEmpty ? "" : " ") + rest
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
