import Foundation
import Testing
@testable import LilLevelerKit

private func sampleReport(lufs: Float = -20) -> LoudnessReport {
    LoudnessReport(
        integratedLUFS: lufs,
        shortTermLUFS: lufs + 1,
        momentaryLUFS: lufs + 2,
        truePeakDbTP: -3,
        samplePeakDbFS: -3.2,
        durationSec: 1,
        channelCount: 2,
        sampleRate: 48_000
    )
}

private func tinyStore(frames: Int = 64) throws -> PCMStore {
    let store = try PCMStore.createTemporary(sampleRate: 48_000, channelCount: 2, frameCount: frames)
    let buffer = [Float](repeating: 0.1, count: frames * 2)
    store.write(interleaved: buffer, startFrame: 0, frames: frames)
    return store
}

private func milliseconds(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
    let duration = start.duration(to: clock.now)
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
}

@Test func scanCacheMissesWhenSizeOrModificationDateChanges() throws {
    let cache = LevelerScanCache(maxAudioFiles: 3, maxAudioBytes: 2_000_000_000, maxReportFiles: 8)
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("scan-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("episode.wav")
    try Data("aaaa".utf8).write(to: url)

    let first = try #require(LevelerFileStamp.make(for: url))
    let again = try #require(LevelerFileStamp.make(for: url))
    #expect(first == again)
    cache.storeSource(stamp: first, report: sampleReport(), store: nil)
    #expect(cache.source(for: first)?.report.integratedLUFS == -20)

    try Data("aaaa-bbbb".utf8).write(to: url)
    let grown = try #require(LevelerFileStamp.make(for: url))
    #expect(grown.byteCount != first.byteCount)
    #expect(grown != first)
    #expect(cache.source(for: grown) == nil)

    try Data("aaaa".utf8).write(to: url)
    let later = Date().addingTimeInterval(180)
    try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
    let redated = try #require(LevelerFileStamp.make(for: url))
    #expect(redated.byteCount == first.byteCount)
    #expect(redated.modifiedAt != first.modifiedAt)
    #expect(cache.source(for: redated) == nil)
    #expect(cache.source(for: first)?.report.integratedLUFS == -20)
}

@Test func scanCacheEvictsOldestAudioAndKeepsTheReport() throws {
    let cache = LevelerScanCache(maxAudioFiles: 2, maxAudioBytes: 2_000_000_000, maxReportFiles: 8)
    let a = try tinyStore()
    let b = try tinyStore()
    let c = try tinyStore()
    let stampA = LevelerFileStamp(path: "/a", byteCount: 1, modifiedAt: 1)
    let stampB = LevelerFileStamp(path: "/b", byteCount: 1, modifiedAt: 2)
    let stampC = LevelerFileStamp(path: "/c", byteCount: 1, modifiedAt: 3)
    cache.storeSource(stamp: stampA, report: sampleReport(lufs: -23), store: a)
    cache.storeSource(stamp: stampB, report: sampleReport(lufs: -22), store: b)
    cache.storeSource(stamp: stampC, report: sampleReport(lufs: -21), store: c)

    let evicted = cache.source(for: stampA)
    #expect(evicted?.store == nil)
    #expect(evicted?.report.integratedLUFS == -23)
    #expect(cache.source(for: stampB)?.store != nil)
    #expect(cache.source(for: stampC)?.store != nil)
}

@Test func scanCacheEvictsOldestAudioWhenTheByteBudgetIsPassed() throws {
    let frames = 256
    let bytes = try #require(PCMStore.estimatedByteCount(frames: frames, channels: 2))
    let cache = LevelerScanCache(maxAudioFiles: 4, maxAudioBytes: bytes, maxReportFiles: 8)
    let older = try tinyStore(frames: frames)
    let newer = try tinyStore(frames: frames)
    let stampOlder = LevelerFileStamp(path: "/older", byteCount: 1, modifiedAt: 1)
    let stampNewer = LevelerFileStamp(path: "/newer", byteCount: 1, modifiedAt: 2)
    cache.storeSource(stamp: stampOlder, report: sampleReport(), store: older)
    #expect(cache.source(for: stampOlder)?.store != nil)
    cache.storeSource(stamp: stampNewer, report: sampleReport(lufs: -18), store: newer)

    #expect(cache.source(for: stampOlder)?.store == nil)
    #expect(cache.source(for: stampOlder)?.report.integratedLUFS == -20)
    #expect(cache.source(for: stampNewer)?.store != nil)
}

@Test func scanCacheKeepsTheOnlyFileEvenWhenItExceedsTheBudget() throws {
    let frames = 256
    let bytes = try #require(PCMStore.estimatedByteCount(frames: frames, channels: 2))
    let cache = LevelerScanCache(maxAudioFiles: 3, maxAudioBytes: max(1, bytes / 2), maxReportFiles: 8)
    let only = try tinyStore(frames: frames)
    let stamp = LevelerFileStamp(path: "/only", byteCount: 1, modifiedAt: 1)
    cache.storeSource(stamp: stamp, report: sampleReport(), store: only)
    #expect(cache.source(for: stamp)?.store != nil)
}

@Test @MainActor func reselectingAScannedFileSkipsAnalysis() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("reselect-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let frames = 48_000 * 8
    let tone = try PCMStore.createTemporary(sampleRate: 48_000, channelCount: 2, frameCount: frames)
    var samples = [Float](repeating: 0, count: frames * 2)
    for frame in 0..<frames {
        let t = Double(frame) / 48_000
        let sample = Float(sin(2 * Double.pi * 440 * t) * 0.2)
        samples[frame * 2] = sample
        samples[frame * 2 + 1] = sample
    }
    tone.write(interleaved: samples, startFrame: 0, frames: frames)
    let settings = LevelerOutputSettings(container: .wav, bitDepth: .int16, rateMode: .matchSource)
    let firstURL = folder.appendingPathComponent("first.wav")
    let secondURL = folder.appendingPathComponent("second.wav")
    try LevelerOutputWriter.write(store: tone, to: firstURL, settings: settings)
    let short = try PCMStore.createTemporary(sampleRate: 48_000, channelCount: 2, frameCount: 48_000)
    short.write(interleaved: Array(samples.prefix(96_000)), startFrame: 0, frames: 48_000)
    try LevelerOutputWriter.write(store: short, to: secondURL, settings: settings)

    let session = LevelerSession()
    let clock = ContinuousClock()
    let coldStart = clock.now
    session.load(url: firstURL)
    try await waitUntilReady(session, url: firstURL)
    let coldMs = milliseconds(since: coldStart, clock: clock)
    let before = session.before.integratedLUFS
    #expect(session.sourceAnalysisCount == 1)
    #expect(session.hasResult)

    session.load(url: secondURL)
    try await waitUntilReady(session, url: secondURL)
    let analyzed = session.sourceAnalysisCount
    #expect(analyzed == 2)

    let warmStart = clock.now
    session.load(url: firstURL)
    let warmMs = milliseconds(since: warmStart, clock: clock)
    #expect(session.hasResult)
    #expect(session.isBusy == false)
    #expect(session.isMeasuring == false)
    #expect(session.sourceAnalysisCount == analyzed)
    #expect(session.before.integratedLUFS == before)
    #expect(session.status.contains("Analyzing") == false)
    #expect(session.status.contains("Loading") == false)
    #expect(warmMs < 150)
    #expect(warmMs * 4 < coldMs)

    let analysesBeforePreset = session.sourceAnalysisCount
    session.selectPreset(.spotify)
    try await waitUntilReady(session, url: firstURL)
    #expect(session.sourceAnalysisCount == analysesBeforePreset)
    #expect(session.activePresetID == "spotify")
    #expect(session.status.contains("Analyzing") == false)

    let restoreStart = clock.now
    session.selectPreset(.universal)
    let restoreMs = milliseconds(since: restoreStart, clock: clock)
    #expect(session.hasResult)
    #expect(session.isBusy == false)
    #expect(session.sourceAnalysisCount == analysesBeforePreset)
    #expect(restoreMs < 150)

    print(
        String(
            format: "RESELECT_TIMING cold_ms=%.1f cached_reselect_ms=%.1f preset_restore_ms=%.1f",
            coldMs,
            warmMs,
            restoreMs
        )
    )
}

@Test @MainActor func reselectingAnEvictedFileShowsItsResultImmediately() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("reselect-evict-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let settings = LevelerOutputSettings(container: .wav, bitDepth: .int16, rateMode: .matchSource)
    let firstURL = folder.appendingPathComponent("first.wav")
    let secondURL = folder.appendingPathComponent("second.wav")
    try writeTone(frames: 48_000 * 2, to: firstURL, settings: settings)
    try writeTone(frames: 48_000, to: secondURL, settings: settings)

    let cache = LevelerScanCache(maxAudioFiles: 1, maxAudioBytes: 2_000_000_000, maxReportFiles: 8)
    let session = LevelerSession(scanCache: cache)

    session.load(url: firstURL)
    try await waitUntilReady(session, url: firstURL)
    let before = session.before
    let after = session.after
    let gain = session.appliedGainDb
    let peak = session.peakGR
    #expect(session.sourceAnalysisCount == 1)
    #expect(session.levelingMeasureCount == 1)
    #expect(session.hasResult)

    session.load(url: secondURL)
    try await waitUntilReady(session, url: secondURL)
    let analyzed = session.sourceAnalysisCount
    let measured = session.levelingMeasureCount
    #expect(analyzed == 2)
    #expect(measured == 2)

    session.load(url: firstURL)
    #expect(session.sourceName == firstURL.lastPathComponent)
    #expect(session.before == before)
    #expect(session.after == after)
    #expect(session.appliedGainDb == gain)
    #expect(session.peakGR == peak)
    #expect(session.hasResult)
    #expect(session.sourceAnalysisCount == analyzed)
    #expect(session.levelingMeasureCount == measured)
    #expect(session.hasFile == false)
    #expect(session.canExportLeveled == false)
    #expect(session.isBusy == false)
    #expect(session.isMeasuring == false)
    #expect(session.renderFraction == 0)
    #expect(session.status.contains("Analyzing") == false)
    #expect(session.status.contains("Leveling") == false)
    #expect(session.status.contains("Loading…") == false)
    #expect(session.status.contains("%") == false)

    try await waitUntilReady(session, url: firstURL)
    #expect(session.hasFile)
    #expect(session.canExportLeveled)
    #expect(session.isBusy == false)
    #expect(session.sourceAnalysisCount == analyzed)
    #expect(session.levelingMeasureCount == measured)
    #expect(session.before == before)
    #expect(session.after == after)
    #expect(session.appliedGainDb == gain)
    #expect(session.peakGR == peak)
    #expect(session.status.contains("Analyzing") == false)
    #expect(session.status.contains("Leveling") == false)
    #expect(session.status.contains("Loading") == false)
}

private func writeTone(frames: Int, to url: URL, settings: LevelerOutputSettings) throws {
    let tone = try PCMStore.createTemporary(sampleRate: 48_000, channelCount: 2, frameCount: frames)
    var samples = [Float](repeating: 0, count: frames * 2)
    for frame in 0..<frames {
        let t = Double(frame) / 48_000
        let sample = Float(sin(2 * Double.pi * 440 * t) * 0.2)
        samples[frame * 2] = sample
        samples[frame * 2 + 1] = sample
    }
    tone.write(interleaved: samples, startFrame: 0, frames: frames)
    try LevelerOutputWriter.write(store: tone, to: url, settings: settings)
}

@MainActor
private func waitUntilReady(_ session: LevelerSession, url: URL) async throws {
    let deadline = Date().addingTimeInterval(90)
    let wanted = url.standardizedFileURL.resolvingSymlinksInPath()
    while Date() < deadline {
        let current = session.sourceURL?.standardizedFileURL.resolvingSymlinksInPath()
        if session.hasResult, session.hasFile, session.canExportLeveled,
           session.isBusy == false, session.isMeasuring == false, current == wanted {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Timed out loading \(url.lastPathComponent): \(session.status)")
}
