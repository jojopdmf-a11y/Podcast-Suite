import Foundation

enum WAVIO {
    static func write(
        url: URL,
        store: PCMStore,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let frames = store.frameCount
        let channels = store.channelCount
        let dataSize64 = Int64(frames) * Int64(channels) * 2
        guard dataSize64 <= Int64(UInt32.max) else {
            throw LevelerError.processFailed(
                "This show is too long to save as a WAV (the file would pass 4 GB). Try a shorter section."
            )
        }
        let dataSize = UInt32(dataSize64)
        let byteRate = UInt32(store.sampleRate) * UInt32(channels) * 2
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        appendU32(&header, 36 + dataSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        appendU32(&header, 16)
        appendU16(&header, 1) // PCM
        appendU16(&header, UInt16(channels))
        appendU32(&header, UInt32(store.sampleRate))
        appendU32(&header, byteRate)
        appendU16(&header, UInt16(channels * 2))
        appendU16(&header, 16)
        header.append(contentsOf: Array("data".utf8))
        appendU32(&header, dataSize)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw LevelerError.processFailed("Could not create the leveled WAV.")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: header)

        let chunkFrames = 16_384
        var floats = [Float](repeating: 0, count: chunkFrames * channels)
        var pcm = Data(capacity: chunkFrames * channels * 2)
        var pos = 0
        var lastPct = -1
        while pos < frames {
            let n = store.copyFrames(start: pos, count: min(chunkFrames, frames - pos), into: &floats)
            guard n > 0 else { break }
            pcm.removeAll(keepingCapacity: true)
            let count = n * channels
            for i in 0..<count {
                let clipped = max(-1.0, min(1.0, floats[i]))
                var v = Int16((clipped * 32767.0).rounded())
                withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
            }
            try handle.write(contentsOf: pcm)
            pos += n
            let pct = Int((Double(pos) / Double(frames)) * 100.0)
            if pct != lastPct {
                lastPct = pct
                progress?(Double(pos) / Double(frames))
            }
        }
    }

    private static func appendU16(_ data: inout Data, _ v: UInt16) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendU32(_ data: inout Data, _ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
