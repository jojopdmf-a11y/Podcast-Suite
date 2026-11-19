import Foundation
import Testing
@testable import PodLoungeCore

@Test func exportSheetDefaultsPerChoiceAndKeepsATypedName() {
    var draft = TrimmerExportNaming.opened(episode: "Show")
    #expect(draft.scope == .fullMix)
    #expect(draft.customized == false)
    #expect(draft.field == "Show \u{2013} Cut")

    draft = TrimmerExportNaming.choosing(.episodeMix, in: draft, episode: "Show")
    #expect(draft.field == "Show \u{2013} Episode Mix Cut")
    draft = TrimmerExportNaming.choosing(.introsOutrosAds, in: draft, episode: "Show")
    #expect(draft.field == "Show \u{2013} Intros · Outros · Ads Cut")
    draft = TrimmerExportNaming.choosing(.musicBeds, in: draft, episode: "Show")
    #expect(draft.field == "Show \u{2013} Music Beds Cut")
    #expect(draft.customized == false)

    draft = TrimmerExportNaming.editing("  My Mix  ", in: draft, episode: "Show")
    #expect(draft.customized)
    draft = TrimmerExportNaming.choosing(.fullMix, in: draft, episode: "Show")
    #expect(draft.scope == .fullMix)
    #expect(draft.field == "  My Mix  ")
    #expect(
        TrimmerExportNaming.resolvedDisplayName(field: draft.field, episode: "Show", scope: draft.scope)
            == "My Mix"
    )

    let opened = TrimmerExportNaming.opened(episode: "Show")
    let typedDefault = TrimmerExportNaming.editing(opened.field, in: opened, episode: "Show")
    #expect(typedDefault.customized == false)
    let stillFollowing = TrimmerExportNaming.choosing(.episodeMix, in: typedDefault, episode: "Show")
    #expect(stillFollowing.field == "Show \u{2013} Episode Mix Cut")
}

@Test func emptyExportNameFallsBackToTheChoiceDefault() {
    #expect(
        TrimmerExportNaming.resolvedDisplayName(field: "", episode: "Show", scope: .fullMix)
            == "Show \u{2013} Cut"
    )
    #expect(
        TrimmerExportNaming.resolvedDisplayName(field: "   ", episode: "Show", scope: .episodeMix)
            == "Show \u{2013} Episode Mix Cut"
    )
    #expect(
        TrimmerExportNaming.resolvedDisplayName(field: " \n\t ", episode: "Show", scope: .introsOutrosAds)
            == "Show \u{2013} Intros · Outros · Ads Cut"
    )
    #expect(
        TrimmerExportNaming.resolvedDisplayName(field: "", episode: "  ", scope: .musicBeds)
            == "Episode \u{2013} Music Beds Cut"
    )

    var draft = TrimmerExportNaming.opened(episode: "Show")
    draft = TrimmerExportNaming.editing("Mine", in: draft, episode: "Show")
    draft = TrimmerExportNaming.editing("   ", in: draft, episode: "Show")
    #expect(draft.customized == false)
    draft = TrimmerExportNaming.choosing(.musicBeds, in: draft, episode: "Show")
    #expect(draft.field == "Show \u{2013} Music Beds Cut")
    #expect(
        TrimmerExportNaming.resolvedDisplayName(field: draft.field, episode: "Show", scope: draft.scope)
            == "Show \u{2013} Music Beds Cut"
    )
}

@Test func exportNameKeepsTheListNameAndNumbersTheFileAndSidecar() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let wav = scratch.root.appendingPathComponent("tone.wav")
    try TrimmerWAV.write(stereo: [0.1, 0.1, 0.1, 0.1], sampleRate: 48_000, depth: .int24, to: wav)
    let folder = scratch.root.appendingPathComponent("Show.podlounge")
    let package = try ProjectPackage.create(at: folder, name: "Show")

    let typed = "Quiz: Show?"
    let display = TrimmerExportNaming.resolvedDisplayName(
        field: "  \(typed)  ",
        episode: "Show",
        scope: .fullMix
    )
    #expect(display == typed)

    let first = try package.importResult(from: wav, producedBy: "trimmer", displayName: display)
    let second = try package.importResult(from: wav, producedBy: "trimmer", displayName: display)
    #expect(first.displayName == "Quiz: Show?")
    #expect(second.displayName == "Quiz: Show?")
    #expect(depotFileName(first) == "Quiz Show.wav")
    #expect(depotFileName(second) == "Quiz Show 2.wav")
    #expect(ProjectPackage.isSafeDepotFileName(depotFileName(first)))
    #expect(ProjectPackage.isSafeDepotFileName(depotFileName(second)))

    let firstAudio = try package.resolvedURL(for: first)
    let secondAudio = try package.resolvedURL(for: second)
    let firstSidecar = PodcastChapters.sidecarURL(forAudio: firstAudio)
    let secondSidecar = PodcastChapters.sidecarURL(forAudio: secondAudio)
    #expect(firstSidecar.lastPathComponent == "Quiz Show chapters.txt")
    #expect(secondSidecar.lastPathComponent == "Quiz Show 2 chapters.txt")
    #expect(secondSidecar.deletingLastPathComponent() == secondAudio.deletingLastPathComponent())
    try Data("00:01:05 Interview\n".utf8).write(to: secondSidecar, options: .atomic)
    let readBack = try String(contentsOf: secondSidecar, encoding: .utf8)
    #expect(readBack == "00:01:05 Interview\n")
    #expect(FileManager.default.fileExists(atPath: firstSidecar.path) == false)

    let slashed = TrimmerExportNaming.resolvedDisplayName(field: "A/B Night", episode: "Show", scope: .episodeMix)
    let slashedAsset = try package.importResult(from: wav, producedBy: "trimmer", displayName: slashed)
    #expect(slashedAsset.displayName == "AB Night")
    #expect(depotFileName(slashedAsset) == "AB Night.wav")

    let marked = "No*pe\"<>|Name?"
    let markedAsset = try package.importResult(from: wav, producedBy: "trimmer", displayName: marked)
    #expect(markedAsset.displayName == marked)
    let markedFile = depotFileName(markedAsset)
    #expect(markedFile == "No pe Name.wav")
    #expect(ProjectPackage.isSafeDepotFileName(markedFile))
    for scalar in markedFile.unicodeScalars {
        #expect(ProjectPackage.isIllegalStorageScalar(scalar) == false)
    }
    let markedAudio = try package.resolvedURL(for: markedAsset)
    let markedSidecar = PodcastChapters.sidecarURL(forAudio: markedAudio)
    #expect(markedSidecar.lastPathComponent == "No pe Name chapters.txt")

    let broken = TrimmerExportNaming.resolvedDisplayName(field: "Bad\nName", episode: "Show", scope: .fullMix)
    let collapsed = try package.importResult(from: wav, producedBy: "trimmer", displayName: broken)
    #expect(collapsed.displayName == "BadName")
    #expect(depotFileName(collapsed) == "BadName.wav")
    #expect(
        PodcastChapters.sidecarURL(forAudio: try package.resolvedURL(for: collapsed)).lastPathComponent
            == "BadName chapters.txt"
    )
}

private func depotFileName(_ asset: DepotAsset) -> String {
    URL(fileURLWithPath: asset.relativePath).lastPathComponent
}
