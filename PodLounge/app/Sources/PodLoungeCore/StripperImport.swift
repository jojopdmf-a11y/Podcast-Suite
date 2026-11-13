import Foundation

extension ProjectPackage {
    public var stripperGroupsURL: URL {
        Self.appending("workspaces/stripper-groups.json", to: rootURL)
    }

    public func readStripperGroups() -> [StripperGroupRecord] {
        guard let data = try? Data(contentsOf: stripperGroupsURL), !data.isEmpty else {
            return []
        }
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "{}" || trimmed.isEmpty { return [] }
        return (try? JSONDecoder().decode(StripperWorkspaceFile.self, from: data))?.groups ?? []
    }

    /// Copies every track into `depot/results` and stores `speakers.json` beside
    /// the workspace, not as a depot file. Selection is never changed.
    /// A failure before the manifest save leaves no new tracks and no metadata.
    public func importStripperGroup(
        tracks: [StripperTrackImport],
        speakersJSON: URL,
        sourceAssetID: String,
        splitIndex: Int,
        outsideDirectory: URL? = nil
    ) throws -> StripperGroupImportResult {
        try rejectNestedWrite()
        let trimmedSource = sourceAssetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            throw PackageError.importFailed("The split is missing its source file.")
        }
        guard !tracks.isEmpty else {
            throw PackageError.importFailed("The split did not produce any tracks.")
        }
        let sanitizedNames = tracks.map { Self.sanitizedDisplayName($0.displayName) }
        if let problem = StripperNaming.validate(
            names: sanitizedNames,
            existingDisplayNames: manifest.assets.map(\.displayName)
        ) {
            throw PackageError.importFailed(problem)
        }

        let fm = FileManager.default
        let jsonSource = speakersJSON.standardizedFileURL
        guard fm.isReadableFile(atPath: jsonSource.path) else {
            throw PackageError.importFailed("The split is missing its speaker notes.")
        }

        var staged: [StagedTrack] = []
        var created: [URL] = []
        let snapshot = manifest
        let previousGroups = readStripperGroups()

        do {
            for track in tracks {
                let stagedTrack = try stage(track)
                staged.append(stagedTrack)
                created.append(stagedTrack.partial)
            }
            if failStripperImportAfterStagingForTesting {
                failStripperImportAfterStagingForTesting = false
                throw PackageError.importFailed("There is not enough free space to add these tracks.")
            }
            for index in staged.indices {
                if fm.fileExists(atPath: staged[index].destination.path) {
                    throw PackageError.importFailed("A depot file already uses that name.")
                }
                try fm.moveItem(at: staged[index].partial, to: staged[index].destination)
                created.removeAll { $0 == staged[index].partial }
                created.append(staged[index].destination)
            }

            let groupID = UUID().uuidString.lowercased()
            let relativeJSON = "workspaces/stripper/runs/\(groupID)/speakers.json"
            let jsonDestination = try Self.checkedPackageFile(relativeJSON, in: rootURL)
            let replacements = pathReplacements(staged: staged, sourceAssetID: trimmedSource)
            let rawJSON = try Data(contentsOf: jsonSource)
            let relativeJSONData = try StripperMetadata.relativize(json: rawJSON, replacements: replacements)
            try fm.createDirectory(at: jsonDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AtomicFile.write(relativeJSONData, to: jsonDestination)
            created.append(jsonDestination)

            let now = Date()
            let assets: [DepotAsset] = staged.map { item in
                DepotAsset(
                    id: UUID().uuidString.lowercased(),
                    displayName: ProjectPackage.sanitizedDisplayName(item.displayName),
                    kind: .result,
                    relativePath: item.relativePath,
                    byteCount: Self.byteCount(at: item.destination),
                    importedAt: now,
                    producedBy: "stripper"
                )
            }
            let group = StripperGroupRecord(
                id: groupID,
                sourceAssetID: trimmedSource,
                splitIndex: splitIndex,
                speakersJSONRelativePath: relativeJSON,
                trackAssetIDs: assets.map(\.id),
                createdAt: now
            )
            manifest.assets.append(contentsOf: assets)
            try save()
            do {
                try writeStripperGroups(previousGroups + [group])
            } catch {
                manifest = snapshot
                try? save()
                throw error
            }
            let warning = copyOutside(staged: staged, to: outsideDirectory)
            return StripperGroupImportResult(assets: assets, group: group, outsideCopyWarning: warning)
        } catch {
            manifest = snapshot
            for url in created.reversed() {
                try? fm.removeItem(at: url)
            }
            throw error
        }
    }

