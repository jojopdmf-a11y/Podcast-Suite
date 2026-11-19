import AVFoundation
import Foundation

public struct PodcastChapter: Equatable, Sendable {
    public var start: Double
    public var title: String

    public init(start: Double, title: String) {
        self.start = start
        self.title = title
    }
}

/// How marker times move when TheRoof's file is a different length from the source.
public struct PodcastChapterAlignment: Equatable, Sendable {
    public var offset: Double
    public var scale: Double

    /// A few milliseconds of encoder or converter padding is not a timeline shift.
    public static let unshiftedTolerance = 0.020

    public var isUnshifted: Bool {
        abs(offset) < 0.000_001 && abs(scale - 1) < 0.000_001
    }

    public init(offset: Double, scale: Double) {
        self.offset = offset
        self.scale = scale
    }

    /// `leadingOffset` is silence inserted before the original audio.
    /// When the rest of the file is the same length, times move by that offset.
    /// When the whole file is stretched, times scale to the new length.
    public static func make(
        sourceDuration: Double,
        outputDuration: Double,
        leadingOffset: Double
    ) -> PodcastChapterAlignment {
        let source = sourceDuration.isFinite ? max(0, sourceDuration) : 0
        let output = outputDuration.isFinite ? max(0, outputDuration) : 0
        let lead = leadingOffset.isFinite ? max(0, leadingOffset) : 0
        guard source > 0, output > 0 else {
            return PodcastChapterAlignment(offset: 0, scale: 1)
        }
        if lead <= unshiftedTolerance, abs(output - source) <= unshiftedTolerance {
            return PodcastChapterAlignment(offset: 0, scale: 1)
        }
        let content = max(0.000_001, output - lead)
        if abs(content - source) <= unshiftedTolerance {
            return PodcastChapterAlignment(offset: lead, scale: 1)
        }
        return PodcastChapterAlignment(offset: lead, scale: content / source)
    }

    public func map(_ time: Double) -> Double {
        let start = time.isFinite ? max(0, time) : 0
        return start * scale + offset
    }
}

/// TheRoof's offline limiter does not move the start of the audio.
/// Its 2 ms lookahead only decides the gain. The first sample written is the
/// first sample read, and the file keeps the same number of frames.
/// Sample-rate conversion on this path shifts an impulse by a sample or two
/// and keeps the length, which is inside `unshiftedTolerance`.
/// MP3 playback uses the gapless tag TheRoof already writes, so the heard
/// start stays on that same sample. Times stay exact unless the output
/// duration actually differs.
public enum RoofChapterClock {
    public static let limiterLeadingOffset = 0.0

    public static func map(sourceDuration: Double, outputDuration: Double) -> PodcastChapterAlignment {
        PodcastChapterAlignment.make(
            sourceDuration: sourceDuration,
            outputDuration: outputDuration,
            leadingOffset: limiterLeadingOffset
        )
    }
}

public enum AudioFileClock {
    public static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }
}

