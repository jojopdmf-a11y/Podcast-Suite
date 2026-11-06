import AVFoundation
import Foundation
import Testing
@testable import LilLevelerKit

private func makeStore(
    rate: Double,
    frames: Int,
    channels: Int = 2,
    fill: (Int, Int) -> Float
) throws -> PCMStore {
    let store = try PCMStore.createTemporary(sampleRate: rate, channelCount: channels, frameCount: frames)
    var buffer = [Float](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
        for channel in 0..<channels {
            buffer[frame * channels + channel] = fill(frame, channel)
        }
    }
    store.write(interleaved: buffer, startFrame: 0, frames: frames)
    return store
}

private func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("leveler-out-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct FileFacts {
    var rate: Double
    var channels: AVAudioChannelCount
    var bitDepth: Int?
    var isFloat: Bool
    var formatID: UInt32
}

private func facts(at url: URL) throws -> FileFacts {
    let file = try AVAudioFile(forReading: url)
    let settings = file.fileFormat.settings
    return FileFacts(
        rate: file.fileFormat.sampleRate,
        channels: file.fileFormat.channelCount,
        bitDepth: settings[AVLinearPCMBitDepthKey] as? Int,
        isFloat: (settings[AVLinearPCMIsFloatKey] as? Bool) ?? false,
        formatID: settings[AVFormatIDKey] as? UInt32 ?? 0
    )
}

private func int16Samples(_ data: Data) -> [Int16] {
    let bytes = [UInt8](data)
    var values: [Int16] = []
    values.reserveCapacity(bytes.count / 2)
    var index = 0
    while index + 1 < bytes.count {
        let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
        values.append(Int16(bitPattern: bits))
        index += 2
    }
    return values
}

private func wavPayload(_ url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    let bytes = [UInt8](data)
    var index = 12
    while index + 8 <= bytes.count {
        let tag = String(bytes: bytes[index..<(index + 4)], encoding: .ascii)
        let size = Int(UInt32(bytes[index + 4])
            | (UInt32(bytes[index + 5]) << 8)
            | (UInt32(bytes[index + 6]) << 16)
            | (UInt32(bytes[index + 7]) << 24))
        let start = index + 8
        guard start + size <= bytes.count else { break }
        if tag == "data" {
            return data.subdata(in: start..<(start + size))
        }
        let padded = size + (size & 1)
        index = start + padded
    }
    Issue.record("WAV data chunk missing")
    return Data()
}

@Test func outputFilesMatchTypeDepthAndRate() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try makeStore(rate: 48_000, frames: 2_048) { frame, channel in
        let t = Double(frame) / 48_000
        return Float(sin(2 * Double.pi * 440 * t) * (channel == 0 ? 0.35 : 0.2))
    }
    for rate in LevelerOutputSettings.standardRates {
        for depth in [LevelerBitDepth.int16, .int24, .float32] {
            for container in [LevelerContainer.wav, .aiff] {
                let url = folder.appendingPathComponent("\(container.rawValue)-\(depth.rawValue)-\(Int(rate)).\(container.fileExtension)")
                let settings = LevelerOutputSettings(container: container, bitDepth: depth, rateMode: .explicit(rate))
                try LevelerOutputWriter.write(store: store, to: url, settings: settings, ditherSeed: 11)
                let info = try facts(at: url)
                #expect(abs(info.rate - rate) < 1, "\(url.lastPathComponent) rate")
                #expect(info.channels == 2)
                switch depth {
                case .float32:
                    #expect(info.isFloat)
                    #expect(info.bitDepth == 32)
                case .int16:
                    #expect(info.isFloat == false)
                    #expect(info.bitDepth == 16)
                case .int24:
                    #expect(info.isFloat == false)
                    #expect(info.bitDepth == 24)
                }
            }
        }
    }
    for rate in LevelerOutputSettings.aacRates {
        let url = folder.appendingPathComponent("aac-\(Int(rate)).m4a")
        let settings = LevelerOutputSettings(container: .m4a, bitDepth: .int24, rateMode: .explicit(rate))
        try LevelerOutputWriter.write(store: store, to: url, settings: settings)
        let info = try facts(at: url)
        #expect(abs(info.rate - rate) < 1)
        #expect(info.channels == 2)
        #expect(info.formatID == kAudioFormatMPEG4AAC)
    }
}

