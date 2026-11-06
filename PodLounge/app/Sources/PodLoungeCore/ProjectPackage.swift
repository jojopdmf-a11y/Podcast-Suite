import Foundation

/// A `.podlounge` folder. Manifest writes are atomic. Depot audio is copied
/// on import and is not rewritten by Save Project.
///
/// Not thread-safe. Call it from one actor (the app uses the main actor).
public final class ProjectPackage {
    public let rootURL: URL
    public var manifest: ProjectManifest
    public private(set) var missingAssetIDs: Set<String>
    public private(set) var mismatchedAssetIDs: Set<String>

    /// Test seam. When set, the next `save()` throws before touching disk.
    var failNextSaveForTesting = false

    init(
        rootURL: URL,
        manifest: ProjectManifest,
        missingAssetIDs: Set<String>,
        mismatchedAssetIDs: Set<String>
    ) {
        self.rootURL = rootURL
        self.manifest = manifest
        self.missingAssetIDs = missingAssetIDs
        self.mismatchedAssetIDs = mismatchedAssetIDs
    }

    public var manifestURL: URL {
        rootURL.appendingPathComponent(PackageLayout.manifestFileName)
    }

    public static func create(at url: URL, name: String) throws -> ProjectPackage {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            throw PackageError.destinationExists(url.path)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw PackageError.operationFailed("Project name is empty.")
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw PackageError.operationFailed("Could not create the project folder.")
        }
        do {
            return try populate(at: url, name: trimmed)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }

