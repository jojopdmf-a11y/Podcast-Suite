import Darwin
import Foundation

/// Streams one mono 16-bit PCM WAV. Writer thread only.
public final class RecordWAVWriter: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Double
    public private(set) var framesWritten: UInt64 = 0

    private let fd: Int32
    private var scratch: [UInt8]
    private var scratchCount = 0
    private var fileEnd: UInt64 = 44
    private var headerFrames: UInt64 = 0
    private var lastSync: TimeInterval = 0
    private var closed = false
    public private(set) var overflowed4GB = false

    public init(url: URL, sampleRate: Double) throws {
        self.url = url
        self.sampleRate = sampleRate
        scratch = [UInt8](repeating: 0, count: 128 * 1024)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var header = [UInt8](repeating: 0, count: 44)
        Self.writeHeader(&header, sampleRate: sampleRate, dataBytes: 0)
        try Data(header).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        let owned = Darwin.dup(handle.fileDescriptor)
        try handle.close()
        guard owned >= 0 else {
            throw RecordWriteError("Could not open \(url.lastPathComponent)")
        }
        fd = owned
    }

    deinit {
        if !closed {
            Darwin.close(fd)
        }
    }

    public func append(samples: UnsafePointer<Float>, frames: Int) {
        guard frames > 0, !closed else { return }
        var i = 0
        while i < frames {
            let roomSamples = (scratch.count - scratchCount) / 2
            if roomSamples == 0 {
                let before = scratchCount
                flushScratch()
                if scratchCount >= before { break }
                continue
            }
            let n = min(frames - i, roomSamples)
            for k in 0..<n {
                let q = Self.quantize(samples[i + k])
                let u = UInt16(bitPattern: q)
                scratch[scratchCount] = UInt8(truncatingIfNeeded: u & 0xFF)
                scratch[scratchCount + 1] = UInt8(truncatingIfNeeded: u >> 8)
                scratchCount += 2
            }
            i += n
            framesWritten += UInt64(n)
            if scratchCount >= 65_536 {
                flushScratch()
            }
            maybeRefreshHeader()
        }
    }

    public func appendZeros(_ frames: Int) {
        guard frames > 0, !closed else { return }
        var left = frames
        while left > 0 {
            let roomSamples = (scratch.count - scratchCount) / 2
            if roomSamples == 0 {
                let before = scratchCount
                flushScratch()
                if scratchCount >= before { break }
                continue
            }
            let n = min(left, roomSamples)
            for k in 0..<(n * 2) {
                scratch[scratchCount + k] = 0
            }
            scratchCount += n * 2
            framesWritten += UInt64(n)
            left -= n
            if scratchCount >= 65_536 {
                flushScratch()
            }
            maybeRefreshHeader()
        }
    }

    public func finalize() {
        guard !closed else { return }
        flushScratch()
        refreshHeader(forceSync: true)
        Darwin.close(fd)
        closed = true
    }

    private func maybeRefreshHeader() {
        let rate = UInt64(max(1, sampleRate.rounded()))
        if framesWritten - headerFrames >= rate {
            flushScratch()
            refreshHeader(forceSync: false)
        }
    }

    private func flushScratch() {
        guard scratchCount > 0 else { return }
        let wrote = scratch.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Self.pwriteAll(fd: fd, base, count: scratchCount, offset: off_t(fileEnd))
        }
        fileEnd += UInt64(wrote)
        if wrote < scratchCount {
            // Keep unwritten tail. Should not happen on a normal disk.
            let keep = scratchCount - wrote
            scratch.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                memmove(base, base.advanced(by: wrote), keep)
            }
            scratchCount = keep
        } else {
            scratchCount = 0
        }
        let dataBytes = fileEnd > 44 ? fileEnd - 44 : 0
        if dataBytes > 4_000_000_000 && !overflowed4GB {
            overflowed4GB = true
            fputs("PodProducer WAV data exceeded 4 GB; RF64 is not used\n", stderr)
            assert(dataBytes <= 4_000_000_000, "WAV data exceeded 4 GB; RF64 is not used")
        }
    }

    private func refreshHeader(forceSync: Bool) {
        var header = [UInt8](repeating: 0, count: 44)
        let dataBytes = fileEnd > 44 ? fileEnd - 44 : 0
        Self.writeHeader(&header, sampleRate: sampleRate, dataBytes: dataBytes)
        _ = header.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Self.pwriteAll(fd: fd, base.advanced(by: 4), count: 4, offset: 4)
        }
        _ = header.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Self.pwriteAll(fd: fd, base.advanced(by: 40), count: 4, offset: 40)
        }
        headerFrames = dataBytes / 2
        let now = Date().timeIntervalSinceReferenceDate
        if forceSync || now - lastSync >= 5 {
            Darwin.fsync(fd)
            lastSync = now
        }
    }

    static func quantize(_ x: Float) -> Int16 {
        let clipped = max(-1 as Float, min(1, x))
        return Int16((clipped * 32767).rounded())
    }

    private static func writeHeader(_ header: inout [UInt8], sampleRate: Double, dataBytes: UInt64) {
        let rate = UInt32(max(1, sampleRate.rounded()))
        let data32 = UInt32(min(dataBytes, UInt64(UInt32.max)))
        let chunk = data32 &+ 36
        putASCII(&header, 0, "RIFF")
        putU32(&header, 4, chunk)
        putASCII(&header, 8, "WAVE")
        putASCII(&header, 12, "fmt ")
        putU32(&header, 16, 16)
        putU16(&header, 20, 1)
        putU16(&header, 22, 1)
        putU32(&header, 24, rate)
        putU32(&header, 28, rate * 2)
        putU16(&header, 32, 2)
        putU16(&header, 34, 16)
        putASCII(&header, 36, "data")
        putU32(&header, 40, data32)
    }

    private static func putASCII(_ b: inout [UInt8], _ o: Int, _ s: String) {
        for (i, c) in s.utf8.enumerated() { b[o + i] = c }
    }

    private static func putU16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
        b[o] = UInt8(truncatingIfNeeded: v & 0xFF)
        b[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }

    private static func putU32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o] = UInt8(truncatingIfNeeded: v & 0xFF)
        b[o + 1] = UInt8(truncatingIfNeeded: (v >> 8) & 0xFF)
        b[o + 2] = UInt8(truncatingIfNeeded: (v >> 16) & 0xFF)
        b[o + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }

    private static func pwriteAll(fd: Int32, _ bytes: [UInt8], offset: off_t) -> Int {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            return pwriteAll(fd: fd, base, count: bytes.count, offset: offset)
        }
    }

    private static func pwriteAll(fd: Int32, _ ptr: UnsafeRawPointer, count: Int, offset: off_t) -> Int {
        var done = 0
        while done < count {
            let n = Darwin.pwrite(fd, ptr.advanced(by: done), count - done, offset + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            done += n
        }
        return done
    }
}

public struct RecordWriteError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
