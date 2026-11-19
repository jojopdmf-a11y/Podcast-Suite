import AVFoundation
import Foundation
import Testing
@testable import PodLoungeCore

private let rate = 48_000.0

private func clip(
    asset: String = "mix",
    track: TrimmerTrackID = .episodeMix,
    start: Double,
    length: Double,
    inOffset: Double = 0,
    fadeIn: Double = 0,
    fadeOut: Double = 0,
    gainDB: Double = 0,
    sourceDuration: Double? = nil
) -> TrimmerClip {
    TrimmerClip(
        assetID: asset,
        track: track,
        start: start,
        inOffset: inOffset,
        length: length,
        fadeIn: fadeIn,
        fadeOut: fadeOut,
        gainDB: gainDB,
        sourceDuration: sourceDuration ?? (inOffset + length)
    )
}

private func sample(_ result: TrimmerRenderResult, frame: Int, channel: Int = 0) -> Float {
    let index = frame * 2 + channel
    guard result.stereo.indices.contains(index) else { return .nan }
    return result.stereo[index]
}

@Test func splitTrimAndMoveClips() {
    let original = clip(start: 0, length: 10, sourceDuration: 10)
    var document = TrimmerDocument.empty.placing(original)
    document = document.splitting(clipID: original.id, at: 4)
    #expect(document.clips.count == 2)
    #expect(abs(document.clips[0].length - 4) < 0.000_1)
    #expect(abs(document.clips[1].start - 4) < 0.000_1)
    #expect(abs(document.clips[1].inOffset - 4) < 0.000_1)
    #expect(abs(document.clips[1].length - 6) < 0.000_1)
    #expect(document.splitting(clipID: original.id, at: 0.01).clips.count == 2)

    let right = document.clips[1]
    document = document.trimming(clipID: right.id, edge: .start, to: 5)
    let trimmed = document.clip(right.id)
    #expect(abs((trimmed?.start ?? 0) - 5) < 0.000_1)
    #expect(abs((trimmed?.inOffset ?? 0) - 5) < 0.000_1)
    #expect(abs((trimmed?.length ?? 0) - 5) < 0.000_1)

    document = document.trimming(clipID: right.id, edge: .end, to: 12)
    #expect(abs((document.clip(right.id)?.end ?? 0) - 10) < 0.000_1)

    let moved = document.clips[0]
    document = document.moving(clipID: moved.id, toStart: 2, track: .musicBeds)
    #expect(document.clip(moved.id)?.track == .musicBeds)
    #expect(abs((document.clip(moved.id)?.start ?? 0) - 2) < 0.000_1)
    #expect(document.clip(right.id)?.track == .episodeMix)
}

@Test func deleteCloseGapShiftsLaterClipsAndMarkers() {
    let mix = clip(asset: "mix", start: 0, length: 10)
    let laterMix = clip(asset: "mix", start: 12, length: 3)
    let ad = clip(asset: "ad", track: .introsOutrosAds, start: 8, length: 2)
    let outro = clip(asset: "outro", track: .introsOutrosAds, start: 14, length: 2)
    let bed = clip(asset: "bed", track: .musicBeds, start: 1, length: 4)
    var document = TrimmerDocument.empty
    document.clips = [mix, laterMix, ad, outro, bed]
    document.markers = [
        TrimmerMarker(time: 1, title: "Keep"),
        TrimmerMarker(time: 4, title: "Inside"),
        TrimmerMarker(time: 6, title: "After"),
    ]
    let closed = document.deleting(
        range: TrimmerTimeRange(start: 2, end: 6),
        on: .episodeMix,
        mode: .closeGap
    )
    let mixClips = closed.clips.filter { $0.track == .episodeMix }.sorted { $0.start < $1.start }
    #expect(mixClips.count == 3)
    #expect(abs(mixClips[0].length - 2) < 0.000_1)
    #expect(abs(mixClips[1].start - 2) < 0.000_1)
    #expect(abs(mixClips[1].inOffset - 6) < 0.000_1)
    #expect(abs(mixClips[1].length - 4) < 0.000_1)
    #expect(abs(mixClips[2].start - 8) < 0.000_1)
    #expect(abs((closed.clips.first { $0.id == ad.id }?.start ?? -1) - 4) < 0.000_1)
    #expect(abs((closed.clips.first { $0.id == outro.id }?.start ?? -1) - 10) < 0.000_1)
    #expect(abs((closed.clips.first { $0.id == bed.id }?.start ?? -1) - 1) < 0.000_1)
    #expect(closed.markers.contains { $0.title == "Keep" && abs($0.time - 1) < 0.000_1 })
    #expect(closed.markers.contains { $0.title == "Inside" } == false)
    #expect(closed.markers.contains { $0.title == "After" && abs($0.time - 2) < 0.000_1 })
}

