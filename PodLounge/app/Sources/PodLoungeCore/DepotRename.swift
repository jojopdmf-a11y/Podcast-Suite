import Foundation

public enum DepotRenameError: Error, Equatable, Sendable {
    case unknownAsset
    case emptyName
    /// `/` and `:` are rejected so a display name cannot look like a path.
    case illegalCharacter
}

public struct DepotRenameOutcome: Equatable, Sendable {
    public var displayName: String
    /// Another depot item already uses this name. The rename still applies.
    public var warnsDuplicate: Bool

    public init(displayName: String, warnsDuplicate: Bool) {
        self.displayName = displayName
        self.warnsDuplicate = warnsDuplicate
    }
}

extension ProjectPackage {
    /// Changes the manifest display name only. The depot file, its path, and its id stay put.
    /// An empty name, or one that contains `/` or `:`, leaves the old name in place.
    public func renameDisplayName(id: String, to raw: String) throws -> DepotRenameOutcome {
        guard let index = manifest.assets.firstIndex(where: { $0.id == id }) else {
            throw DepotRenameError.unknownAsset
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw DepotRenameError.emptyName
        }
        if trimmed.contains("/") || trimmed.contains(":") {
            throw DepotRenameError.illegalCharacter
        }
        let name = trimmed.count > 255 ? String(trimmed.prefix(255)) : trimmed
        let duplicate = manifest.assets.contains { $0.id != id && $0.displayName == name }
        if manifest.assets[index].displayName != name {
            manifest.assets[index].displayName = name
        }
        return DepotRenameOutcome(displayName: name, warnsDuplicate: duplicate)
    }
}
