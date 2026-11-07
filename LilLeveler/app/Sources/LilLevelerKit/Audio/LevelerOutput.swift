import AudioToolbox
import AVFoundation
import Foundation
import UniformTypeIdentifiers

public enum LevelerContainer: String, CaseIterable, Identifiable, Sendable {
    case wav
    case aiff
    case m4a
    case mp3

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .m4a: "M4A"
        case .mp3: "MP3"
        }
    }

    public var fileExtension: String {
        switch self {
        case .wav: "wav"
        case .aiff: "aiff"
        case .m4a: "m4a"
        case .mp3: "mp3"
        }
    }

    /// MP3 stays off when `libmp3lame` was not built or bundled.
    public var isWritable: Bool {
        if self == .mp3 { return LAMELibrary.isAvailable }
        return true
    }
}

public enum LevelerBitDepth: String, CaseIterable, Identifiable, Sendable {
    case int16
    case int24
    case float32

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .int16: "16-bit"
        case .int24: "24-bit"
        case .float32: "32-bit float"
        }
    }

    public var detail: String {
        switch self {
        case .int16: "TPDF dither"
        case .int24: "no dither"
        case .float32: "full precision"
        }
    }
}

public enum LevelerRateMode: Equatable, Sendable {
    /// Standalone export: leave the file at the source rate, including odd rates.
    case matchSource
    /// Limiter workspace: source rate when it is 44.1 / 48 / 88.2 / 96, otherwise 48 kHz.
    case automatic
    case explicit(Double)
}

public struct LevelerOutputSettings: Equatable, Sendable {
    public var container: LevelerContainer
    public var bitDepth: LevelerBitDepth
    public var rateMode: LevelerRateMode
    /// Constant MP3 bitrate in kbps. Ignored by WAV, AIFF, and M4A.
    public var mp3BitrateKbps: Int

    public static let standardRates: [Double] = [44_100, 48_000, 88_200, 96_000]
    public static let aacRates: [Double] = [44_100, 48_000]
    public static let mp3Rates: [Double] = [44_100, 48_000]
    public static let mp3Bitrates = [96, 128, 160, 192]

    public static let standaloneDefaults = LevelerOutputSettings(
        container: .wav,
        bitDepth: .int16,
        rateMode: .matchSource
    )

    public static let loungeDefaults = LevelerOutputSettings(
        container: .wav,
        bitDepth: .int24,
        rateMode: .automatic
    )

    public init(
        container: LevelerContainer,
        bitDepth: LevelerBitDepth,
        rateMode: LevelerRateMode,
        mp3BitrateKbps: Int = 128
    ) {
        self.container = container
        self.bitDepth = bitDepth
        self.rateMode = rateMode
        self.mp3BitrateKbps = Self.normalizedMP3Bitrate(mp3BitrateKbps)
    }

    public static func normalizedMP3Bitrate(_ value: Int) -> Int {
        mp3Bitrates.contains(value) ? value : 128
    }

    /// Sample rate the file will actually use. AAC is limited to 44.1 and 48 kHz.
    public func resolvedSampleRate(sourceRate: Double) -> Double {
        let source = sourceRate > 0 ? sourceRate : 48_000
        let chosen: Double
        switch rateMode {
        case .matchSource:
            chosen = source
        case .automatic:
            if let match = Self.standardRates.first(where: { abs($0 - source) < 1 }) {
                chosen = match
            } else {
                chosen = 48_000
            }
        case let .explicit(rate):
            chosen = rate
        }
        if container == .m4a, Self.aacRates.contains(where: { abs($0 - chosen) < 1 }) == false {
            return 48_000
        }
        if container == .mp3, Self.mp3Rates.contains(where: { abs($0 - chosen) < 1 }) == false {
            return 48_000
        }
        return chosen
    }

    public func rateIsEnabled(_ rate: Double) -> Bool {
        switch container {
        case .wav, .aiff:
            return true
        case .m4a:
            return Self.aacRates.contains(where: { abs($0 - rate) < 1 })
        case .mp3:
            return Self.mp3Rates.contains(where: { abs($0 - rate) < 1 })
        }
    }

    public var contentType: UTType {
        switch container {
        case .wav: .wav
        case .aiff: .aiff
        case .m4a: .mpeg4Audio
        case .mp3: .mp3
        }
    }
}

