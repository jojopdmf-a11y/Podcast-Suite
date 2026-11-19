import AVFoundation
import Foundation
import Testing
@testable import PodLoungeCore

private let rate = 48_000.0

private func clip(
    asset: String,
    track: TrimmerTrackID,
    start: Double = 0,
    length: Double = 1,
    fadeIn: Double = 0
) -> TrimmerClip {
    TrimmerClip(
        assetID: asset,
        track: track,
        start: start,
        inOffset: 0,
        length: length,
        fadeIn: fadeIn,
        sourceDuration: length
    )
}

private func sample(_ result: TrimmerRenderResult, frame: Int, channel: Int = 0) -> Float {
    let index = frame * 2 + channel
    guard result.stereo.indices.contains(index) else { return .nan }
    return result.stereo[index]
}

@Test func singleTrackRenderUsesThatTrackOnly() {
    let episode = clip(asset: "ep", track: .episodeMix)
    let bed = clip(asset: "bed", track: .musicBeds)
    var document = TrimmerDocument.empty.placing(episode).placing(bed)
    document = document.settingTrack(.episodeMix, muted: true)
    document = document.settingTrack(.musicBeds, solo: true, gainDB: -6)
    let sources = [
        "ep": TrimmerSourceAudio.constant(frames: 48_000, amplitude: 0.5, sampleRate: rate),
        "bed": TrimmerSourceAudio.constant(frames: 48_000, amplitude: 0.8, sampleRate: rate),
    ]
    let bedGain = TrimmerGain.linear(decibels: -6) * 0.8

    let full = TrimmerRenderer.render(document: document, sampleRate: rate, sources: sources, scope: .fullMix)
    let episodeOnly = TrimmerRenderer.render(document: document, sampleRate: rate, sources: sources, scope: .episodeMix)
    let bedOnly = TrimmerRenderer.render(document: document, sampleRate: rate, sources: sources, scope: .musicBeds)

    #expect(abs(sample(full, frame: 2_000) - bedGain) < 0.002)
    #expect(abs(sample(episodeOnly, frame: 2_000) - 0.5) < 0.002)
    #expect(abs(sample(episodeOnly, frame: 2_000, channel: 1) - 0.5) < 0.002)
    #expect(abs(sample(bedOnly, frame: 2_000) - bedGain) < 0.002)

    var mutedBed = document.settingTrack(.musicBeds, muted: true, solo: false, gainDB: 0)
    mutedBed = mutedBed.settingTrack(.episodeMix, muted: false, solo: true, gainDB: 0)
    let exportedBed = TrimmerRenderer.render(document: mutedBed, sampleRate: rate, sources: sources, scope: .musicBeds)
    #expect(abs(sample(exportedBed, frame: 2_000) - 0.8) < 0.002)

    let faded = TrimmerDocument.empty.placing(clip(asset: "ep", track: .episodeMix, fadeIn: 1))
        .placing(clip(asset: "bed", track: .musicBeds))
    let fadeMix = TrimmerRenderer.render(document: faded, sampleRate: rate, sources: sources, scope: .episodeMix)
    #expect(abs(sample(fadeMix, frame: 0)) < 0.02)
    #expect(sample(fadeMix, frame: 40_000) > 0.4)
    #expect(sample(fadeMix, frame: 2_000) < 0.1)
}

