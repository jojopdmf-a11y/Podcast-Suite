import Foundation
import Testing
@testable import PodLoungeCore

struct Scratch {
    let root: URL
    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("podlounge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? fm.removeItem(at: root)
    }

    func file(_ name: String, _ contents: String, in directory: URL? = nil) throws -> URL {
        let folder = directory ?? root
        if folder != root {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func manifestData(_ package: ProjectPackage) throws -> Data {
        try Data(contentsOf: package.manifestURL)
    }
}

private func expect<T: Error & Equatable>(
    _ expected: T,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record("Expected \(expected) to be thrown")
    } catch let error as T {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error \(error)")
    }
}

@Test func createSaveReopenRoundTripsMetadata() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let folder = scratch.root.appendingPathComponent("Morning.podlounge")
    let package = try ProjectPackage.create(at: folder, name: "Morning Show")
    #expect(package.manifest.formatVersion == PackageLayout.formatVersion)
    #expect(FileManager.default.fileExists(atPath: package.rootURL.appendingPathComponent("recovery").path))
    #expect(FileManager.default.fileExists(atPath: package.rootURL.appendingPathComponent("depot/results").path))
    let stub = try String(contentsOf: package.rootURL.appendingPathComponent("workspaces/fixer.json"), encoding: .utf8)
    #expect(stub == "{}\n")

    package.manifest.projectName = "Morning Show Ep. 12"
    package.manifest.workspaceSettings["fixer"] = WorkspaceSettings(notes: "stay until stop")
    try package.save()

    let names = try FileManager.default.contentsOfDirectory(atPath: package.rootURL.path)
    #expect(names.allSatisfy { !$0.contains(".tmp") })

    let reopened = try ProjectPackage.open(at: folder)
    #expect(reopened.manifest.projectName == "Morning Show Ep. 12")
    #expect(reopened.manifest.formatVersion == 1)
    #expect(reopened.manifest.workspaceSettings["fixer"]?.notes == "stay until stop")
    #expect(reopened.manifest.assets.isEmpty)
    let stubAfter = try String(contentsOf: reopened.rootURL.appendingPathComponent("workspaces/fixer.json"), encoding: .utf8)
    #expect(stubAfter == "{}\n")
}

@Test func saveDoesNotRewriteOrCopyAudio() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let source = try scratch.file("episode.wav", "original-bytes")
    let sourceBytes = try Data(contentsOf: source)
    let sourceDate = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let asset = try package.importMedia(from: source, kind: .original, producedBy: nil, select: true)
    let depotURL = try package.resolvedURL(for: asset)
    let depotBytes = try Data(contentsOf: depotURL)
    let depotDate = try FileManager.default.attributesOfItem(atPath: depotURL.path)[.modificationDate] as? Date
    #expect(depotBytes == sourceBytes)
    #expect(try Data(contentsOf: source) == sourceBytes)
    #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date == sourceDate)

    package.manifest.projectName = "Show renamed"
    try package.save()
    try package.save()

    #expect(try Data(contentsOf: depotURL) == depotBytes)
    #expect(try FileManager.default.attributesOfItem(atPath: depotURL.path)[.modificationDate] as? Date == depotDate)
    let originals = try FileManager.default.contentsOfDirectory(
        at: package.rootURL.appendingPathComponent("depot/originals"),
        includingPropertiesForKeys: nil
    )
    #expect(originals.count == 1)
    #expect(originals[0].lastPathComponent == "episode.wav")
    let raw = try String(contentsOf: package.manifestURL, encoding: .utf8)
    #expect(raw.contains("depot/originals/episode.wav"))
    #expect(raw.contains(asset.id))
    #expect(!raw.contains("depot/originals/\(asset.id).wav"))
    #expect(!raw.contains(source.deletingLastPathComponent().path))
    #expect(!raw.hasPrefix("/"))
    #expect(!raw.contains("\"relativePath\" : \"/"))
}

