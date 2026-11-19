import AVFoundation
import Foundation

/// Min/max peaks for one depot file, kept at several levels of detail.
/// The finest level is decoded once. Coarser levels are built from it, so zooming does not read the file again.
struct WaveformPyramid: Sendable {
    struct Level: Sendable {
        var framesPerBucket: Int
        var minima: [Float]
        var maxima: [Float]

        func range(from startFrame: Int, to endFrame: Int) -> (Float, Float) {
            guard framesPerBucket > 0, !minima.isEmpty else { return (0, 0) }
            let lastFrame = max(startFrame, endFrame - 1)
            var first = startFrame / framesPerBucket
            var last = lastFrame / framesPerBucket
            if first >= minima.count { return (0, 0) }
            first = max(0, first)
            last = min(minima.count - 1, max(first, last))
            var low = minima[first]
            var high = maxima[first]
            if last > first {
                for index in (first + 1)...last {
                    low = min(low, minima[index])
                    high = max(high, maxima[index])
                }
            }
            return (low, high)
        }
    }

    var sampleRate: Double
    var totalFrames: Int
    var levels: [Level]

    static let empty = WaveformPyramid(sampleRate: 0, totalFrames: 0, levels: [])

    /// One min/max pair per column across `frameCount` source frames starting at `startFrame`.
    func columns(startFrame: Int, frameCount: Int, count: Int) -> [(Float, Float)] {
        guard count > 0, let level = level(for: frameCount, columns: count) else {
            return Array(repeating: (0, 0), count: max(0, count))
        }
        let span = max(1, frameCount)
        let origin = max(0, startFrame)
        var pairs: [(Float, Float)] = []
        pairs.reserveCapacity(count)
        for column in 0..<count {
            let start = origin + span * column / count
            let end = max(start + 1, origin + span * (column + 1) / count)
            pairs.append(level.range(from: start, to: end))
        }
        return pairs
    }

    /// Finest level that still puts about one bucket in each column. Zooming in walks toward the first level.
    private func level(for frameCount: Int, columns: Int) -> Level? {
        guard let finest = levels.first, columns > 0 else { return nil }
        let framesPerColumn = Double(max(1, frameCount)) / Double(columns)
        var chosen = finest
        for level in levels where Double(level.framesPerBucket) <= framesPerColumn * 1.25 {
            chosen = level
        }
        return chosen
    }

    static func compute(url: URL) -> WaveformPyramid {
        guard let file = try? AVAudioFile(forReading: url) else { return .empty }
        let total = Int(file.length)
        let rate = file.processingFormat.sampleRate
        guard total > 0, rate > 0 else { return .empty }
        let bucket = bucketSize(totalFrames: total)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(min(16_384, max(bucket, 1)))
        ) else { return .empty }
        let channels = Int(file.processingFormat.channelCount)
        var minima: [Float] = []
        var maxima: [Float] = []
        minima.reserveCapacity(total / bucket + 1)
        maxima.reserveCapacity(total / bucket + 1)
        var pending = 0
        var low: Float = 0
        var high: Float = 0
        while file.framePosition < file.length {
            let want = AVAudioFrameCount(min(Int(buffer.frameCapacity), Int(file.length - file.framePosition)))
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: want)
            } catch {
                break
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                var sampleLow = data[0][frame]
                var sampleHigh = sampleLow
                if channels > 1 {
                    for channel in 1..<channels {
                        let sample = data[channel][frame]
                        sampleLow = min(sampleLow, sample)
                        sampleHigh = max(sampleHigh, sample)
                    }
                }
                if pending == 0 {
                    low = sampleLow
                    high = sampleHigh
                } else {
                    low = min(low, sampleLow)
                    high = max(high, sampleHigh)
                }
                pending += 1
                if pending >= bucket {
                    minima.append(low)
                    maxima.append(high)
                    pending = 0
                }
            }
        }
        if pending > 0 {
            minima.append(low)
            maxima.append(high)
        }
        guard !minima.isEmpty else { return .empty }
        var levels = [Level(framesPerBucket: bucket, minima: minima, maxima: maxima)]
        while let last = levels.last, last.minima.count > 256, levels.count < 16 {
            levels.append(downsample(last))
        }
        return WaveformPyramid(sampleRate: rate, totalFrames: total, levels: levels)
    }

    /// About 128 source frames per bucket, coarser only when a file would otherwise hold millions of buckets.
    private static func bucketSize(totalFrames: Int) -> Int {
        let base = 128
        let cap = 1_500_000
        if totalFrames <= base * cap { return base }
        return max(base, (totalFrames + cap - 1) / cap)
    }

    private static func downsample(_ level: Level) -> Level {
        let count = (level.minima.count + 1) / 2
        var minima: [Float] = []
        var maxima: [Float] = []
        minima.reserveCapacity(count)
        maxima.reserveCapacity(count)
        var index = 0
        while index < level.minima.count {
            let next = min(index + 1, level.minima.count - 1)
            minima.append(min(level.minima[index], level.minima[next]))
            maxima.append(max(level.maxima[index], level.maxima[next]))
            index += 2
        }
        return Level(framesPerBucket: level.framesPerBucket * 2, minima: minima, maxima: maxima)
    }
}

actor TrimmerWaveformCache {
    static let shared = TrimmerWaveformCache()
    private var jobs: [String: Task<WaveformPyramid, Never>] = [:]

    func pyramid(assetID: String, url: URL) async -> WaveformPyramid {
        if let existing = jobs[assetID] {
            return await existing.value
        }
        let task = Task.detached(priority: .utility) {
            WaveformPyramid.compute(url: url)
        }
        jobs[assetID] = task
        return await task.value
    }
}