@Test func deleteLeaveGapKeepsLaterTiming() {
    let mix = clip(start: 0, length: 10)
    let later = clip(asset: "tail", start: 12, length: 2)
    let outro = clip(asset: "outro", track: .introsOutrosAds, start: 14, length: 1)
    var document = TrimmerDocument.empty
    document.clips = [mix, later, outro]
    document.markers = [TrimmerMarker(time: 8, title: "Stay")]
    let left = document.deleting(
        range: TrimmerTimeRange(start: 2, end: 6),
        on: .episodeMix,
        mode: .leaveGap
    )
    let parts = left.clips.filter { $0.track == .episodeMix }.sorted { $0.start < $1.start }
    #expect(parts.count == 3)
    #expect(abs(parts[0].end - 2) < 0.000_1)
    #expect(abs(parts[1].start - 6) < 0.000_1)
    #expect(abs(parts[2].start - 12) < 0.000_1)
    #expect(abs((left.clips.first { $0.id == outro.id }?.start ?? -1) - 14) < 0.000_1)
    #expect(left.markers.first?.time == 8)
}

@Test func wholeClipWithNothingAfterDeletesWithoutAChoice() {
    let only = clip(start: 1, length: 4)
    let other = clip(asset: "ad", track: .introsOutrosAds, start: 20, length: 2)
    var document = TrimmerDocument.empty
    document.clips = [only, other]
    let plan = document.planDelete(clipID: only.id)
    guard case let .removeClips(ids) = plan else {
        Issue.record("Expected a silent delete")
        return
    }
    #expect(ids == [only.id])
    let removed = document.removingClips(ids: ids)
    #expect(removed.clips.map(\.id) == [other.id])
    #expect(removed.clips[0].start == 20)

    let followed = clip(asset: "tail", start: 6, length: 2)
    document.clips.append(followed)
    guard case .choose = document.planDelete(clipID: only.id) else {
        Issue.record("A clip with something after it asks first")
        return
    }
    guard case .choose = document.planDelete(range: TrimmerTimeRange(start: 2, end: 3), on: .episodeMix) else {
        Issue.record("A range inside a clip asks first")
        return
    }
}

@Test func overlapUsesEqualPowerCrossfade() {
    let rate = 48_000.0
    let frames = 48_000
    var document = TrimmerDocument.empty
    let first = clip(asset: "a", start: 0, length: 1, sourceDuration: 1)
    let second = clip(asset: "b", start: 0.5, length: 1, sourceDuration: 1)
    document.clips = [first, second]
    let result = TrimmerRenderer.render(
        document: document,
        sampleRate: rate,
        sources: [
            "a": .constant(frames: frames, amplitude: 1, sampleRate: rate),
            "b": .constant(frames: frames, amplitude: 0, sampleRate: rate),
        ]
    )
    let midpoint = TrimmerClock.frames(seconds: 0.75, sampleRate: rate)
    let expected = TrimmerGain.crossfade(at: 0.5).outgoing
    #expect(abs(sample(result, frame: midpoint) - expected) < 0.002)
    #expect(abs(sample(result, frame: midpoint, channel: 1) - expected) < 0.002)
    let before = TrimmerClock.frames(seconds: 0.25, sampleRate: rate)
    #expect(abs(sample(result, frame: before) - 1) < 0.002)
    #expect(abs(Float(TrimmerGain.fadeIn(0.5)) - expected) < 0.000_1)
}

@Test func fadeInDefaultsToAStraightLine() {
    var document = TrimmerDocument.empty
    document.clips = [clip(start: 0, length: 1, fadeIn: 1, sourceDuration: 1)]
    let result = TrimmerRenderer.render(
        document: document,
        sampleRate: rate,
        sources: ["mix": .constant(frames: 48_000, amplitude: 1, sampleRate: rate)]
    )
    let frame = TrimmerClock.frames(seconds: 0.5, sampleRate: rate)
    #expect(abs(sample(result, frame: frame) - 0.5) < 0.002)
    #expect(abs(sample(result, frame: 0)) < 0.002)
    let nearEnd = TrimmerClock.frames(seconds: 0.999, sampleRate: rate)
    #expect(sample(result, frame: nearEnd) > 0.99)
}

@Test func closeGapRenderIsShorterAndJoined() {
    var ramp = [Float](repeating: 0, count: 48_000 * 2)
    for frame in 0..<48_000 {
        ramp[frame * 2] = Float(frame)
        ramp[frame * 2 + 1] = Float(frame)
    }
    var document = TrimmerDocument.empty
    let whole = clip(start: 0, length: 1, sourceDuration: 1)
    document.clips = [whole]
    document = document.deleting(
        range: TrimmerTimeRange(start: 0.25, end: 0.5),
        on: .episodeMix,
        mode: .closeGap
    )
    let result = TrimmerRenderer.render(
        document: document,
        sampleRate: rate,
        sources: ["mix": TrimmerSourceAudio(sampleRate: rate, stereo: ramp)]
    )
    #expect(result.frameCount == 36_000)
    #expect(abs(sample(result, frame: 0)) < 0.001)
    #expect(abs(sample(result, frame: 11_999) - 11_999) < 1)
    #expect(abs(sample(result, frame: 12_000) - 24_000) < 1)
}