    /// Deletes a directory this split created. Paths outside the job folder are left alone.
    public func removeOwnedStripperStaging(_ url: URL) {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let allowed = Self.appending("recovery/stripper-jobs", to: root).standardizedFileURL.path
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = allowed.hasSuffix("/") ? allowed : allowed + "/"
        guard target.path.hasPrefix(prefix) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    public func makeStripperStagingDirectory() throws -> URL {
        try rejectNestedWrite()
        let url = Self.appending("recovery/stripper-jobs/\(UUID().uuidString.lowercased())", to: rootURL)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Private

    private struct StagedTrack {
        var displayName: String
        var sourceURL: URL
        var relativePath: String
        var partial: URL
        var destination: URL
    }

    private func stage(_ track: StripperTrackImport) throws -> StagedTrack {
        let fm = FileManager.default
        let source = track.sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PackageError.importFailed("A split track is missing.")
        }
        guard fm.isReadableFile(atPath: source.path) else {
            throw PackageError.importFailed("A split track is not readable.")
        }
        let ext = Self.storageExtension(for: source)
        let display = Self.sanitizedDisplayName(track.displayName)
        let fileName = try allocateDepotFileName(displayName: display, ext: ext, kind: .result)
        let relativePath = "\(AssetKind.result.depotDirectory)/\(fileName)"
        let destination = try Self.locate(relativePath: relativePath, kind: .result, in: rootURL)
        let partial = destination.appendingPathExtension("partial")
        if fm.fileExists(atPath: partial.path) {
            try? fm.removeItem(at: partial)
        }
        do {
            try fm.copyItem(at: source, to: partial)
            if (try? fm.destinationOfSymbolicLink(atPath: partial.path)) != nil {
                try? fm.removeItem(at: partial)
                throw PackageError.importFailed("Import refused to store a symlink.")
            }
        } catch let error as PackageError {
            try? fm.removeItem(at: partial)
            throw error
        } catch {
            try? fm.removeItem(at: partial)
            throw PackageError.importFailed(error.localizedDescription)
        }
        return StagedTrack(
            displayName: display,
            sourceURL: source,
            relativePath: relativePath,
            partial: partial,
            destination: destination
        )
    }

    private func pathReplacements(staged: [StagedTrack], sourceAssetID: String) -> [String: String] {
        var map: [String: String] = [:]
        for item in staged {
            let source = item.sourceURL
            map[source.path] = item.relativePath
            map[source.standardizedFileURL.path] = item.relativePath
            map[source.resolvingSymlinksInPath().path] = item.relativePath
            map[source.standardizedFileURL.resolvingSymlinksInPath().path] = item.relativePath
        }
        if let source = manifest.assets.first(where: { $0.id == sourceAssetID }),
           let url = try? resolvedURL(for: source) {
            map[url.standardizedFileURL.resolvingSymlinksInPath().path] = source.relativePath
        }
        return map
    }

    private func writeStripperGroups(_ groups: [StripperGroupRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(StripperWorkspaceFile(groups: groups))
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\n") { text += "\n" }
        try AtomicFile.write(Data(text.utf8), to: stripperGroupsURL)
    }

    private func copyOutside(staged: [StagedTrack], to directory: URL?) -> String? {
        guard let directory else { return nil }
        let folder = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "The tracks are in the depot. The extra folder could not be used."
        }
        var failures: [String] = []
        for item in staged {
            let ext = Self.storageExtension(for: item.destination)
            let stem = Self.cappedStem(Self.storageStem(displayName: item.displayName, extension: ext), extension: ext)
            let destination = uniqueOutsideFile(stem: stem, ext: ext, in: folder)
            do {
                if destination.standardizedFileURL.path == item.destination.standardizedFileURL.path {
                    continue
                }
                try FileManager.default.copyItem(at: item.destination, to: destination)
            } catch {
                failures.append(item.displayName)
            }
        }
        guard !failures.isEmpty else { return nil }
        return "The tracks are in the depot. The extra copy could not write \(failures.joined(separator: ", "))."
    }

    private func uniqueOutsideFile(stem: String, ext: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var suffix: Int?
        for _ in 0..<9_000 {
            let name = suffix.map { "\(stem) \($0).\(ext)" } ?? "\(stem).\(ext)"
            let url = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
            suffix = (suffix ?? 1) + 1
        }
        return folder.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(8)).\(ext)")
    }

    static func checkedPackageFile(_ relativePath: String, in root: URL) throws -> URL {
        if relativePath.contains("..") || relativePath.hasPrefix("/") {
            throw PackageError.pathEscapesPackage(relativePath)
        }
        let url = appending(relativePath, to: root).standardizedFileURL
        let rootStandard = root.standardizedFileURL
        guard isInsideOrEqual(url, root: rootStandard), url.path != rootStandard.path else {
            throw PackageError.pathEscapesPackage(relativePath)
        }
        return url
    }
}
