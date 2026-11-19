import Foundation

/// The three stereo lanes in TheCut, top to bottom.
public enum TrimmerTrackID: String, Codable, CaseIterable, Identifiable, Sendable {
    case episodeMix
    case introsOutrosAds
    case musicBeds

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .episodeMix: "Episode Mix"
        case .introsOutrosAds: "Intros · Outros · Ads"
        case .musicBeds: "Music Beds"
        }
    }

    public static let defaultStates: [TrimmerTrackID: TrimmerTrackState] = {
        var states: [TrimmerTrackID: TrimmerTrackState] = [:]
        for track in TrimmerTrackID.allCases {
            states[track] = TrimmerTrackState()
        }
        return states
    }()
}

public struct TrimmerTrackState: Codable, Equatable, Sendable {
    public var muted: Bool
    public var solo: Bool
    /// Track fader. 0 is unity.
    public var gainDB: Double

    public init(muted: Bool = false, solo: Bool = false, gainDB: Double = 0) {
        self.muted = muted
        self.solo = solo
        self.gainDB = gainDB
    }
}

public struct TrimmerClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var assetID: String
    public var track: TrimmerTrackID
    /// Timeline position, in seconds.
    public var start: Double
    /// Seconds into the depot file where this clip begins.
    public var inOffset: Double
    public var length: Double
    public var fadeIn: Double
    public var fadeOut: Double
    /// Clip gain. The track fader is separate. 0 is unity.
    public var gainDB: Double
    /// File length when the clip was placed, so a trim can stop at the file's end.
    public var sourceDuration: Double?

    public init(
        id: UUID = UUID(),
        assetID: String,
        track: TrimmerTrackID,
        start: Double,
        inOffset: Double,
        length: Double,
        fadeIn: Double = 0,
        fadeOut: Double = 0,
        gainDB: Double = 0,
        sourceDuration: Double? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.track = track
        self.start = start
        self.inOffset = inOffset
        self.length = length
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.gainDB = gainDB
        self.sourceDuration = sourceDuration
    }

    public var end: Double { start + length }

    public func contains(_ time: Double, margin: Double = 0) -> Bool {
        time >= start + margin && time < end - margin
    }
}

public struct TrimmerMarker: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: Double
    public var title: String

    public init(id: UUID = UUID(), time: Double, title: String) {
        self.id = id
        self.time = time
        self.title = title
    }
}

public struct TrimmerTimeRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        if end < start {
            self.start = end
            self.end = start
        } else {
            self.start = start
            self.end = end
        }
    }

    public var length: Double { max(0, end - start) }

    public func covers(_ clip: TrimmerClip, epsilon: Double = TrimmerDocument.epsilon) -> Bool {
        clip.start >= start - epsilon && clip.end <= end + epsilon
    }
}

public enum TrimmerEdge: Equatable, Sendable {
    case start
    case end
}

public enum TrimmerFadeEdge: Equatable, Sendable {
    case fadeIn
    case fadeOut
}

public enum TrimmerDeleteMode: Equatable, Sendable {
    case closeGap
    case leaveGap
}

/// What Delete should do before it changes the timeline.
public enum TrimmerDeletePlan: Equatable, Sendable {
    case nothing
    /// A whole clip with nothing after it on its track. No dialog.
    case removeClips(ids: [UUID])
    case choose(range: TrimmerTimeRange, track: TrimmerTrackID)
}

