import AVFoundation
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

@Test @MainActor func depotDisplayNameNamesTheStripAndRenameFollowsOnlyTheDefault() throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("producer-rename-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let mono = scratch.appendingPathComponent("episode.wav")
    try WAVIO.write(
        url: mono,
        buffer: WAVIO.Buffer(sampleRate: 48_000, channelCount: 1, samples: Array(repeating: 0.1, count: 480))
    )
    let bytes = try Data(contentsOf: mono)

    let model = ProducerLoungeModel()
    model.importDepotFiles([
        ProducerDepotFile(url: mono, assetID: "ep-1", displayName: "episode.wav"),
    ], append: false)
    let strip = try #require(model.session.voices.first)
    #expect(strip.name == "episode")
    #expect(strip.depotAssetID == "ep-1")
    let eq = strip.eq

    model.followDepotDisplayName(assetID: "ep-1", from: "episode.wav", to: "Host Take")
    #expect(model.session.voices[0].name == "Host Take")
    #expect(model.session.voices[0].eq == eq)
    #expect(model.session.voices[0].fileURL?.path == mono.path)
    #expect(try Data(contentsOf: mono) == bytes)

    model.session.voices[0].name = "Jeffrey"
    model.followDepotDisplayName(assetID: "ep-1", from: "Host Take", to: "Guest")
    #expect(model.session.voices[0].name == "Jeffrey")

    model.setRecordingForTest(true)
    model.session.voices[0].name = "episode"
    model.followDepotDisplayName(assetID: "ep-1", from: "episode.wav", to: "Host Take")
    #expect(model.session.voices[0].name == "episode")
    model.setRecordingForTest(false)
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
    #expect(ProducerTrackControls.inputDeviceTitle == "Input Device")
    #expect(ProducerTrackControls.inputDeviceButtonTitle == "INPUT")
    #expect(ProducerTrackControls.inputDeviceNotification == .fixerMixerPickInput)
}

@Test @MainActor func inputDeviceCanBeChosenWithoutTheFileMenu() {
    let session = MixerSession()
    #expect(session.hasSession == false)
    #expect(session.prepareForInputSelection())
    #expect(session.hasSession)
    #expect(session.voices.isEmpty)
    #expect(session.stereos.isEmpty)

    session.isRecording = true
    #expect(session.prepareForInputSelection() == false)
    #expect(session.isRecording)
    #expect(session.voices.isEmpty)
    session.isRecording = false
    session.closeMixer()
}