@Test func muteSoloAndGainShapeTheMix() {
    var document = TrimmerDocument.empty
    document.clips = [
        clip(asset: "mix", track: .episodeMix, start: 0, length: 0.1, sourceDuration: 0.1),
        clip(asset: "bed", track: .musicBeds, start: 0, length: 0.1, sourceDuration: 0.1),
    ]
    let sources = [
        "mix": TrimmerSourceAudio.constant(frames: 4_800, amplitude: 1, sampleRate: rate),
        "bed": TrimmerSourceAudio.constant(frames: 4_800, amplitude: 0.25, sampleRate: rate),
    ]
    let open = TrimmerRenderer.render(document: document, sampleRate: rate, sources: sources)
    #expect(abs(sample(open, frame: 100) - 1.25) < 0.002)

    let muted = document.settingTrack(.episodeMix, muted: true)
    let mutedMix = TrimmerRenderer.render(document: muted, sampleRate: rate, sources: sources)
    #expect(abs(sample(mutedMix, frame: 100) - 0.25) < 0.002)

    let soloBed = document.settingTrack(.musicBeds, solo: true)
    let soloMix = TrimmerRenderer.render(document: soloBed, sampleRate: rate, sources: sources)
    #expect(abs(sample(soloMix, frame: 100) - 0.25) < 0.002)

    let soloAndMute = soloBed.settingTrack(.musicBeds, muted: true)
    let silent = TrimmerRenderer.render(document: soloAndMute, sampleRate: rate, sources: sources)
    #expect(abs(sample(silent, frame: 100)) < 0.000_1)

    let gained = document.settingTrack(.episodeMix, gainDB: -6).settingTrack(.musicBeds, muted: true)
    let gainedMix = TrimmerRenderer.render(document: gained, sampleRate: rate, sources: sources)
    let expected = TrimmerGain.linear(decibels: -6)
    #expect(abs(sample(gainedMix, frame: 100) - expected) < 0.002)
}

@Test @MainActor func undoAndRedoRoundTripEdits() {
    let editor = TrimmerEditor()
    let placed = clip(start: 0, length: 8, sourceDuration: 8)
    editor.edit("Place") { $0.clips.append(placed) }
    editor.edit("Move") { document in
        document = document.moving(clipID: placed.id, toStart: 3, track: .episodeMix)
    }
    editor.edit("Gain") { document in
        document = document.settingTrack(.episodeMix, muted: true, gainDB: -3)
    }
    editor.edit("Chapter") { document in
        document = document.addingMarker(at: 1, title: "Intro")
    }
    #expect(editor.document.clips.count == 1)
    #expect(editor.document.trackState(.episodeMix).muted)
    editor.undoManager.undo()
    #expect(editor.document.markers.isEmpty)
    editor.undoManager.undo()
    #expect(editor.document.trackState(.episodeMix).gainDB == 0)
    #expect(editor.document.trackState(.episodeMix).muted == false)
    editor.undoManager.undo()
    #expect(abs(editor.document.clips[0].start) < 0.000_1)
    editor.undoManager.undo()
    #expect(editor.document.clips.isEmpty)
    editor.undoManager.redo()
    #expect(editor.document.clips.count == 1)
    editor.undoManager.redo()
    #expect(abs(editor.document.clips[0].start - 3) < 0.000_1)
}

@Test func trimmerDocumentRoundTripsAndOldProjectsOpen() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let folder = scratch.root.appendingPathComponent("Show.podlounge")
    let package = try ProjectPackage.create(at: folder, name: "Show")
    #expect(package.readTrimmerDocument() == .empty)

    try FileManager.default.removeItem(at: package.trimmerDocumentURL)
    let missing = try ProjectPackage.open(at: folder)
    #expect(missing.readTrimmerDocument() == .empty)
    #expect(missing.manifest.projectName == "Show")

    try Data("{}\n".utf8).write(to: package.trimmerDocumentURL)
    #expect(package.readTrimmerDocument() == .empty)

    var document = TrimmerDocument.empty
    let episode = clip(asset: "abc", start: 1.5, length: 4, fadeIn: 0.5, fadeOut: 0.25, gainDB: -2)
    document = document.placing(episode)
    document = document.settingTrack(.musicBeds, solo: true, gainDB: -8)
    document = document.addingMarker(at: 12, title: "Wrap-up")
    try package.writeTrimmerDocument(document)
    let reopened = try ProjectPackage.open(at: folder)
    let loaded = reopened.readTrimmerDocument()
    #expect(loaded.clips.count == 1)
    #expect(loaded.clips[0].assetID == "abc")
    #expect(loaded.clips[0].track == .episodeMix)
    #expect(abs(loaded.clips[0].start - 1.5) < 0.000_1)
    #expect(abs(loaded.clips[0].inOffset) < 0.000_1)
    #expect(abs(loaded.clips[0].length - 4) < 0.000_1)
    #expect(abs(loaded.clips[0].fadeIn - 0.5) < 0.000_1)
    #expect(abs(loaded.clips[0].fadeOut - 0.25) < 0.000_1)
    #expect(abs(loaded.clips[0].gainDB - (-2)) < 0.000_1)
    #expect(loaded.trackState(.musicBeds).solo)
    #expect(abs(loaded.trackState(.musicBeds).gainDB - (-8)) < 0.000_1)
    #expect(loaded.trackState(.episodeMix).gainDB == 0)
    #expect(loaded.markers.first?.title == "Wrap-up")
    #expect(reopened.manifest.assets.isEmpty)
}

