import Foundation
import Testing
@testable import PodLoungeCore

@Test func stripperPrefillsUseSourceNameAndRepeatSuffix() {
    let first = StripperNaming.prefill(sourceDisplayName: "Episode.wav", roleLabel: "Speaker 1", splitIndex: 1)
    let music = StripperNaming.prefill(sourceDisplayName: "Episode.wav", roleLabel: StripperNaming.musicRole, splitIndex: 1)
    let again = StripperNaming.prefill(sourceDisplayName: "Episode.wav", roleLabel: "Speaker 2", splitIndex: 2)
    #expect(first == "Episode – Speaker 1")
    #expect(music == "Episode – Music & SFX")
    #expect(again == "Episode (Split 2) – Speaker 2")
}

@Test func stripperSplitIndexFollowsEarlierGroupsForThatSource() {
    let first = StripperGroupRecord(
        id: "a",
        sourceAssetID: "source",
        splitIndex: 1,
        speakersJSONRelativePath: "workspaces/stripper/runs/a/speakers.json",
        trackAssetIDs: ["t"],
        createdAt: Date()
    )
    let other = StripperGroupRecord(
        id: "b",
        sourceAssetID: "other",
        splitIndex: 4,
        speakersJSONRelativePath: "workspaces/stripper/runs/b/speakers.json",
        trackAssetIDs: ["u"],
        createdAt: Date()
    )
    #expect(StripperNaming.nextSplitIndex(sourceAssetID: "source", groups: []) == 1)
    #expect(StripperNaming.nextSplitIndex(sourceAssetID: "source", groups: [first, other]) == 2)
    #expect(StripperNaming.nextSplitIndex(sourceAssetID: "fresh", groups: [first]) == 1)
}

@Test func stripperNamesAreCheckedGently() {
    #expect(StripperNaming.validate(names: ["A", ""], existingDisplayNames: []) != nil)
    #expect(StripperNaming.validate(names: ["Same", "same"], existingDisplayNames: []) != nil)
    #expect(StripperNaming.validate(names: ["Episode – Speaker 1"], existingDisplayNames: ["episode – speaker 1"]) != nil)
    #expect(StripperNaming.validate(names: ["Episode – Speaker 1", "Episode – Music & SFX"], existingDisplayNames: ["Episode.wav"]) == nil)
}

@Test func stripperRoleLabelsComeFromEngineFileNames() {
    #expect(StripperNaming.roleLabel(engineFileName: "Speaker_1.wav") == "Speaker 1")
    #expect(StripperNaming.roleLabel(engineFileName: "Speaker_2.aiff") == "Speaker 2")
    #expect(StripperNaming.roleLabel(engineFileName: "Music_and_SFX.wav") == "Music & SFX")
}

