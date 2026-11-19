import Foundation
import LilLevelerKit
import PodLoungeCore

enum TrimmerExportError: LocalizedError {
    case noAudio
    case emptyTrack(String)
    case missing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio:
            "Add a clip to the timeline before exporting."
        case let .emptyTrack(name):
            "\(name) has no clips to export."
        case let .missing(name):
            "\(name) is missing from the project, so the cut was not written."
        case let .failed(detail):
            "The cut could not be written (\(detail))."
        }
    }
}

enum TrimmerExporter {
    struct Outcome: Sendable {
        var fileURL: URL
        var peak: Float
        var sampleRate: Double
        var wroteFloat: Bool
        var clipped: Bool
    }

    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0

        func set(_ value: Double) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> Double {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    static func export(
        document: TrimmerDocument,
        urls: [String: URL],
        names: [String: String],
        scope: TrimmerExportScope = .fullMix,
        channelCounts: [String: Int] = [:],
        container: TrimmerExportContainer = .wav,
        bitDepth: TrimmerExportDepth = .int24,
        mp3BitrateKbps: Int = 192,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> Outcome {
        let clips: [TrimmerClip]
        if let track = scope.track {
            clips = document.clips.filter { $0.track == track }
            guard clips.isEmpty == false else { throw TrimmerExportError.emptyTrack(track.title) }
        } else {
            clips = document.clips
            guard clips.isEmpty == false else { throw TrimmerExportError.noAudio }
        }
        let sampleRate = renderRate(document: document, urls: urls, scope: scope)
        let channels = TrimmerExportPlan.channelCount(
            scope: scope,
            document: document,
            channelCounts: channelCounts
        )
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("thecut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var readers: [String: TrimmerRawAudio] = [:]
        let ids = Array(Set(clips.map(\.assetID)))
        for (index, id) in ids.enumerated() {
            let name = names[id] ?? "A file in TheValet"
            guard let source = urls[id] else { throw TrimmerExportError.missing(name) }
            let raw = folder.appendingPathComponent("source-\(index).f32")
            let frames: Int
            do {
                frames = try TrimmerDecoder.decodeRaw(url: source, to: raw, targetRate: sampleRate)
            } catch {
                throw TrimmerExportError.failed("\(name) could not be read")
            }
            guard frames > 0 else { throw TrimmerExportError.missing(name) }
            readers[id] = try TrimmerRawAudio(url: raw)
            progress(0.05 + 0.30 * Double(index + 1) / Double(ids.count))
        }

        let floatURL = folder.appendingPathComponent("mix-float.wav")
        let writer = try TrimmerWAV.Writer(url: floatURL, sampleRate: sampleRate, depth: .float32, channels: channels)
        let failure = FailureBox()
        let peak = TrimmerRenderer.renderStreaming(
            document: document,
            sampleRate: sampleRate,
            read: { id, frame, count in
                readers[id]?.read(frame: frame, count: count) ?? [Float](repeating: 0, count: max(0, count) * 2)
            },
            scope: scope,
            progress: { fraction in
                progress(0.35 + 0.55 * fraction)
            },
            consume: { block in
                do {
                    let samples = channels == 1 ? TrimmerExportPlan.leftChannel(block) : block
                    try writer.append(samples)
                } catch {
                    failure.set(error)
                }
            }
        )
        try writer.close()
        if let error = failure.get() { throw error }
        guard FileManager.default.fileExists(atPath: floatURL.path) else {
            throw TrimmerExportError.failed("the mix file is empty")
        }

        let written = TrimmerExportPlan.writtenDepth(chosen: bitDepth, container: container, peak: peak)
        let rate = TrimmerExportPlan.deliveryRate(renderRate: sampleRate, container: container)
        let settings = LevelerOutputSettings(
            container: LevelerContainer(rawValue: container.rawValue) ?? .wav,
            bitDepth: levelerDepth(written.depth),
            rateMode: .explicit(rate),
            mp3BitrateKbps: mp3BitrateKbps
        )
        let staged = folder.appendingPathComponent("mix.\(container.fileExtension)")
        do {
            try LevelerFileExport.write(pcmWAV: floatURL, to: staged, settings: settings) { fraction in
                progress(0.90 + 0.10 * fraction)
            }
        } catch {
            throw TrimmerExportError.failed(error.localizedDescription)
        }
        progress(1)
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("thecut-export-\(UUID().uuidString).\(container.fileExtension)")
        try FileManager.default.copyItem(at: staged, to: stable)
        let lossy = container.isLossy
        return Outcome(
            fileURL: stable,
            peak: peak,
            sampleRate: rate,
            wroteFloat: lossy == false && written.depth == .float32 && peak > 1,
            clipped: lossy && peak > 1
        )
    }

    private static func levelerDepth(_ depth: TrimmerExportDepth) -> LevelerBitDepth {
        switch depth {
        case .int16: .int16
        case .int24: .int24
        case .float32: .float32
        }
    }

    private static func renderRate(
        document: TrimmerDocument,
        urls: [String: URL],
        scope: TrimmerExportScope
    ) -> Double {
        let pool: [TrimmerClip]
        if let track = scope.track {
            pool = document.clips.filter { $0.track == track }.sorted { $0.start < $1.start }
        } else {
            let mix = document.clips.filter { $0.track == .episodeMix }.sorted { $0.start < $1.start }
            pool = mix.isEmpty ? document.clips.sorted { $0.start < $1.start } : mix
        }
        let source = pool.first
        if let id = source?.assetID, let url = urls[id], let rate = TrimmerDecoder.sampleRate(of: url), rate >= 8_000 {
            return rate
        }
        return 48_000
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?

        func set(_ error: Error) {
            lock.lock()
            if self.error == nil { self.error = error }
            lock.unlock()
        }

        func get() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return error
        }
    }
}
