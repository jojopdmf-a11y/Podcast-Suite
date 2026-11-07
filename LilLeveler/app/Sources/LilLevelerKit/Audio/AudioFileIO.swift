import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Load common audio containers via AVFoundation into a mapped PCM working copy.
enum AudioFileIO {
    /// Formats we advertise in the open panel / docs.
    /// Prefer broad `audio` so the macOS panel doesn’t grey out MP3/M4A.
    static let importTypes: [UTType] = [.audio]

    static let importExtensions = ["wav", "wave", "aif", "aiff", "mp3", "m4a", "aac", "caf", "flac", "ogg", "wma"]

    private static let decodeChunkFrames: AVAudioFrameCount = 65_536

    static func isSupportedAudioURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if importExtensions.contains(ext) { return true }
        return (try? AVAudioFile(forReading: url)) != nil
    }

    /// Decode `url` in modest chunks so a 4-hour MP3 is not inflated into RAM at once.
    static func ingest(
        url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> PCMStore {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw LevelerError.loadFailed("Can’t open “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }

        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let frames64 = file.length
        guard frames64 > 0 else {
            throw LevelerError.loadFailed("File has no audio frames.")
        }
        guard frames64 <= Int64(Int.max) else {
            throw LevelerError.loadFailed("This show is too long to open.")
        }
        let frames = Int(frames64)
        guard channels >= 1, channels <= 8 else {
            throw LevelerError.loadFailed("Unsupported audio layout (\(channels) ch, \(frames) frames).")
        }

        let store = try PCMStore.createTemporary(
            sampleRate: format.sampleRate,
            channelCount: channels,
            frameCount: frames
        )
        store.adviseSequential()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.decodeChunkFrames) else {
            throw LevelerError.loadFailed("Out of memory reading audio.")
        }

        var written = 0
        var lastReported = -1
        while written < frames {
            let remaining = frames - written
            let want = min(Int(Self.decodeChunkFrames), remaining)
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(want))
            } catch {
                throw LevelerError.loadFailed("Read failed: \(error.localizedDescription)")
            }
            let got = Int(buffer.frameLength)
            if got <= 0 { break }
            try store.write(from: buffer, atFrame: written)
            written += got
            let pct = Int((Double(written) / Double(frames)) * 100.0)
            if pct != lastReported {
                lastReported = pct
                progress?(Double(written) / Double(frames))
            }
        }

        guard written > 0 else {
            throw LevelerError.loadFailed("File has no audio frames.")
        }
        if written < frames {
            try store.shrinkFrameCount(to: written)
        }
        store.sync()
        progress?(1)
        return store
    }
}
