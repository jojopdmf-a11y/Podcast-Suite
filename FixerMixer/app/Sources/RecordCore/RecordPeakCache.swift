import Foundation
import PPAtomics

/// Max-abs peak per 1024 frames. Writer thread appends; UI reads the published prefix.
public final class RecordPeakCache: @unchecked Sendable {
    public static let framesPerBin = 1024
    public let capacityBins: Int
    private let bins: UnsafeMutablePointer<Float>
    private let published: PPAtomicU64
    private var frameCursor: Int = 0

    public init(sampleRate: Double) {
        let bins = Int((8.0 * 3600.0 * max(sampleRate, 1)) / Double(Self.framesPerBin)) + 8
        capacityBins = max(8, bins)
        self.bins = .allocate(capacity: capacityBins)
        self.bins.initialize(repeating: 0, count: capacityBins)
        published = PPAtomicU64(0)
    }

    deinit {
        bins.deinitialize(count: capacityBins)
        bins.deallocate()
    }

    public func add(samples: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        var i = 0
        while i < frames {
            if frameCursor / Self.framesPerBin >= capacityBins { return }
            let within = frameCursor % Self.framesPerBin
            let room = Self.framesPerBin - within
            let n = min(room, frames - i)
            let bin = frameCursor / Self.framesPerBin
            var peak = bins[bin]
            for k in 0..<n {
                peak = max(peak, abs(samples[i + k]))
            }
            bins[bin] = peak
            i += n
            frameCursor += n
            if frameCursor % Self.framesPerBin == 0 {
                published.store(UInt64(frameCursor / Self.framesPerBin))
            }
        }
    }

    public func addZeros(_ frames: Int) {
        guard frames > 0 else { return }
        let end = frameCursor + frames
        let limit = capacityBins * Self.framesPerBin
        frameCursor = min(end, limit)
        let complete = frameCursor / Self.framesPerBin
        if complete > Int(published.load()) {
            published.store(UInt64(complete))
        }
    }

    public func finish() {
        guard frameCursor > 0 else { return }
        let shown = min(capacityBins, (frameCursor + Self.framesPerBin - 1) / Self.framesPerBin)
        published.store(UInt64(shown))
    }

    /// Acquire the published bin count, then read peaks `[0, count)`.
    public func withPublished(_ body: (UnsafePointer<Float>, Int) -> Void) {
        let n = min(capacityBins, Int(published.load()))
        body(UnsafePointer(bins), n)
    }
}

/// Per-voice input peaks as Float bit patterns in acquire/release atomics.
public final class RecordLivePeaks: @unchecked Sendable {
    public let count: Int
    private let storage: UnsafeMutablePointer<pp_atomic_u64>

    public init(count: Int) {
        let n = max(1, count)
        self.count = n
        storage = .allocate(capacity: n)
        for i in 0..<n {
            pp_atomic_init(storage.advanced(by: i))
        }
    }

    deinit {
        storage.deallocate()
    }

    public func store(index: Int, peak: Float) {
        guard index >= 0, index < count else { return }
        pp_store_release(storage.advanced(by: index), UInt64(peak.bitPattern))
    }

    public func load(index: Int) -> Float {
        guard index >= 0, index < count else { return 0 }
        let raw = pp_load_acquire(storage.advanced(by: index))
        return Float(bitPattern: UInt32(truncatingIfNeeded: raw))
    }

    public func clear() {
        for i in 0..<count { store(index: i, peak: 0) }
    }

    public func decayAll(by factor: Float) {
        for i in 0..<count {
            store(index: i, peak: load(index: i) * factor)
        }
    }
}