@Test func decoderReadsAWrittenWav() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let url = scratch.root.appendingPathComponent("tone.wav")
    let frames = 4_800
    try TrimmerWAV.write(
        stereo: [Float](repeating: 0.5, count: frames * 2),
        sampleRate: 48_000,
        depth: .int24,
        to: url
    )
    let decoded = try TrimmerDecoder.readStereo(url: url, targetRate: 48_000)
    #expect(decoded.frameCount > 4_000)
    #expect(decoded.frameCount < 5_600)
    let mid = decoded.frameCount / 2
    #expect(abs(decoded.stereo[mid * 2] - 0.5) < 0.02)
    #expect(abs(decoded.stereo[mid * 2 + 1] - 0.5) < 0.02)
}

@Test func trimDoesNotRollTheNeighborAndStaysInsideTheSource() {
    let left = clip(start: 0, length: 4, inOffset: 0, sourceDuration: 10)
    let right = clip(start: 4, length: 6, inOffset: 4, sourceDuration: 10)
    var document = TrimmerDocument.empty
    document.clips = [left, right]

    let opened = document.trimming(clipID: left.id, edge: .end, to: 3)
    #expect(abs((opened.clip(left.id)?.end ?? 0) - 3) < 0.000_1)
    #expect(opened.clip(right.id) == right)

    let overlapped = document.trimming(clipID: right.id, edge: .start, to: 3)
    #expect(overlapped.clip(left.id) == left)
    #expect(abs((overlapped.clip(right.id)?.start ?? 0) - 3) < 0.000_1)
    #expect(abs((overlapped.clip(right.id)?.length ?? 0) - 7) < 0.000_1)
    #expect(abs((overlapped.clip(right.id)?.inOffset ?? 0) - 3) < 0.000_1)

    let head = clip(start: 5, length: 3, inOffset: 1, sourceDuration: 10)
    var headed = TrimmerDocument.empty
    headed.clips = [head]
    let clamped = headed.trimming(clipID: head.id, edge: .start, to: 0)
    #expect(abs((clamped.clip(head.id)?.start ?? -1) - 4) < 0.000_1)
    #expect((clamped.clip(head.id)?.inOffset ?? -1) < 0.000_1)
    #expect(abs((clamped.clip(head.id)?.length ?? 0) - 4) < 0.000_1)

    let pastEnd = document.trimming(clipID: right.id, edge: .end, to: 40)
    #expect(abs((pastEnd.clip(right.id)?.end ?? 0) - 10) < 0.000_1)
    #expect(pastEnd.clip(left.id) == left)

    let tooShort = document.trimming(clipID: left.id, edge: .end, to: 0.01)
    #expect(abs((tooShort.clip(left.id)?.length ?? 0) - TrimmerDocument.minimumLength) < 0.000_1)
    #expect(tooShort.clip(right.id) == right)
}

@Test @MainActor func trimAndFadeUndoRestoreTheClip() {
    let left = clip(start: 0, length: 4, sourceDuration: 10)
    let right = clip(start: 4, length: 6, inOffset: 4, sourceDuration: 10)
    let editor = TrimmerEditor()
    editor.edit("Place") { $0.clips = [left, right] }
    editor.edit("Trim") { document in
        document = document.trimming(clipID: left.id, edge: .end, to: 2.5)
    }
    #expect(abs((editor.document.clip(left.id)?.end ?? 0) - 2.5) < 0.000_1)
    #expect(editor.document.clip(right.id)?.start == 4)
    editor.undoManager.undo()
    #expect(abs((editor.document.clip(left.id)?.length ?? 0) - 4) < 0.000_1)
    #expect(abs((editor.document.clip(right.id)?.start ?? 0) - 4) < 0.000_1)

    editor.edit("Fade") { document in
        document = document.settingFade(clipID: left.id, edge: .fadeIn, seconds: 0.6)
    }
    #expect(abs((editor.document.clip(left.id)?.fadeIn ?? 0) - 0.6) < 0.000_1)
    editor.undoManager.undo()
    #expect((editor.document.clip(left.id)?.fadeIn ?? 1) < 0.000_1)
}