/// Edits for one episode. Times are seconds. Missing `workspaces/trimmer.json` is an empty cut.
public struct TrimmerDocument: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    public static let epsilon = 0.000_05
    public static let minimumLength = 0.05
    public static let defaultFade: Double = 0.5

    public var formatVersion: Int
    public var clips: [TrimmerClip]
    public var tracks: [TrimmerTrackID: TrimmerTrackState]
    public var markers: [TrimmerMarker]

    public init(
        formatVersion: Int = TrimmerDocument.formatVersion,
        clips: [TrimmerClip],
        tracks: [TrimmerTrackID: TrimmerTrackState],
        markers: [TrimmerMarker]
    ) {
        self.formatVersion = formatVersion
        self.clips = clips
        self.tracks = tracks
        self.markers = markers
    }

    public static let empty = TrimmerDocument(
        clips: [],
        tracks: TrimmerTrackID.defaultStates,
        markers: []
    )

    public var timelineEnd: Double {
        let clipEnd = clips.map(\.end).max() ?? 0
        let markerEnd = markers.map(\.time).max() ?? 0
        return max(clipEnd, markerEnd)
    }

    public func trackState(_ track: TrimmerTrackID) -> TrimmerTrackState {
        tracks[track] ?? TrimmerTrackState()
    }

    /// A muted track is silent. If any track is solo, only soloed tracks play.
    public func isAudible(_ track: TrimmerTrackID) -> Bool {
        let state = trackState(track)
        if state.muted { return false }
        let anySolo = TrimmerTrackID.allCases.contains { trackState($0).solo }
        if anySolo { return state.solo }
        return true
    }

    public func clip(_ id: UUID) -> TrimmerClip? {
        clips.first { $0.id == id }
    }

    public static func load(from url: URL) -> TrimmerDocument {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return .empty }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "{}" { return .empty }
        guard let document = try? decode(data) else { return .empty }
        return document
    }

    public static func decode(_ data: Data) throws -> TrimmerDocument {
        let decoder = JSONDecoder()
        let document = try decoder.decode(TrimmerDocument.self, from: data)
        return document.normalized()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var text = String(decoding: try encoder.encode(normalized()), as: UTF8.self)
        if !text.hasSuffix("\n") { text += "\n" }
        return Data(text.utf8)
    }

    public func normalized() -> TrimmerDocument {
        var copy = self
        copy.formatVersion = Self.formatVersion
        var states = TrimmerTrackID.defaultStates
        for track in TrimmerTrackID.allCases {
            if let existing = tracks[track] {
                states[track] = existing
            }
        }
        copy.tracks = states
        copy.clips = clips.map { clip in
            var clip = clip
            clip.length = max(Self.minimumLength, clip.length)
            clip.start = max(0, clip.start)
            clip.inOffset = max(0, clip.inOffset)
            clip.fadeIn = min(max(0, clip.fadeIn), clip.length)
            clip.fadeOut = min(max(0, clip.fadeOut), clip.length)
            return clip
        }
        copy.markers = markers.map { marker in
            var marker = marker
            marker.time = max(0, marker.time)
            return marker
        }
        return copy
    }

    // MARK: - Edits

    public func placing(_ clip: TrimmerClip) -> TrimmerDocument {
        var copy = self
        var clip = clip
        clip.start = max(0, clip.start)
        clip.inOffset = max(0, clip.inOffset)
        clip.length = max(Self.minimumLength, clip.length)
        copy.clips.append(clip)
        return copy
    }

    public func splitting(clipID: UUID, at time: Double) -> TrimmerDocument {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return self }
        let clip = clips[index]
        let margin = Self.minimumLength
        guard time >= clip.start + margin, time <= clip.end - margin else { return self }
        let leftLength = time - clip.start
        let rightLength = clip.end - time
        var left = clip
        left.length = leftLength
        left.fadeIn = min(clip.fadeIn, leftLength)
        left.fadeOut = 0
        var right = clip
        right.id = UUID()
        right.start = time
        right.inOffset = clip.inOffset + leftLength
        right.length = rightLength
        right.fadeIn = 0
        right.fadeOut = min(clip.fadeOut, rightLength)
        var copy = self
        copy.clips[index] = left
        copy.clips.insert(right, at: index + 1)
        return copy
    }

    public func moving(clipID: UUID, toStart: Double, track: TrimmerTrackID) -> TrimmerDocument {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return self }
        var copy = self
        copy.clips[index].track = track
        copy.clips[index].start = max(0, toStart)
        return copy
    }

    public func trimming(clipID: UUID, edge: TrimmerEdge, to time: Double) -> TrimmerDocument {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return self }
        var clip = clips[index]
        switch edge {
        case .start:
            var newStart = time
            let latest = clip.end - Self.minimumLength
            newStart = min(newStart, latest)
            let delta = newStart - clip.start
            var newIn = clip.inOffset + delta
            if newIn < 0 {
                newStart -= newIn
                newIn = 0
            }
            if let source = clip.sourceDuration {
                let latestIn = max(0, source - Self.minimumLength)
                if newIn > latestIn {
                    let overflow = newIn - latestIn
                    newIn = latestIn
                    newStart -= overflow
                }
            }
            newStart = max(0, newStart)
            let newLength = clip.end - newStart
            guard newLength >= Self.minimumLength - 0.000_000_1 else { return self }
            clip.start = newStart
            clip.inOffset = max(0, newIn)
            clip.length = newLength
        case .end:
            var newEnd = max(time, clip.start + Self.minimumLength)
            if let source = clip.sourceDuration {
                let limit = clip.start + max(Self.minimumLength, source - clip.inOffset)
                newEnd = min(newEnd, limit)
            }
            clip.length = max(Self.minimumLength, newEnd - clip.start)
        }
        // A trim changes only this clip. The neighbor is left where it is, so a gap can open.
        fittingFades(on: &clip)
        var copy = self
        copy.clips[index] = clip
        return copy
    }

    /// Keeps fade-in and fade-out from crossing. A fade already stored that way (an older edit) is left alone until the next fade drag.
    public func settingFade(clipID: UUID, edge: TrimmerFadeEdge, seconds: Double) -> TrimmerDocument {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return self }
        var copy = self
        var clip = copy.clips[index]
        let asked = max(0, seconds)
        switch edge {
        case .fadeIn:
            clip.fadeIn = min(asked, max(0, clip.length - max(0, clip.fadeOut)))
        case .fadeOut:
            clip.fadeOut = min(asked, max(0, clip.length - max(0, clip.fadeIn)))
        }
        copy.clips[index] = clip
        return copy
    }

    /// Shrinks the two fades together when a shorter clip can no longer hold both.
    private func fittingFades(on clip: inout TrimmerClip) {
        clip.fadeIn = max(0, clip.fadeIn)
        clip.fadeOut = max(0, clip.fadeOut)
        let sum = clip.fadeIn + clip.fadeOut
        guard sum > clip.length else { return }
        guard clip.length > 0, sum > 0 else {
            clip.fadeIn = 0
            clip.fadeOut = 0
            return
        }
        let scale = clip.length / sum
        clip.fadeIn *= scale
        clip.fadeOut *= scale
    }

    public func applyingDefaultFades(clipID: UUID) -> TrimmerDocument {
        guard let clip = clip(clipID) else { return self }
        let seconds = min(Self.defaultFade, clip.length / 2)
        return settingFade(clipID: clipID, edge: .fadeIn, seconds: seconds)
            .settingFade(clipID: clipID, edge: .fadeOut, seconds: seconds)
    }

    public func settingTrack(
        _ track: TrimmerTrackID,
        muted: Bool? = nil,
        solo: Bool? = nil,
        gainDB: Double? = nil
    ) -> TrimmerDocument {
        var copy = self
        var state = copy.trackState(track)
        if let muted { state.muted = muted }
        if let solo { state.solo = solo }
        if let gainDB { state.gainDB = min(12, max(-60, gainDB)) }
        copy.tracks[track] = state
        return copy
    }

    public func removingClips(ids: [UUID]) -> TrimmerDocument {
        let drop = Set(ids)
        guard !drop.isEmpty else { return self }
        var copy = self
        copy.clips.removeAll { drop.contains($0.id) }
        return copy
    }

    /// Whole-clip delete skips the dialog when nothing on that track extends past the clip.
    public func planDelete(clipID: UUID) -> TrimmerDeletePlan {
        guard let clip = clip(clipID) else { return .nothing }
        let later = clips.contains { other in
            other.id != clip.id && other.track == clip.track && other.end > clip.end + Self.epsilon
        }
        if later {
            return .choose(range: TrimmerTimeRange(start: clip.start, end: clip.end), track: clip.track)
        }
        return .removeClips(ids: [clip.id])
    }

    /// A time-range delete that hits audio always asks, including a range inside one clip.
    public func planDelete(range: TrimmerTimeRange, on track: TrimmerTrackID) -> TrimmerDeletePlan {
        guard range.length > Self.epsilon else { return .nothing }
        let hits = clips.contains { clip in
            clip.track == track && clip.end > range.start + Self.epsilon && clip.start < range.end - Self.epsilon
        }
        if !hits { return .nothing }
        return .choose(range: range, track: track)
    }

    public func deleting(range: TrimmerTimeRange, on track: TrimmerTrackID, mode: TrimmerDeleteMode) -> TrimmerDocument {
        guard range.length > Self.epsilon else { return self }
        let cut = range.length
        var kept: [TrimmerClip] = []
        for clip in clips {
            if clip.track != track {
                var other = clip
                if mode == .closeGap, other.start >= range.end - Self.epsilon {
                    other.start = max(0, other.start - cut)
                }
                kept.append(other)
                continue
            }
            if clip.end <= range.start + Self.epsilon {
                kept.append(clip)
                continue
            }
            if clip.start >= range.end - Self.epsilon {
                var later = clip
                if mode == .closeGap {
                    later.start = max(0, later.start - cut)
                }
                kept.append(later)
                continue
            }
            if clip.start < range.start - Self.epsilon {
                var left = clip
                left.length = range.start - clip.start
                left.fadeOut = 0
                left.fadeIn = min(left.fadeIn, left.length)
                if left.length >= Self.minimumLength {
                    kept.append(left)
                }
            }
            if clip.end > range.end + Self.epsilon {
                var right = clip
                let skipped = range.end - clip.start
                right.inOffset = clip.inOffset + skipped
                right.length = clip.end - range.end
                right.start = mode == .closeGap ? range.start : range.end
                right.fadeIn = 0
                right.fadeOut = min(clip.fadeOut, right.length)
                if right.length >= Self.minimumLength {
                    kept.append(right)
                }
            }
        }
        var copy = self
        copy.clips = kept
        if mode == .closeGap {
            copy.markers = markers.compactMap { marker in
                if marker.time >= range.end - Self.epsilon {
                    var moved = marker
                    moved.time = max(0, marker.time - cut)
                    return moved
                }
                if marker.time >= range.start - Self.epsilon && marker.time < range.end - Self.epsilon {
                    return nil
                }
                return marker
            }
        }
        return copy
    }

    public func addingMarker(at time: Double, title: String) -> TrimmerDocument {
        var copy = self
        copy.markers.append(TrimmerMarker(time: max(0, time), title: title))
        return copy
    }

    public func renamingMarker(id: UUID, title: String) -> TrimmerDocument {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return self }
        var copy = self
        copy.markers[index].title = title
        return copy
    }

    public func movingMarker(id: UUID, to time: Double) -> TrimmerDocument {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return self }
        var copy = self
        copy.markers[index].time = max(0, time)
        return copy
    }

    public func removingMarkers(ids: [UUID]) -> TrimmerDocument {
        let drop = Set(ids)
        guard !drop.isEmpty else { return self }
        var copy = self
        copy.markers.removeAll { drop.contains($0.id) }
        return copy
    }

    public func suggestedChapterTitle() -> String {
        let existing = Set(markers.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) })
        if !existing.contains("Chapter") { return "Chapter" }
        var number = 2
        while existing.contains("Chapter \(number)") {
            number += 1
        }
        return "Chapter \(number)"
    }
}

