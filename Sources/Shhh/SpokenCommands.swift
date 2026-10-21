import Foundation

/// Layout said out loud while dictating: "new line", "new paragraph", "new bullet". For essays,
/// emails and notes, where the breaks matter. Dictation only: Claude understands the words as they are.
enum SpokenCommands {
    private static let commands: [(words: String, insert: String)] = [
        ("new paragraph|next paragraph", "\n\n"),
        ("new line|next line", "\n"),
        ("(?:new|next) bullet(?: point)?", "\n- "),
    ]

    /// The text with the spoken breaks made real. The punctuation the model put before the words
    /// stays ("Dear Ms Lee, new line" keeps its comma); the one after them goes.
    static func apply(_ text: String, capitalize: Bool) -> String {
        var text = text
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
}