@Test func fadeLengthsRoundTripAndReachTheMix() throws {
    var document = TrimmerDocument.empty
    let episode = clip(start: 0, length: 1, fadeIn: 0.4, fadeOut: 0.25, sourceDuration: 1)
    document.clips = [episode]
    let loaded = try TrimmerDocument.decode(try document.encoded())
    #expect(abs(loaded.clips[0].fadeIn - 0.4) < 0.000_1)
    #expect(abs(loaded.clips[0].fadeOut - 0.25) < 0.000_1)

    var crossed = TrimmerDocument.empty
    crossed.clips = [clip(start: 0, length: 1, fadeIn: 0.8, fadeOut: 0.8, sourceDuration: 1)]
    let kept = try TrimmerDocument.decode(try crossed.encoded())
    #expect(abs(kept.clips[0].fadeIn - 0.8) < 0.000_1)
    #expect(abs(kept.clips[0].fadeOut - 0.8) < 0.000_1)

    let limited = loaded.settingFade(clipID: loaded.clips[0].id, edge: .fadeIn, seconds: 10)
    #expect(abs((limited.clip(loaded.clips[0].id)?.fadeIn ?? 0) - 0.75) < 0.000_1)
    #expect(abs((limited.clip(loaded.clips[0].id)?.fadeOut ?? 0) - 0.25) < 0.000_1)

    let result = TrimmerRenderer.render(
        document: loaded,
        sampleRate: rate,
        sources: ["mix": .constant(frames: 48_000, amplitude: 1, sampleRate: rate)]
    )
    let early = TrimmerClock.frames(seconds: 0.2, sampleRate: rate)
    #expect(abs(sample(result, frame: early) - 0.5) < 0.002)
    let middle = TrimmerClock.frames(seconds: 0.5, sampleRate: rate)
    #expect(abs(sample(result, frame: middle) - 1) < 0.002)
    let late = TrimmerClock.frames(seconds: 0.875, sampleRate: rate)
    #expect(abs(sample(result, frame: late) - 0.5) < 0.002)
    #expect(abs(sample(result, frame: 0)) < 0.002)
}

@Test func fitRangeCoversEveryTrackAndMinusCanReachIt() {
    var document = TrimmerDocument.empty
    document.clips = [
        clip(track: .episodeMix, start: 0, length: 12),
        clip(track: .introsOutrosAds, start: 40, length: 5),
        clip(track: .musicBeds, start: 3, length: 2),
    ]
    let end = TrimmerViewport.fitEnd(of: document)
    #expect(abs(end - (45 + TrimmerViewport.margin)) < 0.000_1)
    for item in document.clips {
        #expect(item.start >= 0)
        #expect(item.end <= end)
    }
    let width = 900.0
    let pps = TrimmerViewport.fitPixelsPerSecond(of: document, width: width)
    #expect(abs(pps * end - (width - TrimmerViewport.edgePadding)) < 0.001)

    var zoomed = pps * 8
    for _ in 0..<40 {
        zoomed = TrimmerViewport.zoom(
            pixelsPerSecond: zoomed,
            by: 1 / TrimmerViewport.zoomFactor,
            fitPixelsPerSecond: pps
        )
    }
    #expect(abs(zoomed - pps) < 0.000_1)

    var long = TrimmerDocument.empty
    long.clips = [clip(start: 0, length: 7_200)]
    let longEnd = TrimmerViewport.fitEnd(of: long)
    let longFit = TrimmerViewport.fitPixelsPerSecond(of: long, width: 800)
    #expect(longEnd >= 7_200)
    #expect(longFit < 2)
    var pulled = 2.0
    for _ in 0..<40 {
        pulled = TrimmerViewport.zoom(
            pixelsPerSecond: pulled,
            by: 1 / TrimmerViewport.zoomFactor,
            fitPixelsPerSecond: longFit
        )
    }
    #expect(abs(pulled - longFit) < 0.000_1)
    let inward = TrimmerViewport.zoom(
        pixelsPerSecond: longFit,
        by: TrimmerViewport.zoomFactor,
        fitPixelsPerSecond: longFit
    )
    #expect(inward > longFit)
}

@Test func seekWhilePlayingKeepsPlayback() {
    let playing = TrimmerSeek.decide(isPlaying: true, time: 12.5)
    #expect(playing.keepPlaying)
    #expect(playing.time == 12.5)
    let stopped = TrimmerSeek.decide(isPlaying: false, time: 4)
    #expect(stopped.keepPlaying == false)
    #expect(stopped.time == 4)
    let negative = TrimmerSeek.decide(isPlaying: true, time: -3)
    #expect(negative.keepPlaying)
    #expect(negative.time == 0)
    let nonsense = TrimmerSeek.decide(isPlaying: false, time: .nan)
    #expect(nonsense.keepPlaying == false)
    #expect(nonsense.time == 0)
}

@Test func chaptersTextUsesClockLines() {
    let markers = [
        TrimmerMarker(time: 65, title: "Interview"),
        TrimmerMarker(time: 0, title: "Intro"),
        TrimmerMarker(time: 3_661, title: "  "),
    ]
    #expect(TrimmerChapters.text(markers: markers) == "00:00:00 Intro\n00:01:05 Interview\n01:01:01 Chapter\n")
    #expect(TrimmerChapters.text(markers: []) == "")
}

