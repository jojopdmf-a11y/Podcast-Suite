import AVFoundation
import Foundation

public enum TrimmerDecoder {
    /// File sample rate, or nil when the file is not audio.
    public static func sampleRate(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? rate : nil
    }

    /// Stereo float samples at `targetRate`. A mono file is copied to both channels.
    public static func readStereo(url: URL, targetRate: Double) throws -> TrimmerSourceAudio {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("thecut-read-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        let frames = try decodeRaw(url: url, to: raw, targetRate: targetRate)
        let data = (try? Data(contentsOf: raw)) ?? Data()
        var stereo = [Float](repeating: 0, count: max(0, frames) * 2)
        data.withUnsafeBytes { rawBuffer in
            let floats = rawBuffer.bindMemory(to: Float.self)
            let count = min(floats.count, stereo.count)
            for index in 0..<count {
                stereo[index] = floats[index]
            }
        }
        return TrimmerSourceAudio(sampleRate: targetRate, stereo: stereo)
    }

    /// Writes interleaved stereo float32 to `destination` and returns the frame count.
    @discardableResult
    public static func decodeRaw(url: URL, to destination: URL, targetRate: Double) throws -> Int {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard sourceFormat.channelCount > 0, sourceFormat.sampleRate > 0, targetRate > 0 else {
            throw TrimmerWAVError.unsupported(url.lastPathComponent)
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 2,
            interleaved: false
        ) else {
            throw TrimmerWAVError.unsupported(url.lastPathComponent)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        if sourceFormat.sampleRate == targetRate,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           sourceFormat.isInterleaved == false {
            return try copyFloat(file: file, to: output)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw TrimmerWAVError.unsupported(url.lastPathComponent)
        }
        let chunk: AVAudioFrameCount = 4096
        let ratio = targetRate / sourceFormat.sampleRate
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunk),
              let targetBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(Double(chunk) * ratio + 128)
              )
        else {
            throw TrimmerWAVError.unreadable
        }

        let gate = Exhaustion()
        var framesWritten = 0
        var convertError: NSError?
        let safety = max(8, Int(file.length) / 1024 + 32)
        for _ in 0..<safety {
            targetBuffer.frameLength = 0
            let status = converter.convert(to: targetBuffer, error: &convertError) { _, outStatus in
                if gate.done {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: sourceBuffer, frameCount: chunk)
                } catch {
                    gate.done = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if sourceBuffer.frameLength == 0 {
                    gate.done = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if let convertError {
                throw TrimmerWAVError.unsupported(convertError.localizedDescription)
            }
            if targetBuffer.frameLength > 0 {
                try appendInterleaved(targetBuffer, to: output)
                framesWritten += Int(targetBuffer.frameLength)
            }
            if status == .endOfStream || status == .error { break }
            if gate.done && targetBuffer.frameLength == 0 { break }
        }
        return framesWritten
    }

    private final class Exhaustion: @unchecked Sendable {
        var done = false
    }

    private static func copyFloat(file: AVAudioFile, to handle: FileHandle) throws -> Int {
        let chunk: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
            throw TrimmerWAVError.unreadable
        }
        var frames = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            try appendInterleaved(buffer, to: handle)
            frames += Int(buffer.frameLength)
        }
        return frames
    }

    private static func appendInterleaved(_ buffer: AVAudioPCMBuffer, to handle: FileHandle) throws {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        var interleaved = [Float](repeating: 0, count: frames * 2)
        let left = channels[0]
        let right = channelCount > 1 ? channels[1] : channels[0]
        for frame in 0..<frames {
            interleaved[frame * 2] = left[frame]
            interleaved[frame * 2 + 1] = right[frame]
        }
        let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.write(contentsOf: data)
    }
}

/// Interleaved stereo float32 written by `TrimmerDecoder.decodeRaw`.
public final class TrimmerRawAudio: @unchecked Sendable {
    public let frameCount: Int
    private let handle: FileHandle
    private let lock = NSLock()

    public init(url: URL) throws {
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        frameCount = max(0, bytes / 8)
        handle = try FileHandle(forReadingFrom: url)
    }

    public func read(frame: Int, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var output = [Float](repeating: 0, count: count * 2)
        let first = max(0, frame)
        let last = min(frameCount, frame + count)
        guard last > first else { return output }
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.seek(toOffset: UInt64(first * 8))
            let byteCount = (last - first) * 8
            guard let data = try handle.read(upToCount: byteCount) else { return output }
            let destination = (first - frame) * 2
            data.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                for index in 0..<min(floats.count, output.count - destination) {
                    output[destination + index] = floats[index]
                }
            }
        } catch {
            return output
        }
        return output
    }
}