@Test func sameDisplayNameImportsDoNotClobber() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let first = try scratch.file("episode.wav", "alpha-take", in: scratch.root.appendingPathComponent("a"))
    let second = try scratch.file("episode.wav", "beta-take", in: scratch.root.appendingPathComponent("b"))
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let alpha = try package.importMedia(from: first, kind: .original, producedBy: nil)
    let beta = try package.importMedia(from: second, kind: .original, producedBy: nil)

    #expect(alpha.id != beta.id)
    #expect(alpha.displayName == "episode.wav")
    #expect(beta.displayName == "episode.wav")
    #expect(alpha.relativePath == "depot/originals/episode.wav")
    #expect(beta.relativePath == "depot/originals/episode 2.wav")
    #expect(try Data(contentsOf: package.resolvedURL(for: alpha)) == Data("alpha-take".utf8))
    #expect(try Data(contentsOf: package.resolvedURL(for: beta)) == Data("beta-take".utf8))
    #expect(try Data(contentsOf: first) == Data("alpha-take".utf8))
    #expect(try Data(contentsOf: second) == Data("beta-take".utf8))

    let resultSource = try scratch.file("bounce.wav", "limited")
    let result = try package.importMedia(from: resultSource, kind: .result, producedBy: "limiter")
    #expect(result.relativePath == "depot/results/bounce.wav")
    #expect(result.producedBy == "limiter")
    #expect(try Data(contentsOf: package.resolvedURL(for: result)) == Data("limited".utf8))

    let odd = try scratch.file("clip.not an ext", "odd-bytes")
    let stored = try package.importMedia(from: odd, kind: .original, producedBy: nil)
    #expect(stored.relativePath == "depot/originals/clip.not an ext.bin")
    #expect(stored.displayName == "clip.not an ext")
}

@Test func relativePathsSurviveSaveAsAndMove() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let source = try scratch.file("intro.wav", "intro-bytes")
    let originalURL = scratch.root.appendingPathComponent("Show.podlounge")
    let package = try ProjectPackage.create(at: originalURL, name: "Original")
    let asset = try package.importMedia(from: source, kind: .original, producedBy: nil)
    let relative = asset.relativePath
    #expect(!relative.hasPrefix("/"))
    #expect(!relative.contains(".."))

    package.manifest.projectName = "Renamed in memory"
    let copyURL = scratch.root.appendingPathComponent("nested/Copy.podlounge")
    try FileManager.default.createDirectory(at: copyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let copy = try package.saveAs(to: copyURL)
    #expect(copy.manifest.projectName == "Renamed in memory")
    #expect(copy.manifest.assets[0].relativePath == relative)
    #expect(try Data(contentsOf: copy.resolvedURL(for: copy.manifest.assets[0])) == Data("intro-bytes".utf8))

    let originalReopened = try ProjectPackage.open(at: originalURL)
    #expect(originalReopened.manifest.projectName == "Original")
    #expect(try Data(contentsOf: originalReopened.resolvedURL(for: originalReopened.manifest.assets[0])) == Data("intro-bytes".utf8))

    let moved = scratch.root.appendingPathComponent("Moved.podlounge")
    try FileManager.default.moveItem(at: copyURL, to: moved)
    let reopened = try ProjectPackage.open(at: moved)
    #expect(reopened.manifest.assets[0].relativePath == relative)
    #expect(try Data(contentsOf: reopened.resolvedURL(for: reopened.manifest.assets[0])) == Data("intro-bytes".utf8))
    let raw = try String(contentsOf: reopened.manifestURL, encoding: .utf8)
    #expect(!raw.contains(moved.path))
}

@Test func unknownSchemaAndMalformedManifestAreLeftUntouched() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let folder = scratch.root.appendingPathComponent("Show.podlounge")
    _ = try ProjectPackage.create(at: folder, name: "Show")

    let future = """
    {
      "formatVersion" : 99,
      "projectName" : "Future"
    }
    """
    let futureURL = folder.appendingPathComponent("manifest.json")
    try Data(future.utf8).write(to: futureURL)
    let futureBytes = try Data(contentsOf: futureURL)
    expect(PackageError.unsupportedFormatVersion(found: 99, supported: 1)) {
        _ = try ProjectPackage.open(at: folder)
    }
    #expect(try Data(contentsOf: futureURL) == futureBytes)

    let broken = Data("{\"formatVersion\":".utf8)
    try broken.write(to: futureURL)
    expect(PackageError.malformedManifest("manifest.json is not JSON with a formatVersion.")) {
        _ = try ProjectPackage.open(at: folder)
    }
    #expect(try Data(contentsOf: futureURL) == broken)

    let missingFields = Data("{\"formatVersion\":1}".utf8)
    try missingFields.write(to: futureURL)
    do {
        _ = try ProjectPackage.open(at: folder)
        Issue.record("Expected a malformed manifest")
    } catch is PackageError {
        #expect(try Data(contentsOf: futureURL) == missingFields)
    } catch {
        Issue.record("Unexpected error \(error)")
    }

    let escape = """
    {
      "assets" : [
        {
          "byteCount" : 4,
          "displayName" : "secret.txt",
          "id" : "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "importedAt" : "2026-01-01T00:00:00Z",
          "kind" : "original",
          "producedBy" : null,
          "relativePath" : "depot/originals/../../secret.txt"
        }
      ],
      "createdAt" : "2026-01-01T00:00:00Z",
      "formatVersion" : 1,
      "modifiedAt" : "2026-01-01T00:00:00Z",
      "projectName" : "Bad",
      "workspaceSettings" : {}
    }
    """
    try Data(escape.utf8).write(to: futureURL)
    let escapeBytes = try Data(contentsOf: futureURL)
    expect(PackageError.pathEscapesPackage("depot/originals/../../secret.txt")) {
        _ = try ProjectPackage.open(at: folder)
    }
    #expect(try Data(contentsOf: futureURL) == escapeBytes)
}