@Test func monoRulePicksTheFileChannelCount() throws {
    let episode = clip(asset: "voice", track: .episodeMix)
    let bed = clip(asset: "bed", track: .musicBeds)
    let document = TrimmerDocument.empty.placing(episode).placing(bed)
    let monoCounts = ["voice": 1, "bed": 1]
    #expect(TrimmerExportPlan.channelCount(scope: .fullMix, document: document, channelCounts: monoCounts) == 2)
    #expect(TrimmerExportPlan.channelCount(scope: .episodeMix, document: document, channelCounts: monoCounts) == 1)
    #expect(TrimmerExportPlan.channelCount(scope: .musicBeds, document: document, channelCounts: ["voice": 1, "bed": 2]) == 2)
    #expect(TrimmerExportPlan.channelCount(scope: .episodeMix, document: document, channelCounts: [:]) == 2)

    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let sources = [
        "voice": TrimmerSourceAudio.constant(frames: 4_800, amplitude: 0.4, sampleRate: rate),
        "bed": TrimmerSourceAudio(
            sampleRate: rate,
            stereo: Array(repeating: [Float(0.2), Float(0.7)], count: 4_800).flatMap { $0 }
        ),
    ]
    let monoRender = TrimmerRenderer.render(
        document: document,
        sampleRate: rate,
        sources: sources,
        scope: .episodeMix
    )
    let monoURL = scratch.root.appendingPathComponent("voice-cut.wav")
    try TrimmerWAV.write(
        interleaved: TrimmerExportPlan.leftChannel(monoRender.stereo),
        channels: 1,
        sampleRate: rate,
        depth: .int24,
        to: monoURL
    )
    let monoFile = try AVAudioFile(forReading: monoURL)
    // TheDecks uses processingFormat.channelCount. One channel is a speaker strip.
    #expect(monoFile.processingFormat.channelCount == 1)
    #expect(monoFile.fileFormat.channelCount == 1)
    let monoRead = try TrimmerWAV.readContents(from: monoURL)
    #expect(monoRead.channels == 1)
    #expect(abs(monoRead.interleaved[100] - 0.4) < 0.001)

    let floatURL = scratch.root.appendingPathComponent("voice-float.wav")
    let rewritten = scratch.root.appendingPathComponent("voice-24.wav")
    try TrimmerWAV.write(
        interleaved: TrimmerExportPlan.leftChannel(monoRender.stereo),
        channels: 1,
        sampleRate: rate,
        depth: .float32,
        to: floatURL
    )
    try TrimmerWAV.rewrite(from: floatURL, to: rewritten, depth: .int24)
    let rewrittenFile = try AVAudioFile(forReading: rewritten)
    #expect(rewrittenFile.processingFormat.channelCount == 1)

    let stereoRender = TrimmerRenderer.render(
        document: document,
        sampleRate: rate,
        sources: sources,
        scope: .musicBeds
    )
    let stereoURL = scratch.root.appendingPathComponent("bed-cut.wav")
    try TrimmerWAV.write(stereo: stereoRender.stereo, sampleRate: rate, depth: .int24, to: stereoURL)
    let stereoFile = try AVAudioFile(forReading: stereoURL)
    #expect(stereoFile.processingFormat.channelCount == 2)
    #expect(stereoFile.fileFormat.channelCount == 2)
    let stereoRead = try TrimmerWAV.read(from: stereoURL)
    #expect(abs(stereoRead.stereo[200] - 0.2) < 0.001)
    #expect(abs(stereoRead.stereo[201] - 0.7) < 0.001)

    let mixURL = scratch.root.appendingPathComponent("full-cut.wav")
    let full = TrimmerRenderer.render(document: document, sampleRate: rate, sources: sources, scope: .fullMix)
    try TrimmerWAV.write(stereo: full.stereo, sampleRate: rate, depth: .int24, to: mixURL)
    let mixFile = try AVAudioFile(forReading: mixURL)
    #expect(mixFile.fileFormat.channelCount == 2)
}

@Test func exportNamesUseTheTrackTitleAndValetNumbering() throws {
    #expect(TrimmerExportPlan.displayName(episode: "Show", scope: .fullMix) == "Show \u{2013} Cut")
    #expect(TrimmerExportPlan.displayName(episode: "Show", scope: .episodeMix) == "Show \u{2013} Episode Mix Cut")
    #expect(
        TrimmerExportPlan.displayName(episode: "Show", scope: .introsOutrosAds)
            == "Show \u{2013} Intros · Outros · Ads Cut"
    )
    #expect(TrimmerExportPlan.displayName(episode: "Show", scope: .musicBeds) == "Show \u{2013} Music Beds Cut")
    #expect(TrimmerExportPlan.displayName(episode: "  ", scope: .fullMix) == "Episode \u{2013} Cut")
    #expect(TrimmerExportPlan.includesChapters(.fullMix))
    #expect(TrimmerExportPlan.includesChapters(.episodeMix) == false)
    #expect(TrimmerExportPlan.includesChapters(.musicBeds) == false)

    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let wav = scratch.root.appendingPathComponent("tone.wav")
    try TrimmerWAV.write(stereo: [0.1, 0.1, 0.1, 0.1], sampleRate: rate, depth: .int24, to: wav)
    let folder = scratch.root.appendingPathComponent("Show.podlounge")
    let package = try ProjectPackage.create(at: folder, name: "Show")
    let name = TrimmerExportPlan.displayName(episode: "Show", scope: .fullMix)
    let first = try package.importResult(from: wav, producedBy: "trimmer", displayName: name)
    let second = try package.importResult(from: wav, producedBy: "trimmer", displayName: name)
    #expect(first.relativePath.hasSuffix("Show \u{2013} Cut.wav"))
    #expect(second.relativePath.hasSuffix("Show \u{2013} Cut 2.wav"))
}

