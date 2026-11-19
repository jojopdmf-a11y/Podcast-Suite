import Foundation
import Testing
@testable import PodLoungeCore

@Test func exportSheetDefaultsPerChoiceAndKeepsATypedName() {
    var draft = TrimmerExportNaming.opened(episode: "Show")
    #expect(draft.scope == .fullMix)
    #expect(draft.customized == false)
    #expect(draft.field == "Show \u{2013} Cut.wav")
    #expect(draft.choices.container == .wav)
    #expect(draft.choices.bitDepth == .int24)

    draft = TrimmerExportNaming.choosing(.episodeMix, in: draft, episode: "Show")
    #expect(draft.field == "Show \u{2013} Episode Mix Cut.wav")
    draft = TrimmerExportNaming.choosing(.introsOutrosAds, in: draft, episode: "Show")
    #expect(draft.field == "Show \u{2013} Intros · Outros · Ads Cut.wav")
    draft = TrimmerExportNaming.choosing(.musicBeds, in: draft, episode: "Show")
    #expect(draft.field == "Show \u{2013} Music Beds Cut.wav")
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
    #expect(stillFollowing.field == "Show \u{2013} Episode Mix Cut.wav")
}

@Test func emptyExportNameFallsBackToTheChoiceDefault() {
    #expect(
        TrimmerExportNaming.resolvedDisplayName(field: "", episode: "Show", scope: .fullMix)
            == "Show \u{2013} Cut.wav"
    )
    #expect(
        TrimmerExportNaming.resolvedDisplayName(field: "   ", episode: "Show", scope: .episodeMix)
            == "Show \u{2013} Episode Mix Cut.wav"
    )
    #expect(
        TrimmerExportNaming.resolvedDisplayName(field: " \n\t ", episode: "Show", scope: .introsOutrosAds)
            == "Show \u{2013} Intros · Outros · Ads Cut.wav"
    )
    #expect(
        TrimmerExportNaming.resolvedDisplayName(field: "", episode: "  ", scope: .musicBeds)
            == "Episode \u{2013} Music Beds Cut.wav"
    )

    var draft = TrimmerExportNaming.opened(episode: "Show")
    draft = TrimmerExportNaming.editing("Mine", in: draft, episode: "Show")
    draft = TrimmerExportNaming.editing("   ", in: draft, episode: "Show")
    #expect(draft.customized == false)
    draft = TrimmerExportNaming.choosing(.musicBeds, in: draft, episode: "Show")
    #expect(draft.field == "Show \u{2013} Music Beds Cut.wav")
    #expect(
        TrimmerExportNaming.resolvedDisplayName(field: draft.field, episode: "Show", scope: draft.scope)
            == "Show \u{2013} Music Beds Cut.wav"
    )
}

@Test func changingTheFileTypeKeepsATypedNameAndSwapsOnlyTheExtension() {
    var draft = TrimmerExportNaming.opened(episode: "Show")
    draft = TrimmerExportNaming.editing("  My Mix  ", in: draft, episode: "Show")
    draft = TrimmerExportNaming.choosingContainer(.mp3, in: draft, episode: "Show")
    #expect(draft.customized)
    #expect(draft.field == "  My Mix.mp3  ")
    #expect(draft.choices.container == .mp3)
    draft = TrimmerExportNaming.choosing(.episodeMix, in: draft, episode: "Show")
    #expect(draft.field == "  My Mix.mp3  ")
    draft = TrimmerExportNaming.choosingContainer(.aiff, in: draft, episode: "Show")
    #expect(draft.field == "  My Mix.aiff  ")

    var fresh = TrimmerExportNaming.opened(episode: "Show")
    fresh = TrimmerExportNaming.choosingContainer(.m4a, in: fresh, episode: "Show")
    #expect(fresh.customized == false)
    #expect(fresh.field == "Show \u{2013} Cut.m4a")
    fresh = TrimmerExportNaming.choosingBitrate(128, in: fresh)
    #expect(fresh.choices.mp3BitrateKbps == 128)
    #expect(fresh.choices.bitrateFollowsWidth == false)
    fresh = TrimmerExportNaming.choosing(.episodeMix, in: fresh, episode: "Show", mono: true)
    #expect(fresh.choices.mp3BitrateKbps == 128)
    #expect(fresh.field == "Show \u{2013} Episode Mix Cut.m4a")

    let monoDefault = TrimmerExportNaming.opened(episode: "Show", mono: true)
    #expect(monoDefault.choices.mp3BitrateKbps == 128)
    let stereoDefault = TrimmerExportNaming.opened(episode: "Show")
    #expect(stereoDefault.choices.mp3BitrateKbps == 192)
    #expect(TrimmerExportPlan.deliveryRate(renderRate: 44_100, container: .mp3) == 44_100)
    #expect(TrimmerExportPlan.deliveryRate(renderRate: 96_000, container: .m4a) == 48_000)
    #expect(TrimmerExportPlan.deliveryRate(renderRate: 96_000, container: .wav) == 96_000)
    let steered = TrimmerExportPlan.writtenDepth(chosen: .int24, container: .wav, peak: 1.2)
    #expect(steered.depth == .float32)
    #expect(steered.steeredToFloat)
    let quiet = TrimmerExportPlan.writtenDepth(chosen: .int16, container: .aiff, peak: 0.5)
    #expect(quiet.depth == .int16)
    #expect(quiet.steeredToFloat == false)
    let lossy = TrimmerExportPlan.writtenDepth(chosen: .int24, container: .mp3, peak: 1.4)
    #expect(lossy.depth == .int24)
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