@Test func missingAndMismatchedAssetsStayListedWithoutRewritingAudio() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let source = try scratch.file("bed.wav", "bed-bytes")
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let asset = try package.importMedia(from: source, kind: .original, producedBy: nil)
    let depotURL = try package.resolvedURL(for: asset)
    try FileManager.default.removeItem(at: depotURL)

    let missing = try ProjectPackage.open(at: package.rootURL)
    #expect(missing.missingAssetIDs.contains(asset.id))
    #expect(missing.health(of: missing.manifest.assets[0]) == .missing)
    #expect(missing.manifest.assets.count == 1)
    missing.manifest.projectName = "Still missing"
    try missing.save()
    let originals = try FileManager.default.contentsOfDirectory(
        at: missing.rootURL.appendingPathComponent("depot/originals"),
        includingPropertiesForKeys: nil
    )
    #expect(originals.isEmpty)
    #expect(missing.manifest.assets.count == 1)
    let savedMissing = try ProjectPackage.open(at: missing.rootURL)
    #expect(savedMissing.manifest.projectName == "Still missing")
    #expect(savedMissing.missingAssetIDs.contains(asset.id))
    #expect(savedMissing.manifest.assets[0].relativePath == asset.relativePath)

    let again = try scratch.file("bed2.wav", "bed-bytes")
    let package2 = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Other.podlounge"), name: "Other")
    let asset2 = try package2.importMedia(from: again, kind: .original, producedBy: nil)
    let url2 = try package2.resolvedURL(for: asset2)
    let handle = try FileHandle(forWritingTo: url2)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("MORE".utf8))
    try handle.close()
    let mismatched = try ProjectPackage.open(at: package2.rootURL)
    #expect(mismatched.mismatchedAssetIDs.contains(asset2.id))
    let audioBefore = try Data(contentsOf: url2)
    try mismatched.save()
    #expect(try Data(contentsOf: url2) == audioBefore)
    #expect(mismatched.manifest.assets[0].byteCount == asset2.byteCount)
}

@Test func failedImportLeavesManifestAndDepotUntouched() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let before = try scratch.manifestData(package)
    let missing = scratch.root.appendingPathComponent("nope.wav")
    expect(PackageError.importFailed("Source is not a readable file.")) {
        _ = try package.importMedia(from: missing, kind: .original, producedBy: nil)
    }
    #expect(try scratch.manifestData(package) == before)
    #expect(package.manifest.assets.isEmpty)

    let originals = package.rootURL.appendingPathComponent("depot/originals")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: originals.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: originals.path)
    }
    let blocked = try scratch.file("blocked.wav", "nope")
    do {
        _ = try package.importMedia(from: blocked, kind: .original, producedBy: nil)
        Issue.record("Import should have failed")
    } catch is PackageError {
        #expect(try scratch.manifestData(package) == before)
        #expect(package.manifest.assets.isEmpty)
    } catch {
        Issue.record("Unexpected error \(error)")
    }
    let leftBehind = try FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil)
    #expect(leftBehind.isEmpty)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: originals.path)
    let source = try scratch.file("ok.wav", "ok-bytes")
    package.failNextSaveForTesting = true
    expect(PackageError.atomicWriteFailed("Simulated save failure.")) {
        _ = try package.importMedia(from: source, kind: .original, producedBy: nil)
    }
    #expect(try scratch.manifestData(package) == before)
    #expect(package.manifest.assets.isEmpty)
    let afterRollback = try FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil)
    #expect(afterRollback.isEmpty)
    #expect(try Data(contentsOf: source) == Data("ok-bytes".utf8))
}

