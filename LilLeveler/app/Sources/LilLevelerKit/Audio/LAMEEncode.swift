import CLame
import Foundation

/// Loads `libmp3lame.0.dylib` at runtime. A missing library disables MP3
/// instead of crashing. WAV, AIFF, and M4A never call into LAME.
enum LAMELibrary {
    static let isAvailable: Bool = openFirstCandidate()

    static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // LAMEEncode.swift → Audio → LilLevelerKit → Sources → app → LilLeveler → repo
        for _ in 0..<6 {
            url.deleteLastPathComponent()
        }
        return url
    }

    static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundle = Bundle.main
        if let frameworks = bundle.privateFrameworksURL {
            urls.append(frameworks.appendingPathComponent("libmp3lame.0.dylib"))
        }
        urls.append(bundle.bundleURL.appendingPathComponent("Contents/Frameworks/libmp3lame.0.dylib"))
        if let executable = bundle.executableURL {
            let folder = executable.deletingLastPathComponent()
            urls.append(folder.appendingPathComponent("libmp3lame.0.dylib"))
            urls.append(folder.appendingPathComponent("../Frameworks/libmp3lame.0.dylib").standardizedFileURL)
        }
        urls.append(repoRoot().appendingPathComponent("ThirdParty/lame/build/lib/libmp3lame.0.dylib"))
        return urls
    }

    private static func openFirstCandidate() -> Bool {
        for url in candidateURLs() {
            let exists = FileManager.default.isReadableFile(atPath: url.path)
            guard exists else { continue }
            let opened = url.path.withCString { lame_shim_open($0) }
            if opened == 0 {
                return true
            }
        }
        return false
    }
}

extension LevelerOutputWriter {
    static func writeMP3(
        _ store: PCMStore,
        to url: URL,
        settings: LevelerOutputSettings,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        guard LAMELibrary.isAvailable else {
            throw LevelerError.processFailed("MP3 encoder is missing.")
        }
        let channels = store.channelCount
        let frames = store.frameCount
        guard frames > 0 else {
            throw LevelerError.processFailed("Nothing to export yet.")
        }
        guard channels == 1 || channels == 2 else {
            throw LevelerError.processFailed("MP3 export supports mono or stereo.")
        }
        guard LevelerOutputSettings.mp3Rates.contains(where: { abs($0 - store.sampleRate) < 1 }) else {
            throw LevelerError.processFailed("MP3 uses 44.1 or 48 kHz.")
        }
        let sampleRate = Int(store.sampleRate.rounded())
        let bitrate = settings.mp3BitrateKbps
        guard let session = lame_shim_begin(Int32(channels), Int32(sampleRate), Int32(bitrate), UInt(frames)) else {
            throw LevelerError.processFailed(String(cString: lame_shim_last_error()))
        }
        defer { lame_shim_end(session) }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var finished = false
        defer {
            try? handle.close()
            if finished == false {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let chunk = 8_192
        var floats = [Float](repeating: 0, count: chunk * channels)
        var position = 0
        while position < frames {
            let count = store.copyFrames(start: position, count: min(chunk, frames - position), into: &floats)
            guard count > 0 else { break }
            let bytes = try encode(session, samples: floats, frames: count, channels: channels)
            if bytes.isEmpty == false {
                try handle.write(contentsOf: bytes)
            }
            position += count
            if frames > 0 {
                progress?(Double(position) / Double(frames))
            }
        }
        let tail = try flush(session)
        if tail.isEmpty == false {
            try handle.write(contentsOf: tail)
        }
        let tag = try lametag(session)
        guard tag.isEmpty == false else {
            throw LevelerError.processFailed("Could not write the MP3 duration tag.")
        }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: tag)
        finished = true
        progress?(1)
    }

    private static func encode(
        _ session: OpaquePointer,
        samples: [Float],
        frames: Int,
        channels: Int
    ) throws -> Data {
        var capacity = Int((1.25 * Double(frames)).rounded(.up)) + 7_200
        for _ in 0..<3 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written: Int32 = samples.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    guard let pcm = source.baseAddress, let mp3 = destination.baseAddress else { return -1 }
                    if channels == 1 {
                        return lame_shim_encode_mono(session, pcm, Int32(frames), mp3, Int32(capacity))
                    }
                    return lame_shim_encode_stereo(session, pcm, Int32(frames), mp3, Int32(capacity))
                }
            }
            if written == -1 {
                capacity *= 2
                continue
            }
            guard written >= 0 else {
                throw LevelerError.processFailed("Could not encode the MP3 file.")
            }
            return Data(output.prefix(Int(written)))
        }
        throw LevelerError.processFailed("Could not encode the MP3 file.")
    }

    private static func flush(_ session: OpaquePointer) throws -> Data {
        var capacity = 65_536
        for _ in 0..<3 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = output.withUnsafeMutableBufferPointer { destination -> Int32 in
                guard let mp3 = destination.baseAddress else { return -1 }
                return lame_shim_flush(session, mp3, Int32(capacity))
            }
            if written == -1 {
                capacity *= 2
                continue
            }
            guard written >= 0 else {
                throw LevelerError.processFailed("Could not finish the MP3 file.")
            }
            return Data(output.prefix(Int(written)))
        }
        throw LevelerError.processFailed("Could not finish the MP3 file.")
    }

    private static func lametag(_ session: OpaquePointer) throws -> Data {
        var output = [UInt8](repeating: 0, count: 8_192)
        let count = output.withUnsafeMutableBufferPointer { destination -> Int in
            guard let mp3 = destination.baseAddress else { return 0 }
            return Int(lame_shim_lametag(session, mp3, destination.count))
        }
        guard count > 0, count <= output.count else {
            throw LevelerError.processFailed("Could not write the MP3 duration tag.")
        }
        return Data(output.prefix(count))
    }
}