@Test func wavRoundTripKeepsLevelAndOpensInAudioToolbox() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    var stereo: [Float] = []
    for frame in 0..<1_000 {
        let value = Float(frame) / 1_000
        stereo.append(value)
        stereo.append(-value * 0.5)
    }
    let intURL = scratch.root.appendingPathComponent("cut24.wav")
    let floatURL = scratch.root.appendingPathComponent("cut32.wav")
    try TrimmerWAV.write(stereo: stereo, sampleRate: rate, depth: .int24, to: intURL)
    try TrimmerWAV.write(stereo: stereo, sampleRate: rate, depth: .float32, to: floatURL)

    let intRead = try TrimmerWAV.read(from: intURL)
    #expect(abs(intRead.sampleRate - rate) < 0.1)
    #expect(intRead.stereo.count == stereo.count)
    #expect(abs(intRead.stereo[100] - stereo[100]) < 0.000_1)

    let floatRead = try TrimmerWAV.read(from: floatURL)
    #expect(abs(floatRead.stereo[100] - stereo[100]) < 0.000_01)
    let hot: [Float] = [1.5, -1.25]
    try TrimmerWAV.write(stereo: hot, sampleRate: rate, depth: .float32, to: floatURL)
    let overs = try TrimmerWAV.read(from: floatURL)
    #expect(abs(overs.stereo[0] - 1.5) < 0.000_1)
    #expect(abs(overs.stereo[1] - (-1.25)) < 0.000_1)

    for url in [intURL, floatURL] {
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 2)
        #expect(abs(file.fileFormat.sampleRate - rate) < 0.1)
    }
}

@Test func zoomKeepsThePlayheadAtTheSameScreenPosition() {
    let scroll = 120.0
    let view = 800.0
    let pps = 20.0
    let playhead = 26.0
    let span = 3_600.0
    let oldScreen = playhead * pps - scroll
    #expect(oldScreen > 0 && oldScreen < view)

    let zoomedIn = pps * TrimmerViewport.zoomFactor
    let inScroll = TrimmerViewport.zoomedScroll(
        scrollX: scroll,
        viewportWidth: view,
        pixelsPerSecond: pps,
        nextPixelsPerSecond: zoomedIn,
        playhead: playhead,
        contentSpan: span
    )
    #expect(abs((playhead * zoomedIn - inScroll) - oldScreen) < 0.01)

    let zoomedOut = pps / TrimmerViewport.zoomFactor
    let outScroll = TrimmerViewport.zoomedScroll(
        scrollX: scroll,
        viewportWidth: view,
        pixelsPerSecond: pps,
        nextPixelsPerSecond: zoomedOut,
        playhead: playhead,
        contentSpan: span
    )
    #expect(abs((playhead * zoomedOut - outScroll) - oldScreen) < 0.01)

    var screen = oldScreen
    var currentScroll = scroll
    var current = pps
    for _ in 0..<4 {
        let next = current * TrimmerViewport.zoomFactor
        currentScroll = TrimmerViewport.zoomedScroll(
            scrollX: currentScroll,
            viewportWidth: view,
            pixelsPerSecond: current,
            nextPixelsPerSecond: next,
            playhead: playhead,
            contentSpan: span
        )
        let landed = playhead * next - currentScroll
        #expect(abs(landed - screen) < 0.01)
        screen = landed
        current = next
    }
}

@Test func zoomOffScreenCentersTheMiddleOfTheView() {
    let scroll = 40.0
    let view = 900.0
    let pps = 10.0
    let playhead = 800.0
    let screen = playhead * pps - scroll
    #expect(screen > view)
    let next = pps * 2
    let newScroll = TrimmerViewport.zoomedScroll(
        scrollX: scroll,
        viewportWidth: view,
        pixelsPerSecond: pps,
        nextPixelsPerSecond: next,
        playhead: playhead,
        contentSpan: 3_600
    )
    let midTime = (scroll + view / 2) / pps
    #expect(abs((midTime * next - newScroll) - view / 2) < 0.01)

    let beforeStart = TrimmerViewport.zoomedScroll(
        scrollX: 0,
        viewportWidth: view,
        pixelsPerSecond: pps,
        nextPixelsPerSecond: next,
        playhead: 0,
        contentSpan: 30
    )
    #expect(abs(beforeStart) < 0.001)
}