    public static func open(at url: URL) throws -> ProjectPackage {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PackageError.notAPackage(url.path)
        }
        let manifestURL = url.appendingPathComponent(PackageLayout.manifestFileName)
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw PackageError.malformedManifest("manifest.json is missing or unreadable.")
        }
        var manifest = try decodeManifest(data)
        for workspace in WorkspaceID.allCases where manifest.workspaceSettings[workspace.rawValue] == nil {
            manifest.workspaceSettings[workspace.rawValue] = WorkspaceSettings()
        }
        try validate(manifest)
        let health = try inspect(rootURL: url, manifest: manifest)
        return ProjectPackage(
            rootURL: url,
            manifest: manifest,
            missingAssetIDs: health.missing,
            mismatchedAssetIDs: health.mismatched
        )
    }

    /// Walks up from a picked file or folder to the project that contains it.
    public static func locateRoot(from picked: URL) -> URL? {
        let fm = FileManager.default
        var current = picked.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: current.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            current = current.deletingLastPathComponent()
        }
        for _ in 0..<6 {
            let manifest = current.appendingPathComponent(PackageLayout.manifestFileName)
            if fm.fileExists(atPath: manifest.path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    public static func directoryURL(forPickedURL url: URL) -> URL {
        if url.pathExtension.lowercased() == PackageLayout.pathExtension {
            return url
        }
        return url.appendingPathExtension(PackageLayout.pathExtension)
    }

    /// Writes `manifest.json` via temp file + rename. Does not touch depot bytes.
    public func save() throws {
        if failNextSaveForTesting {
            failNextSaveForTesting = false
            throw PackageError.atomicWriteFailed("Simulated save failure.")
        }
        manifest.formatVersion = PackageLayout.formatVersion
        manifest.modifiedAt = Date()
        let data = try Self.encode(manifest)
        do {
            try AtomicFile.write(data, to: manifestURL)
        } catch let error as PackageError {
            throw error
        } catch {
            throw PackageError.atomicWriteFailed(error.localizedDescription)
        }
    }

    /// Copies the folder once, then writes the in-memory manifest on the copy only.
    public func saveAs(to destination: URL) throws -> ProjectPackage {
        let fm = FileManager.default
        let dest = destination.standardizedFileURL
        let root = rootURL.standardizedFileURL
        if Self.isInsideOrEqual(dest, root: root) {
            throw PackageError.operationFailed("Save As must be outside this project folder.")
        }
        if fm.fileExists(atPath: dest.path) {
            throw PackageError.destinationExists(dest.path)
        }
        do {
            try fm.copyItem(at: rootURL, to: dest)
        } catch {
            throw PackageError.operationFailed("Could not copy the project folder.")
        }
        let copy = ProjectPackage(
            rootURL: dest,
            manifest: manifest,
            missingAssetIDs: missingAssetIDs,
            mismatchedAssetIDs: mismatchedAssetIDs
        )
        do {
            try copy.save()
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
        return copy
    }

    /// Copies `source` into the depot once, under a new id. Same display names
    /// do not share a filename. The source file is only read. On any failure
    /// the manifest file and the in-memory asset list are left as they were.
    @discardableResult
    public func importMedia(
        from source: URL,
        kind: AssetKind,
        producedBy: String?,
        select: Bool = false
    ) throws -> DepotAsset {
        if kind == .original, producedBy != nil {
            throw PackageError.operationFailed("Originals do not have a producing tool.")
        }
        let fm = FileManager.default
        let resolvedSource = source.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolvedSource.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PackageError.importFailed("Source is not a readable file.")
        }
        guard fm.isReadableFile(atPath: resolvedSource.path) else {
            throw PackageError.importFailed("Source is not readable.")
        }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        if Self.isInsideOrEqual(resolvedSource, root: root) {
            throw PackageError.importFailed("Choose a file outside this project. Depot files are already inside the package.")
        }

        let id = UUID().uuidString.lowercased()
        let ext = Self.storageExtension(for: source)
        let fileName = "\(id).\(ext)"
        let relativePath = "\(kind.depotDirectory)/\(fileName)"
        let destination = try Self.locate(relativePath: relativePath, kind: kind, in: rootURL)
        if fm.fileExists(atPath: destination.path) {
            throw PackageError.importFailed("Depot id collision.")
        }
        let partial = destination.appendingPathExtension("partial")
        if fm.fileExists(atPath: partial.path) {
            try? fm.removeItem(at: partial)
        }

        do {
            try fm.copyItem(at: resolvedSource, to: partial)
            if (try? fm.destinationOfSymbolicLink(atPath: partial.path)) != nil {
                try? fm.removeItem(at: partial)
                throw PackageError.importFailed("Import refused to store a symlink.")
            }
            try fm.moveItem(at: partial, to: destination)
        } catch let error as PackageError {
            try? fm.removeItem(at: partial)
            throw error
        } catch {
            try? fm.removeItem(at: partial)
            throw PackageError.importFailed(error.localizedDescription)
        }

        let byteCount = Self.byteCount(at: destination)
        let asset = DepotAsset(
            id: id,
            displayName: Self.displayName(for: source),
            kind: kind,
            relativePath: relativePath,
            byteCount: byteCount,
            importedAt: Date(),
            producedBy: producedBy
        )
        let snapshot = manifest
        manifest.assets.append(asset)
        if select {
            manifest.selectedAssetID = asset.id
        }
        do {
            try save()
        } catch {
            manifest = snapshot
            try? fm.removeItem(at: destination)
            try? fm.removeItem(at: partial)
            throw error
        }
        missingAssetIDs.remove(asset.id)
        mismatchedAssetIDs.remove(asset.id)
        return asset
    }

    public func resolvedURL(for asset: DepotAsset) throws -> URL {
        try Self.locate(relativePath: asset.relativePath, kind: asset.kind, in: rootURL)
    }

    public func health(of asset: DepotAsset) -> AssetHealth {
        if missingAssetIDs.contains(asset.id) { return .missing }
        if mismatchedAssetIDs.contains(asset.id) { return .sizeMismatch }
        return .present
    }

    public func rescan() throws {
        try Self.validate(manifest)
        let health = try Self.inspect(rootURL: rootURL, manifest: manifest)
        missingAssetIDs = health.missing
        mismatchedAssetIDs = health.mismatched
    }

    // MARK: - Private

    private static func populate(at url: URL, name: String) throws -> ProjectPackage {
        let fm = FileManager.default
        for relative in PackageLayout.reservedDirectories {
            try fm.createDirectory(at: appending(relative, to: url), withIntermediateDirectories: true)
        }
        for workspace in WorkspaceID.allCases {
            let stub = appending("workspaces/\(workspace.rawValue).json", to: url)
            try Data("{}\n".utf8).write(to: stub, options: .atomic)
        }
        let now = Date()
        var settings: [String: WorkspaceSettings] = [:]
        for workspace in WorkspaceID.allCases {
            settings[workspace.rawValue] = WorkspaceSettings()
        }
        let manifest = ProjectManifest(
            formatVersion: PackageLayout.formatVersion,
            projectName: name,
            createdAt: now,
            modifiedAt: now,
            selectedAssetID: nil,
            assets: [],
            workspaceSettings: settings
        )
        let package = ProjectPackage(
            rootURL: url,
            manifest: manifest,
            missingAssetIDs: [],
            mismatchedAssetIDs: []
        )
        try package.save()
        return package
    }

    private static func decodeManifest(_ data: Data) throws -> ProjectManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header: ManifestHeader
        do {
            header = try decoder.decode(ManifestHeader.self, from: data)
        } catch {
            throw PackageError.malformedManifest("manifest.json is not JSON with a formatVersion.")
        }
        guard header.formatVersion == PackageLayout.formatVersion else {
            throw PackageError.unsupportedFormatVersion(
                found: header.formatVersion,
                supported: PackageLayout.formatVersion
            )
        }
        let manifest: ProjectManifest
        do {
            manifest = try decoder.decode(ProjectManifest.self, from: data)
        } catch {
            throw PackageError.malformedManifest(error.localizedDescription)
        }
        return manifest
    }

    static func encode(_ manifest: ProjectManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private static func validate(_ manifest: ProjectManifest) throws {
        if manifest.formatVersion != PackageLayout.formatVersion {
            throw PackageError.unsupportedFormatVersion(
                found: manifest.formatVersion,
                supported: PackageLayout.formatVersion
            )
        }
        var ids: Set<String> = []
        var paths: Set<String> = []
        for asset in manifest.assets {
            if asset.id.isEmpty || !ids.insert(asset.id).inserted {
                throw PackageError.malformedManifest("Asset ids must be unique and non-empty.")
            }
            if asset.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PackageError.malformedManifest("Asset \(asset.id) has no display name.")
            }
            if asset.byteCount < 0 {
                throw PackageError.malformedManifest("Asset \(asset.id) has a negative size.")
            }
            if asset.kind == .original, asset.producedBy != nil {
                throw PackageError.malformedManifest("Original \(asset.id) must not name a producing tool.")
            }
            if let producedBy = asset.producedBy,
               producedBy.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) == nil {
                throw PackageError.malformedManifest("Asset \(asset.id) has an unsafe producedBy value.")
            }
            let relative = try checkedRelativePath(asset.relativePath, kind: asset.kind)
            if !paths.insert(relative).inserted {
                throw PackageError.malformedManifest("Two assets share \(relative).")
            }
        }
    }

    private static func inspect(rootURL: URL, manifest: ProjectManifest) throws -> (missing: Set<String>, mismatched: Set<String>) {
        let fm = FileManager.default
        let rootResolved = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        var missing: Set<String> = []
        var mismatched: Set<String> = []
        for asset in manifest.assets {
            let url = try locate(relativePath: asset.relativePath, kind: asset.kind, in: rootURL)
            if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                if !isInsideOrEqual(resolved, root: rootResolved) {
                    throw PackageError.pathEscapesPackage(asset.relativePath)
                }
            }
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !exists {
                missing.insert(asset.id)
                continue
            }
            if isDirectory.boolValue {
                throw PackageError.malformedManifest("Asset \(asset.id) points at a directory.")
            }
            let actual = byteCount(at: url)
            if actual != asset.byteCount {
                mismatched.insert(asset.id)
            }
        }
        return (missing, mismatched)
    }

    static func checkedRelativePath(_ raw: String, kind: AssetKind) throws -> String {
        if raw.isEmpty || raw.hasPrefix("/") || raw.hasPrefix("~") || raw.contains("\\") || raw.contains("\0") {
            throw PackageError.pathEscapesPackage(raw)
        }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            throw PackageError.pathEscapesPackage(raw)
        }
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            throw PackageError.pathEscapesPackage(raw)
        }
        let expected = kind.depotDirectory.split(separator: "/").map(String.init)
        guard parts[0] == expected[0], parts[1] == expected[1] else {
            throw PackageError.malformedManifest("Asset path is outside \(kind.depotDirectory).")
        }
        let fileName = parts[2]
        guard fileName.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
            throw PackageError.malformedManifest("Unsafe depot filename.")
        }
        return parts.joined(separator: "/")
    }

    static func locate(relativePath: String, kind: AssetKind, in root: URL) throws -> URL {
        let relative = try checkedRelativePath(relativePath, kind: kind)
        let url = appending(relative, to: root).standardizedFileURL
        let rootStandard = root.standardizedFileURL
        guard isInsideOrEqual(url, root: rootStandard), url.path != rootStandard.path else {
            throw PackageError.pathEscapesPackage(relativePath)
        }
        return url
    }

    static func appending(_ relative: String, to root: URL) -> URL {
        var url = root
        for part in relative.split(separator: "/") where !part.isEmpty {
            url.appendPathComponent(String(part))
        }
        return url
    }

    static func isInsideOrEqual(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix)
    }

    static func storageExtension(for source: URL) -> String {
        let ext = source.pathExtension.lowercased()
        if ext.range(of: #"^[a-z0-9]{1,8}$"#, options: .regularExpression) != nil {
            return ext
        }
        return "bin"
    }

    static func displayName(for source: URL) -> String {
        let scalars = source.lastPathComponent.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != "\\" && !CharacterSet.controlCharacters.contains(scalar)
        }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Untitled" }
        if text.count > 255 { return String(text.prefix(255)) }
        return text
    }

    static func byteCount(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let number = attributes?[.size] as? NSNumber
        return number?.int64Value ?? 0
    }
}

private struct ManifestHeader: Decodable {
    let formatVersion: Int
}

enum AtomicFile {
    static func write(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .noFileProtection)
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.synchronize()
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        } catch {
            if fm.fileExists(atPath: temporary.path) {
                try? fm.removeItem(at: temporary)
            }
            throw PackageError.atomicWriteFailed(error.localizedDescription)
        }
    }
}
