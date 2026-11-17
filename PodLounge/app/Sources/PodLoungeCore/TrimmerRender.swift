import Foundation

public enum TrimmerClock {
    public static func frames(seconds: Double, sampleRate: Double) -> Int {
        guard seconds.isFinite, sampleRate > 0 else { return 0 }
        return max(0, Int((seconds * sampleRate).rounded(.toNearestOrAwayFromZero)))
    }

    public static func seconds(frames: Int, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate
    }
}

public struct TrimmerSourceAudio: Sendable, Equatable {
    public var sampleRate: Double
    public var stereo: [Float]

    public init(sampleRate: Double, stereo: [Float]) {
        var samples = stereo
        if samples.count % 2 != 0 { samples.append(0) }
        self.sampleRate = sampleRate
        self.stereo = samples
    }

    public var frameCount: Int { stereo.count / 2 }

    public static func constant(frames: Int, amplitude: Float, sampleRate: Double) -> TrimmerSourceAudio {
        TrimmerSourceAudio(
            sampleRate: sampleRate,
            stereo: Array(repeating: amplitude, count: max(0, frames) * 2)
        )
    }

    /// Stereo frames. Missing audio is silence, so a short file does not crash a longer clip.
    public func read(frame: Int, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count * 2)
        let first = max(0, frame)
        let last = min(frameCount, frame + count)
        guard last > first else { return out }
        let sourceStart = first * 2
        let destStart = (first - frame) * 2
        let sampleCount = (last - first) * 2
        for offset in 0..<sampleCount {
            out[destStart + offset] = stereo[sourceStart + offset]
        }
        return out
    }
}

public struct TrimmerRenderResult: Equatable, Sendable {
    public var sampleRate: Double
    public var stereo: [Float]
    public var peak: Float
    public var frameCount: Int

    public init(sampleRate: Double, stereo: [Float], peak: Float, frameCount: Int) {
        self.sampleRate = sampleRate
        self.stereo = stereo
        self.peak = peak
        self.frameCount = frameCount
    }
}

public enum TrimmerGain {
    public static func linear(decibels: Double) -> Float {
        guard decibels.isFinite else { return 0 }
        return Float(pow(10, decibels / 20))
    }

    /// Equal-power fade-in. `t` is 0 at silence and 1 at full level.
    public static func fadeIn(_ t: Double) -> Float {
        let clamped = min(1, max(0, t))
        return Float(sin(clamped * .pi / 2))
    }

    /// Equal-power fade-out. `t` is 0 at full level and 1 at silence.
    public static func fadeOut(_ t: Double) -> Float {
        let clamped = min(1, max(0, t))
        return Float(cos(clamped * .pi / 2))
    }

    /// Equal-power pair across an overlap. `t` is 0 at the start of the overlap.
    public static func crossfade(at t: Double) -> (outgoing: Float, incoming: Float) {
        (fadeOut(t), fadeIn(t))
    }

    public static func peakDecibels(_ peak: Float) -> String {
        guard peak > 0, peak.isFinite else { return "−∞ dB" }
        let db = 20 * log10(Double(peak))
        return String(format: "%+.1f dB", db)
    }
}

public enum TrimmerEnvelope {
    /// Gain for one clip at `time`, including an equal-power crossfade when it overlaps one other clip on the same track.
    public static func gain(of clip: TrimmerClip, among mates: [TrimmerClip], at time: Double) -> Float {
        guard time >= clip.start, time < clip.end else { return 0 }
        var overlaps: [(start: Double, end: Double, outgoing: Bool)] = []
        for other in mates where other.id != clip.id {
            let start = max(clip.start, other.start)
            let end = min(clip.end, other.end)
            guard end - start > TrimmerDocument.epsilon else { continue }
            let outgoing = clip.start < other.start
                || (abs(clip.start - other.start) <= TrimmerDocument.epsilon && clip.id.uuidString < other.id.uuidString)
            overlaps.append((start, end, outgoing))
        }
        let active = overlaps.filter { time >= $0.start && time < $0.end }
        if active.count == 1, let overlap = active.first {
            let span = max(overlap.end - overlap.start, 1e-9)
            let position = (time - overlap.start) / span
            let pair = TrimmerGain.crossfade(at: position)
            return overlap.outgoing ? pair.outgoing : pair.incoming
        }
        return edgeFade(clip, at: time)
    }

    private static func edgeFade(_ clip: TrimmerClip, at time: Double) -> Float {
        var gain: Float = 1
        if clip.fadeIn > 0 {
            let position = (time - clip.start) / clip.fadeIn
            if position < 1 { gain *= TrimmerGain.fadeIn(position) }
        }
        if clip.fadeOut > 0 {
            let fadeStart = clip.end - clip.fadeOut
            if time >= fadeStart {
                let position = (time - fadeStart) / clip.fadeOut
                gain *= TrimmerGain.fadeOut(position)
            }
        }
        return gain
    }
}