@Test func fadeCurveGainIsLinearAtZeroAndBendsUpOrDown() {
    for curve in [-1.0, -0.4, 0, 0.4, 1] {
        #expect(TrimmerFadeCurve.fadeInGain(0, curve: curve) == 0)
        #expect(abs(TrimmerFadeCurve.fadeInGain(1, curve: curve) - 1) < 0.000_1)
        #expect(TrimmerFadeCurve.fadeOutGain(0, curve: curve) == 1)
        #expect(TrimmerFadeCurve.fadeOutGain(1, curve: curve) == 0)
        var previous: Float = -0.01
        for step in 0...24 {
            let gain = TrimmerFadeCurve.fadeInGain(Double(step) / 24, curve: curve)
            #expect(gain + 0.000_01 >= previous)
            previous = gain
        }
    }
    let linear = TrimmerFadeCurve.fadeInGain(0.25, curve: 0)
    #expect(abs(linear - 0.25) < 0.000_1)
    let fast = TrimmerFadeCurve.fadeInGain(0.25, curve: 1)
    let slow = TrimmerFadeCurve.fadeInGain(0.25, curve: -1)
    #expect(fast > linear)
    #expect(slow < linear)
    #expect(abs(TrimmerFadeCurve.fadeOutGain(0.25, curve: 1) - TrimmerFadeCurve.fadeInGain(0.75, curve: 1)) < 0.000_1)
    #expect(TrimmerFadeCurve.clamped(4) == 1)
    #expect(TrimmerFadeCurve.clamped(-3) == -1)
    #expect(TrimmerFadeCurve.bent(0, upPoints: TrimmerFadeCurve.pointsPerFullBend) == 1)
    #expect(TrimmerFadeCurve.bent(0, upPoints: -TrimmerFadeCurve.pointsPerFullBend) == -1)
}

@Test func fadeCurveRoundTripsAndOldFilesStayLinear() throws {
    var document = TrimmerDocument.empty
    var episode = clip(start: 0, length: 2, fadeIn: 0.4, fadeOut: 0.3, sourceDuration: 2)
    episode.fadeInCurve = 0.55
    episode.fadeOutCurve = -0.4
    document.clips = [episode]
    let loaded = try TrimmerDocument.decode(try document.encoded())
    #expect(abs(loaded.clips[0].fadeInCurve - 0.55) < 0.000_1)
    #expect(abs(loaded.clips[0].fadeOutCurve - (-0.4)) < 0.000_1)
    #expect(abs(loaded.clips[0].fadeIn - 0.4) < 0.000_1)
    let text = String(decoding: try document.encoded(), as: UTF8.self)
    #expect(text.contains("fadeInCurve"))

    let id = UUID()
    let old = """
    {
      "clips" : [
        {
          "assetID" : "mix",
          "fadeIn" : 0.4,
          "fadeOut" : 0.25,
          "gainDB" : 0,
          "id" : "\(id.uuidString)",
          "inOffset" : 0,
          "length" : 1,
          "sourceDuration" : 1,
          "start" : 0,
          "track" : "episodeMix"
        }
      ],
      "formatVersion" : 1,
      "markers" : [],
      "tracks" : []
    }
    """
    let legacy = try TrimmerDocument.decode(Data(old.utf8))
    #expect(abs(legacy.clips[0].fadeIn - 0.4) < 0.000_1)
    #expect(abs(legacy.clips[0].fadeOut - 0.25) < 0.000_1)
    #expect(legacy.clips[0].fadeInCurve == 0)
    #expect(legacy.clips[0].fadeOutCurve == 0)

    let clamped = document.settingFade(clipID: episode.id, edge: .fadeIn, seconds: 0.4, curve: 8)
    #expect((clamped.clip(episode.id)?.fadeInCurve ?? 0) == 1)
    let reset = clamped.resettingFadeCurve(clipID: episode.id, edge: .fadeIn)
    #expect((reset.clip(episode.id)?.fadeInCurve ?? 1) == 0)
    #expect(abs((reset.clip(episode.id)?.fadeIn ?? 0) - 0.4) < 0.000_1)
}

@Test @MainActor func fadeCurveUndoRestoresTheBend() {
    var episode = clip(start: 0, length: 2, fadeIn: 0.2, sourceDuration: 2)
    let editor = TrimmerEditor()
    editor.edit("Place") { $0.clips = [episode] }
    editor.edit("Fade") { document in
        document = document.settingFade(clipID: episode.id, edge: .fadeIn, seconds: 0.5, curve: 0.7)
    }
    #expect(abs((editor.document.clip(episode.id)?.fadeInCurve ?? 0) - 0.7) < 0.000_1)
    #expect(abs((editor.document.clip(episode.id)?.fadeIn ?? 0) - 0.5) < 0.000_1)
    editor.undoManager.undo()
    #expect((editor.document.clip(episode.id)?.fadeInCurve ?? 1) == 0)
    #expect(abs((editor.document.clip(episode.id)?.fadeIn ?? 0) - 0.2) < 0.000_1)
    editor.undoManager.redo()
    #expect(abs((editor.document.clip(episode.id)?.fadeInCurve ?? 0) - 0.7) < 0.000_1)
    editor.edit("Straighten") { document in
        document = document.resettingFadeCurve(clipID: episode.id, edge: .fadeIn)
    }
    #expect((editor.document.clip(episode.id)?.fadeInCurve ?? 1) == 0)
    #expect(abs((editor.document.clip(episode.id)?.fadeIn ?? 0) - 0.5) < 0.000_1)
}