@Test func stripperGroupImportKeepsSelectionAndStoresRelativeNotes() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let original = try scratch.file("Episode.wav", "original-bytes")
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    package.manifest.workspaceSettings["stripper"] = WorkspaceSettings(notes: "keep the cold open")
    let source = try package.importMedia(from: original, kind: .original, producedBy: nil, select: true)
    let selected = package.manifest.selectedAssetID

    let staging = try package.makeStripperStagingDirectory()
    let speaker = try scratch.file("Speaker_1.wav", "speaker-one", in: staging)
    let music = try scratch.file("Music_and_SFX.wav", "music-bed", in: staging)
    let depotSource = try package.resolvedURL(for: source)
    let absolute = """
    {"source":"\(depotSource.path)","speakers":[{"label":"Speaker 1","path":"\(speaker.path)"}],"music":{"path":"\(music.path)"}}
    """
    let json = staging.appendingPathComponent("speakers.json")
    try Data(absolute.utf8).write(to: json)

    let outcome = try package.importStripperGroup(
        tracks: [
            StripperTrackImport(sourceURL: speaker, displayName: "Episode – Speaker 1"),
            StripperTrackImport(sourceURL: music, displayName: "Episode – Music & SFX"),
        ],
        speakersJSON: json,
        sourceAssetID: source.id,
        splitIndex: 1
    )

    #expect(package.manifest.selectedAssetID == selected)
    #expect(outcome.assets.count == 2)
    #expect(outcome.assets.allSatisfy { $0.kind == .result && $0.producedBy == "stripper" })
    #expect(package.manifest.assets.contains { $0.relativePath.hasSuffix("speakers.json") } == false)
    #expect(package.manifest.workspaceSettings["stripper"]?.notes == "keep the cold open")

    let storedData = try Data(contentsOf: package.rootURL.appendingPathComponent(outcome.group.speakersJSONRelativePath))
    let storedObject = try JSONSerialization.jsonObject(with: storedData) as? [String: Any]
    let storedSpeaker = ((storedObject?["speakers"] as? [[String: Any]])?.first)?["path"] as? String
    let storedSource = storedObject?["source"] as? String
    #expect(storedSpeaker?.hasPrefix("depot/results/") == true)
    #expect(storedSource == source.relativePath)
    let storedText = String(decoding: storedData, as: UTF8.self)
    #expect(storedText.contains(speaker.path) == false)
    #expect(storedText.contains(depotSource.path) == false)
    #expect(outcome.group.speakersJSONRelativePath.hasPrefix("workspaces/stripper/runs/"))

    let reopened = try ProjectPackage.open(at: package.rootURL)
    #expect(reopened.readStripperGroups().map(\.id) == [outcome.group.id])
    #expect(reopened.manifest.workspaceSettings["stripper"]?.notes == "keep the cold open")
    #expect(reopened.manifest.selectedAssetID == selected)
    let moved = scratch.root.appendingPathComponent("Moved.podlounge")
    try FileManager.default.copyItem(at: package.rootURL, to: moved)
    let relocated = try ProjectPackage.open(at: moved)
    let note = relocated.rootURL.appendingPathComponent(outcome.group.speakersJSONRelativePath)
    #expect(FileManager.default.fileExists(atPath: note.path))
    #expect(try String(contentsOf: note, encoding: .utf8).contains(speaker.path) == false)
}

@Test func stripperRepeatSplitUsesTheNextIndex() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let original = try scratch.file("Episode.wav", "original-bytes")
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let source = try package.importMedia(from: original, kind: .original, producedBy: nil, select: true)
    let first = try importPair(package, sourceID: source.id, splitIndex: 1, stem: "Episode")
    let second = try importPair(package, sourceID: source.id, splitIndex: 2, stem: "Episode (Split 2)")
    let indexes = package.readStripperGroups().map(\.splitIndex).sorted()
    #expect(indexes == [1, 2])
    #expect(first.assets.map(\.displayName).contains("Episode – Speaker 1"))
    #expect(second.assets.map(\.displayName).contains("Episode (Split 2) – Speaker 1"))
    #expect(package.manifest.selectedAssetID == source.id)
}

@Test func stripperImportRollsBackWhenTheSaveFails() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let original = try scratch.file("Episode.wav", "original-bytes")
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let source = try package.importMedia(from: original, kind: .original, producedBy: nil, select: true)
    let before = package.manifest.assets.map(\.id)
    let staging = try stagedPair(package, scratch: scratch)
    package.failNextSaveForTesting = true
    expect(PackageError.atomicWriteFailed("Simulated save failure.")) {
        _ = try package.importStripperGroup(
            tracks: staging.tracks,
            speakersJSON: staging.json,
            sourceAssetID: source.id,
            splitIndex: 1
        )
    }
    #expect(package.manifest.assets.map(\.id) == before)
    #expect(package.readStripperGroups().isEmpty)
    #expect(try results(package).isEmpty)
    #expect(FileManager.default.fileExists(atPath: staging.speaker.path))
}

@Test func stripperImportRollsBackWhenTheDiskFillsAfterCopying() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let original = try scratch.file("Episode.wav", "original-bytes")
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let source = try package.importMedia(from: original, kind: .original, producedBy: nil, select: true)
    let before = package.manifest.assets.count
    let staging = try stagedPair(package, scratch: scratch)
    package.failStripperImportAfterStagingForTesting = true
    expect(PackageError.importFailed("There is not enough free space to add these tracks.")) {
        _ = try package.importStripperGroup(
            tracks: staging.tracks,
            speakersJSON: staging.json,
            sourceAssetID: source.id,
            splitIndex: 1
        )
    }
    #expect(package.manifest.assets.count == before)
    #expect(package.readStripperGroups().isEmpty)
    #expect(try results(package).isEmpty)
    let partials = try FileManager.default.contentsOfDirectory(atPath: package.rootURL.appendingPathComponent("depot/results").path)
    #expect(partials.filter { $0.hasSuffix(".partial") }.isEmpty)
}

