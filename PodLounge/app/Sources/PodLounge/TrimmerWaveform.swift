import AVFoundation
import Foundation

actor TrimmerWaveformCache {
    static let shared = TrimmerWaveformCache()
    private var store: [String: [Float]] = [:]

    func peaks(assetID: String, url: URL) async -> [Float] {
        if let cached = store[assetID] { return cached }
        let computed = await Task.detached(priority: .utility) {
            TrimmerWaveform.compute(url: url, buckets: 1400)
        }.value
        store[assetID] = computed
        return computed
    }
}

enum TrimmerWaveform {
    static func compute(url: URL, buckets: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let total = Int(file.length)
        guard total > 0 else { return [] }
        let bucketCount = min(buckets, max(1, total))
        let framesPerBucket = max(1, total / bucketCount)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(min(framesPerBucket, 65_536))
        ) else { return [] }
        var peaks = [Float]()
        peaks.reserveCapacity(bucketCount)
        var pending = 0
        var peak: Float = 0
        let channels = Int(file.processingFormat.channelCount)
        while file.framePosition < file.length {
            let want = AVAudioFrameCount(min(framesPerBucket, Int(file.length - file.framePosition)))
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: want)
            } catch {
                break
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            var index = 0
            while index < frames {
                var magnitude: Float = 0
                for channel in 0..<max(1, channels) {
                    magnitude = max(magnitude, abs(data[channel][index]))
                }
                peak = max(peak, magnitude)
                pending += 1
                index += 1
                if pending >= framesPerBucket {
                    peaks.append(min(1, peak))
                    peak = 0
                    pending = 0
                }
            }
        }
        if pending > 0 { peaks.append(min(1, peak)) }
        return peaks
    }
}
