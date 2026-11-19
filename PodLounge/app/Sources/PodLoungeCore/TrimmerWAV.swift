import Foundation

public enum TrimmerWAVError: Error, Equatable, LocalizedError {
    case unreadable
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            "The audio file could not be read."
        case let .unsupported(detail):
            "The audio file is not a stereo WAV this cut can write (\(detail))."
        }
    }
}

/// Stereo WAV files for TheCut's export. 24-bit integer stays at or under full scale.
/// 32-bit float keeps samples that peak above 0 dBFS.
public enum TrimmerWAV {
    public enum Depth: Equatable, Sendable {
        case int24
        case float32
    }

    public static func write(stereo: [Float], sampleRate: Double, depth: Depth, to url: URL) throws {
        let writer = try Writer(url: url, sampleRate: sampleRate, depth: depth)
        try writer.append(stereo)
        try writer.close()
    }

    /// Rewrites a stereo WAV this type can read into another bit depth, streaming so a long episode is not held in memory.
    public static func rewrite(from source: URL, to destination: URL, depth: Depth) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let header = try parseHeader(input)
        let writer = try Writer(url: destination, sampleRate: header.sampleRate, depth: depth)
        var remaining = header.dataBytes
        let framesPerRead = 8192
        while remaining >= header.blockAlign {
            let bytes = min(remaining, framesPerRead * header.blockAlign)
            let aligned = bytes - (bytes % header.blockAlign)
            guard aligned > 0, let data = try input.read(upToCount: aligned), data.count >= header.blockAlign else { break }
            var stereo: [Float] = []
            stereo.reserveCapacity((data.count / header.blockAlign) * 2)
            var offset = 0
            while offset + header.blockAlign <= data.count {
                switch header.depth {
                case .int24:
                    stereo.append(decodeInt24(data, offset))
                    stereo.append(decodeInt24(data, offset + 3))
                case .float32:
                    stereo.append(decodeFloat(data, offset))
                    stereo.append(decodeFloat(data, offset + 4))
                }
                offset += header.blockAlign
            }
            try writer.append(stereo)
            remaining -= offset
        }
        try writer.close()
    }

    public static func read(from url: URL) throws -> (sampleRate: Double, stereo: [Float]) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try parseHeader(handle)
        let bytes = try handle.readToEnd() ?? Data()
        let available = min(bytes.count, header.dataBytes)
        var stereo: [Float] = []
        stereo.reserveCapacity((available / header.blockAlign) * 2)
        var offset = 0
        while offset + header.blockAlign <= available {
            switch header.depth {
            case .int24:
                stereo.append(decodeInt24(bytes, offset))
                stereo.append(decodeInt24(bytes, offset + 3))
            case .float32:
                stereo.append(decodeFloat(bytes, offset))
                stereo.append(decodeFloat(bytes, offset + 4))
            }
            offset += header.blockAlign
        }
        return (header.sampleRate, stereo)
    }

    public final class Writer {
        private let handle: FileHandle
        private let depth: Depth
        private let blockAlign: Int
        private var dataBytes = 0
        private var closed = false

        public init(url: URL, sampleRate: Double, depth: Depth) throws {
            let rate = max(1, Int(sampleRate.rounded()))
            self.depth = depth
            switch depth {
            case .int24: blockAlign = 6
            case .float32: blockAlign = 8
            }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            var header = Data(count: 44)
            header.replaceSubrange(0..<4, with: Data("RIFF".utf8))
            header.replaceSubrange(8..<12, with: Data("WAVE".utf8))
            header.replaceSubrange(12..<16, with: Data("fmt ".utf8))
            writeUInt32(16, into: &header, at: 16)
            switch depth {
            case .int24:
                writeUInt16(1, into: &header, at: 20)
                writeUInt16(24, into: &header, at: 34)
            case .float32:
                writeUInt16(3, into: &header, at: 20)
                writeUInt16(32, into: &header, at: 34)
            }
            writeUInt16(2, into: &header, at: 22)
            writeUInt32(UInt32(rate), into: &header, at: 24)
            writeUInt32(UInt32(rate * blockAlign), into: &header, at: 28)
            writeUInt16(UInt16(blockAlign), into: &header, at: 32)
            header.replaceSubrange(36..<40, with: Data("data".utf8))
            try handle.write(contentsOf: header)
        }

        public func append(_ stereo: [Float]) throws {
            guard !closed else { return }
            var payload = Data()
            payload.reserveCapacity((stereo.count / 2) * blockAlign)
            var index = 0
            while index + 1 < stereo.count {
                switch depth {
                case .int24:
                    appendInt24(stereo[index], to: &payload)
                    appendInt24(stereo[index + 1], to: &payload)
                case .float32:
                    appendFloat(stereo[index], to: &payload)
                    appendFloat(stereo[index + 1], to: &payload)
                }
                index += 2
                dataBytes += blockAlign
            }
            try handle.write(contentsOf: payload)
        }

        public func close() throws {
            guard !closed else { return }
            closed = true
            try handle.seek(toOffset: 4)
            var riff = Data()
            appendUInt32(UInt32(36 + dataBytes), to: &riff)
            try handle.write(contentsOf: riff)
            try handle.seek(toOffset: 40)
            var data = Data()
            appendUInt32(UInt32(dataBytes), to: &data)
            try handle.write(contentsOf: data)
            try handle.close()
        }

        private func appendInt24(_ sample: Float, to data: inout Data) {
            let clamped = max(-1, min(1, sample))
            var value = Int32((Double(clamped) * 8_388_607).rounded(.toNearestOrAwayFromZero))
            value = max(-8_388_608, min(8_388_607, value))
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
        }

        private func appendFloat(_ sample: Float, to data: inout Data) {
            var value = sample
            withUnsafeBytes(of: &value) { raw in
                data.append(contentsOf: raw)
            }
        }
    }

    private struct Header {
        var sampleRate: Double
        var depth: Depth
        var blockAlign: Int
        var dataBytes: Int
    }

    private static func parseHeader(_ handle: FileHandle) throws -> Header {
        let prefix = try handle.read(upToCount: 12) ?? Data()
        guard prefix.count == 12, String(decoding: prefix.prefix(4), as: UTF8.self) == "RIFF" else {
            throw TrimmerWAVError.unreadable
        }
        var formatTag: UInt16 = 0
        var channels: UInt16 = 0
        var sampleRate: UInt32 = 0
        var bits: UInt16 = 0
        var blockAlign = 0
        var dataBytes = 0
        var foundData = false
        while true {
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { break }
            let name = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = Int(readUInt32(chunk, 4))
            if name == "fmt " {
                let body = try handle.read(upToCount: size) ?? Data()
                guard body.count >= 16 else { throw TrimmerWAVError.unreadable }
                formatTag = readUInt16(body, 0)
                channels = readUInt16(body, 2)
                sampleRate = readUInt32(body, 4)
                bits = readUInt16(body, 14)
                blockAlign = Int(readUInt16(body, 12))
                if size % 2 == 1 { _ = try handle.read(upToCount: 1) }
            } else if name == "data" {
                dataBytes = size
                foundData = true
                break
            } else {
                let skip = size + (size % 2)
                try handle.seek(toOffset: handle.offset() + UInt64(skip))
            }
        }
        guard foundData, channels == 2, sampleRate > 0 else {
            throw TrimmerWAVError.unsupported("expected stereo PCM")
        }
        let depth: Depth
        if formatTag == 1, bits == 24, blockAlign == 6 {
            depth = .int24
        } else if formatTag == 3, bits == 32, blockAlign == 8 {
            depth = .float32
        } else {
            throw TrimmerWAVError.unsupported("format \(formatTag) bits \(bits)")
        }
        return Header(sampleRate: Double(sampleRate), depth: depth, blockAlign: blockAlign, dataBytes: dataBytes)
    }

    private static func decodeInt24(_ data: Data, _ offset: Int) -> Float {
        guard offset + 2 < data.count else { return 0 }
        let b0 = Int32(data[offset])
        let b1 = Int32(data[offset + 1])
        let b2 = Int32(data[offset + 2])
        var value = b0 | (b1 << 8) | (b2 << 16)
        if value & 0x80_0000 != 0 {
            value |= ~0xFF_FFFF
        }
        return Float(value) / 8_388_607
    }

    private static func decodeFloat(_ data: Data, _ offset: Int) -> Float {
        guard offset + 3 < data.count else { return 0 }
        let bytes = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
        return bytes.withUnsafeBytes { raw in
            raw.load(as: Float.self)
        }
    }

    private static func writeUInt16(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private static func writeUInt32(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
