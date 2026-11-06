import Foundation

public enum PackageLayout {
    public static let formatVersion = 1
    public static let manifestFileName = "manifest.json"
    public static let pathExtension = "podlounge"
    public static let reservedDirectories = [
        "depot",
        "depot/originals",
        "depot/results",
        "workspaces",
        "recovery",
    ]
}

public struct DepotAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var kind: AssetKind
    /// Package-relative POSIX path. Never absolute, never `..`.
    public var relativePath: String
    public var byteCount: Int64
    public var importedAt: Date
    /// Set for results once a tool can write one. Originals stay nil.
    public var producedBy: String?

    public init(
        id: String,
        displayName: String,
        kind: AssetKind,
        relativePath: String,
        byteCount: Int64,
        importedAt: Date,
        producedBy: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.importedAt = importedAt
        self.producedBy = producedBy
    }
}

public struct WorkspaceSettings: Codable, Equatable, Sendable {
    public var notes: String

    public init(notes: String = "") {
        self.notes = notes
    }
}

public struct ProjectManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var projectName: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var selectedAssetID: String?
    public var assets: [DepotAsset]
    public var workspaceSettings: [String: WorkspaceSettings]
}

public enum AssetHealth: Equatable, Sendable {
    case present
    case missing
    case sizeMismatch
}

public enum PackageError: Error, Equatable, LocalizedError {
    case unsupportedFormatVersion(found: Int, supported: Int)
    case malformedManifest(String)
    case pathEscapesPackage(String)
    case importFailed(String)
    case notAPackage(String)
    case destinationExists(String)
    case atomicWriteFailed(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormatVersion(found, supported):
            "This project uses package format version \(found). Pod Lounge opens version \(supported) only and left the folder unchanged."
        case let .malformedManifest(detail):
            "The project manifest is malformed (\(detail)). Pod Lounge left the folder unchanged."
        case let .pathEscapesPackage(path):
            "The project points outside its folder (\(path)). Pod Lounge left the folder unchanged."
        case let .importFailed(detail):
            "Import failed (\(detail)). The project manifest was not changed."
        case let .notAPackage(path):
            "That folder is not a Pod Lounge project (\(path))."
        case let .destinationExists(path):
            "A file or folder already exists there (\(path))."
        case let .atomicWriteFailed(detail):
            "Could not save the project manifest (\(detail))."
        case let .operationFailed(detail):
            detail
        }
    }
}