@Test func stripperOutsideCopyDoesNotOverwriteAndIsNotRequired() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let original = try scratch.file("Episode.wav", "original-bytes")
    let package = try ProjectPackage.create(at: scratch.root.appendingPathComponent("Show.podlounge"), name: "Show")
    let source = try package.importMedia(from: original, kind: .original, producedBy: nil, select: true)
    let outside = scratch.root.appendingPathComponent("extra", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let existing = outside.appendingPathComponent("Episode – Speaker 1.wav")
    try Data("leave-me".utf8).write(to: existing)
    let staging = try stagedPair(package, scratch: scratch)
    let outcome = try package.importStripperGroup(
        tracks: staging.tracks,
        speakersJSON: staging.json,
        sourceAssetID: source.id,
        splitIndex: 1,
        outsideDirectory: outside
    )
    #expect(outcome.outsideCopyWarning == nil)
    #expect(try String(contentsOf: existing, encoding: .utf8) == "leave-me")
    let copies = try FileManager.default.contentsOfDirectory(atPath: outside.path)
    #expect(copies.contains("Episode – Music & SFX.wav"))
    #expect(copies.contains { $0.contains("Episode – Speaker 1") && $0 != "Episode – Speaker 1.wav" })
    #expect(try String(contentsOf: original, encoding: .utf8) == "original-bytes")
}

private struct StagedPair {
    var tracks: [StripperTrackImport]
    var json: URL
    var speaker: URL
}

private func stagedPair(_ package: ProjectPackage, scratch: Scratch) throws -> StagedPair {
    let staging = try package.makeStripperStagingDirectory()
    let speaker = try scratch.file("Speaker_1.wav", "speaker-one", in: staging)
    let music = try scratch.file("Music_and_SFX.wav", "music-bed", in: staging)
    let json = staging.appendingPathComponent("speakers.json")
    let payload = """
    {"source":"\(speaker.deletingLastPathComponent().path)","speakers":[{"path":"\(speaker.path)"}],"music":{"path":"\(music.path)"}}
    """
    try Data(payload.utf8).write(to: json)
    return StagedPair(
        tracks: [
            StripperTrackImport(sourceURL: speaker, displayName: "Episode – Speaker 1"),
            StripperTrackImport(sourceURL: music, displayName: "Episode – Music & SFX"),
        ],
        json: json,
        speaker: speaker
    )
}

private func importPair(_ package: ProjectPackage, sourceID: String, splitIndex: Int, stem: String) throws -> StripperGroupImportResult {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let staging = try package.makeStripperStagingDirectory()
    let speaker = try scratch.file("Speaker_1.wav", "speaker-\(splitIndex)", in: staging)
    let music = try scratch.file("Music_and_SFX.wav", "music-\(splitIndex)", in: staging)
    let json = staging.appendingPathComponent("speakers.json")
    try Data("{\"speakers\":[{\"path\":\"\(speaker.path)\"}]}".utf8).write(to: json)
    return try package.importStripperGroup(
        tracks: [
            StripperTrackImport(sourceURL: speaker, displayName: "\(stem) – Speaker 1"),
            StripperTrackImport(sourceURL: music, displayName: "\(stem) – Music & SFX"),
        ],
        speakersJSON: json,
        sourceAssetID: sourceID,
        splitIndex: splitIndex
    )
}

private func expect<T: Error & Equatable>(_ expected: T, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("Expected \(expected) to be thrown")
    } catch let error as T {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error \(error)")
    }
}

private func results(_ package: ProjectPackage) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: package.rootURL.appendingPathComponent("depot/results").path)
        .filter { $0.hasPrefix(".") == false }
}