extension TrimmerDocument {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case clips
        case tracks
        case markers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 0
        if version != Self.formatVersion {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported trimmer document version \(version)."
            )
        }
        formatVersion = version
        clips = try container.decodeIfPresent([TrimmerClip].self, forKey: .clips) ?? []
        tracks = try container.decodeIfPresent([TrimmerTrackID: TrimmerTrackState].self, forKey: .tracks) ?? [:]
        markers = try container.decodeIfPresent([TrimmerMarker].self, forKey: .markers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(clips, forKey: .clips)
        try container.encode(tracks, forKey: .tracks)
        try container.encode(markers, forKey: .markers)
    }
}

/// One undo step per edit. The window's UndoManager is used by the app; tests use a private one.
@MainActor
public final class TrimmerEditor: ObservableObject {
    @Published public private(set) var document: TrimmerDocument
    public var undoManager: UndoManager

    public init(document: TrimmerDocument = .empty, undoManager: UndoManager? = nil) {
        self.document = document
        if let undoManager {
            self.undoManager = undoManager
        } else {
            let manager = UndoManager()
            manager.groupsByEvent = false
            self.undoManager = manager
        }
    }

    public func replace(_ document: TrimmerDocument, clearUndo: Bool) {
        self.document = document.normalized()
        if clearUndo {
            undoManager.removeAllActions()
        }
    }