@Test func symlinkOutsidePackageIsRejectedWithoutWriting() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let source = try scratch.file("inside.wav", "inside")
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let asset = try package.importMedia(from: source, kind: .original, producedBy: nil)
    let depotURL = try package.resolvedURL(for: asset)
    let outside = try scratch.file("secret.txt", "secret")
    try FileManager.default.removeItem(at: depotURL)
    try FileManager.default.createSymbolicLink(at: depotURL, withDestinationURL: outside)
    let before = try scratch.manifestData(package)
    expect(PackageError.pathEscapesPackage(asset.relativePath)) {
        _ = try ProjectPackage.open(at: package.rootURL)
    }
    #expect(try scratch.manifestData(package) == before)
    #expect(try Data(contentsOf: outside) == Data("secret".utf8))
}

@Test func pickedLocationsResolveInsideThePackageExtension() throws {
    let show = URL(fileURLWithPath: "/tmp/My Show")
    #expect(ProjectPackage.directoryURL(forPickedURL: show).lastPathComponent == "My Show.podlounge")
    let already = URL(fileURLWithPath: "/tmp/My Show.podlounge")
    #expect(ProjectPackage.directoryURL(forPickedURL: already).path == already.path)

    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let located = ProjectPackage.locateRoot(from: package.manifestURL)
    #expect(located?.resolvingSymlinksInPath().path == package.rootURL.resolvingSymlinksInPath().path)
}

@Test func removeAssetDeletesDepotCopyAndSurvivesReopen() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let original = try scratch.file("keep-me.wav", "AUDIO-A")
    let other = try scratch.file("other.wav", "AUDIO-B")
    let folder = scratch.root.appendingPathComponent("Delete.podlounge")
    let package = try ProjectPackage.create(at: folder, name: "Delete Test")
    let a = try package.importMedia(from: original, kind: .original, producedBy: nil, select: true)
    let b = try package.importMedia(from: other, kind: .original, producedBy: nil)
    let copyA = try package.resolvedURL(for: a)
    #expect(FileManager.default.fileExists(atPath: copyA.path))

    try package.removeAsset(id: a.id)
    #expect(package.manifest.assets.map(\.id) == [b.id])
    #expect(package.manifest.selectedAssetID == nil)
    #expect(!FileManager.default.fileExists(atPath: copyA.path))
    #expect(FileManager.default.fileExists(atPath: original.path))
    #expect(FileManager.default.fileExists(atPath: try package.resolvedURL(for: b).path))

    let reopened = try ProjectPackage.open(at: folder)
    #expect(reopened.manifest.assets.map(\.id) == [b.id])
}

@Test func limiterSettingsRoundTripAndOldProjectsOpen() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let folder = scratch.root.appendingPathComponent("Show.podlounge")
    let package = try ProjectPackage.create(at: folder, name: "Show")
    #expect(package.readLimiterSettings() == .defaults)
    let stub = try String(contentsOf: package.limiterSettingsURL, encoding: .utf8)
    #expect(stub == "{}\n")

    var settings = LimiterWorkspaceSettings.defaults
    settings.presetID = "spotify"
    settings.customLUFS = -14
    settings.customTruePeak = -1
    settings.musicThresholdDb = -6
    settings.meterMode = "RMS"
    settings.peakHold = false
    settings.listenPost = true
    settings.container = "aiff"
    settings.bitDepth = "16"
    settings.mp3BitrateKbps = 160
    settings.sampleRate = 96_000
    settings.resultName = "Episode – Leveled (SPOTIFY).aiff"
    settings.resultNameFollowsSource = false
    try package.writeLimiterSettings(settings)

    let reopened = try ProjectPackage.open(at: folder)
    #expect(reopened.readLimiterSettings() == settings)
    #expect(reopened.manifest.projectName == "Show")

    try Data("{}\n".utf8).write(to: reopened.limiterSettingsURL)
    let empty = try ProjectPackage.open(at: folder)
    #expect(empty.readLimiterSettings() == .defaults)

    try Data("{\"presetID\":\"apple\"}".utf8).write(to: empty.limiterSettingsURL)
    let partial = try ProjectPackage.open(at: folder)
    let partialSettings = partial.readLimiterSettings()
    #expect(partialSettings.presetID == "apple")
    #expect(partialSettings.bitDepth == "24")
    #expect(partialSettings.container == "wav")
    #expect(partialSettings.mp3BitrateKbps == 128)
    #expect(partialSettings.sampleRate == nil)

    try Data("not-json".utf8).write(to: partial.limiterSettingsURL)
    let broken = try ProjectPackage.open(at: folder)
    #expect(broken.readLimiterSettings() == .defaults)
    #expect(broken.manifest.projectName == "Show")
}

