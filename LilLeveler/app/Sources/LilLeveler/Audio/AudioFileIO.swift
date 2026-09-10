import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Load common audio containers via AVFoundation into interleaved float PCM.
enum AudioFileIO {
    /// Formats we advertise in the open panel / docs.
    /// Prefer broad `audio` so the macOS panel doesn’t grey out MP3/M4A.
    static let importTypes: [UTType] = [.audio]

    static let importExtensions = ["wav", "wave", "aif", "aiff", "mp3", "m4a", "aac", "caf", "flac", "ogg", "wma"]

    static func isSupportedAudioURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if importExtensions.contains(ext) { return true }
        return (try? AVAudioFile(forReading: url)) != nil
    }

    static func load(url: URL) throws -> WAVIO.Buffer {
        // Fast path for plain PCM/float WAV
        if url.pathExtension.lowercased() == "wav", let buf = try? WAVIO.load(url: url) {
            return buf
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw LevelerError.loadFailed("Can’t open “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }

        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else {
            throw LevelerError.loadFailed("File has no audio frames.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw LevelerError.loadFailed("Out of memory reading audio.")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw LevelerError.loadFailed("Read failed: \(error.localizedDescription)")
        }
        buffer.frameLength = frameCount

        let channels = Int(format.channelCount)
        let rate = format.sampleRate
        let frames = Int(buffer.frameLength)
        guard channels >= 1, channels <= 8, frames > 0 else {
            throw LevelerError.loadFailed("Unsupported audio layout (\(channels) ch, \(frames) frames).")
        }
        guard let channelsPtr = buffer.floatChannelData else {
            throw LevelerError.loadFailed("Expected float PCM from decoder.")
        }

        var interleaved = [Float](repeating: 0, count: frames * channels)
        if format.isInterleaved {
            let ptr = channelsPtr[0]
            for i in 0..<(frames * channels) {
                interleaved[i] = ptr[i]
            }
        } else {
            for f in 0..<frames {
                for c in 0..<channels {
                    interleaved[f * channels + c] = channelsPtr[c][f]
                }
            }
        }

        return WAVIO.Buffer(sampleRate: rate, channelCount: channels, samples: interleaved)
    }
}
