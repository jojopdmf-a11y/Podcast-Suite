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

@Test func mp3EncodesMonoAndStereoAtPodcastRates() async throws {
    try #require(LAMELibrary.isAvailable, "Run ThirdParty/lame/build_lame.sh before the MP3 tests.")
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for rate in [44_100.0, 48_000.0] {
        let frames = Int(rate * 2)
        for channels in [1, 2] {
            let store = try makeStore(rate: rate, frames: frames, channels: channels) { frame, channel in
                let t = Double(frame) / rate
                return Float(sin(2 * Double.pi * (channel == 0 ? 440 : 554) * t) * 0.25)
            }
            let url = folder.appendingPathComponent("tone-\(channels)ch-\(Int(rate)).mp3")
            let settings = LevelerOutputSettings(
                container: .mp3,
                bitDepth: .int24,
                rateMode: .explicit(rate),
                mp3BitrateKbps: 128
            )
            try LevelerOutputWriter.write(store: store, to: url, settings: settings)
            try await expectMP3(url, rate: rate, channels: channels, seconds: 2, bitrate: 128)
        }
    }

    let wide = try makeStore(rate: 48_000, frames: 48_000, channels: 3) { _, _ in 0.1 }
    let rejected = folder.appendingPathComponent("wide.mp3")
    #expect(throws: (any Error).self) {
        try LevelerOutputWriter.write(
            store: wide,
            to: rejected,
            settings: LevelerOutputSettings(container: .mp3, bitDepth: .int16, rateMode: .matchSource)
        )
    }
    #expect(FileManager.default.fileExists(atPath: rejected.path) == false)

    let stereo = try makeStore(rate: 48_000, frames: 96_000) { frame, channel in
        Float(sin(2 * Double.pi * 330 * Double(frame) / 48_000) * (channel == 0 ? 0.2 : 0.15))
    }
    var sizes: [Int: Int] = [:]
    for bitrate in LevelerOutputSettings.mp3Bitrates {
        let url = folder.appendingPathComponent("rate-\(bitrate).mp3")
        try LevelerOutputWriter.write(
            store: stereo,
            to: url,
            settings: LevelerOutputSettings(
                container: .mp3,
                bitDepth: .int16,
                rateMode: .explicit(48_000),
                mp3BitrateKbps: bitrate
            )
        )
        let size = try fileSize(url)
        sizes[bitrate] = size
        let expected = Double(bitrate * 1_000) / 8.0 * 2.0
        let ratio = Double(size) / expected
        #expect(ratio > 0.85 && ratio < 1.2, "\(bitrate) kbps file is \(size) bytes, expected about \(Int(expected))")
    }
    #expect((sizes[192] ?? 0) > (sizes[160] ?? 0))
    #expect((sizes[160] ?? 0) > (sizes[128] ?? 0))
    #expect((sizes[128] ?? 0) > (sizes[96] ?? 0))

    for rate in [88_200.0, 96_000.0] {
        let frames = Int(rate)
        let store = try makeStore(rate: rate, frames: frames) { frame, _ in
            Float(sin(2 * Double.pi * 440 * Double(frame) / rate) * 0.2)
        }
        let url = folder.appendingPathComponent("fallback-\(Int(rate)).mp3")
        let settings = LevelerOutputSettings(
            container: .mp3,
            bitDepth: .int24,
            rateMode: .explicit(rate),
            mp3BitrateKbps: 128
        )
        #expect(settings.rateIsEnabled(rate) == false)
        #expect(abs(settings.resolvedSampleRate(sourceRate: rate) - 48_000) < 1)
        try LevelerOutputWriter.write(store: store, to: url, settings: settings)
        let file = try AVAudioFile(forReading: url)
        #expect(abs(file.fileFormat.sampleRate - 48_000) < 1)
        #expect(file.fileFormat.channelCount == 2)
    }
}

