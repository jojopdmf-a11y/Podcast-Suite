import Foundation
import Testing
@testable import PodProducerKit

@Test @MainActor func leaveWhileRecordingDoesNotStop() {
    let model = ProducerLoungeModel()
    model.setRecordingForTest(true)
    #expect(model.isRecording)
    #expect(model.requestLeave() == false)
    #expect(model.stopRecordCalls == 0)
    #expect(model.isRecording)
    model.setRecordingForTest(false)
    #expect(model.requestLeave())
    #expect(model.stopRecordCalls == 0)
}

@Test @MainActor func protectedTakeIgnoresImport() {
    let session = MixerSession()
    session.protectTakeUntilStop = true
    session.isRecording = true
    session.importAudioFiles([URL(fileURLWithPath: "/tmp/podproducer-not-a-real-file.wav")], append: false)
    #expect(session.isRecording)
    #expect(session.voices.isEmpty)
}

@Test @MainActor func sessionRoundTripKeepsDepotAssetIDs() throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("producer-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let mono = scratch.appendingPathComponent("host.wav")
    let stereo = scratch.appendingPathComponent("bed.wav")
    try WAVIO.write(
        url: mono,
        buffer: WAVIO.Buffer(sampleRate: 48_000, channelCount: 1, samples: Array(repeating: 0.1, count: 4_800))
    )
    try WAVIO.write(
        url: stereo,
        buffer: WAVIO.Buffer(sampleRate: 48_000, channelCount: 2, samples: Array(repeating: 0.05, count: 9_600))
    )

    let model = ProducerLoungeModel()
    model.importDepotFiles([
        ProducerDepotFile(url: mono, assetID: "spk-1", displayName: "Host"),
        ProducerDepotFile(url: stereo, assetID: "bed-1", displayName: "Bed"),
    ], append: false)

    let document = model.captureDocument()
    #expect(document.tracks.contains { $0.assetID == "spk-1" && $0.role == "speaker" })
    #expect(document.tracks.contains { $0.assetID == "bed-1" && $0.role == "stereo" })
    #expect(document.mixJSON.contains("\"") )
    #expect(!document.mixJSON.contains(mono.path))
    #expect(!document.mixJSON.contains(stereo.path))

    let decoded = try #require(ProducerSessionDocument.decode(try document.encoded()))
    #expect(decoded.tracks.map(\.assetID) == document.tracks.map(\.assetID))

    let restored = ProducerLoungeModel()
    restored.restore(document: decoded) { id in
        switch id {
        case "spk-1": return mono
        case "bed-1": return stereo
        default: return nil
        }
    }
    let again = restored.captureDocument()
    #expect(again.tracks.map(\.assetID) == ["spk-1", "bed-1"])
    #expect(again.tracks.map(\.role) == ["speaker", "stereo"])
}

@Test @MainActor func standaloneMixFileRoundTrip() throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("producer-mix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let session = MixerSession()
    session.newRecordSession()
    session.addBlankStrip()
    session.masterDb = -4.5
    session.voices[0].faderDb = -7
    session.voices[0].name = "Host"

    let url = scratch.appendingPathComponent(MixerMixFile.fileName)
    try MixerMixFile.write(MixerMixFile.make(from: session), to: url)
    let read = try MixerMixFile.read(from: url)
    #expect(read.masterDb == -4.5)
    #expect(read.voices.first?.name == "Host")
    #expect(read.voices.first?.faderDb == -7)
    #expect(read.formatVersion == MixerMixFile.formatVersion)

    let other = MixerSession()
    other.newRecordSession()
    other.addBlankStrip()
    MixerMixFile.apply(read, to: other)
    #expect(other.masterDb == -4.5)
    #expect(other.voices[0].name == "Host")
    #expect(other.voices[0].faderDb == -7)

    let rewritten = scratch.appendingPathComponent("again.json")
    try MixerMixFile.write(MixerMixFile.make(from: other), to: rewritten)
    let again = try MixerMixFile.read(from: rewritten)
    #expect(again.masterDb == read.masterDb)
    #expect(again.voices.first?.faderDb == read.voices.first?.faderDb)
}