public enum TrimmerRenderer {
    public static let blockSize = 4096

    public static func render(
        document: TrimmerDocument,
        sampleRate: Double,
        sources: [String: TrimmerSourceAudio],
        progress: ((Double) -> Void)? = nil
    ) -> TrimmerRenderResult {
        let timeline = timelineFrames(document: document, sampleRate: sampleRate)
        var stereo: [Float] = []
        stereo.reserveCapacity(timeline * 2)
        let peak = renderStreaming(
            document: document,
            sampleRate: sampleRate,
            read: { assetID, frame, count in
                sources[assetID]?.read(frame: frame, count: count) ?? [Float](repeating: 0, count: max(0, count) * 2)
            },
            progress: progress
        ) { block in
            stereo.append(contentsOf: block)
        }
        return TrimmerRenderResult(
            sampleRate: sampleRate,
            stereo: stereo,
            peak: peak,
            frameCount: stereo.count / 2
        )
    }

    /// Mixes the timeline in blocks. `read` returns interleaved stereo at `sampleRate`.
    @discardableResult
    public static func renderStreaming(
        document: TrimmerDocument,
        sampleRate: Double,
        read: (String, Int, Int) -> [Float],
        progress: ((Double) -> Void)? = nil,
        consume: ([Float]) -> Void
    ) -> Float {
        let timeline = timelineFrames(document: document, sampleRate: sampleRate)
        guard timeline > 0, sampleRate > 0 else {
            progress?(1)
            return 0
        }
        let prepared = prepare(document: document, sampleRate: sampleRate)
        var peak: Float = 0
        var frame = 0
        while frame < timeline {
            let count = min(blockSize, timeline - frame)
            var block = [Float](repeating: 0, count: count * 2)
            for clip in prepared {
                let localStart = max(frame, clip.startFrame)
                let localEnd = min(frame + count, clip.endFrame)
                guard localEnd > localStart else { continue }
                let sourceFrame = clip.inFrame + (localStart - clip.startFrame)
                let needed = localEnd - localStart
                let source = read(clip.assetID, sourceFrame, needed)
                let destBase = (localStart - frame) * 2
                for index in 0..<needed {
                    let timelineFrame = localStart + index
                    let time = Double(timelineFrame) / sampleRate
                    let envelope = clip.envelope(at: time)
                    let gain = clip.linear * envelope
                    let leftIndex = index * 2
                    let rightIndex = leftIndex + 1
                    let left = leftIndex < source.count ? source[leftIndex] : 0
                    let right = rightIndex < source.count ? source[rightIndex] : 0
                    block[destBase + leftIndex] += left * gain
                    block[destBase + rightIndex] += right * gain
                }
            }
            for sample in block {
                peak = max(peak, abs(sample))
            }
            consume(block)
            frame += count
            progress?(Double(frame) / Double(timeline))
        }
        return peak
    }

    public static func timelineFrames(document: TrimmerDocument, sampleRate: Double) -> Int {
        document.clips.map { clip in
            TrimmerClock.frames(seconds: clip.start, sampleRate: sampleRate)
                + TrimmerClock.frames(seconds: clip.length, sampleRate: sampleRate)
        }.max() ?? 0
    }

    private struct PreparedClip {
        var assetID: String
        var startFrame: Int
        var endFrame: Int
        var inFrame: Int
        var linear: Float
        var clip: TrimmerClip
        var mates: [TrimmerClip]

        func envelope(at time: Double) -> Float {
            TrimmerEnvelope.gain(of: clip, among: mates, at: time)
        }
    }

    private static func prepare(document: TrimmerDocument, sampleRate: Double) -> [PreparedClip] {
        var prepared: [PreparedClip] = []
        for track in TrimmerTrackID.allCases where document.isAudible(track) {
            let trackGain = TrimmerGain.linear(decibels: document.trackState(track).gainDB)
            let mates = document.clips.filter { $0.track == track }
            for clip in mates {
                let startFrame = TrimmerClock.frames(seconds: clip.start, sampleRate: sampleRate)
                let lengthFrames = TrimmerClock.frames(seconds: clip.length, sampleRate: sampleRate)
                guard lengthFrames > 0 else { continue }
                prepared.append(PreparedClip(
                    assetID: clip.assetID,
                    startFrame: startFrame,
                    endFrame: startFrame + lengthFrames,
                    inFrame: TrimmerClock.frames(seconds: clip.inOffset, sampleRate: sampleRate),
                    linear: trackGain * TrimmerGain.linear(decibels: clip.gainDB),
                    clip: clip,
                    mates: mates
                ))
            }
        }
        return prepared
    }
}