    public func edit(_ label: String, _ mutate: (inout TrimmerDocument) -> Void) {
        var copy = document
        mutate(&copy)
        apply(label: label, copy)
    }

    public func apply(label: String, _ next: TrimmerDocument) {
        let before = document
        let after = next.normalized()
        guard after != before else { return }
        document = after
        // A private undo manager has no open event group. The window's manager
        // already opened one for the click, and undo() opens one for the redo.
        let openGroup = undoManager.groupingLevel == 0
        if openGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { editor in
            editor.apply(label: label, before)
        }
        undoManager.setActionName(label)
        if openGroup { undoManager.endUndoGrouping() }
    }
}

/// What Fit shows, and how far minus is allowed to zoom out.
public enum TrimmerViewport: Sendable {
    /// Empty seconds after the last clip.
    public static let margin = 1.0
    /// Points kept clear on the right so the last clip is not cut off by the window edge.
    public static let edgePadding = 16.0
    /// Ruler span when TheCut has no clips yet.
    public static let emptySpan = 30.0
    public static let maximumPixelsPerSecond = 800.0
    /// Same step as the plus and minus buttons.
    public static let zoomFactor = 1.25

    /// 0 through the end of the latest clip, plus `margin`. Every track is included.
    public static func fitEnd(of document: TrimmerDocument) -> Double {
        let clipEnd = document.clips.map(\.end).max() ?? 0
        if clipEnd > TrimmerDocument.epsilon {
            return clipEnd + margin
        }
        return emptySpan
    }