@Test func timestampListFormatsHoursAndAddsTheOpeningLine() {
    let under = PodcastTimestampList.make(
        chapters: [
            PodcastChapter(start: 0, title: "Intro"),
            PodcastChapter(start: 65, title: "Interview"),
        ],
        episodeDuration: 120
    )
    #expect(under.addedOpening == false)
    #expect(under.text == "00:00 Intro\n01:05 Interview\n")

    let over = PodcastTimestampList.make(
        chapters: [
            PodcastChapter(start: 0, title: "Intro"),
            PodcastChapter(start: 3_661, title: "Later"),
        ],
        episodeDuration: 3_700
    )
    #expect(over.addedOpening == false)
    #expect(over.text == "0:00:00 Intro\n1:01:01 Later\n")

    let added = PodcastTimestampList.make(
        chapters: [PodcastChapter(start: 65, title: "Interview")],
        episodeDuration: 200
    )
    #expect(added.addedOpening)
    #expect(added.text == "00:00 Intro\n01:05 Interview\n")
    #expect(added.note.contains("00:00 Intro"))

    let addedHour = PodcastTimestampList.make(
        chapters: [PodcastChapter(start: 3_700, title: "Wrap")],
        episodeDuration: 4_000
    )
    #expect(addedHour.addedOpening)
    #expect(addedHour.text.hasPrefix("0:00:00 Intro\n"))
}

@Test func chapterTimesStayPutUnlessTheFileActuallyShifts() {
    let same = RoofChapterClock.map(sourceDuration: 180, outputDuration: 180)
    #expect(same.isUnshifted)
    #expect(RoofChapterClock.limiterLeadingOffset == 0)
    let padded = PodcastChapterAlignment.make(sourceDuration: 100, outputDuration: 100.01, leadingOffset: 0)
    #expect(padded.isUnshifted)
    #expect(abs(padded.map(12) - 12) < 0.000_1)

    let delayed = PodcastChapterAlignment.make(sourceDuration: 100, outputDuration: 100.5, leadingOffset: 0.5)
    #expect(abs(delayed.offset - 0.5) < 0.000_1)
    #expect(abs(delayed.scale - 1) < 0.000_1)
    #expect(abs(delayed.map(10) - 10.5) < 0.000_1)

    let stretched = PodcastChapterAlignment.make(sourceDuration: 100, outputDuration: 200, leadingOffset: 0)
    #expect(abs(stretched.scale - 2) < 0.000_1)
    #expect(abs(stretched.map(10) - 20) < 0.000_1)

    let aligned = PodcastChapters.apply(
        [PodcastChapter(start: 10, title: "Talk"), PodcastChapter(start: 40, title: "End")],
        map: delayed,
        outputDuration: 100.5
    )
    #expect(abs(aligned[0].start - 10.5) < 0.000_1)
    #expect(abs(aligned[1].start - 40.5) < 0.000_1)
}

