import AVFoundation
import Foundation
import LilLevelerKit
import Testing
@testable import PodLoungeCore

@Test func mixedSourceFilesDecodeToOneRateAndMonoStaysMono() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }

    let wav44 = scratch.root.appendingPathComponent("voice-44.wav")
    let wav48 = scratch.root.appendingPathComponent("bed-48.wav")
    try TrimmerWAV.write(
        interleaved: tone(frames: 44_100, channels: 1, rate: 44_100),
        channels: 1,
        sampleRate: 44_100,
        depth: .int24,
        to: wav44
    )
    try TrimmerWAV.write(
        stereo: tone(frames: 48_000, channels: 2, rate: 48_000),
        sampleRate: 48_000,
        depth: .float32,
        to: wav48
    )

    var sources = [wav44, wav48]
    if LevelerContainer.mp3.isWritable {
        let mp3 = scratch.root.appendingPathComponent("ad.mp3")
        let settings = LevelerOutputSettings(
            container: .mp3,
            bitDepth: .int16,
            rateMode: .explicit(44_100),
            mp3BitrateKbps: 128
        )
        try LevelerFileExport.write(pcmWAV: wav44, to: mp3, settings: settings)
        sources.append(mp3)
    }
    let m4a = scratch.root.appendingPathComponent("sting.m4a")
    try LevelerFileExport.write(
        pcmWAV: wav48,
        to: m4a,
        settings: LevelerOutputSettings(
            container: .m4a,
            bitDepth: .int24,
            rateMode: .explicit(48_000)
        )
    )
    sources.append(m4a)

    for source in sources {
        let raw = scratch.root.appendingPathComponent("\(source.lastPathComponent).f32")
        let frames = try TrimmerDecoder.decodeRaw(url: source, to: raw, targetRate: 48_000)
        #expect(frames > 40_000)
        let bytes = try Data(contentsOf: raw).count
        #expect(bytes == frames * 2 * MemoryLayout<Float>.size)
    }

    let containers: [LevelerContainer] = LevelerContainer.mp3.isWritable
        ? [.wav, .aiff, .m4a, .mp3]
        : [.wav, .aiff, .m4a]
    for container in containers {
        let url = scratch.root.appendingPathComponent("mono.\(container.fileExtension)")
        let depth: LevelerBitDepth = container == .wav || container == .aiff ? .int24 : .int16
        try LevelerFileExport.write(
            pcmWAV: wav44,
            to: url,
            settings: LevelerOutputSettings(
                container: container,
                bitDepth: depth,
                rateMode: .explicit(44_100),
                mp3BitrateKbps: 128
            )
        )
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 1)
        if container == .mp3 || container == .m4a {
            #expect(abs(file.fileFormat.sampleRate - 44_100) < 1)
        }
    }
}

private func tone(frames: Int, channels: Int, rate: Double) -> [Float] {
    var samples: [Float] = []
    samples.reserveCapacity(frames * channels)
    for frame in 0..<frames {
        let value = Float(sin(2 * Double.pi * 440 * Double(frame) / rate) * 0.2)
        for _ in 0..<channels {
            samples.append(value)
        }
    }
    return samples
}