@Test func importResultAddsAssetAndLeavesOriginalUntouched() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let original = try scratch.file("episode.wav", "ORIGINAL-BYTES")
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let source = try package.importMedia(from: original, kind: .original, producedBy: nil, select: true)
    let originalURL = try package.resolvedURL(for: source)
    let originalBytes = try Data(contentsOf: originalURL)
    let rendered = try scratch.file("rendered.wav", "LEVELED-BYTES")
    let result = try package.importResult(
        from: rendered,
        producedBy: "limiter",
        displayName: "Episode – Leveled (UNIVERSAL).wav"
    )
    #expect(result.kind == .result)
    #expect(result.producedBy == "limiter")
    #expect(result.displayName == "Episode – Leveled (UNIVERSAL).wav")
    #expect(result.relativePath == "depot/results/Episode – Leveled (UNIVERSAL).wav")
    // A result stays in the list. The file already selected stays selected.
    #expect(package.manifest.selectedAssetID == source.id)
    #expect(package.manifest.assets.count == 2)
    #expect(try Data(contentsOf: package.resolvedURL(for: result)) == Data("LEVELED-BYTES".utf8))
    #expect(try Data(contentsOf: originalURL) == originalBytes)
    #expect(try Data(contentsOf: original) == Data("ORIGINAL-BYTES".utf8))

    let reopened = try ProjectPackage.open(at: package.rootURL)
    #expect(reopened.manifest.assets.map(\.id) == [source.id, result.id])
    #expect(reopened.manifest.selectedAssetID == source.id)
    #expect(try Data(contentsOf: reopened.resolvedURL(for: source)) == originalBytes)
}

@Test func importResultLeavesSelectionNilWhenNothingWasSelected() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Empty.podlounge"), name: "Empty")
    #expect(package.manifest.selectedAssetID == nil)
    let rendered = try scratch.file("rendered.wav", "LEVELED")
    let result = try package.importResult(from: rendered, producedBy: "limiter", displayName: "Leveled.wav")
    // Nothing was selected, so nothing becomes selected. The new file is still listed.
    #expect(package.manifest.selectedAssetID == nil)
    #expect(package.manifest.assets.map(\.id) == [result.id])
    let reopened = try ProjectPackage.open(at: package.rootURL)
    #expect(reopened.manifest.selectedAssetID == nil)
}

@Test func importResultSelectsOnlyWhenAsked() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let original = try scratch.file("episode.wav", "ORIGINAL")
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Pick.podlounge"), name: "Pick")
    let source = try package.importMedia(from: original, kind: .original, producedBy: nil, select: true)
    let rendered = try scratch.file("rendered.wav", "LEVELED")
    let result = try package.importResult(
        from: rendered,
        producedBy: "limiter",
        displayName: "Leveled.wav",
        select: true
    )
    #expect(package.manifest.selectedAssetID == result.id)
    #expect(package.manifest.assets.map(\.id) == [source.id, result.id])
}

@Test func removeAssetRollsBackWhenSaveFails() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let source = try scratch.file("a.wav", "AUDIO")
    let folder = scratch.root.appendingPathComponent("Rollback.podlounge")
    let package = try ProjectPackage.create(at: folder, name: "Rollback")
    let a = try package.importMedia(from: source, kind: .original, producedBy: nil, select: true)
    package.failNextSaveForTesting = true
    #expect(throws: (any Error).self) { try package.removeAsset(id: a.id) }
    #expect(package.manifest.assets.map(\.id) == [a.id])
    #expect(package.manifest.selectedAssetID == a.id)
    #expect(FileManager.default.fileExists(atPath: try package.resolvedURL(for: a).path))
}