@Test @MainActor func stereoStripRenamePersistsThroughSaveAndLoad() throws {
    var music = ChannelStripState.stereo(slot: 0, name: "  ")
    music.commitDisplayName()
    #expect(music.name == "MUSIC")
    var sfx = ChannelStripState.stereo(slot: 1, name: "")
    sfx.commitDisplayName()
    #expect(sfx.name == "SFX")
    var speaker = ChannelStripState.voice(slot: 0, speakerNumber: 2, name: " ")
    speaker.commitDisplayName()
    #expect(speaker.name == "SPK 2")

    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("producer-stereo-name-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let stereo = scratch.appendingPathComponent("bed.wav")
    try WAVIO.write(
        url: stereo,
        buffer: WAVIO.Buffer(sampleRate: 48_000, channelCount: 2, samples: Array(repeating: 0.05, count: 9_600))
    )

    let session = MixerSession()
    session.importAudioFiles([stereo], append: false)
    let bed = try #require(session.stereos.first)
    #expect(bed.isStereo)
    #expect(bed.dspOrder == ChannelDSPSlot.musicDefault)
    session.stereos[0].name = "Bumper"
    session.stereos[0].eq.gains[0] = 3.5

    let mixURL = scratch.appendingPathComponent(MixerMixFile.fileName)
    try MixerMixFile.write(MixerMixFile.make(from: session), to: mixURL)
    let read = try MixerMixFile.read(from: mixURL)
    let other = MixerSession()
    other.importAudioFiles([stereo], append: false)
    MixerMixFile.apply(read, to: other)
    #expect(other.stereos[0].name == "Bumper")
    #expect(other.stereos[0].isStereo)
    #expect(other.stereos[0].dspOrder == ChannelDSPSlot.musicDefault)
    #expect(other.stereos[0].eq.gains[0] == 3.5)

    let model = ProducerLoungeModel()
    model.importDepotFiles([
        ProducerDepotFile(url: stereo, assetID: "bed-1", displayName: "Bed"),
    ], append: false)
    model.session.stereos[0].name = "Bumper"
    model.session.stereos[0].eq.gains[0] = 3.5
    let document = model.captureDocument()
    #expect(document.tracks.first { $0.role == "stereo" }?.name == "Bumper")

    let restored = ProducerLoungeModel()
    restored.restore(document: document) { id in
        id == "bed-1" ? stereo : nil
    }
    #expect(restored.session.stereos[0].name == "Bumper")
    #expect(restored.session.stereos[0].isStereo)
    #expect(restored.session.stereos[0].dspOrder == ChannelDSPSlot.musicDefault)
    #expect(restored.session.stereos[0].eq.gains[0] == 3.5)
}

@Test @MainActor func tighterChannelHeaderGivesTheHeightToEQ2520() {
    let column: CGFloat = 480
    let savings = SelectedChannelPanel.Layout.headerSavings
    #expect(savings == 60)
    #expect(SelectedChannelPanel.Layout.midRowH == 136)
    #expect(SelectedChannelPanel.Layout.bottomRowH == 150)

    let rta = SelectedChannelPanel.Layout.rtaHeight(columnHeight: column, voice: true)
    let eq = SelectedChannelPanel.Layout.eqHeight(columnHeight: column, voice: true)
    let previous = SelectedChannelPanel.Layout.equalShare(columnHeight: column - savings, voice: true)
    #expect(abs(rta - previous) < 0.01)
    #expect(abs((eq - rta) - savings) < 0.01)

    let stereoRTA = SelectedChannelPanel.Layout.rtaHeight(columnHeight: column, voice: false)
    let stereoEQ = SelectedChannelPanel.Layout.eqHeight(columnHeight: column, voice: false)
    let stereoPrevious = SelectedChannelPanel.Layout.equalShare(columnHeight: column - savings, voice: false)
    #expect(abs(stereoRTA - stereoPrevious) < 0.01)
    #expect(abs((stereoEQ - stereoRTA) - savings) < 0.01)
}

@Test func monoInputMapsToChannelOne() {
    #expect(MixerHardwareInput.hardwareChannel(inputNumber: 1, channelCount: 1) == 0)
    #expect(MixerHardwareInput.channelIndex(forInputNumber: 1) == 0)
    #expect(MixerHardwareInput.hardwareChannel(inputNumber: 2, channelCount: 1) == nil)
    #expect(MixerHardwareInput.isPresent(hwChannel: 0, channelCount: 1))
    #expect(!MixerHardwareInput.isPresent(hwChannel: 1, channelCount: 1))
}

@Test func inputOnlyMicUsesPrivateAggregate() {
    #expect(
        MixerInputAttachPlan.plan(
            inputOutputChannels: 0,
            inputUID: "BuiltInMicrophoneDevice",
            outputUID: "BuiltInSpeakerDevice"
        ) == .privateAggregate(clockUID: "BuiltInMicrophoneDevice", outputUID: "BuiltInSpeakerDevice")
    )
    #expect(
        MixerInputAttachPlan.plan(
            inputOutputChannels: 8,
            inputUID: "AUDINATE-DVS-UID",
            outputUID: "BuiltInSpeakerDevice"
        ) == .useInputDevice
    )
    #expect(DeckStatusCopy.noInput(deviceName: "MacBook Pro Microphone") == "No input from MacBook Pro Microphone. Pick another INPUT.")
    #expect(DeckStatusCopy.noInput(deviceName: "  ") == "No input from that interface. Pick another INPUT.")
}

