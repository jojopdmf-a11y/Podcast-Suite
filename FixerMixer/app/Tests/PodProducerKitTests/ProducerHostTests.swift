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
