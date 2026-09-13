import AVFoundation
import Darwin
import Foundation

/// Interleaved float32 PCM living in a mapped temp file.
///
/// Lil Leveler used to keep the whole show in `[Float]` (plus extra copies for
/// analyze / level / play). A 4-hour stereo 48 kHz podcast is ~5.5 GB per copy,
/// so the app was jetsam’d. Mapping a file lets the OS page samples in and out.
final class PCMStore: @unchecked Sendable {
    static let headerSize = 32
    private static let magic = "LLPCM001"

    let url: URL
    let sampleRate: Double
    let channelCount: Int
    private(set) var frameCount: Int
    let ownsFile: Bool

    private var mapped: UnsafeMutableRawPointer?
    private var mappedSize = 0
    private var samples: UnsafeMutablePointer<Float>?

    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }

    deinit {
        unmap()
        if ownsFile {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func estimatedByteCount(frames: Int, channels: Int) -> Int? {
        guard frames > 0, channels > 0 else { return nil }
        let perFrame = channels * MemoryLayout<Float>.size
        guard frames <= (Int.max - headerSize) / perFrame else { return nil }
        return headerSize + frames * perFrame
    }

    static func sweepTemporaryFiles() {
        let dir = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in items where url.pathExtension == "llpcm"
            && url.lastPathComponent.hasPrefix("LilLeveler-")
        {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let date = values?.contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func createTemporary(
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int
    ) throws -> PCMStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LilLeveler-\(UUID().uuidString).llpcm")
        return try PCMStore(
            url: url,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            ownsFile: true
        )
    }

    private init(
        url: URL,
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        ownsFile: Bool
    ) throws {
        guard channelCount >= 1, channelCount <= 8 else {
            throw LevelerError.loadFailed("Unsupported audio layout (\(channelCount) ch).")
        }
        guard frameCount > 0, sampleRate > 0 else {
            throw LevelerError.loadFailed("File has no audio frames.")
        }
        guard let total = Self.estimatedByteCount(frames: frameCount, channels: channelCount) else {
            throw LevelerError.loadFailed("This show is too long to open.")
        }

        try Self.ensureDiskSpace(bytes: Int64(total) + 32_000_000, near: FileManager.default.temporaryDirectory)

        self.url = url
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.ownsFile = ownsFile

        if !FileManager.default.createFile(atPath: url.path, contents: nil) {
            throw LevelerError.loadFailed("Could not create a working copy of this audio.")
        }
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else {
            throw LevelerError.loadFailed("Could not open a working copy of this audio.")
        }
        defer { close(fd) }
        if ftruncate(fd, off_t(total)) != 0 {
            throw LevelerError.loadFailed(Self.diskFullMessage(needed: total))
        }
        let ptr = try Self.mapWritable(fd: fd, size: total, failure: .memory(total))
        mapped = ptr
        mappedSize = total
        samples = ptr.advanced(by: Self.headerSize).assumingMemoryBound(to: Float.self)
        writeHeader()
    }

    func adviseSequential() {
        guard let mapped, mappedSize > 0 else { return }
        madvise(mapped, mappedSize, MADV_SEQUENTIAL)
    }

    func sync() {
        guard let mapped, mappedSize > 0 else { return }
        msync(mapped, mappedSize, MS_SYNC)
    }

    /// Trim unused tail if decode produced fewer frames than the container promised.
    func shrinkFrameCount(to newCount: Int) throws {
        guard newCount > 0, newCount <= frameCount else {
            throw LevelerError.loadFailed("File has no audio frames.")
        }
        guard newCount != frameCount else { return }
        guard let total = Self.estimatedByteCount(frames: newCount, channels: channelCount) else {
            throw LevelerError.loadFailed("File has no audio frames.")
        }
        unmap()
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else {
            throw LevelerError.loadFailed("Could not finish reading this audio.")
        }
        defer { close(fd) }
        if ftruncate(fd, off_t(total)) != 0 {
            throw LevelerError.loadFailed("Could not finish reading this audio.")
        }
        let ptr = try Self.mapWritable(fd: fd, size: total, failure: .finish)
        frameCount = newCount
        mapped = ptr
        mappedSize = total
        samples = ptr.advanced(by: Self.headerSize).assumingMemoryBound(to: Float.self)
        writeHeader()
    }

    func write(from buffer: AVAudioPCMBuffer, atFrame start: Int) throws {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        guard start >= 0, start + n <= frameCount else {
            throw LevelerError.loadFailed("Read overran the working copy.")
        }
        guard let dest = samples else {
            throw LevelerError.loadFailed("Working copy is missing.")
        }
        let ch = channelCount
        let dst = dest.advanced(by: start * ch)
        guard let channelsPtr = buffer.floatChannelData else {
            throw LevelerError.loadFailed("Expected float PCM from decoder.")
        }
        if buffer.format.isInterleaved {
            dst.update(from: channelsPtr[0], count: n * ch)
        } else {
            for f in 0..<n {
                for c in 0..<ch {
                    dst[f * ch + c] = channelsPtr[c][f]
                }
            }
        }
    }

    func write(interleaved: [Float], startFrame: Int, frames: Int) {
        guard let dest = samples, frames > 0 else { return }
        let ch = channelCount
        let n = min(frames, max(0, frameCount - startFrame))
        guard n > 0, startFrame >= 0 else { return }
        interleaved.withUnsafeBufferPointer { buf in
            guard let src = buf.baseAddress else { return }
            dest.advanced(by: startFrame * ch).update(from: src, count: n * ch)
        }
    }

    @discardableResult
    func copyFrames(start: Int, count: Int, into dest: UnsafeMutablePointer<Float>) -> Int {
        guard let samples, count > 0 else { return 0 }
        let startFrame = max(0, start)
        guard startFrame < frameCount else { return 0 }
        let n = min(count, frameCount - startFrame)
        dest.update(from: samples.advanced(by: startFrame * channelCount), count: n * channelCount)
        return n
    }

    @discardableResult
    func copyFrames(start: Int, count: Int, into dest: inout [Float]) -> Int {
        dest.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return 0 }
            return copyFrames(start: start, count: count, into: base)
        }
    }

    func sample(frame: Int, channel: Int) -> Float {
        guard let samples, frame >= 0, frame < frameCount, channel >= 0, channel < channelCount else {
            return 0
        }
        return samples[frame * channelCount + channel]
    }

    func stereoFrame(at frame: Int) -> (Float, Float) {
        guard let samples, frame >= 0, frame < frameCount else { return (0, 0) }
        let ch = channelCount
        let base = frame * ch
        let left = samples[base]
        let right = ch >= 2 ? samples[base + 1] : left
        return (left, right)
    }

    private func writeHeader() {
        guard let mapped else { return }
        let base = mapped.assumingMemoryBound(to: UInt8.self)
        let magicBytes = Array(Self.magic.utf8)
        for i in 0..<min(8, magicBytes.count) {
            base[i] = magicBytes[i]
        }
        var rate = sampleRate
        withUnsafeBytes(of: &rate) { raw in
            for i in 0..<8 { base[8 + i] = raw[i] }
        }
        var ch = UInt32(channelCount).littleEndian
        withUnsafeBytes(of: &ch) { raw in
            for i in 0..<4 { base[16 + i] = raw[i] }
        }
        var version = UInt32(1).littleEndian
        withUnsafeBytes(of: &version) { raw in
            for i in 0..<4 { base[20 + i] = raw[i] }
        }
        var frames = UInt64(frameCount).littleEndian
        withUnsafeBytes(of: &frames) { raw in
            for i in 0..<8 { base[24 + i] = raw[i] }
        }
    }

    private func unmap() {
        if let mapped, mappedSize > 0 {
            munmap(mapped, mappedSize)
        }
        mapped = nil
        mappedSize = 0
        samples = nil
    }

    static func ensureDiskSpace(bytes: Int64, near url: URL) throws {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        let values = try? url.resourceValues(forKeys: keys)
        if let free = values?.volumeAvailableCapacityForImportantUsage, free > 0, free < bytes {
            throw LevelerError.loadFailed(
                "Need about \(gb(Int(bytes))) GB free to open this show. This Mac has \(gb(Int(free))) GB free."
            )
        }
    }

    static func diskFullMessage(needed: Int) -> String {
        "Need about \(gb(needed)) GB free for a working copy of this show."
    }

    static func gb(_ bytes: Int) -> String {
        String(format: "%.1f", Double(max(0, bytes)) / 1_000_000_000.0)
    }

    private enum MapFailure {
        case memory(Int)
        case finish

        var message: String {
            switch self {
            case .memory(let total):
                "This Mac ran out of memory mapping a \(PCMStore.gb(total)) GB working copy. Close other apps and try again."
            case .finish:
                "Out of memory finishing this audio."
            }
        }
    }

    /// Darwin `mmap` is optional here; unwrap before calling `.advanced`.
    private static func mapWritable(fd: Int32, size: Int, failure: MapFailure) throws -> UnsafeMutableRawPointer {
        let ptr = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let ptr, ptr != MAP_FAILED else {
            throw LevelerError.loadFailed(failure.message)
        }
        return ptr
    }
}