public struct LevelerControlSnapshot: Equatable, Sendable {
    public var presetID: String
    public var customLUFS: Float
    public var customTruePeak: Float
    public var musicThresholdDb: Float
    public var meterMode: String
    public var peakHold: Bool
    public var listenPost: Bool

    public init(
        presetID: String,
        customLUFS: Float,
        customTruePeak: Float,
        musicThresholdDb: Float,
        meterMode: String,
        peakHold: Bool,
        listenPost: Bool
    ) {
        self.presetID = presetID
        self.customLUFS = customLUFS
        self.customTruePeak = customTruePeak
        self.musicThresholdDb = musicThresholdDb
        self.meterMode = meterMode
        self.peakHold = peakHold
        self.listenPost = listenPost
    }
}

/// Writes a leveled `PCMStore`. Order is fixed: sample-rate conversion (float,
/// max quality) and only then 16-bit TPDF dither. 24-bit and float are not dithered.
enum LevelerOutputWriter {
    static func write(
        store: PCMStore,
        to url: URL,
        settings: LevelerOutputSettings,
        ditherSeed: UInt64? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let rate = settings.resolvedSampleRate(sourceRate: store.sampleRate)
        let working: PCMStore
        if abs(rate - store.sampleRate) < 0.5 {
            working = store
        } else {
            working = try convertSampleRate(store, to: rate) { fraction in
                progress?(0.65 * fraction)
            }
        }
        switch settings.container {
        case .mp3:
            guard settings.container.isWritable else {
                throw LevelerError.processFailed("MP3 encoder is missing.")
            }
            try writeMP3(working, to: url, settings: settings) { fraction in
                progress?(0.65 + 0.35 * fraction)
            }
        case .m4a:
            try writeAAC(working, to: url) { fraction in
                progress?(0.65 + 0.35 * fraction)
            }
        case .wav, .aiff:
            try writeLinearPCM(
                working,
                to: url,
                container: settings.container,
                bitDepth: settings.bitDepth,
                ditherSeed: ditherSeed
            ) { fraction in
                progress?(0.65 + 0.35 * fraction)
            }
        }
        progress?(1)
    }

