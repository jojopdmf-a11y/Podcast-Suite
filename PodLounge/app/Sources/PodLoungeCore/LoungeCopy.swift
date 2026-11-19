import Foundation

/// On-screen name for the project audio list. The folder on disk stays `depot/`.
public enum LoungeCopy {
    public static let valet = "TheValet"

    /// True when a string literal says Depot as a word, not as part of an identifier.
    public static func mentionsDepot(_ literal: String) -> Bool {
        let word = "de" + "pot"
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)(?<![A-Za-z0-9_])\(word)(?![A-Za-z0-9_])"
        ) else { return false }
        let range = NSRange(literal.startIndex..., in: literal)
        return regex.firstMatch(in: literal, options: [], range: range) != nil
    }

    /// Paths, the folder name, the pasteboard type, and identifier keys are not labels.
    public static func isAllowedDepotLiteral(_ literal: String) -> Bool {
        if literal.contains("depot/") { return true }
        if literal == "depot" { return true }
        if literal.contains("depot-asset") { return true }
        if literal.contains("depot."),
           literal.contains(" ") == false,
           literal.contains("\n") == false {
            return true
        }
        return false
    }

    public static func stringLiterals(in source: String) -> [String] {
        var literals: [String] = []
        var index = source.startIndex
        while index < source.endIndex {
            guard source[index] == "\"" else {
                index = source.index(after: index)
                continue
            }
            var cursor = source.index(after: index)
            var content = ""
            var escaped = false
            var closed = false
            while cursor < source.endIndex {
                let character = source[cursor]
                if escaped {
                    content.append(character)
                    escaped = false
                    cursor = source.index(after: cursor)
                    continue
                }
                if character == "\\" {
                    escaped = true
                    content.append(character)
                    cursor = source.index(after: cursor)
                    continue
                }
                if character == "\"" {
                    literals.append(content)
                    index = source.index(after: cursor)
                    closed = true
                    break
                }
                content.append(character)
                cursor = source.index(after: cursor)
            }
            if closed == false { break }
        }
        return literals
    }
}
