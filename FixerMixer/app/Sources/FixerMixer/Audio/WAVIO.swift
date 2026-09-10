import Foundation

enum WAVIO {
    struct Buffer {
        var sampleRate: Double
        var channelCount: Int
        /// Interleaved float samples −1…1
        var samples: [Float]
        var frameCount: Int { samples.count / max(1, channelCount) }
    }

    static func load(url: URL) throws -> Buffer {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { throw MixerError.loadFailed("File too small") }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Buffer in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw MixerError.loadFailed("Empty file")
            }
            // RIFF / WAVE
            guard String(bytes: raw[0..<4], encoding: .ascii) == "RIFF",
                  String(bytes: raw[8..<12], encoding: .ascii) == "WAVE"
            else { throw MixerError.loadFailed("Not a WAV file") }

            var offset = 12
            var fmtChannels = 1
            var fmtRate = 44100
            var fmtBits = 16
            var fmtAudioFormat = 1
            var pcmData: Data?

            while offset + 8 <= data.count {
                let chunkId = String(bytes: raw[offset..<(offset + 4)], encoding: .ascii) ?? ""
                let chunkSize = Int(readU32(base, offset + 4))
                let next = offset + 8 + chunkSize + (chunkSize % 2)
                if chunkId == "fmt ", chunkSize >= 16 {
                    fmtAudioFormat = Int(readU16(base, offset + 8))
                    fmtChannels = Int(readU16(base, offset + 10))
                    fmtRate = Int(readU32(base, offset + 12))
                    fmtBits = Int(readU16(base, offset + 22))
                } else if chunkId == "data" {
                    let start = offset + 8
                    let end = min(data.count, start + chunkSize)
                    pcmData = data.subdata(in: start..<end)
                }
                offset = next
                if offset > data.count { break }
            }

            guard let pcm = pcmData else { throw MixerError.loadFailed("No data chunk") }
            guard fmtAudioFormat == 1 || fmtAudioFormat == 3 else {
                throw MixerError.loadFailed("Only PCM/float WAV supported")
            }

            var floats: [Float] = []
            if fmtAudioFormat == 3, fmtBits == 32 {
                floats = pcm.withUnsafeBytes { ptr in
                    Array(ptr.bindMemory(to: Float.self))
                }
            } else if fmtBits == 16 {
                floats = pcm.withUnsafeBytes { ptr in
                    ptr.bindMemory(to: Int16.self).map { Float($0) / 32768.0 }
                }
            } else if fmtBits == 24 {
                let bytes = [UInt8](pcm)
                floats.reserveCapacity(bytes.count / 3)
                var i = 0
                while i + 2 < bytes.count {
                    var v = Int32(bytes[i]) | (Int32(bytes[i + 1]) << 8) | (Int32(bytes[i + 2]) << 16)
                    if v & 0x800000 != 0 { v |= ~0xFFFFFF }
                    floats.append(Float(v) / 8_388_608.0)
                    i += 3
                }
            } else if fmtBits == 32, fmtAudioFormat == 1 {
                floats = pcm.withUnsafeBytes { ptr in
                    ptr.bindMemory(to: Int32.self).map { Float($0) / Float(Int32.max) }
                }
            } else {
                throw MixerError.loadFailed("Unsupported bit depth \(fmtBits)")
            }

            return Buffer(sampleRate: Double(fmtRate), channelCount: fmtChannels, samples: floats)
        }
    }

    static func write(url: URL, buffer: Buffer) throws {
        let frames = buffer.frameCount
        let channels = buffer.channelCount
        var pcm = Data(capacity: frames * channels * 2)
        for s in buffer.samples {
            let clipped = max(-1.0, min(1.0, s))
            var v = Int16((clipped * 32767.0).rounded())
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        let dataSize = UInt32(pcm.count)
        let byteRate = UInt32(buffer.sampleRate) * UInt32(channels) * 2
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        var chunkSize = UInt32(36 + dataSize)
        appendU32(&header, chunkSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        appendU32(&header, 16)
        appendU16(&header, 1) // PCM
        appendU16(&header, UInt16(channels))
        appendU32(&header, UInt32(buffer.sampleRate))
        appendU32(&header, byteRate)
        appendU16(&header, UInt16(channels * 2))
        appendU16(&header, 16)
        header.append(contentsOf: Array("data".utf8))
        appendU32(&header, dataSize)
        try (header + pcm).write(to: url)
    }

    private static func readU16(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt16 {
        UInt16(base[offset]) | (UInt16(base[offset + 1]) << 8)
    }

    private static func readU32(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(base[offset])
            | (UInt32(base[offset + 1]) << 8)
            | (UInt32(base[offset + 2]) << 16)
            | (UInt32(base[offset + 3]) << 24)
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
