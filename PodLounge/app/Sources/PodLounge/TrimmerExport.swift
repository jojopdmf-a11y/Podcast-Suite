import Foundation
import PodLoungeCore

enum TrimmerExportError: LocalizedError {
    case noAudio
    case missing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio:
            "Add a clip to the timeline before exporting."
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
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> Outcome {
        let clips = document.clips
        guard !clips.isEmpty else { throw TrimmerExportError.noAudio }
        let sampleRate = renderRate(document: document, urls: urls)
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
        let writer = try TrimmerWAV.Writer(url: floatURL, sampleRate: sampleRate, depth: .float32)
        let failure = FailureBox()
        let peak = TrimmerRenderer.renderStreaming(
            document: document,
            sampleRate: sampleRate,
            read: { id, frame, count in
                readers[id]?.read(frame: frame, count: count) ?? [Float](repeating: 0, count: max(0, count) * 2)
            },
            progress: { fraction in
                progress(0.35 + 0.55 * fraction)
            },
            consume: { block in
                do {
                    try writer.append(block)
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

        let wroteFloat = peak > 1
        let staged = folder.appendingPathComponent(wroteFloat ? "mix-float-copy.wav" : "mix-24.wav")
        if wroteFloat {
            try FileManager.default.copyItem(at: floatURL, to: staged)
        } else {
            try TrimmerWAV.rewrite(from: floatURL, to: staged, depth: .int24)
        }
        progress(1)
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("thecut-export-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: staged, to: stable)
        return Outcome(fileURL: stable, peak: peak, sampleRate: sampleRate, wroteFloat: wroteFloat)
    }

    private static func renderRate(document: TrimmerDocument, urls: [String: URL]) -> Double {
        let mix = document.clips.filter { $0.track == .episodeMix }.sorted { $0.start < $1.start }
        let source = mix.first ?? document.clips.sorted { $0.start < $1.start }.first
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