    public static func fitPixelsPerSecond(of document: TrimmerDocument, width: Double) -> Double {
        let span = max(fitEnd(of: document), 0.001)
        let available = max(1, width - edgePadding)
        return min(maximumPixelsPerSecond, available / span)
    }

    /// Zooming out stops at Fit, so minus can always reach the whole timeline.
    public static func zoom(pixelsPerSecond: Double, by factor: Double, fitPixelsPerSecond: Double) -> Double {
        let floor = max(0.000_1, fitPixelsPerSecond)
        guard pixelsPerSecond.isFinite, factor.isFinite, factor > 0 else { return floor }
        let next = pixelsPerSecond * factor
        if factor < 1 {
            return max(floor, next)
        }
        return min(maximumPixelsPerSecond, max(floor, next))
    }
}

/// A click on the ruler, a clip, an empty lane, or a chapter.
public struct TrimmerSeek: Equatable, Sendable {
    public var time: Double
    /// True when playback was already running and should continue from `time`.
    public var keepPlaying: Bool

    public init(time: Double, keepPlaying: Bool) {
        self.time = time
        self.keepPlaying = keepPlaying
    }

    public static func decide(isPlaying: Bool, time: Double) -> TrimmerSeek {
        let landed = time.isFinite ? max(0, time) : 0
        return TrimmerSeek(time: landed, keepPlaying: isPlaying)
    }
}

public enum TrimmerChapters {
    /// `HH:MM:SS Title`, one chapter per line, sorted by time.
    public static func text(markers: [TrimmerMarker]) -> String {
        let sorted = markers.sorted { lhs, rhs in
            if lhs.time == rhs.time { return lhs.title < rhs.title }
            return lhs.time < rhs.time
        }
        guard !sorted.isEmpty else { return "" }
        let lines = sorted.map { marker in
            let title = marker.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(clock(marker.time)) \(title.isEmpty ? "Chapter" : title)"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