@Test func statusLineFitsTheTitleRow() {
    #expect(DeckStatusCopy.progressText(label: "Importing", fraction: 1) == "Importing · 100%")
    #expect(DeckStatusCopy.progressText(label: nil, fraction: 0.5) == "50%")
    #expect(!DeckStatusCopy.hint(lounge: true).contains("File menu"))
    #expect(DeckStatusCopy.hint(lounge: false).contains("INPUT"))
    #expect(DeckStatusCopy.openSettingsTitle == "Open Settings")
    #expect(DeckStatusCopy.microphoneDenied(appName: "Lounge").contains("Turn on Lounge"))
    #expect(DeckStatusCopy.microphoneDenied(appName: "TheDecks").contains("Turn on TheDecks"))
}

@Test func deniedMicrophoneGateNamesTheApp() {
    let lounge = MicrophoneGate.decide(status: .denied, appName: "Lounge")
    #expect(lounge == .denied(DeckStatusCopy.microphoneDenied(appName: "Lounge")))
    #expect(MicrophoneGate.decide(status: .restricted, appName: "TheDecks") == .denied(DeckStatusCopy.microphoneDenied(appName: "TheDecks")))
    #expect(MicrophoneGate.decide(status: .notDetermined, appName: "Lounge") == .request)
    #expect(MicrophoneGate.decide(status: .authorized, appName: "Lounge") == .proceed)
}

@Test func microphoneSettingsOpensThePrivacyPane() {
    var opened: [URL] = []
    let ok = MicrophoneSettings.open { url in
        opened.append(url)
        return true
    }
    #expect(ok)
    #expect(opened.count == 1)
    #expect(opened[0].absoluteString.contains("Privacy_Microphone"))
}

@Test @MainActor func deniedMicrophoneDoesNotStartRecording() async {
    let session = MixerSession()
    session.permissionAppName = "TheDecks"
    session.microphoneAccess = MicrophoneAccess(
        status: { .denied },
        requestAccess: { _ in },
        openSettings: {}
    )
    session.newRecordSession()
    session.addBlankStrip()
    session.voices[0].inputChannel = 0
    session.toggleRecord()
    #expect(session.status == DeckStatusCopy.microphoneDenied(appName: "TheDecks"))
    #expect(session.microphoneSettingsVisible)
    #expect(!session.isRecording)

    var opened = false
    session.microphoneAccess.openSettings = { opened = true }
    session.openMicrophoneSettings()
    #expect(opened)
}

@Test @MainActor func undeterminedMicrophoneDenialStaysOffTheEngine() async {
    let session = MixerSession()
    session.permissionAppName = "Lounge"
    session.microphoneAccess = MicrophoneAccess(
        status: { .notDetermined },
        requestAccess: { handler in handler(false) },
        openSettings: {}
    )
    session.newRecordSession()
    session.addBlankStrip()
    session.voices[0].inputChannel = 0
    session.toggleRecord()
    await Task.yield()
    #expect(session.status == DeckStatusCopy.microphoneDenied(appName: "Lounge"))
    #expect(session.microphoneSettingsVisible)
    #expect(!session.isRecording)
}

@Test @MainActor func loungeModelMirrorsStatusIntoTheTitleRow() {
    let model = ProducerLoungeModel()
    model.session.status = "Paused · 3:34"
    model.session.busyProgress = 1
    model.session.busyProgressLabel = "Importing"
    model.session.microphoneSettingsVisible = true
    #expect(model.statusLine == "Paused · 3:34")
    #expect(model.busyProgress == 1)
    #expect(model.busyProgressLabel == "Importing")
    #expect(model.microphoneSettingsVisible)
}