@Test func renderAppliesTheFadeCurveAndCrossfadesStayEqualPower() {
    var fast = TrimmerDocument.empty
    var rising = clip(start: 0, length: 1, fadeIn: 1, sourceDuration: 1)
    rising.fadeInCurve = 1
    fast.clips = [rising]
    let fastMix = TrimmerRenderer.render(
        document: fast,
        sampleRate: rate,
        sources: ["mix": .constant(frames: 48_000, amplitude: 1, sampleRate: rate)]
    )
    var slow = fast
    slow.clips[0].fadeInCurve = -1
    let slowMix = TrimmerRenderer.render(
        document: slow,
        sampleRate: rate,
        sources: ["mix": .constant(frames: 48_000, amplitude: 1, sampleRate: rate)]
    )
    let frame = TrimmerClock.frames(seconds: 0.25, sampleRate: rate)
    let fastGain = sample(fastMix, frame: frame)
    let slowGain = sample(slowMix, frame: frame)
    #expect(abs(fastGain - TrimmerFadeCurve.fadeInGain(0.25, curve: 1)) < 0.01)
    #expect(abs(slowGain - TrimmerFadeCurve.fadeInGain(0.25, curve: -1)) < 0.01)
    #expect(fastGain > 0.25)
    #expect(slowGain < 0.25)
    #expect(abs(sample(fastMix, frame: 0)) < 0.002)
    let nearEnd = TrimmerClock.frames(seconds: 0.999, sampleRate: rate)
    #expect(sample(fastMix, frame: nearEnd) > 0.99)

    var overlap = TrimmerDocument.empty
    var first = clip(asset: "a", start: 0, length: 1, sourceDuration: 1)
    var second = clip(asset: "b", start: 0.5, length: 1, sourceDuration: 1)
    first.fadeOutCurve = 1
    second.fadeInCurve = -1
    overlap.clips = [first, second]
    let mixed = TrimmerRenderer.render(
        document: overlap,
        sampleRate: rate,
        sources: [
            "a": .constant(frames: 48_000, amplitude: 1, sampleRate: rate),
            "b": .constant(frames: 48_000, amplitude: 0, sampleRate: rate),
        ]
    )
    let midpoint = TrimmerClock.frames(seconds: 0.75, sampleRate: rate)
    let expected = TrimmerGain.crossfade(at: 0.5).outgoing
    #expect(abs(sample(mixed, frame: midpoint) - expected) < 0.002)
}

@Test func peakLevelOfDetailNeverExceedsOnePairPerPixel() {
    let total = 48_000 * 3_600
    var bucket = 128
    var count = (total + bucket - 1) / bucket
    var framesPerBucket: [Int] = []
    var levels: [TrimmerPeakLevel] = []
    while framesPerBucket.count < 16 {
        framesPerBucket.append(bucket)
        levels.append(TrimmerPeakLevel(
            framesPerBucket: bucket,
            minima: [Float](repeating: -0.2, count: count),
            maxima: [Float](repeating: 0.4, count: count)
        ))
        if count <= 256 { break }
        count = (count + 1) / 2
        bucket *= 2
    }

    for pixels in [1, 8, 100, 1_400, 4_000] {
        let choice = TrimmerPeakLOD.choose(framesPerBucket: framesPerBucket, frameCount: total, pixels: pixels)
        #expect(choice.pairCount(frameCount: total) <= pixels)
        let pairs = TrimmerPeakLOD.pairs(levels: levels, startFrame: 0, frameCount: total, pixels: pixels)
        #expect(pairs.count <= pixels)
        #expect(pairs.count >= 1)
    }

    let closest = TrimmerPeakLOD.choose(framesPerBucket: [64, 128, 512], frameCount: 10_000, pixels: 100)
    #expect(closest.levelIndex == 1)
    #expect(closest.pairCount(frameCount: 10_000) <= 100)
    // 96 buckets across 10,000 frames is a little more than one pair per pixel, so the next coarser level is used.
    let notFiner = TrimmerPeakLOD.choose(framesPerBucket: [64, 96, 256], frameCount: 10_000, pixels: 100)
    #expect(notFiner.levelIndex == 2)
    #expect(notFiner.pairCount(frameCount: 10_000) <= 100)

    let widened = TrimmerPeakLOD.choose(framesPerBucket: [32], frameCount: 10_000, pixels: 100)
    #expect(widened.framesPerPair >= 100)
    #expect(widened.pairCount(frameCount: 10_000) <= 100)

    let clock = ContinuousClock()
    let elapsed = clock.measure {
        _ = TrimmerPeakLOD.pairs(levels: levels, startFrame: 1_000_000, frameCount: 400_000, pixels: 1_600)
        _ = TrimmerPeakLOD.pairs(levels: levels, startFrame: 0, frameCount: total, pixels: 1_400)
    }
    #expect(elapsed < .milliseconds(50))
}