@Test @MainActor func newTrackOnEmptyLoungeMixerAddsOneEmptySpeaker() {
    let model = ProducerLoungeModel()
    model.restore(data: Data("{}".utf8)) { _ in nil }
    #expect(model.hasSession == false)

    model.session.newTrack()

    #expect(model.hasSession)
    #expect(model.session.voices.count == 1)
    #expect(model.session.voices[0].fileURL == nil)
    #expect(model.session.voices[0].depotAssetID == nil)
    #expect(model.session.engine.voiceHasAudio(at: 0) == false)
    let document = model.captureDocument()
    #expect(document.tracks.count == 1)
    #expect(document.tracks[0].role == "speaker")
    #expect(document.tracks[0].assetID == nil)

    let kept = model.session.voices[0].name
    model.session.newTrack()
    #expect(model.session.voices.count == 2)
    #expect(model.session.voices[0].name == kept)
}

@Test @MainActor func newTrackDoesNothingWhileRecording() {
    let session = MixerSession()
    session.newTrack()
    session.isRecording = true
    let count = session.voices.count
    session.newTrack()
    #expect(session.isRecording)
    #expect(session.voices.count == count)
}

@Test @MainActor func removeTrackRefusesStripThatHasAudioAndAllowsEmpty() throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("producer-remove-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let mono = scratch.appendingPathComponent("host.wav")
    try WAVIO.write(
        url: mono,
        buffer: WAVIO.Buffer(sampleRate: 48_000, channelCount: 1, samples: Array(repeating: 0.1, count: 4_800))
    )

    let session = MixerSession()
    session.importAudioFiles([mono], append: false)
    let loadedID = try #require(session.voices.first?.id)
    #expect(session.canRemoveStrip(loadedID) == false)
    session.removeEmptyStrip(loadedID)
    #expect(session.voices.count == 1)
    #expect(session.voices[0].fileURL != nil)

    session.newTrack()
    let emptyID = try #require(session.voices.last?.id)
    #expect(emptyID != loadedID)
    #expect(session.canRemoveStrip(emptyID))
    session.removeEmptyStrip(emptyID)
    #expect(session.voices.count == 1)
    #expect(session.voices[0].id == loadedID)
}

@Test @MainActor func reorderToggleAndMoveStillWork() {
    let session = MixerSession()
    session.newTrack()
    session.newTrack()
    let order = session.displayChannelOrder
    #expect(order.count == 2)
    session.moveChannel(fromID: order[1], toID: order[0])
    #expect(session.displayChannelOrder == [order[1], order[0]])
    #expect(ProducerTrackControls.toggledReorder(false, hasSession: true, isRecording: false))
    #expect(ProducerTrackControls.toggledReorder(true, hasSession: true, isRecording: false) == false)
    #expect(ProducerTrackControls.toggledReorder(false, hasSession: true, isRecording: true) == false)
    #expect(ProducerTrackControls.toggledReorder(true, hasSession: false, isRecording: false))
}

@Test func theDecksWordmarkIsPartOfClubPod() {
    #expect(DeckWordmark.quiet == "The")
    #expect(DeckWordmark.name == "Decks")
    #expect(DeckWordmark.joined == "TheDecks")
    #expect(DeckWordmark.joined.contains(" ") == false)
    #expect(DeckWordmark.suite == "ClubPod")
    #expect(CougarCalcBrand.suiteName == "ClubPod")
    #expect(ProducerTrackControls.newTrackTitle == "New Track")
    #expect(ProducerTrackControls.removeTrackTitle == "Remove Track")
    #expect(ProducerTrackControls.reorderTitle == "Reorder")
}