@Test func newImportsUseReadableDepotFileNames() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let source = try scratch.file("Morning Show.wav", "SHOW-BYTES")
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let asset = try package.importMedia(from: source, kind: .original, producedBy: nil, select: true)
    #expect(asset.displayName == "Morning Show.wav")
    #expect(asset.relativePath == "depot/originals/Morning Show.wav")
    #expect(UUID(uuidString: asset.id) != nil)
    #expect(!asset.relativePath.contains(asset.id))
    #expect(try Data(contentsOf: package.resolvedURL(for: asset)) == Data("SHOW-BYTES".utf8))

    let rendered = try scratch.file("rendered.wav", "LEVELED")
    let result = try package.importResult(
        from: rendered,
        producedBy: "limiter",
        displayName: "Morning Show Leveled.wav"
    )
    #expect(result.displayName == "Morning Show Leveled.wav")
    #expect(result.relativePath == "depot/results/Morning Show Leveled.wav")
    #expect(UUID(uuidString: result.id) != nil)
    #expect(result.id != asset.id)
    #expect(package.manifest.selectedAssetID == asset.id)

    let reopened = try ProjectPackage.open(at: package.rootURL)
    #expect(reopened.manifest.assets.map(\.relativePath) == [
        "depot/originals/Morning Show.wav",
        "depot/results/Morning Show Leveled.wav",
    ])
    #expect(ProjectPackage.exportCopySuggestedName(
        displayName: result.displayName,
        relativePath: result.relativePath
    ) == "Morning Show Leveled.wav")
}

@Test func readableDepotNamesGainNumericSuffixOnCollision() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let folders = ["a", "b", "c"]
    var imported: [DepotAsset] = []
    for folder in folders {
        let source = try scratch.file("episode.wav", "take-\(folder)", in: scratch.root.appendingPathComponent(folder))
        imported.append(try package.importMedia(from: source, kind: .original, producedBy: nil))
    }
    #expect(imported.map(\.relativePath) == [
        "depot/originals/episode.wav",
        "depot/originals/episode 2.wav",
        "depot/originals/episode 3.wav",
    ])
    #expect(imported.map(\.displayName) == ["episode.wav", "episode.wav", "episode.wav"])
    #expect(Set(imported.map(\.id)).count == 3)
    #expect(try Data(contentsOf: package.resolvedURL(for: imported[0])) == Data("take-a".utf8))
    #expect(try Data(contentsOf: package.resolvedURL(for: imported[1])) == Data("take-b".utf8))
    #expect(try Data(contentsOf: package.resolvedURL(for: imported[2])) == Data("take-c".utf8))

    let upper = try scratch.file("Episode.wav", "UPPER", in: scratch.root.appendingPathComponent("upper"))
    let lower = try scratch.file("episode.wav", "LOWER", in: scratch.root.appendingPathComponent("lower"))
    let casePackage = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Case.podlounge"), name: "Case")
    let first = try casePackage.importMedia(from: upper, kind: .original, producedBy: nil)
    let second = try casePackage.importMedia(from: lower, kind: .original, producedBy: nil)
    #expect(first.relativePath == "depot/originals/Episode.wav")
    #expect(second.relativePath == "depot/originals/episode 2.wav")
    #expect(try Data(contentsOf: casePackage.resolvedURL(for: first)) == Data("UPPER".utf8))
    #expect(try Data(contentsOf: casePackage.resolvedURL(for: second)) == Data("LOWER".utf8))

    let sameName = try scratch.file("episode.wav", "RESULT", in: scratch.root.appendingPathComponent("result"))
    let result = try package.importResult(from: sameName, producedBy: "limiter", displayName: "episode.wav")
    #expect(result.relativePath == "depot/results/episode.wav")
}

@Test func depotFileNamesStripIllegalCharacters() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let rendered = try scratch.file("rendered.wav", "LEVELED")
    let quiz = try package.importResult(from: rendered, producedBy: "limiter", displayName: "Quiz: Show?.wav")
    #expect(quiz.displayName == "Quiz: Show?.wav")
    #expect(quiz.relativePath == "depot/results/Quiz Show.wav")
    #expect(ProjectPackage.exportCopySuggestedName(displayName: quiz.displayName, relativePath: quiz.relativePath) == "Quiz Show.wav")

    let slashy = try scratch.file("again.wav", "SLASH")
    let joined = try package.importResult(from: slashy, producedBy: "limiter", displayName: "A/B Test.wav")
    #expect(joined.displayName == "AB Test.wav")
    #expect(joined.relativePath == "depot/results/AB Test.wav")

    let marked = try scratch.file("third.wav", "MARKS")
    let cleaned = try package.importResult(
        from: marked,
        producedBy: "limiter",
        displayName: "No*pe\"<>|Name?.wav"
    )
    #expect(cleaned.displayName == "No*pe\"<>|Name?.wav")
    #expect(cleaned.relativePath == "depot/results/No pe Name.wav")

    let broken = try scratch.file("fourth.wav", "BREAK")
    let collapsed = try package.importResult(from: broken, producedBy: "limiter", displayName: "Bad\nName.wav")
    #expect(collapsed.displayName == "BadName.wav")
    #expect(collapsed.relativePath == "depot/results/BadName.wav")

    let reopened = try ProjectPackage.open(at: package.rootURL)
    #expect(reopened.manifest.assets.map(\.relativePath) == [
        "depot/results/Quiz Show.wav",
        "depot/results/AB Test.wav",
        "depot/results/No pe Name.wav",
        "depot/results/BadName.wav",
    ])
}