@Test func mp3SixtySecondFileIsLayer3() async throws {
    try #require(LAMELibrary.isAvailable, "Run ThirdParty/lame/build_lame.sh before the MP3 tests.")
    let rate = 48_000.0
    let frames = Int(rate * 60)
    let store = try makeStore(rate: rate, frames: frames) { frame, channel in
        let t = Double(frame) / rate
        return Float(sin(2 * Double.pi * (channel == 0 ? 220 : 277) * t) * 0.2)
    }
    let folder = try scratchFolder()
    let url = folder.appendingPathComponent("minute.mp3")
    try LevelerOutputWriter.write(
        store: store,
        to: url,
        settings: LevelerOutputSettings(container: .mp3, bitDepth: .int24, rateMode: .explicit(rate), mp3BitrateKbps: 128)
    )
    try await expectMP3(url, rate: rate, channels: 2, seconds: 60, bitrate: 128)
    let published = URL(fileURLWithPath: "/tmp/podleveler-mp3-e2e.mp3")
    try? FileManager.default.removeItem(at: published)
    try FileManager.default.copyItem(at: url, to: published)
    let report = try afinfo(published)
    print(report)
    #expect(report.contains(".mp3"))
    #expect(report.localizedCaseInsensitiveContains("mpeg") || report.contains(".mp3"))
    #expect(report.contains("48000"))
    #expect(report.contains("128"))
    try? FileManager.default.removeItem(at: folder)
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

    #expect(standalone.mp3BitrateKbps == 128)
    #expect(lounge.mp3BitrateKbps == 128)
    let odd = LevelerOutputSettings(container: .mp3, bitDepth: .int16, rateMode: .explicit(48_000), mp3BitrateKbps: 320)
    #expect(odd.mp3BitrateKbps == 128)

    var mp3 = lounge
    mp3.container = .mp3
    mp3.rateMode = .explicit(96_000)
    #expect(abs(mp3.resolvedSampleRate(sourceRate: 96_000) - 48_000) < 1)
    mp3.rateMode = .explicit(88_200)
    #expect(abs(mp3.resolvedSampleRate(sourceRate: 88_200) - 48_000) < 1)
    #expect(mp3.rateIsEnabled(88_200) == false)
    #expect(mp3.rateIsEnabled(96_000) == false)
    #expect(mp3.rateIsEnabled(44_100))
    #expect(mp3.rateIsEnabled(48_000))
    mp3.rateMode = .matchSource
    #expect(abs(mp3.resolvedSampleRate(sourceRate: 44_100) - 44_100) < 1)
    #expect(abs(mp3.resolvedSampleRate(sourceRate: 96_000) - 48_000) < 1)

    var wav = lounge
    wav.container = .wav
    wav.rateMode = .explicit(96_000)
    #expect(abs(wav.resolvedSampleRate(sourceRate: 96_000) - 96_000) < 1)
    #expect(wav.rateIsEnabled(88_200))
    #expect(wav.rateIsEnabled(96_000))
}

private func fileSize(_ url: URL) throws -> Int {
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    return try #require(size)
}

private func expectMP3(
    _ url: URL,
    rate: Double,
    channels: Int,
    seconds: Double,
    bitrate: Int
) async throws {
    let size = try fileSize(url)
    #expect(size > 0)
    let header = try Data(contentsOf: url).prefix(2_048)
    #expect(header.first == 0xFF)
    #expect(header.prefix(3) != Data("ID3".utf8))
    #expect(header.range(of: Data("LAME".utf8)) != nil)

    let file = try AVAudioFile(forReading: url)
    #expect(abs(file.fileFormat.sampleRate - rate) < 1)
    #expect(Int(file.fileFormat.channelCount) == channels)
    let formatID = file.fileFormat.settings[AVFormatIDKey] as? UInt32
    #expect(formatID == kAudioFormatMPEGLayer3)
    let fileSeconds = Double(file.length) / file.fileFormat.sampleRate
    let asset = AVURLAsset(url: url)
    let assetSeconds = CMTimeGetSeconds(try await asset.load(.duration))
    let slop = (1_152.0 + 576.0) / rate
    #expect(abs(fileSeconds - seconds) <= slop, "AVAudioFile duration \(fileSeconds) vs \(seconds)")
    #expect(abs(assetSeconds - seconds) <= slop, "AVURLAsset duration \(assetSeconds) vs \(seconds)")

    let expectedBytes = Double(bitrate * 1_000) / 8.0 * seconds
    let ratio = Double(size) / expectedBytes
    #expect(ratio > 0.85 && ratio < 1.2, "size \(size) vs \(Int(expectedBytes))")
}

private func afinfo(_ url: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
    process.arguments = [url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
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
