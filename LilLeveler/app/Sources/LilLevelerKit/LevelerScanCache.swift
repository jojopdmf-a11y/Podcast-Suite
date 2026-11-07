import Foundation

/// Identity of a file on disk. A different size or modification date is a miss,
/// so a replaced file is scanned again. The path is standardized.
struct LevelerFileStamp: Hashable, Sendable {
    var path: String
    var byteCount: Int64
    var modifiedAt: TimeInterval

    static func make(for url: URL) -> LevelerFileStamp? {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: standardized.path),
              let size = attrs[.size] as? NSNumber,
              let modified = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        return LevelerFileStamp(
            path: standardized.path,
            byteCount: size.int64Value,
            modifiedAt: modified.timeIntervalSinceReferenceDate
        )
    }
}

/// In-memory loudness cache for one app launch. Nothing is written into the project.
///
/// Reports stay for many files. Mapped audio is kept for only a few recent files
/// (and about 2 GB). The newest file is kept even when it alone is larger than
/// the budget, so the show you just scanned can be reselected without a rescan.
/// Evicted audio can be decoded again. The stored reports still redraw the last
/// level, and skip measuring, before that audio is back.
final class LevelerScanCache: @unchecked Sendable {
    struct ProcessKey: Hashable, Sendable {
        var presetID: String
        var targetLUFSMilli: Int
        var truePeakMilli: Int
        /// Included only for MUSIC LOUD. Loudness presets ignore threshold.
        var musicThresholdMilli: Int
        var maximizer: Bool
    }

    struct SourceHit {
        var report: LoudnessReport
        var store: PCMStore?
    }

    struct ResultHit {
        var report: LoudnessReport
        var appliedGainDb: Float
        var peakGR: Float
        var store: PCMStore?
    }

    static let shared = LevelerScanCache()

    let maxAudioFiles: Int
    let maxAudioBytes: Int
    let maxReportFiles: Int

    private struct SourceRecord {
        var report: LoudnessReport
        var store: PCMStore?
        var bytes: Int
        var used: UInt64
    }

    private struct ResultRecord {
        var report: LoudnessReport
        var appliedGainDb: Float
        var peakGR: Float
        var store: PCMStore?
        var bytes: Int
        var used: UInt64
    }

    private struct FileRecord {
        var source: SourceRecord?
        var results: [ProcessKey: ResultRecord] = [:]
        var used: UInt64
    }

    private let lock = NSLock()
    private var files: [LevelerFileStamp: FileRecord] = [:]
    private var clock: UInt64 = 0

    init(maxAudioFiles: Int = 3, maxAudioBytes: Int = 2_000_000_000, maxReportFiles: Int = 64) {
        self.maxAudioFiles = max(1, maxAudioFiles)
        self.maxAudioBytes = max(1, maxAudioBytes)
        self.maxReportFiles = max(1, maxReportFiles)
    }

    static func milli(_ value: Float) -> Int {
        Int((Double(value) * 100).rounded())
    }

    func source(for stamp: LevelerFileStamp) -> SourceHit? {
        lock.lock()
        defer { lock.unlock() }
        guard var file = files[stamp], let source = file.source else { return nil }
        clock += 1
        file.used = clock
        file.source?.used = clock
        files[stamp] = file
        return SourceHit(report: source.report, store: source.store)
    }

    func storeSource(stamp: LevelerFileStamp, report: LoudnessReport, store: PCMStore?) {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        var file = files[stamp] ?? FileRecord(source: nil, results: [:], used: clock)
        file.used = clock
        file.source = SourceRecord(
            report: report,
            store: store,
            bytes: Self.audioBytes(of: store),
            used: clock
        )
        files[stamp] = file
        evictLocked()
    }

    func result(for stamp: LevelerFileStamp, key: ProcessKey) -> ResultHit? {
        lock.lock()
        defer { lock.unlock() }
        guard var file = files[stamp], let result = file.results[key] else { return nil }
        clock += 1
        file.used = clock
        file.results[key]?.used = clock
        files[stamp] = file
        return ResultHit(
            report: result.report,
            appliedGainDb: result.appliedGainDb,
            peakGR: result.peakGR,
            store: result.store
        )
    }

    func storeResult(
        stamp: LevelerFileStamp,
        key: ProcessKey,
        report: LoudnessReport,
        appliedGainDb: Float,
        peakGR: Float,
        store: PCMStore?
    ) {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        var file = files[stamp] ?? FileRecord(source: nil, results: [:], used: clock)
        file.used = clock
        file.results[key] = ResultRecord(
            report: report,
            appliedGainDb: appliedGainDb,
            peakGR: peakGR,
            store: store,
            bytes: Self.audioBytes(of: store),
            used: clock
        )
        files[stamp] = file
        evictLocked()
    }

    private static func audioBytes(of store: PCMStore?) -> Int {
        guard let store else { return 0 }
        return PCMStore.estimatedByteCount(frames: store.frameCount, channels: store.channelCount) ?? 0
    }

    private func evictLocked() {
        while files.count > maxReportFiles {
            guard let oldest = files.min(by: { $0.value.used < $1.value.used })?.key else { break }
            files.removeValue(forKey: oldest)
        }
        while true {
            let holders = files.filter { _, file in
                file.source?.store != nil || file.results.values.contains { $0.store != nil }
            }
            guard holders.count > 1 else { break }
            let overCount = holders.count > maxAudioFiles
            let overBytes = audioBytesLocked() > maxAudioBytes
            guard overCount || overBytes else { break }
            guard let oldest = holders.min(by: { $0.value.used < $1.value.used })?.key else { break }
            clearAudioLocked(oldest)
        }
    }

    private func audioBytesLocked() -> Int {
        var total = 0
        for file in files.values {
            if file.source?.store != nil { total += file.source?.bytes ?? 0 }
            for result in file.results.values where result.store != nil {
                total += result.bytes
            }
        }
        return total
    }

    private func clearAudioLocked(_ stamp: LevelerFileStamp) {
        guard var file = files[stamp] else { return }
        if var source = file.source {
            source.store = nil
            source.bytes = 0
            file.source = source
        }
        for (key, var result) in file.results {
            result.store = nil
            result.bytes = 0
            file.results[key] = result
        }
        files[stamp] = file
    }
}