public enum PodcastChapters {
    public static func sidecarURL(forAudio url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent + " chapters.txt"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func load(beside audio: URL) -> [PodcastChapter]? {
        let url = sidecarURL(forAudio: audio)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let chapters = parse(String(decoding: data, as: UTF8.self))
        return chapters.isEmpty ? nil : chapters
    }

    /// `HH:MM:SS Title` lines, the same clock TheCut writes.
    public static func parse(_ text: String) -> [PodcastChapter] {
        var chapters: [PodcastChapter] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.isEmpty == false else { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let time = parseClock(String(parts[0])) else { continue }
            chapters.append(PodcastChapter(start: time, title: String(parts[1])))
        }
        return chapters
    }

    public static func sidecarText(_ chapters: [PodcastChapter]) -> String {
        let markers = chapters.map { TrimmerMarker(time: $0.start, title: $0.title) }
        return TrimmerChapters.text(markers: markers)
    }

    /// A marker this close to 0:00 already opens the episode.
    public static let openingGap = 0.5

    /// Adds "Intro" at 0:00 when the first marker is more than half a second in.
    /// A marker already at the start is left alone. Nothing is added at the end.
    public static func withOpeningIntro(_ chapters: [PodcastChapter]) -> [PodcastChapter] {
        guard chapters.isEmpty == false else { return chapters }
        let earliest = chapters.map(\.start).min() ?? 0
        if earliest <= openingGap { return chapters }
        return [PodcastChapter(start: 0, title: "Intro")] + chapters
    }

    public static func apply(
        _ chapters: [PodcastChapter],
        map: PodcastChapterAlignment,
        outputDuration: Double
    ) -> [PodcastChapter] {
        let limit = outputDuration.isFinite ? max(0, outputDuration) : 0
        return chapters.map { chapter in
            var start = map.map(chapter.start)
            if limit > 0 { start = min(start, limit) }
            return PodcastChapter(start: start, title: chapter.title)
        }
    }

    /// Writes the chapters beside `audio`. An unshifted map copies the original
    /// text file. A shifted map writes the corrected times in the same clock format.
    public static func write(
        _ chapters: [PodcastChapter],
        map: PodcastChapterAlignment,
        outputDuration: Double,
        beside audio: URL,
        originalSidecar: URL?
    ) throws {
        let prepared = withOpeningIntro(chapters)
        let destination = sidecarURL(forAudio: audio)
        if map.isUnshifted, let originalSidecar, FileManager.default.fileExists(atPath: originalSidecar.path) {
            let originalText = (try? String(contentsOf: originalSidecar, encoding: .utf8)) ?? ""
            if parse(originalText) == prepared {
                if originalSidecar.standardizedFileURL == destination.standardizedFileURL { return }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: originalSidecar, to: destination)
                return
            }
        }
        let aligned = apply(prepared, map: map, outputDuration: outputDuration)
        try Data(sidecarText(aligned).utf8).write(to: destination, options: .atomic)
    }

    private static func parseClock(_ text: String) -> Double? {
        let bits = text.split(separator: ":")
        guard bits.count == 3,
              let hours = Int(bits[0]),
              let minutes = Int(bits[1]),
              let seconds = Int(bits[2]),
              hours >= 0, minutes >= 0, seconds >= 0
        else { return nil }
        return Double(hours * 3600 + minutes * 60 + seconds)
    }
}

/// YouTube and Spotify description lines. Under an hour the clock is `MM:SS`.
/// An hour or longer uses `H:MM:SS`.
public enum PodcastTimestampList {
    public struct Result: Equatable, Sendable {
        public var text: String
        public var addedOpening: Bool
        public var note: String
    }

    public static func make(chapters: [PodcastChapter], episodeDuration: Double) -> Result {
        let sorted = chapters.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.title < rhs.title }
            return lhs.start < rhs.start
        }
        let span = episodeDuration.isFinite && episodeDuration > 0
            ? episodeDuration
            : (sorted.map(\.start).max() ?? 0)
        let hours = span >= 3_600
        var rows = sorted.map { (start: $0.start, title: displayTitle($0.title)) }
        var added = false
        if rows.isEmpty || stamp(rows[0].start, hours: hours) != stamp(0, hours: hours) {
            rows.insert((start: 0, title: "Intro"), at: 0)
            added = true
        }
        let lines = rows.map { "\(stamp($0.start, hours: hours)) \($0.title)" }
        let note = added
            ? (hours
                ? "YouTube needs the first chapter at the start, so the copied list begins with 0:00:00 Intro."
                : "YouTube needs the first chapter at the start, so the copied list begins with 00:00 Intro.")
            : ""
        return Result(text: lines.joined(separator: "\n") + "\n", addedOpening: added, note: note)
    }

    private static func displayTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Chapter" : trimmed
    }

    static func stamp(_ seconds: Double, hours: Bool) -> String {
        let total = max(0, Int((seconds.isFinite ? seconds : 0).rounded()))
        let hour = total / 3600
        let minute = (total % 3600) / 60
        let second = total % 60
        if hours {
            return String(format: "%d:%02d:%02d", hour, minute, second)
        }
        return String(format: "%02d:%02d", hour * 60 + minute, second)
    }
}

