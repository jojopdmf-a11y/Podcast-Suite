import Foundation

public struct TrimmerPeakLevel: Sendable, Equatable {
    public var framesPerBucket: Int
    public var minima: [Float]
    public var maxima: [Float]

    public init(framesPerBucket: Int, minima: [Float], maxima: [Float]) {
        self.framesPerBucket = framesPerBucket
        self.minima = minima
        self.maxima = maxima
    }

    /// Quietest and loudest sample from `startFrame` up to, but not including, `endFrame`.
    public func range(from startFrame: Int, to endFrame: Int) -> (Float, Float) {
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

public struct TrimmerPeakChoice: Equatable, Sendable {
    public var levelIndex: Int
    /// Source frames covered by one drawn min/max pair.
    public var framesPerPair: Int

    public init(levelIndex: Int, framesPerPair: Int) {
        self.levelIndex = levelIndex
        self.framesPerPair = framesPerPair
    }

    public func pairCount(frameCount: Int) -> Int {
        let frames = max(1, frameCount)
        let span = max(1, framesPerPair)
        return max(1, (frames + span - 1) / span)
    }
}

/// Picks a saved peak level for the current zoom.
/// The result never asks for more than one min/max pair per screen pixel.
public enum TrimmerPeakLOD {
    public static func choose(framesPerBucket: [Int], frameCount: Int, pixels: Int) -> TrimmerPeakChoice {
        let pixels = max(1, pixels)
        let frameCount = max(1, frameCount)
        let framesPerPixel = Double(frameCount) / Double(pixels)
        let widenedFloor = max(1, Int(framesPerPixel.rounded(.up)))
        guard !framesPerBucket.isEmpty else {
            return TrimmerPeakChoice(levelIndex: 0, framesPerPair: widenedFloor)
        }
        var bestIndex = framesPerBucket.count - 1
        var bestDistance = Double.infinity
        var found = false
        let target = log2(max(framesPerPixel, 1))
        for (index, bucket) in framesPerBucket.enumerated() {
            let size = Double(max(1, bucket))
            // A finer bucket than one pixel would draw more than one pair per pixel.
            if size + 0.000_001 < framesPerPixel { continue }
            let distance = abs(log2(size) - target)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
                found = true
            }
        }
        if !found {
            var coarsest = 0
            var coarsestSize = -1
            for (index, bucket) in framesPerBucket.enumerated() where bucket > coarsestSize {
                coarsestSize = bucket
                coarsest = index
            }
            bestIndex = coarsest
        }
        let bucket = max(1, framesPerBucket[min(bestIndex, framesPerBucket.count - 1)])
        return TrimmerPeakChoice(levelIndex: bestIndex, framesPerPair: max(bucket, widenedFloor))
    }

    /// Min/max pairs for `pixels` columns. The count is never more than `pixels`.
    public static func pairs(
        levels: [TrimmerPeakLevel],
        startFrame: Int,
        frameCount: Int,
        pixels: Int
    ) -> [(Float, Float)] {
        let pixels = max(0, pixels)
        guard pixels > 0 else { return [] }
        let buckets = levels.map(\.framesPerBucket)
        let choice = choose(framesPerBucket: buckets, frameCount: max(1, frameCount), pixels: pixels)
        let drawn = min(pixels, choice.pairCount(frameCount: max(1, frameCount)))
        guard levels.indices.contains(choice.levelIndex) else {
            return Array(repeating: (0, 0), count: drawn)
        }
        let level = levels[choice.levelIndex]
        let span = max(1, frameCount)
        let origin = max(0, startFrame)
        var pairs: [(Float, Float)] = []
        pairs.reserveCapacity(drawn)
        for column in 0..<drawn {
            let start = origin + span * column / drawn
            let end = max(start + 1, origin + span * (column + 1) / drawn)
            pairs.append(level.range(from: start, to: end))
        }
        return pairs
    }
}
