import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Decode everyday audio (WAV, AIFF, MP3, M4A…) into the same float buffer Mixer already uses.
enum MixerAudioIO {
    static let importExtensions = [
        "wav", "wave", "aif", "aiff", "mp3", "m4a", "aac", "caf", "flac", "ogg"
    ]

    static func isSupportedAudioURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if importExtensions.contains(ext) { return true }
        return (try? AVAudioFile(forReading: url)) != nil
    }

    static func looksLikeMusic(url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.contains("music") || name.contains("sfx")
    }

    static func displayName(url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return "Track" }
        if base.count > 22 { return String(base.prefix(20)) + "…" }
        return base
    }

    static func load(url: URL, targetSampleRate: Double? = nil) throws -> WAVIO.Buffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MixerError.loadFailed("Can’t open “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }

        let srcFormat = file.processingFormat
        let srcFrames = Int(file.length)
        guard srcFrames > 0 else {
            throw MixerError.loadFailed("“\(url.lastPathComponent)” has no audio.")
        }
        let channels = Int(srcFormat.channelCount)
        guard channels >= 1, channels <= 8 else {
            throw MixerError.loadFailed("“\(url.lastPathComponent)” has an unsupported channel layout.")
        }

        var interleaved = try readInterleaved(file: file, format: srcFormat, frames: srcFrames, channels: channels)
        var rate = srcFormat.sampleRate

        if let target = targetSampleRate, abs(target - rate) > 0.5 {
            interleaved = try resample(
                interleaved,
                channels: channels,
                from: rate,
                to: target
            )
            rate = target
        }

        return WAVIO.Buffer(
            sampleRate: rate,
            channelCount: channels,
            samples: interleaved
        )
    }

    private static func readInterleaved(
        file: AVAudioFile,
        format: AVAudioFormat,
        frames: Int,
        channels: Int
    ) throws -> [Float] {
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw MixerError.loadFailed("Out of memory reading audio.")
        }
        var out = [Float]()
        out.reserveCapacity(frames * channels)
        var remaining = frames
        while remaining > 0 {
            let want = min(Int(chunk), remaining)
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(want))
            } catch {
                throw MixerError.loadFailed("Read failed: \(error.localizedDescription)")
            }
            let got = Int(buffer.frameLength)
            if got <= 0 { break }
            append(buffer: buffer, channels: channels, into: &out)
            remaining -= got
        }
        guard !out.isEmpty else {
            throw MixerError.loadFailed("File has no audio frames.")
        }
        return out
    }

    private static func append(buffer: AVAudioPCMBuffer, channels: Int, into dest: inout [Float]) {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        if let chans = buffer.floatChannelData {
            for f in 0..<n {
                for c in 0..<channels {
                    dest.append(chans[c][f])
                }
            }
            return
        }
        if buffer.format.isInterleaved, let list = buffer.audioBufferList.pointee.mBuffers.mData {
            let ptr = list.assumingMemoryBound(to: Float.self)
            dest.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n * channels))
        }
    }

    private static func resample(
        _ interleaved: [Float],
        channels: Int,
        from srcRate: Double,
        to destRate: Double
    ) throws -> [Float] {
        let ch = AVAudioChannelCount(channels)
        guard
            let srcFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: srcRate,
                channels: ch,
                interleaved: false
            ),
            let dstFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: destRate,
                channels: ch,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: srcFmt, to: dstFmt)
        else {
            throw MixerError.loadFailed("Could not convert sample rate.")
        }

        let srcFrames = interleaved.count / max(1, channels)
        let dstFrames = Int((Double(srcFrames) * destRate / srcRate).rounded(.up)) + 32
        guard
            let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(srcFrames)),
            let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: AVAudioFrameCount(dstFrames))
        else {
            throw MixerError.loadFailed("Out of memory converting sample rate.")
        }

        srcBuf.frameLength = AVAudioFrameCount(srcFrames)
        guard let srcCh = srcBuf.floatChannelData else {
            throw MixerError.loadFailed("Could not convert sample rate.")
        }
        for f in 0..<srcFrames {
            for c in 0..<channels {
                srcCh[c][f] = interleaved[f * channels + c]
            }
        }

        var supplied = false
        var convertError: NSError?
        let status = converter.convert(to: dstBuf, error: &convertError) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return srcBuf
        }
        if let convertError {
            throw MixerError.loadFailed(convertError.localizedDescription)
        }
        if status == .error {
            throw MixerError.loadFailed("Sample-rate conversion failed.")
        }

        let got = Int(dstBuf.frameLength)
        guard got > 0, let dstCh = dstBuf.floatChannelData else {
            throw MixerError.loadFailed("Sample-rate conversion produced no audio.")
        }
        var out = [Float]()
        out.reserveCapacity(got * channels)
        for f in 0..<got {
            for c in 0..<channels {
                out.append(dstCh[c][f])
            }
        }
        return out
    }
}