@Test func legacyUUIDNamedDepotFileStillLoads() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let folder = scratch.root.appendingPathComponent("Legacy.podlounge")
    let package = try ProjectPackage.create(at: folder, name: "Legacy")
    let id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let relative = "depot/originals/\(id).wav"
    let audio = folder.appendingPathComponent("depot/originals/\(id).wav")
    let bytes = Data("legacy-bytes".utf8)
    try bytes.write(to: audio)
    package.manifest.assets = [
        DepotAsset(
            id: id,
            displayName: "episode.wav",
            kind: .original,
            relativePath: relative,
            byteCount: Int64(bytes.count),
            importedAt: Date(timeIntervalSince1970: 0),
            producedBy: nil
        ),
    ]
    package.manifest.selectedAssetID = id
    try package.save()

    let opened = try ProjectPackage.open(at: folder)
    #expect(opened.manifest.assets.map(\.id) == [id])
    #expect(opened.manifest.assets[0].relativePath == relative)
    #expect(opened.manifest.selectedAssetID == id)
    #expect(opened.missingAssetIDs.isEmpty)
    #expect(opened.health(of: opened.manifest.assets[0]) == .present)
    #expect(try Data(contentsOf: opened.resolvedURL(for: opened.manifest.assets[0])) == bytes)
    #expect(ProjectPackage.exportCopySuggestedName(displayName: "episode.wav", relativePath: relative) == "episode.wav")

    try opened.save()
    let names = try FileManager.default.contentsOfDirectory(
        at: folder.appendingPathComponent("depot/originals"),
        includingPropertiesForKeys: nil
    )
    #expect(names.map(\.lastPathComponent).sorted() == ["\(id).wav"])

    let added = try scratch.file("notes.wav", "new-bytes")
    let imported = try opened.importMedia(from: added, kind: .original, producedBy: nil)
    #expect(imported.relativePath == "depot/originals/notes.wav")
    #expect(FileManager.default.fileExists(atPath: audio.path))
    #expect(try Data(contentsOf: audio) == bytes)
}

@Test func exportCopyWritesBytesWithoutChangingTheProject() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let source = try scratch.file("episode.wav", "COPY-BYTES")
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let asset = try package.importMedia(from: source, kind: .original, producedBy: nil, select: true)
    let depotURL = try package.resolvedURL(for: asset)
    let manifestBefore = try Data(contentsOf: package.manifestURL)
    let depotBefore = try Data(contentsOf: depotURL)
    let depotDate = try FileManager.default.attributesOfItem(atPath: depotURL.path)[.modificationDate] as? Date
    let destination = scratch.root.appendingPathComponent("exported/episode.wav")
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

    try package.exportCopy(of: asset, to: destination)

    #expect(try Data(contentsOf: destination) == depotBefore)
    #expect(try Data(contentsOf: depotURL) == depotBefore)
    #expect(try Data(contentsOf: package.manifestURL) == manifestBefore)
    #expect(package.manifest.assets.map(\.relativePath) == ["depot/originals/episode.wav"])
    #expect(package.manifest.selectedAssetID == asset.id)
    #expect(try FileManager.default.attributesOfItem(atPath: depotURL.path)[.modificationDate] as? Date == depotDate)
    #expect(try Data(contentsOf: source) == Data("COPY-BYTES".utf8))
}