/// ID3v2.3 chapter tag. Apple Podcasts and Overcast both read CHAP plus a
/// top-level ordered CTOC from ID3v2.3. ID3v2.4 frame sizes are synchsafe and
/// older Apple builds skip those chapter frames, so this writer stays on 2.3.
public enum PodcastID3 {
    public static func tag(chapters: [PodcastChapter], duration: Double) -> Data {
        let sorted = chapters.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.title < rhs.title }
            return lhs.start < rhs.start
        }
        let usable = Array(sorted.prefix(255))
        guard usable.isEmpty == false else { return Data() }
        let fileEnd = duration.isFinite && duration > 0 ? duration : (usable.last?.start ?? 0)
        var frames = Data()
        frames.append(ctocFrame(count: usable.count))
        for index in usable.indices {
            let start = max(0, usable[index].start)
            let end: Double
            if index + 1 < usable.count {
                end = max(start, usable[index + 1].start)
            } else {
                end = max(start, fileEnd)
            }
            frames.append(chapFrame(index: index, title: usable[index].title, start: start, end: end))
        }
        var header = Data("ID3".utf8)
        header.append(3)
        header.append(0)
        header.append(0)
        header.append(contentsOf: synchsafe(frames.count))
        header.append(frames)
        return header
    }

    /// Prepends a chapter tag, replacing an ID3v2 tag already at the front of the file.
    public static func apply(chapters: [PodcastChapter], duration: Double, to url: URL) throws {
        let tag = tag(chapters: chapters, duration: duration)
        guard tag.isEmpty == false else { return }
        let original = try Data(contentsOf: url)
        let combined = tag + stripID3v2(original)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".chapters-\(UUID().uuidString).mp3")
        try combined.write(to: temporary, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func stripID3v2(_ data: Data) -> Data {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33
        else { return data }
        let size = unsynchsafe(data[6], data[7], data[8], data[9])
        var total = 10 + size
        if data[5] & 0x10 != 0 { total += 10 }
        guard total >= 10, total <= data.count else { return data }
        return data.subdata(in: total..<data.count)
    }

    private static func ctocFrame(count: Int) -> Data {
        var body = Data("toc".utf8)
        body.append(0)
        body.append(0x03)
        body.append(UInt8(count))
        for index in 0..<count {
            body.append(contentsOf: Data(elementID(index).utf8))
            body.append(0)
        }
        return frame("CTOC", body: body)
    }

    private static func chapFrame(index: Int, title: String, start: Double, end: Double) -> Data {
        var body = Data(elementID(index).utf8)
        body.append(0)
        body.append(u32(milliseconds(start)))
        body.append(u32(milliseconds(end)))
        body.append(u32(0xFFFF_FFFF))
        body.append(u32(0xFFFF_FFFF))
        body.append(titleFrame(title))
        return frame("CHAP", body: body)
    }

    private static func titleFrame(_ title: String) -> Data {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? "Chapter" : trimmed
        var body = Data([0x01, 0xFF, 0xFE])
        for unit in text.utf16 {
            body.append(UInt8(unit & 0xFF))
            body.append(UInt8(unit >> 8))
        }
        return frame("TIT2", body: body)
    }

    private static func elementID(_ index: Int) -> String {
        String(format: "ch%03d", index)
    }

    private static func frame(_ id: String, body: Data) -> Data {
        var data = Data(id.utf8)
        var size = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(0)
        data.append(0)
        data.append(body)
        return data
    }

    private static func u32(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 4)
    }

    private static func milliseconds(_ seconds: Double) -> UInt32 {
        let value = seconds.isFinite ? max(0, seconds) : 0
        let rounded = (value * 1000).rounded()
        if rounded >= Double(UInt32.max) { return UInt32.max }
        return UInt32(rounded)
    }

    private static func synchsafe(_ size: Int) -> [UInt8] {
        let value = max(0, size)
        return [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F),
        ]
    }

    private static func unsynchsafe(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Int {
        (Int(b0 & 0x7F) << 21) | (Int(b1 & 0x7F) << 14) | (Int(b2 & 0x7F) << 7) | Int(b3 & 0x7F)
    }
}
