import Foundation

/// Default depot result name: `<source> – Leveled (<preset>)`.
///
/// A file that is already a result keeps a single suffix. Re-leveling replaces
/// ` – Leveled (…)`, including a suffix that was appended more than once.
public enum LevelerResultName {
    /// Space, en dash, space, then the label. Matches the name the Limiter writes.
    public static let marker = " \u{2013} Leveled ("

    public static func suggested(sourceName: String, presetTitle: String) -> String {
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? "Audio" : trimmed
        let withoutExtension = (raw as NSString).deletingPathExtension
        var stem = withoutExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty { stem = "Audio" }
        stem = strippingLeveledSuffixes(from: stem)
        if stem.isEmpty { stem = "Audio" }
        return "\(stem)\(marker)\(presetTitle))"
    }

    /// Removes every trailing ` – Leveled (…)` suffix. Other text is left as it is.
    public static func strippingLeveledSuffixes(from name: String) -> String {
        var stem = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while let range = stem.range(of: marker, options: .backwards) {
            let tail = stem[range.upperBound...]
            guard consumesBalancedSuffix(tail) else { break }
            stem = String(stem[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stem
    }

    /// `tail` is the text after ` – Leveled (`. The closing parenthesis must be the last character.
    private static func consumesBalancedSuffix(_ tail: Substring) -> Bool {
        guard tail.hasSuffix(")") else { return false }
        var depth = 1
        for (index, character) in tail.enumerated() {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth == 0 {
                return index == tail.count - 1
            }
        }
        return false
    }
}