@Test func id3ChaptersRoundTripToTheSameTimesAndTitles() throws {
    let chapters = [
        PodcastChapter(start: 65.5, title: "Interview"),
        PodcastChapter(start: 0, title: "Intro"),
        PodcastChapter(start: 125, title: "Caf\u{00e9}"),
    ]
    let tag = PodcastID3.tag(chapters: chapters, duration: 180)
    let read = try readID3Chapters(tag)
    #expect(read.version == 3)
    #expect(read.topLevelOrdered)
    #expect(read.childIDs == read.chapters.map(\.id))
    #expect(read.chapters.map(\.title) == ["Intro", "Interview", "Caf\u{00e9}"])
    #expect(read.chapters.map(\.start) == [0, 65.5, 125])
    #expect(read.chapters.map(\.end) == [65.5, 125, 180])

    let shifted = PodcastChapters.apply(
        [PodcastChapter(start: 10, title: "Talk")],
        map: PodcastChapterAlignment.make(sourceDuration: 100, outputDuration: 100.5, leadingOffset: 0.5),
        outputDuration: 100.5
    )
    let shiftedTag = PodcastID3.tag(chapters: shifted, duration: 100.5)
    let shiftedRead = try readID3Chapters(shiftedTag)
    #expect(shiftedRead.chapters.count == 1)
    #expect(abs(shiftedRead.chapters[0].start - 10.5) < 0.001)
    #expect(abs(shiftedRead.chapters[0].end - 100.5) < 0.001)

    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let mpeg = Data([0xFF, 0xFB, 0x90, 0x64])
    let url = scratch.root.appendingPathComponent("show.mp3")
    try (tag + mpeg).write(to: url)
    let replacement = [PodcastChapter(start: 1, title: "One")]
    try PodcastID3.apply(chapters: replacement, duration: 4, to: url)
    let stored = try Data(contentsOf: url)
    #expect(stored.suffix(4) == mpeg)
    let replaced = try readID3Chapters(stored)
    #expect(replaced.chapters.map(\.title) == ["One"])
    #expect(replaced.chapters.map(\.start) == [1])
    #expect(replaced.chapters.map(\.end) == [4])
    let after = PodcastID3.stripID3v2(stored)
    #expect(after == mpeg)
}

@Test func openingIntroIsAddedOnlyWhenTheFirstMarkerIsLate() throws {
    #expect(PodcastChapters.withOpeningIntro([]) == [])
    let atStart = [PodcastChapter(start: 0, title: "Cold open")]
    #expect(PodcastChapters.withOpeningIntro(atStart) == atStart)
    let close = [PodcastChapter(start: 0.5, title: "Cold open")]
    #expect(PodcastChapters.withOpeningIntro(close) == close)
    let late = [
        PodcastChapter(start: 12.2, title: "Talk"),
        PodcastChapter(start: 40, title: "Wrap"),
    ]
    let opened = PodcastChapters.withOpeningIntro(late)
    #expect(opened.map(\.title) == ["Intro", "Talk", "Wrap"])
    #expect(opened.map(\.start) == [0, 12.2, 40])
    #expect(PodcastChapters.withOpeningIntro(opened) == opened)

    let list = PodcastTimestampList.make(chapters: opened, episodeDuration: 90)
    #expect(list.addedOpening == false)
    #expect(list.text.hasPrefix("00:00 Intro\n"))
    #expect(list.note.isEmpty)

    let tag = PodcastID3.tag(chapters: opened, duration: 90)
    let read = try readID3Chapters(tag)
    #expect(read.chapters.map(\.title) == ["Intro", "Talk", "Wrap"])
    #expect(read.chapters.map(\.start) == [0, 12.2, 40])
    #expect(read.chapters.map(\.end) == [12.2, 40, 90])

    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let audio = scratch.root.appendingPathComponent("show.mp3")
    try Data([0xFF, 0xFB, 0x90, 0x64]).write(to: audio)
    let sidecar = PodcastChapters.sidecarURL(forAudio: audio)
    try Data("00:00:12 Talk\n00:00:40 Wrap\n".utf8).write(to: sidecar)
    try PodcastChapters.write(
        late,
        map: PodcastChapterAlignment(offset: 0, scale: 1),
        outputDuration: 90,
        beside: audio,
        originalSidecar: sidecar
    )
    let written = try String(contentsOf: sidecar, encoding: .utf8)
    #expect(written.hasPrefix("00:00:00 Intro\n"))
    #expect(written.contains("Talk"))
    #expect(written.contains("Wrap"))
    #expect(written.contains("End") == false)

    try Data("00:00:00 Cold open\n".utf8).write(to: sidecar)
    try PodcastChapters.write(
        atStart,
        map: PodcastChapterAlignment(offset: 0, scale: 1),
        outputDuration: 90,
        beside: audio,
        originalSidecar: sidecar
    )
    #expect(try String(contentsOf: sidecar, encoding: .utf8) == "00:00:00 Cold open\n")
}