@Test func ditherIsOnlyAppliedTo16Bit() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let frames = 4_096
    let store = try makeStore(rate: 48_000, frames: frames) { frame, channel in
        if frame < 800 { return 0 }
        let slope = Float(frame) / Float(frames)
        return channel == 0 ? slope * 0.5 : -slope * 0.25
    }

    func write(_ name: String, depth: LevelerBitDepth, seed: UInt64) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let settings = LevelerOutputSettings(container: .wav, bitDepth: depth, rateMode: .matchSource)
        try LevelerOutputWriter.write(store: store, to: url, settings: settings, ditherSeed: seed)
        return url
    }

    let a16 = try write("a16.wav", depth: .int16, seed: 1)
    let b16 = try write("b16.wav", depth: .int16, seed: 2)
    let a24 = try write("a24.wav", depth: .int24, seed: 1)
    let b24 = try write("b24.wav", depth: .int24, seed: 2)
    let a32 = try write("a32.wav", depth: .float32, seed: 1)
    let b32 = try write("b32.wav", depth: .float32, seed: 2)

    let pcm16a = try wavPayload(a16)
    let pcm16b = try wavPayload(b16)
    #expect(pcm16a != pcm16b)
    #expect(try wavPayload(a24) == wavPayload(b24))
    #expect(try wavPayload(a32) == wavPayload(b32))

    var mismatches = 0
    var zerosThatMoved = 0
    let samples16 = int16Samples(pcm16a)
    for frame in 0..<frames {
        for channel in 0..<2 {
            let source = store.sample(frame: frame, channel: channel)
            let plain = LevelerOutputWriter.quantizeInt16(source)
            let written = samples16[frame * 2 + channel]
            if written != plain { mismatches += 1 }
            if source == 0, written != 0 { zerosThatMoved += 1 }
        }
    }
    #expect(mismatches > 0)
    #expect(zerosThatMoved > 0)

    let pcm24 = try wavPayload(a24)
    var packedMismatches = 0
    let bytes = [UInt8](pcm24)
    for frame in 0..<frames {
        for channel in 0..<2 {
            let source = store.sample(frame: frame, channel: channel)
            let expected = LevelerOutputWriter.quantizeInt24(source)
            let offset = (frame * 2 + channel) * 3
            let lo = UInt32(bytes[offset])
            let mid = UInt32(bytes[offset + 1])
            let hi = UInt32(bytes[offset + 2])
            var bits = lo | (mid << 8) | (hi << 16)
            if bits & 0x800000 != 0 { bits |= 0xFF000000 }
            let written = Int32(bitPattern: bits)
            if written != expected { packedMismatches += 1 }
        }
    }
    #expect(packedMismatches == 0)
}

@Test func mp3WriterRefusesToEncode() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try makeStore(rate: 48_000, frames: 256) { _, _ in 0.1 }
    let url = folder.appendingPathComponent("nope.mp3")
    let settings = LevelerOutputSettings(container: .mp3, bitDepth: .int16, rateMode: .matchSource)
    #expect(throws: (any Error).self) {
        try LevelerOutputWriter.write(store: store, to: url, settings: settings)
    }
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
}

@Test func outputRateFollowsSourceUnlessAsked() {
    let standalone = LevelerOutputSettings.standaloneDefaults
    #expect(standalone.container == .wav)
    #expect(standalone.bitDepth == .int16)
    #expect(abs(standalone.resolvedSampleRate(sourceRate: 48_000) - 48_000) < 1)
    #expect(abs(standalone.resolvedSampleRate(sourceRate: 22_050) - 22_050) < 1)

    let lounge = LevelerOutputSettings.loungeDefaults
    #expect(lounge.bitDepth == .int24)
    #expect(abs(lounge.resolvedSampleRate(sourceRate: 44_100) - 44_100) < 1)
    #expect(abs(lounge.resolvedSampleRate(sourceRate: 96_000) - 96_000) < 1)
    #expect(abs(lounge.resolvedSampleRate(sourceRate: 22_050) - 48_000) < 1)

    var aac = lounge
    aac.container = .m4a
    aac.rateMode = .explicit(96_000)
    #expect(abs(aac.resolvedSampleRate(sourceRate: 96_000) - 48_000) < 1)
    #expect(aac.rateIsEnabled(88_200) == false)
    #expect(aac.rateIsEnabled(48_000))
}

@Test func sampleRateConversionTruePeakReport() throws {
    let frames = 48_000 * 3
    let store = try makeStore(rate: 48_000, frames: frames) { frame, channel in
        let t = Double(frame) / 48_000
        var sample = Float(sin(2 * Double.pi * 180 * t) * 0.15 + sin(2 * Double.pi * 740 * t) * 0.05)
        // Spikes force the true-peak limiter up against the preset ceiling.
        if frame % 2_400 == 0 { sample = channel == 0 ? 0.99 : -0.99 }
        if frame % 2_400 == 1 { sample = channel == 0 ? -0.99 : 0.99 }
        return sample
    }
    let (leveled, after, _) = try LoudnessEngine.normalize(
        store,
        targetLUFS: -16,
        truePeakCeilingDbTP: -1
    )
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let up = folder.appendingPathComponent("to96.wav")
    let down = folder.appendingPathComponent("to44.wav")
    try LevelerOutputWriter.write(
        store: leveled,
        to: up,
        settings: LevelerOutputSettings(container: .wav, bitDepth: .float32, rateMode: .explicit(96_000))
    )
    try LevelerOutputWriter.write(
        store: leveled,
        to: down,
        settings: LevelerOutputSettings(container: .wav, bitDepth: .float32, rateMode: .explicit(44_100))
    )
    let upInfo = try facts(at: up)
    let downInfo = try facts(at: down)
    #expect(abs(upInfo.rate - 96_000) < 1)
    #expect(abs(downInfo.rate - 44_100) < 1)
    let tp96 = LoudnessEngine.analyze(try AudioFileIO.ingest(url: up)).truePeakDbTP
    let tp44 = LoudnessEngine.analyze(try AudioFileIO.ingest(url: down)).truePeakDbTP
    print(
        String(
            format: "PEAK_REPORT ceiling=-1.0 leveled_lufs=%.3f leveled_tp=%.3f src_48k_to_96k_tp=%.3f src_48k_to_44.1k_tp=%.3f",
            after.integratedLUFS,
            after.truePeakDbTP,
            tp96,
            tp44
        )
    )
    #expect(after.truePeakDbTP <= -0.9)
    #expect(tp96.isFinite)
    #expect(tp44.isFinite)
}
