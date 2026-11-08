import Foundation

public struct StripperNameRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var sourceURL: URL
    public var roleLabel: String
    public var displayName: String

    public init(id: String, sourceURL: URL, roleLabel: String, displayName: String) {
        self.id = id
        self.sourceURL = sourceURL
        self.roleLabel = roleLabel
        self.displayName = displayName
    }
}

public struct StripperGroupRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sourceAssetID: String
    public var splitIndex: Int
    public var speakersJSONRelativePath: String
    public var trackAssetIDs: [String]
    public var createdAt: Date

    public init(
        id: String,
        sourceAssetID: String,
        splitIndex: Int,
        speakersJSONRelativePath: String,
        trackAssetIDs: [String],
        createdAt: Date
    ) {
        self.id = id
        self.sourceAssetID = sourceAssetID
        self.splitIndex = splitIndex
        self.speakersJSONRelativePath = speakersJSONRelativePath
        self.trackAssetIDs = trackAssetIDs
        self.createdAt = createdAt
    }
}

/// Groups live beside the workspace stub. `{}` from an older project means no groups.
public struct StripperWorkspaceFile: Codable, Equatable, Sendable {
    public var groups: [StripperGroupRecord]

    public init(groups: [StripperGroupRecord] = []) {
        self.groups = groups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decodeIfPresent([StripperGroupRecord].self, forKey: .groups) ?? []
    }
}

public struct StripperTrackImport: Equatable, Sendable {
    public var sourceURL: URL
    public var displayName: String

    public init(sourceURL: URL, displayName: String) {
        self.sourceURL = sourceURL
        self.displayName = displayName
    }
}

public struct StripperGroupImportResult: Equatable, Sendable {
    public var assets: [DepotAsset]
    public var group: StripperGroupRecord
    /// Set when the depot copy succeeded and the extra outside copy did not.
    public var outsideCopyWarning: String?

    public init(assets: [DepotAsset], group: StripperGroupRecord, outsideCopyWarning: String? = nil) {
        self.assets = assets
        self.group = group
        self.outsideCopyWarning = outsideCopyWarning
    }
}

public enum StripperNaming {
    public static let musicRole = "Music & SFX"
    public static let separator = " – "

    public static func sourceStem(displayName: String) -> String {
        let cleaned = ProjectPackage.sanitizedDisplayName(displayName)
        let url = URL(fileURLWithPath: cleaned)
        let ext = url.pathExtension
        guard !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return cleaned
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? cleaned : stem
    }

    public static func roleLabel(engineFileName: String) -> String {
        let stem = URL(fileURLWithPath: engineFileName).deletingPathExtension().lastPathComponent
        let spaced = stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let folded = spaced.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        if folded.contains("music"), folded.contains("sfx") || folded.contains("s f x") {
            return musicRole
        }
        if let number = firstInteger(in: folded, after: "speaker") {
            return "Speaker \(number)"
        }
        let trimmed = spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return trimmed.isEmpty ? "Track" : trimmed
    }

    /// Split 1 has no suffix. Later splits of the same source use `(Split 2)`.
    public static func prefill(sourceDisplayName: String, roleLabel: String, splitIndex: Int) -> String {
        let stem = sourceStem(displayName: sourceDisplayName)
        if splitIndex <= 1 {
            return "\(stem)\(separator)\(roleLabel)"
        }
        return "\(stem) (Split \(splitIndex))\(separator)\(roleLabel)"
    }

    public static func nextSplitIndex(sourceAssetID: String, groups: [StripperGroupRecord]) -> Int {
        let used = groups.filter { $0.sourceAssetID == sourceAssetID }.map(\.splitIndex)
        return (used.max() ?? 0) + 1
    }

    public static func drafts(
        sourceDisplayName: String,
        splitIndex: Int,
        tracks: [URL]
    ) -> [StripperNameRow] {
        tracks.map { url in
            let role = roleLabel(engineFileName: url.lastPathComponent)
            return StripperNameRow(
                id: url.lastPathComponent,
                sourceURL: url,
                roleLabel: role,
                displayName: prefill(sourceDisplayName: sourceDisplayName, roleLabel: role, splitIndex: splitIndex)
            )
        }
    }

    /// A gentle reason the names cannot be added, or nil when they are fine.
    public static func validate(names: [String], existingDisplayNames: [String]) -> String? {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if cleaned.contains(where: \.isEmpty) {
            return "Give every track a name. Nothing was added."
        }
        let folded = cleaned.map(fold)
        if Set(folded).count != folded.count {
            return "Each track needs its own name. Two of these match, so nothing was added."
        }
        let existing = Set(existingDisplayNames.map(fold))
        if let clash = cleaned.first(where: { existing.contains(fold($0)) }) {
            return "“\(clash)” is already in the depot. Change it so nothing is overwritten."
        }
        return nil
    }

    public static func fold(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func firstInteger(in text: String, after token: String) -> Int? {
        guard let range = text.range(of: token) else { return nil }
        let tail = text[range.upperBound...]
        let digits = tail.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}

public enum StripperMetadata {
    /// Rewrites absolute engine paths to package-relative paths. Other fields stay.
    public static func relativize(json: Data, replacements: [String: String]) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: json)
        let rewritten = rewrite(object, replacements: normalized(replacements))
        let data = try JSONSerialization.data(withJSONObject: rewritten, options: [.prettyPrinted, .sortedKeys])
        return data
    }

    private static func normalized(_ replacements: [String: String]) -> [String: String] {
        var map: [String: String] = [:]
        for (key, value) in replacements {
            map[standardPath(key)] = value
            map[key] = value
        }
        return map
    }

    private static func standardPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func rewrite(_ value: Any, replacements: [String: String]) -> Any {
        if let string = value as? String {
            if let match = replacements[string] { return match }
            let standard = standardPath(string)
            if let match = replacements[standard] { return match }
            let resolved = URL(fileURLWithPath: string).resolvingSymlinksInPath().path
            if let match = replacements[resolved] { return match }
            return string
        }
        if let array = value as? [Any] {
            return array.map { rewrite($0, replacements: replacements) }
        }
        if let dictionary = value as? [String: Any] {
            var next: [String: Any] = [:]
            for (key, item) in dictionary {
                next[key] = rewrite(item, replacements: replacements)
            }
            return next
        }
        return value
    }
}