    static func convertSampleRate(
        _ store: PCMStore,
        to targetRate: Double,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> PCMStore {
        if abs(store.sampleRate - targetRate) < 0.5 {
            return store
        }
        let channelCount = store.channelCount
        let channels = AVAudioChannelCount(channelCount)
        guard channelCount >= 1, channelCount <= 8,
              let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: store.sampleRate,
                channels: channels,
                interleaved: false
              ),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetRate,
                channels: channels,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw LevelerError.processFailed("Could not convert the sample rate.")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let chunk: AVAudioFrameCount = 4_096
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunk),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunk)
        else {
            throw LevelerError.processFailed("Out of memory converting the sample rate.")
        }

        let ratio = targetRate / store.sampleRate
        let estimated = Int((Double(store.frameCount) * ratio).rounded(.up)) + 48_000
        let dest = try PCMStore.createTemporary(
            sampleRate: targetRate,
            channelCount: channelCount,
            frameCount: max(estimated, 1)
        )

        let cursor = FrameCursor()
        var written = 0
        let totalIn = store.frameCount

        while true {
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if cursor.frame >= totalIn {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let want = min(Int(chunk), totalIn - cursor.frame)
                var tmp = [Float](repeating: 0, count: want * channelCount)
                let got = store.copyFrames(start: cursor.frame, count: want, into: &tmp)
                if got <= 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inputBuffer.frameLength = AVAudioFrameCount(got)
                if let pointers = inputBuffer.floatChannelData {
                    for frame in 0..<got {
                        for channel in 0..<channelCount {
                            pointers[channel][frame] = tmp[frame * channelCount + channel]
                        }
                    }
                }
                cursor.frame += got
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if let error {
                throw LevelerError.processFailed("Sample-rate conversion failed (\(error.localizedDescription)).")
            }
            if status == .error {
                throw LevelerError.processFailed("Sample-rate conversion failed.")
            }
            let produced = Int(outputBuffer.frameLength)
            if produced > 0 {
                guard written + produced <= dest.frameCount else {
                    throw LevelerError.processFailed("Sample-rate conversion ran past the prepared file.")
                }
                var interleaved = [Float](repeating: 0, count: produced * channelCount)
                if let pointers = outputBuffer.floatChannelData {
                    for frame in 0..<produced {
                        for channel in 0..<channelCount {
                            interleaved[frame * channelCount + channel] = pointers[channel][frame]
                        }
                    }
                }
                dest.write(interleaved: interleaved, startFrame: written, frames: produced)
                written += produced
            }
            if totalIn > 0 {
                progress?(min(1, Double(cursor.frame) / Double(totalIn)))
            }
            if status == .endOfStream || (produced == 0 && cursor.frame >= totalIn) {
                break
            }
        }
        guard written > 0 else {
            throw LevelerError.processFailed("Sample-rate conversion produced no audio.")
        }
        try dest.shrinkFrameCount(to: written)
        dest.sync()
        progress?(1)
        return dest
    }

    static func quantizeInt16(_ sample: Float) -> Int16 {
        let clipped = max(-1, min(1, sample))
        let scaled = Double(clipped) * 32_767
        let rounded = Int(scaled.rounded())
        return Int16(max(-32_767, min(32_767, rounded)))
    }

    /// Triangular dither of ±1 LSB, added in the 16-bit quantizer only.
    static func ditherInt16(_ sample: Float, rng: inout some RandomNumberGenerator) -> Int16 {
        let clipped = max(-1, min(1, sample))
        let u1 = Double.random(in: -0.5..<0.5, using: &rng)
        let u2 = Double.random(in: -0.5..<0.5, using: &rng)
        let scaled = Double(clipped) * 32_767 + (u1 + u2)
        let rounded = Int(scaled.rounded())
        return Int16(max(-32_767, min(32_767, rounded)))
    }

    static func quantizeInt24(_ sample: Float) -> Int32 {
        let clipped = max(-1, min(1, sample))
        let scaled = Double(clipped) * 8_388_607
        let rounded = Int(scaled.rounded())
        return Int32(max(-8_388_607, min(8_388_607, rounded)))
    }

    private static func writeLinearPCM(
        _ store: PCMStore,
        to url: URL,
        container: LevelerContainer,
        bitDepth: LevelerBitDepth,
        ditherSeed: UInt64?,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        if let ditherSeed {
            var rng = SplitMix64(state: ditherSeed)
            try writeLinearPCM(store, to: url, container: container, bitDepth: bitDepth, rng: &rng, progress: progress)
        } else {
            var rng = SystemRandomNumberGenerator()
            try writeLinearPCM(store, to: url, container: container, bitDepth: bitDepth, rng: &rng, progress: progress)
        }
    }

    private static func writeLinearPCM<R: RandomNumberGenerator>(
        _ store: PCMStore,
        to url: URL,
        container: LevelerContainer,
        bitDepth: LevelerBitDepth,
        rng: inout R,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        let channels = store.channelCount
        let frames = store.frameCount
        guard channels >= 1, frames > 0 else {
            throw LevelerError.processFailed("Nothing to export yet.")
        }
        let floatFile = bitDepth == .float32
        let bits: UInt32 = floatFile ? 32 : (bitDepth == .int16 ? 16 : 24)
        let bytesPerSample = Int(bits / 8)
        let bigEndian = container == .aiff
        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
        if floatFile {
            flags |= kAudioFormatFlagIsFloat
        } else {
            flags |= kAudioFormatFlagIsSignedInteger
        }
        if bigEndian {
            flags |= kAudioFormatFlagIsBigEndian
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: store.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: UInt32(bytesPerSample * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerSample * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: bits,
            mReserved: 0
        )
        let fileType: AudioFileTypeID = switch container {
        case .wav: kAudioFileWAVEType
        case .aiff: floatFile ? kAudioFileAIFCType : kAudioFileAIFFType
        case .m4a, .mp3: kAudioFileWAVEType
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var fileID: AudioFileID?
        let created = AudioFileCreateWithURL(url as CFURL, fileType, &description, .eraseFile, &fileID)
        guard created == noErr, let fileID else {
            throw LevelerError.processFailed("Could not create the audio file.")
        }
        defer { AudioFileClose(fileID) }

        let dither = bitDepth == .int16
        let chunk = 8_192
        var floats = [Float](repeating: 0, count: chunk * channels)
        var bytes = Data()
        var position = 0
        var byteOffset: Int64 = 0
        while position < frames {
            let count = store.copyFrames(start: position, count: min(chunk, frames - position), into: &floats)
            guard count > 0 else { break }
            bytes.removeAll(keepingCapacity: true)
            let samples = count * channels
            if floatFile {
                for index in 0..<samples {
                    appendFloat(floats[index], to: &bytes, bigEndian: bigEndian)
                }
            } else if bitDepth == .int24 {
                for index in 0..<samples {
                    appendInt24(quantizeInt24(floats[index]), to: &bytes, bigEndian: bigEndian)
                }
            } else {
                for index in 0..<samples {
                    let value = dither ? ditherInt16(floats[index], rng: &rng) : quantizeInt16(floats[index])
                    appendInt16(value, to: &bytes, bigEndian: bigEndian)
                }
            }
            try bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var numBytes = UInt32(raw.count)
                let status = AudioFileWriteBytes(fileID, false, byteOffset, &numBytes, base)
                if status != noErr {
                    throw LevelerError.processFailed("Could not write the audio file.")
                }
                byteOffset += Int64(numBytes)
            }
            position += count
            progress?(Double(position) / Double(frames))
        }
    }

    private static func writeAAC(
        _ store: PCMStore,
        to url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        let channels = store.channelCount
        let frames = store.frameCount
        guard channels >= 1, frames > 0 else {
            throw LevelerError.processFailed("Nothing to export yet.")
        }
        guard LevelerOutputSettings.aacRates.contains(where: { abs($0 - store.sampleRate) < 1 }) else {
            throw LevelerError.processFailed("M4A uses 44.1 or 48 kHz.")
        }
        let bitrate = channels >= 2 ? 256_000 : 128_000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: store.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ]
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            throw LevelerError.processFailed("Could not create the M4A file (\(error.localizedDescription)).")
        }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw LevelerError.processFailed("Out of memory writing M4A.")
        }
        var floats = [Float](repeating: 0, count: Int(chunk) * channels)
        var position = 0
        while position < frames {
            let count = store.copyFrames(start: position, count: min(Int(chunk), frames - position), into: &floats)
            guard count > 0 else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            let fileChannels = Int(format.channelCount)
            if format.isInterleaved, let destination = buffer.floatChannelData?[0] {
                if fileChannels == channels {
                    for index in 0..<(count * channels) {
                        destination[index] = floats[index]
                    }
                } else {
                    for frame in 0..<count {
                        for channel in 0..<fileChannels {
                            let sourceChannel = min(channel, channels - 1)
                            destination[frame * fileChannels + channel] = floats[frame * channels + sourceChannel]
                        }
                    }
                }
            } else if let destination = buffer.floatChannelData {
                for frame in 0..<count {
                    for channel in 0..<fileChannels {
                        let sourceChannel = min(channel, channels - 1)
                        destination[channel][frame] = floats[frame * channels + sourceChannel]
                    }
                }
            }
            do {
                try file.write(from: buffer)
            } catch {
                throw LevelerError.processFailed("Could not write the M4A file (\(error.localizedDescription)).")
            }
            position += count
            progress?(Double(position) / Double(frames))
        }
    }

    private static func appendFloat(_ sample: Float, to data: inout Data, bigEndian: Bool) {
        var bits = sample.bitPattern
        if bigEndian {
            bits = bits.bigEndian
        } else {
            bits = bits.littleEndian
        }
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private static func appendInt16(_ value: Int16, to data: inout Data, bigEndian: Bool) {
        var stored: UInt16 = bigEndian ? UInt16(bitPattern: value).bigEndian : UInt16(bitPattern: value).littleEndian
        withUnsafeBytes(of: &stored) { data.append(contentsOf: $0) }
    }

    private static func appendInt24(_ value: Int32, to data: inout Data, bigEndian: Bool) {
        let clipped = max(-8_388_607, min(8_388_607, value))
        let bits = UInt32(bitPattern: clipped)
        if bigEndian {
            data.append(UInt8((bits >> 16) & 0xFF))
            data.append(UInt8((bits >> 8) & 0xFF))
            data.append(UInt8(bits & 0xFF))
        } else {
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8((bits >> 8) & 0xFF))
            data.append(UInt8((bits >> 16) & 0xFF))
        }
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private final class FrameCursor: @unchecked Sendable {
    var frame = 0
}
