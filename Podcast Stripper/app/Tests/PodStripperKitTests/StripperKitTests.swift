import AVFoundation
import Foundation
import Testing
@testable import PodStripperKit

@Test @MainActor func elapsedClockStaysReadable() {
    #expect(EngineRunner.formatElapsed(0) == "0s")
    #expect(EngineRunner.formatElapsed(75) == "1m 15s")
    #expect(EngineRunner.formatElapsed(3661) == "1h 1m 01s")
}

@Test func stubSplitWritesTracksWithoutAModelDownload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stripper-stub-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("episode.wav")
    let output = root.appendingPathComponent("out", isDirectory: true)
    try Data(silentWAV(frames: 48_000, rate: 48_000)).write(to: input)
    let written = try StripperStubJob.write(input: input, outputDir: output, audioFormat: .wav16)
    #expect(written.tracks.count == 3)
    let speaker = try AVAudioFile(forReading: written.tracks[0])
    #expect(speaker.length == 48_000)
    let json = try String(contentsOf: written.speakersJSON, encoding: .utf8)
    #expect(json.contains("Speaker_1"))
    #expect(json.contains("Music_and_SFX"))
}

private func silentWAV(frames: Int, rate: Int) -> Data {
    let channels = 2
    let bits = 16
    let block = channels * bits / 8
    let dataBytes = frames * block
    var bytes = Data(count: 44 + dataBytes)
    func write(_ text: String, at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + text.count), with: Data(text.utf8))
    }
    write("RIFF", at: 0)
    write("WAVE", at: 8)
    write("fmt ", at: 12)
    write("data", at: 36)
    bytes.replaceSubrange(4..<8, with: uint32(UInt32(36 + dataBytes)))
    bytes.replaceSubrange(16..<20, with: uint32(16))
    bytes.replaceSubrange(20..<22, with: uint16(1))
    bytes.replaceSubrange(22..<24, with: uint16(UInt16(channels)))
    bytes.replaceSubrange(24..<28, with: uint32(UInt32(rate)))
    bytes.replaceSubrange(28..<32, with: uint32(UInt32(rate * block)))
    bytes.replaceSubrange(32..<34, with: uint16(UInt16(block)))
    bytes.replaceSubrange(34..<36, with: uint16(UInt16(bits)))
    bytes.replaceSubrange(40..<44, with: uint32(UInt32(dataBytes)))
    return bytes
}

private func uint16(_ value: UInt16) -> Data {
    var little = value.littleEndian
    return Data(bytes: &little, count: 2)
}

private func uint32(_ value: UInt32) -> Data {
    var little = value.littleEndian
    return Data(bytes: &little, count: 4)
}