private struct ReadID3 {
    var version: Int
    var topLevelOrdered: Bool
    var childIDs: [String]
    var chapters: [ReadChapter]
}

private struct ReadChapter {
    var id: String
    var start: Double
    var end: Double
    var title: String
}

private func readID3Chapters(_ data: Data) throws -> ReadID3 {
    let bytes = [UInt8](data)
    guard bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else {
        throw TestError("missing ID3")
    }
    let version = Int(bytes[3])
    let size = synchsafe(bytes[6], bytes[7], bytes[8], bytes[9])
    var cursor = 10
    let end = min(bytes.count, 10 + size)
    var topLevelOrdered = false
    var childIDs: [String] = []
    var chapters: [ReadChapter] = []
    while cursor + 10 <= end {
        let id = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
        let frameSize = Int(be32(bytes, cursor + 4))
        let body = cursor + 10
        guard frameSize >= 0, body + frameSize <= end else { throw TestError("bad frame \(id)") }
        if id == "CTOC" {
            var local = body
            _ = cstring(bytes, &local, limit: body + frameSize)
            guard local < body + frameSize else { throw TestError("short CTOC") }
            let flags = bytes[local]
            local += 1
            topLevelOrdered = flags & 0x03 == 0x03
            guard local < body + frameSize else { throw TestError("short CTOC") }
            let count = Int(bytes[local])
            local += 1
            for _ in 0..<count {
                childIDs.append(cstring(bytes, &local, limit: body + frameSize))
            }
        } else if id == "CHAP" {
            var local = body
            let element = cstring(bytes, &local, limit: body + frameSize)
            guard local + 16 <= body + frameSize else { throw TestError("short CHAP") }
            let start = Double(be32(bytes, local)) / 1000
            let stop = Double(be32(bytes, local + 4)) / 1000
            local += 16
            var title = ""
            while local + 10 <= body + frameSize {
                let subID = String(bytes: bytes[local..<(local + 4)], encoding: .ascii) ?? ""
                let subSize = Int(be32(bytes, local + 4))
                let sub = local + 10
                guard subSize >= 0, sub + subSize <= body + frameSize else { break }
                if subID == "TIT2" {
                    title = decodeText(bytes, start: sub, count: subSize)
                }
                local = sub + subSize
            }
            chapters.append(ReadChapter(id: element, start: start, end: stop, title: title))
        }
        cursor = body + frameSize
    }
    return ReadID3(version: version, topLevelOrdered: topLevelOrdered, childIDs: childIDs, chapters: chapters)
}

private func decodeText(_ bytes: [UInt8], start: Int, count: Int) -> String {
    guard count > 0 else { return "" }
    let encoding = bytes[start]
    let text = bytes[(start + 1)..<(start + count)]
    if encoding == 1 {
        var units = Array(text)
        if units.count >= 2, units[0] == 0xFF, units[1] == 0xFE {
            units.removeFirst(2)
        }
        var code: [UInt16] = []
        var index = 0
        while index + 1 < units.count {
            code.append(UInt16(units[index]) | (UInt16(units[index + 1]) << 8))
            index += 2
        }
        return String(utf16CodeUnits: code, count: code.count)
    }
    return String(bytes: text, encoding: .isoLatin1) ?? ""
}

private func cstring(_ bytes: [UInt8], _ cursor: inout Int, limit: Int) -> String {
    var end = cursor
    while end < limit, bytes[end] != 0 { end += 1 }
    let text = String(bytes: bytes[cursor..<end], encoding: .ascii) ?? ""
    cursor = min(limit, end + 1)
    return text
}

private func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (UInt32(bytes[offset]) << 24)
        | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8)
        | UInt32(bytes[offset + 3])
}

private func synchsafe(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Int {
    (Int(b0 & 0x7F) << 21) | (Int(b1 & 0x7F) << 14) | (Int(b2 & 0x7F) << 7) | Int(b3 & 0x7F)
}

private struct TestError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}