@Test func nestedPodloungeLocationsAreRejected() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let showURL = scratch.root.appendingPathComponent("Show.podlounge")
    let show = try ProjectPackage.create(at: showURL, name: "Show")
    #expect(!ProjectPackage.isInsideAnotherProject(show.rootURL))
    show.manifest.projectName = "Show saved"
    try show.save()
    #expect(try ProjectPackage.open(at: showURL).manifest.projectName == "Show saved")

    let wrapper = scratch.root.appendingPathComponent("Tape.podlounge")
    try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
    let inner = wrapper.appendingPathComponent("Inner.podlounge")
    expect(PackageError.operationFailed(ProjectPackage.nestedProjectMessage)) {
        _ = try ProjectPackage.create(at: inner, name: "Inner")
    }
    #expect(!FileManager.default.fileExists(atPath: inner.path))

    let deep = wrapper.appendingPathComponent("depot/results/Deep.podlounge")
    expect(PackageError.operationFailed(ProjectPackage.nestedProjectMessage)) {
        _ = try ProjectPackage.create(at: deep, name: "Deep")
    }
    #expect(!FileManager.default.fileExists(atPath: deep.path))

    let upper = scratch.root.appendingPathComponent("TAPE.PODLOUNGE")
    try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: true)
    expect(PackageError.operationFailed(ProjectPackage.nestedProjectMessage)) {
        _ = try ProjectPackage.create(at: upper.appendingPathComponent("Child.podlounge"), name: "Child")
    }

    expect(PackageError.operationFailed(ProjectPackage.nestedProjectMessage)) {
        _ = try show.saveAs(to: wrapper.appendingPathComponent("Copy.podlounge"))
    }
    #expect(!FileManager.default.fileExists(atPath: wrapper.appendingPathComponent("Copy.podlounge").path))
    #expect(try ProjectPackage.open(at: showURL).manifest.projectName == "Show saved")

    let parked = wrapper.appendingPathComponent("Parked.podlounge")
    try FileManager.default.copyItem(at: showURL, to: parked)
    let opened = try ProjectPackage.open(at: parked)
    let manifestBefore = try Data(contentsOf: opened.manifestURL)
    let settingsBefore = try Data(contentsOf: opened.limiterSettingsURL)
    expect(PackageError.operationFailed(ProjectPackage.nestedProjectMessage)) {
        try opened.save()
    }
    expect(PackageError.operationFailed(ProjectPackage.nestedProjectMessage)) {
        try opened.writeLimiterSettings(.defaults)
    }
    #expect(try Data(contentsOf: opened.manifestURL) == manifestBefore)
    #expect(try Data(contentsOf: opened.limiterSettingsURL) == settingsBefore)
    #expect(opened.manifest.projectName == "Show saved")
}

@Test func recoveredTakeRenamesIntoDepotWithoutSelectingOrOverwriting() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let package = try ProjectPackage.create(
        at: scratch.root.appendingPathComponent("Show.podlounge"),
        name: "Show"
    )
    let original = try scratch.file("episode.wav", "original-bytes")
    let originalBytes = try Data(contentsOf: original)
    let kept = try package.importMedia(from: original, kind: .original, producedBy: nil, select: true)
    #expect(package.manifest.selectedAssetID == kept.id)

    let recovery = package.producerRecoveryURL
    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
    let take = recovery.appendingPathComponent("Speaker_1.wav")
    try Data("take-one".utf8).write(to: take)
    let adopted = try package.adoptRecoveredResult(from: take, displayName: "Speaker_1", producedBy: "fixer")
    #expect(package.manifest.selectedAssetID == kept.id)
    #expect(!FileManager.default.fileExists(atPath: take.path))
    let adoptedURL = try package.resolvedURL(for: adopted)
    #expect(adoptedURL.path.contains("/depot/results/"))
    #expect(try Data(contentsOf: adoptedURL) == Data("take-one".utf8))
    #expect(try Data(contentsOf: original) == originalBytes)
    #expect(adopted.producedBy == "fixer")
    #expect(adopted.kind == .result)

    let second = recovery.appendingPathComponent("Speaker_1.wav")
    try Data("take-two".utf8).write(to: second)
    let again = try package.adoptRecoveredResult(from: second, displayName: "Speaker_1", producedBy: "fixer")
    #expect(again.id != adopted.id)
    #expect(again.relativePath != adopted.relativePath)
    #expect(try Data(contentsOf: adoptedURL) == Data("take-one".utf8))
    #expect(package.manifest.selectedAssetID == kept.id)

    let session = Data("{\"formatVersion\":1,\"mixJSON\":\"\",\"tracks\":[]}\n".utf8)
    try package.writeProducerSession(session)
    #expect(package.readProducerSession() == session)
    let originalInDepot = try package.resolvedURL(for: kept)
    #expect(try Data(contentsOf: originalInDepot) == originalBytes)
}
