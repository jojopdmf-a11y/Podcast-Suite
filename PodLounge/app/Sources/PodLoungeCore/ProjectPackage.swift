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
    /// Test seam. The next Stripper group import fails after its copies, then deletes them.
    var failStripperImportAfterStagingForTesting = false

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

    public static let nestedProjectMessage = "You can't save a project inside another project. Pick a different folder."

    /// True when a parent of `url` is a folder whose name ends in `.podlounge`.
    /// The URL itself is the project being saved or created, so that folder does not count.
    public static func isInsideAnotherProject(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.count >= 2 else { return false }
        for part in parts.dropLast() {
            let ext = URL(fileURLWithPath: part).pathExtension
            if ext.lowercased() == PackageLayout.pathExtension {
                return true
            }
        }
        return false
    }

    public static func create(at url: URL, name: String) throws -> ProjectPackage {
        if isInsideAnotherProject(url) {
            throw PackageError.operationFailed(nestedProjectMessage)
        }
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
        try rejectNestedWrite()
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
        if Self.isInsideAnotherProject(dest) {
            throw PackageError.operationFailed(Self.nestedProjectMessage)
        }
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

    /// Copies `source` into the depot once. The asset id is a new UUID. The
    /// stored file name is the sanitized display name plus the file extension,
    /// with " 2", " 3", … when that name is already used (case-insensitive).
    /// Existing relative paths are never renamed. The source file is only read.
    /// On any failure the manifest file and the in-memory asset list are left
    /// as they were.
    @discardableResult
    public func importMedia(
        from source: URL,
        kind: AssetKind,
        producedBy: String?,
        select: Bool = false,
        displayName: String? = nil
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
        let display = Self.sanitizedDisplayName(displayName ?? Self.displayName(for: source))
        let fileName = try allocateDepotFileName(displayName: display, ext: ext, kind: kind)
        let relativePath = "\(kind.depotDirectory)/\(fileName)"
        let destination = try Self.locate(relativePath: relativePath, kind: kind, in: rootURL)
        if fm.fileExists(atPath: destination.path) {
            throw PackageError.importFailed("A depot file already uses that name.")
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
            displayName: display,
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

    /// Copies a rendered file into `depot/results` under `displayName`.
    /// The source file is only read. Existing depot files are not renamed.
    ///
    /// Selection is left alone unless `select` is true. Saving a leveled file
    /// therefore keeps the depot on the file being worked on. When nothing was
    /// selected and `select` is false, the selection stays nil: the new file
    /// appears in the list and nothing jumps to it.
    @discardableResult
    public func importResult(
        from source: URL,
        producedBy: String,
        displayName: String,
        select: Bool = false
    ) throws -> DepotAsset {
        try importMedia(
            from: source,
            kind: .result,
            producedBy: producedBy,
            select: select,
            displayName: displayName
        )
    }

    /// Copies the stored depot file to `destination` byte for byte.
    /// Does not rewrite the project, the manifest, or the depot original.
    public func exportCopy(of asset: DepotAsset, to destination: URL) throws {
        let source = try resolvedURL(for: asset)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PackageError.operationFailed("That file is missing from the project.")
        }
        try Self.copyFileBytes(from: source, to: destination.standardizedFileURL)
    }

    /// Save-panel name: the display name plus the stored file's extension,
    /// with characters the file system rejects turned into spaces.
    public static func exportCopySuggestedName(displayName: String, relativePath: String) -> String {
        let ext = storageExtensionString(URL(fileURLWithPath: relativePath).pathExtension)
        let display = sanitizedDisplayName(displayName)
        let stem = cappedStem(storageStem(displayName: display, extension: ext), extension: ext)
        return "\(stem).\(ext)"
    }

    public var limiterSettingsURL: URL {
        Self.appending("workspaces/limiter.json", to: rootURL)
    }

    /// `{}` and unreadable files become defaults. Opening a project never fails on this file.
    public func readLimiterSettings() -> LimiterWorkspaceSettings {
        guard let data = try? Data(contentsOf: limiterSettingsURL), !data.isEmpty else {
            return .defaults
        }
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "{}" { return .defaults }
        return (try? JSONDecoder().decode(LimiterWorkspaceSettings.self, from: data)) ?? .defaults
    }

    public func writeLimiterSettings(_ settings: LimiterWorkspaceSettings) throws {
        try rejectNestedWrite()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\n") { text += "\n" }
        do {
            try AtomicFile.write(Data(text.utf8), to: limiterSettingsURL)
        } catch let error as PackageError {
            throw error
        } catch {
            throw PackageError.atomicWriteFailed(error.localizedDescription)
        }
    }

    /// Removes an asset from the project: the manifest is saved without it,
    /// then its copy inside the depot is deleted. Files outside the project
    /// (the user's originals) are never touched. If the manifest save fails,
    /// nothing changes on disk or in memory.
    public func removeAsset(id: String) throws {
        guard let index = manifest.assets.firstIndex(where: { $0.id == id }) else {
            throw PackageError.operationFailed("That file is not in this project's depot.")
        }
        let asset = manifest.assets[index]
        let fileURL = try? resolvedURL(for: asset)
        let snapshot = manifest
        manifest.assets.remove(at: index)
        if manifest.selectedAssetID == id {
            manifest.selectedAssetID = nil
        }
        do {
            try save()
        } catch {
            manifest = snapshot
            throw error
        }
        missingAssetIDs.remove(id)
        mismatchedAssetIDs.remove(id)
        if let fileURL {
            let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
            let target = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            if Self.isInsideOrEqual(target, root: root), target.path != root.path {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
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
        guard isSafeDepotFileName(fileName) else {
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
        storageExtensionString(source.pathExtension)
    }

    static func storageExtensionString(_ ext: String) -> String {
        let lower = ext.lowercased()
        if lower.range(of: #"^[a-z0-9]{1,8}$"#, options: .regularExpression) != nil {
            return lower
        }
        return "bin"
    }

    /// File name stem for a depot copy. Illegal storage characters become spaces.
    /// A matching extension on `displayName` is removed so it is not doubled.
    static func storageStem(displayName: String, extension ext: String) -> String {
        var text = displayName
        let suffix = "." + ext.lowercased()
        if !ext.isEmpty, text.lowercased().hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        var mapped = ""
        mapped.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if isIllegalStorageScalar(scalar) {
                mapped.append(" ")
            } else {
                mapped.unicodeScalars.append(scalar)
            }
        }
        let collapsed = mapped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var stem = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if stem.isEmpty || stem == "." || stem == ".." {
            stem = "Untitled"
        }
        return stem.precomposedStringWithCanonicalMapping
    }

    static func cappedStem(_ stem: String, extension ext: String) -> String {
        let reserve = 6 + ext.utf8.count
        let budget = max(1, 255 - reserve)
        var text = stem
        while text.utf8.count > budget, !text.isEmpty {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return text.isEmpty ? "Untitled" : text
    }

    static func isIllegalStorageScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\u{2028}", "\u{2029}":
            return true
        default:
            return scalar.value == 0 || CharacterSet.controlCharacters.contains(scalar)
        }
    }

    /// Accepts both legacy UUID file names and the readable names new imports use.
    static func isSafeDepotFileName(_ fileName: String) -> Bool {
        if fileName.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil {
            return true
        }
        if fileName.isEmpty || fileName == "." || fileName == ".." { return false }
        if fileName.utf8.count > 255 { return false }
        if fileName.hasPrefix(".") || fileName.hasSuffix(".") { return false }
        if fileName.hasPrefix(" ") || fileName.hasSuffix(" ") { return false }
        if fileName.unicodeScalars.contains(where: isIllegalStorageScalar) { return false }
        return true
    }

    static func displayName(for source: URL) -> String {
        sanitizedDisplayName(source.lastPathComponent)
    }

    static func sanitizedDisplayName(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { scalar in
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

    func rejectNestedWrite() throws {
        if Self.isInsideAnotherProject(rootURL) {
            throw PackageError.operationFailed(Self.nestedProjectMessage)
        }
    }

    /// Picks `stem.ext`, then `stem 2.ext`, `stem 3.ext`, … until the name is free.
    func allocateDepotFileName(displayName: String, ext: String, kind: AssetKind) throws -> String {
        let stem = Self.cappedStem(Self.storageStem(displayName: displayName, extension: ext), extension: ext)
        var suffix: Int?
        for _ in 0..<9_000 {
            let fileName = suffix.map { "\(stem) \($0).\(ext)" } ?? "\(stem).\(ext)"
            guard Self.isSafeDepotFileName(fileName) else {
                throw PackageError.importFailed("Could not make a safe file name.")
            }
            if !depotFileNameIsTaken(fileName, kind: kind) {
                return fileName
            }
            suffix = (suffix ?? 1) + 1
        }
        throw PackageError.importFailed("Could not find a free file name in the depot.")
    }

    private func depotFileNameIsTaken(_ fileName: String, kind: AssetKind) -> Bool {
        let needle = Self.caseFold(fileName)
        for asset in manifest.assets where asset.kind == kind {
            let existing = URL(fileURLWithPath: asset.relativePath).lastPathComponent
            if Self.caseFold(existing) == needle { return true }
        }
        let directory = Self.appending(kind.depotDirectory, to: rootURL)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return names.contains { Self.caseFold($0) == needle }
    }

    private static func caseFold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func copyFileBytes(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let sourceID = source.standardizedFileURL.resolvingSymlinksInPath()
        let destID = destination.standardizedFileURL.resolvingSymlinksInPath()
        if sourceID == destID { return }
        let directory = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PackageError.operationFailed("Could not export a copy of that file.")
        }
        let temporary = directory.appendingPathComponent(".podlounge-export-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: temporary)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        } catch let error as PackageError {
            if fm.fileExists(atPath: temporary.path) {
                try? fm.removeItem(at: temporary)
            }
            throw error
        } catch {
            if fm.fileExists(atPath: temporary.path) {
                try? fm.removeItem(at: temporary)
            }
            throw PackageError.operationFailed("Could not export a copy of that file.")
        }
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
