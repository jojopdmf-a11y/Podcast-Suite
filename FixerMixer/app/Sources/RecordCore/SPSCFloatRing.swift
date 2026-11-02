import Foundation
import PPAtomics

/// Heap atomic. Swift 6 `Synchronization.Atomic` needs macOS 15; this package targets 14.
public final class PPAtomicU64: @unchecked Sendable {
    private let ptr: UnsafeMutablePointer<pp_atomic_u64>

    public init(_ value: UInt64 = 0) {
        ptr = .allocate(capacity: 1)
        pp_atomic_init(ptr)
        if value != 0 {
            pp_store_release(ptr, value)
        }
    }

    deinit {
        ptr.deallocate()
    }

    public func load() -> UInt64 { pp_load_acquire(ptr) }
    public func store(_ value: UInt64) { pp_store_release(ptr, value) }
    @discardableResult
    public func fetchAdd(_ delta: UInt64) -> UInt64 { pp_fetch_add(ptr, delta) }
}

/// Single-producer / single-consumer ring of interleaved Float32.
/// Capacity is the next power of two at or above 4 seconds.
public final class SPSCFloatRing: @unchecked Sendable {
    public let capacityFrames: Int
    public let channels: Int
    private let mask: UInt64
    private let storage: UnsafeMutablePointer<Float>
    private let writeFrame: PPAtomicU64
    private let readFrame: PPAtomicU64

    public init(sampleRate: Double, channels: Int) {
        let ch = max(1, channels)
        let need = max(1, Int((4.0 * max(sampleRate, 1)).rounded(.up)))
        var cap = 1
        while cap < need { cap <<= 1 }
        self.capacityFrames = cap
        self.channels = ch
        self.mask = UInt64(cap - 1)
        storage = .allocate(capacity: cap * ch)
        storage.initialize(repeating: 0, count: cap * ch)
        writeFrame = PPAtomicU64(0)
        readFrame = PPAtomicU64(0)
    }

    deinit {
        storage.deinitialize(count: capacityFrames * channels)
        storage.deallocate()
    }

    public var availableToRead: Int {
        let used = writeFrame.load() &- readFrame.load()
        return Int(used)
    }

    public var availableToWrite: Int {
        let used = writeFrame.load() &- readFrame.load()
        if used >= UInt64(capacityFrames) { return 0 }
        return capacityFrames - Int(used)
    }

    /// Frames accepted. Never overwrites unread data.
    public func write(_ src: UnsafePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let w = writeFrame.load()
        let r = readFrame.load()
        let used = w &- r
        if used >= UInt64(capacityFrames) { return 0 }
        let free = capacityFrames - Int(used)
        let n = min(frames, free)
        copy(from: src, toFrame: w, frames: n)
        writeFrame.store(w &+ UInt64(n))
        return n
    }

    public func read(into dst: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        guard maxFrames > 0 else { return 0 }
        let r = readFrame.load()
        let w = writeFrame.load()
        let used = w &- r
        if used == 0 { return 0 }
        let n = min(maxFrames, Int(used))
        copy(fromFrame: r, to: dst, frames: n)
        readFrame.store(r &+ UInt64(n))
        return n
    }

    /// Producer's write cursor (frames successfully placed in the ring).
    public var writeCursor: UInt64 { writeFrame.load() }

    private func copy(from src: UnsafePointer<Float>, toFrame start: UInt64, frames: Int) {
        var left = frames
        var cursor = start
        var srcOff = 0
        while left > 0 {
            let pos = Int(cursor & mask)
            let run = min(left, capacityFrames - pos)
            let dst = storage.advanced(by: pos * channels)
            dst.update(from: src.advanced(by: srcOff * channels), count: run * channels)
            cursor &+= UInt64(run)
            srcOff += run
            left -= run
        }
    }

    private func copy(fromFrame start: UInt64, to dst: UnsafeMutablePointer<Float>, frames: Int) {
        var left = frames
        var cursor = start
        var dstOff = 0
        while left > 0 {
            let pos = Int(cursor & mask)
            let run = min(left, capacityFrames - pos)
            let src = storage.advanced(by: pos * channels)
            dst.advanced(by: dstOff * channels).update(from: src, count: run * channels)
            cursor &+= UInt64(run)
            dstOff += run
            left -= run
        }
    }
}
