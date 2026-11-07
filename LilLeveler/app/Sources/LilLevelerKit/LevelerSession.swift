import Combine
import Foundation
import SwiftUI

@MainActor
public final class LevelerSession: ObservableObject {
    @Published public var sourceURL: URL?
    @Published var sourceName: String = ""
    @Published public var status: String = "Drop a final mix to begin"
    @Published var isBusy = false
    /// True while a leveled file is being rendered or copied. The Lounge locks the depot on this.
    @Published public internal(set) var isExporting = false
    /// MUSIC LOUD FILE LOUDNESS rewrite — does not freeze Play or THRESHOLD.
    @Published var isMeasuring = false
    @Published var preset: PlatformPreset = .universal
    @Published var customLUFS: Float = -16
    @Published var customTP: Float = -1
    @Published var userPresets: [UserLoudnessPreset] = []
    /// L1-style threshold. Lower = more makeup into the −0.1 dB limiter.
    @Published var musicThresholdDb: Float = -0.1
    @Published var liveGR: Float = 0
    @Published var peakGR: Float = 0
    private var filePeakGR: Float = 0

    @Published var before = LoudnessReport.empty
    @Published var after = LoudnessReport.empty
    @Published var appliedGainDb: Float = 0
    @Published var hasResult = false

    @Published var isPlaying = false
    /// false = PRE (source), true = POST (leveled)
    @Published var playAfter = false
    @Published var playheadFrame = 0
    @Published var durationFrames = 0
    @Published var sampleRate: Double = 44100
    @Published var isScrubbing = false

    @Published var meterMode: LevelerMeterMode = .truePeak
    @Published var peakHold = true
    @Published var livePre = LiveMeterSample.silent
    @Published var livePost = LiveMeterSample.silent
    @Published var preHoldL: Float = -80
    @Published var preHoldR: Float = -80
    @Published var postHoldL: Float = -80
    @Published var postHoldR: Float = -80
    @Published var preOvers = false
    @Published var postOvers = false

    @Published var renderFraction: Double = 0

    private var sourceStore: PCMStore?
    private var leveledStore: PCMStore?
    /// Session-long scan cache. Torn down with the process, not with one file load.
    private let scanCache: LevelerScanCache
    private var loadedStamp: LevelerFileStamp?
    /// How many times this session walked a source file for its "before" report.
    private(set) var sourceAnalysisCount = 0
    /// How many times this session ran a leveling pass that measured loudness.
    private(set) var levelingMeasureCount = 0
    /// Decoded audio for the file on screen was evicted; it is coming back quietly.
    private var restoringAudio = false
    /// Preset or re-level changed while that quiet reload was still running.
    private var levelWhenAudioReturns = false
    private var pendingProcessUseCache = true
    private let playback = LevelerPlaybackEngine()
    private var loadGeneration: UInt64 = 0
    private var processGeneration: UInt64 = 0
    /// If THRESHOLD is released while FILE LOUDNESS is still rewriting, run once more.
    private var measureAgain = false
    /// Restored from the project after the file's own peak would otherwise replace it.
    private var pendingMusicThreshold: Float?
    private var pendingListenPost: Bool?

    var activeTargetLUFS: Float {
        preset.isCustom ? customLUFS : preset.targetLUFS
    }

    var activeTruePeak: Float {
        preset.isCustom ? customTP : preset.truePeakDbTP
    }

    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(durationFrames) / sampleRate
    }

    var playheadSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(playheadFrame) / sampleRate
    }

    static let musicCeilingDb: Float = -0.1
    static let musicThresholdMin: Float = -24
    static let musicThresholdMax: Float = -0.1

    var musicMakeupDb: Float {
        Self.musicCeilingDb - musicThresholdDb
    }

    var hasFile: Bool { sourceStore != nil }

    /// POST is live for MUSIC LOUD; other presets need a finished leveled file.
    var canListenPost: Bool {
        guard hasFile else { return false }
        if preset.isMaximizer { return true }
        return hasResult
    }

    var liveMaximizerActive: Bool { preset.isMaximizer && hasFile }

    var listedPresets: [PlatformPreset] {
        PlatformPreset.factory + userPresets.map(\.asPlatformPreset) + [.custom]
    }

    public convenience init() {
        self.init(scanCache: .shared)
    }

    init(scanCache: LevelerScanCache) {
        self.scanCache = scanCache
        PCMStore.sweepTemporaryFiles()
        userPresets = UserLoudnessPresetStore.load()
        playback.onPlayhead = { [weak self] frame in
            Task { @MainActor in
                guard let self, !self.isScrubbing else { return }
                self.playheadFrame = frame
            }
        }
        playback.onEnded = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.playheadFrame = 0
                self.status = self.readyStatus()
            }
        }
        playback.onMeters = { [weak self] pre, post in
            Task { @MainActor in
                self?.ingestMeters(pre: pre, post: post)
            }
        }
        playback.onGainReduction = { [weak self] gr in
            Task { @MainActor in
                guard let self, self.preset.isMaximizer else { return }
                self.liveGR = gr
                self.peakGR = max(self.peakGR, gr)
            }
        }
    }

    func selectPreset(_ p: PlatformPreset) {
        preset = p
        if !p.isCustom, let match = userPresets.first(where: { $0.id == p.id }) {
            customLUFS = match.targetLUFS
            customTP = match.truePeakDbTP
        }
        if p.isMaximizer, hasFile {
            playAfter = true
            playback.setPlayPost(true)
            syncLiveMaximizer()
        } else {
            syncLiveMaximizer()
            if !hasResult {
                playAfter = false
                playback.setPlayPost(false)
            }
        }
        process()
    }

    func saveCustomAsPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Give the preset a name first."
            return
        }
        let item = UserLoudnessPreset(
            id: "user-\(UUID().uuidString)",
            title: trimmed,
            targetLUFS: customLUFS,
            truePeakDbTP: customTP
        )
        userPresets.append(item)
        do {
            try UserLoudnessPresetStore.save(userPresets)
            selectPreset(item.asPlatformPreset)
            status = "Saved preset “\(trimmed)”"
        } catch {
            userPresets.removeAll { $0.id == item.id }
            status = "Could not save preset: \(error.localizedDescription)"
        }
    }

    func deleteUserPreset(_ id: String) {
        userPresets.removeAll { $0.id == id }
        do {
            try UserLoudnessPresetStore.save(userPresets)
        } catch {
            status = "Could not update presets: \(error.localizedDescription)"
            return
        }
        if preset.id == id {
            preset = .universal
            process()
        }
        status = "Removed personal preset"
    }

    public func load(url: URL, displayName: String? = nil) {
        stopPlayback()
        loadGeneration += 1
        processGeneration += 1
        restoringAudio = false
        levelWhenAudioReturns = false
        pendingProcessUseCache = true
        let gen = loadGeneration
        let resolvedName = Self.presentationName(displayName, url: url)
        let stamp = LevelerFileStamp.make(for: url)

        if let stamp, let hit = scanCache.source(for: stamp) {
            if let store = hit.store {
                acceptLoadedFile(url: url, name: resolvedName, stamp: stamp, store: store, report: hit.report)
                return
            }
            let threshold = prospectiveThreshold(for: hit.report)
            let key = processKey(musicThreshold: threshold)
            if let result = scanCache.result(for: stamp, key: key) {
                presentCachedLevel(
                    url: url,
                    name: resolvedName,
                    stamp: stamp,
                    sourceReport: hit.report,
                    result: result,
                    threshold: threshold,
                    generation: gen
                )
                return
            }
            startVisibleLoad(
                url: url,
                name: resolvedName,
                stamp: stamp,
                cachedReport: hit.report,
                generation: gen
            )
            return
        }

        startVisibleLoad(
            url: url,
            name: resolvedName,
            stamp: stamp,
            cachedReport: nil,
            generation: gen
        )
    }

    /// Decode and, when the source report is new, measure it. Shows the cached
    /// BEFORE numbers immediately, then the usual loading and leveling progress.
    private func startVisibleLoad(
        url: URL,
        name: String,
        stamp: LevelerFileStamp?,
        cachedReport: LoudnessReport?,
        generation: UInt64
    ) {
        isBusy = true
        status = "Loading…"
        hasResult = false
        isMeasuring = false
        measureAgain = false
        before = cachedReport ?? .empty
        after = .empty
        appliedGainDb = 0
        sourceStore = nil
        leveledStore = nil
        loadedStamp = nil
        playback.load(pre: nil, post: nil)
        playAfter = false
        playheadFrame = 0
        durationFrames = 0
        resetMeterUI()
        sourceURL = url
        sourceName = name

        Task.detached(priority: .userInitiated) {
            do {
                let store = try AudioFileIO.ingest(url: url) { fraction in
                    Task { @MainActor in
                        guard self.loadGeneration == generation else { return }
                        self.status = String(format: "Loading… %.0f%%", fraction * 100)
                    }
                }
                let report: LoudnessReport
                let didAnalyze: Bool
                if let cachedReport {
                    report = cachedReport
                    didAnalyze = false
                } else {
                    report = LoudnessEngine.analyze(store) { fraction in
                        Task { @MainActor in
                            guard self.loadGeneration == generation else { return }
                            self.status = String(format: "Analyzing… %.0f%%", fraction * 100)
                        }
                    }
                    didAnalyze = true
                }
                await MainActor.run {
                    if didAnalyze { self.sourceAnalysisCount += 1 }
                    if let stamp {
                        self.scanCache.storeSource(stamp: stamp, report: report, store: store)
                    }
                    guard self.loadGeneration == generation else { return }
                    self.acceptLoadedFile(
                        url: url,
                        name: name,
                        stamp: stamp,
                        store: store,
                        report: report
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.isBusy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    /// Puts the last level back on screen in this turn, then refills audio
    /// without a scan. Play and export stay off until that audio is in place.
    private func presentCachedLevel(
        url: URL,
        name: String,
        stamp: LevelerFileStamp,
        sourceReport: LoudnessReport,
        result: LevelerScanCache.ResultHit,
        threshold: Float,
        generation: UInt64
    ) {
        sourceURL = url
        sourceName = name
        loadedStamp = stamp
        sourceStore = nil
        leveledStore = nil
        before = sourceReport
        let rate = sourceReport.sampleRate > 0 ? sourceReport.sampleRate : 44_100
        sampleRate = rate
        durationFrames = Int((sourceReport.durationSec * rate).rounded())
        musicThresholdDb = threshold
        pendingMusicThreshold = nil
        isBusy = false
        isMeasuring = false
        measureAgain = false
        renderFraction = 0
        resetMeterUI()
        peakGR = result.peakGR
        filePeakGR = result.peakGR
        playback.load(pre: nil, post: nil)
        playheadFrame = 0
        playAfter = false
        after = result.report
        appliedGainDb = result.appliedGainDb
        hasResult = true
        if preset.isMaximizer {
            playAfter = true
            playback.setPlayPost(true)
        }
        restoringAudio = true
        status = "Loading audio…"

        let key = currentProcessKey()
        let cachedAfter = result.report
        let cachedGain = result.appliedGainDb
        let cachedPeak = result.peakGR
        let maximizer = preset.isMaximizer
        let target = activeTargetLUFS
        let truePeak = activeTruePeak
        let ceiling = Self.musicCeilingDb
        let restoreThreshold = musicThresholdDb

        Task.detached(priority: .userInitiated) {
            do {
                let store = try AudioFileIO.ingest(url: url, progress: nil)
                let leveled: PCMStore
                if maximizer {
                    leveled = try LoudnessEngine.renderMaximized(
                        store,
                        thresholdDb: restoreThreshold,
                        ceilingDb: ceiling,
                        progress: nil
                    )
                } else {
                    leveled = try LoudnessEngine.renderNormalized(
                        store,
                        knownBefore: sourceReport,
                        targetLUFS: target,
                        truePeakCeilingDbTP: truePeak,
                        progress: nil
                    )
                }
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.finishQuietRestore(
                        stamp: stamp,
                        sourceReport: sourceReport,
                        store: store,
                        leveled: leveled,
                        key: key,
                        cachedAfter: cachedAfter,
                        cachedGain: cachedGain,
                        cachedPeak: cachedPeak
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.restoringAudio = false
                    self.levelWhenAudioReturns = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func finishQuietRestore(
        stamp: LevelerFileStamp,
        sourceReport: LoudnessReport,
        store: PCMStore,
        leveled: PCMStore,
        key: LevelerScanCache.ProcessKey,
        cachedAfter: LoudnessReport,
        cachedGain: Float,
        cachedPeak: Float
    ) {
        scanCache.storeSource(stamp: stamp, report: sourceReport, store: store)
        scanCache.storeResult(
            stamp: stamp,
            key: key,
            report: cachedAfter,
            appliedGainDb: cachedGain,
            peakGR: cachedPeak,
            store: leveled
        )
        let rerun = levelWhenAudioReturns || currentProcessKey() != key
        let useCache = pendingProcessUseCache
        restoringAudio = false
        levelWhenAudioReturns = false
        pendingProcessUseCache = true
        sourceStore = store
        loadedStamp = stamp
        sampleRate = store.sampleRate
        durationFrames = store.frameCount
        playback.load(pre: store, post: nil)
        if preset.isMaximizer {
            playAfter = true
            syncLiveMaximizer()
            playback.setPlayPost(true)
        }
        if rerun {
            process(useCache: useCache)
            return
        }
        applyProcessedResult(
            report: cachedAfter,
            gain: cachedGain,
            peakGR: cachedPeak,
            store: leveled
        )
    }

    func setMusicThreshold(_ db: Float) {
        musicThresholdDb = min(Self.musicThresholdMax, max(Self.musicThresholdMin, db))
        syncLiveMaximizer()
    }

    func process() {
        process(useCache: true)
    }

    /// Same settings as the last level, but run the processor again.
    func relevel() {
        process(useCache: false)
    }

    private func process(useCache: Bool) {
        guard let sourceStore else {
            if restoringAudio {
                levelWhenAudioReturns = true
                pendingProcessUseCache = useCache
                return
            }
            status = "Load a file first."
            return
        }
        let maximizer = preset.isMaximizer
        let key = currentProcessKey()
        if useCache, let stamp = loadedStamp,
           let hit = scanCache.result(for: stamp, key: key),
           let leveled = hit.store {
            processGeneration += 1
            measureAgain = false
            applyProcessedResult(
                report: hit.report,
                gain: hit.appliedGainDb,
                peakGR: hit.peakGR,
                store: leveled
            )
            return
        }
        if maximizer, isMeasuring {
            measureAgain = true
            return
        }
        measureAgain = false
        processGeneration += 1
        let gen = processGeneration
        let target = activeTargetLUFS
        let tp = activeTruePeak
        let store = sourceStore
        let threshold = musicThresholdDb
        let ceiling = Self.musicCeilingDb
        let stamp = loadedStamp
        let knownBefore: LoudnessReport? = before.durationSec > 0.05 && before.channelCount > 0 ? before : nil
        syncLiveMaximizer()
        if maximizer {
            isMeasuring = true
            if !isPlaying {
                status = "Updating FILE LOUDNESS…"
            }
        } else {
            isMeasuring = false
            isBusy = true
            status = "Leveling to \(String(format: "%.1f", target)) LUFS…"
        }

        Task.detached(priority: .userInitiated) {
            do {
                let (out, report, gain): (PCMStore, LoudnessReport, Float)
                var renderGR: Float = 0
                if maximizer {
                    let result = try LoudnessEngine.maximize(
                        store,
                        thresholdDb: threshold,
                        ceilingDb: ceiling,
                        knownBefore: knownBefore
                    ) { fraction in
                        Task { @MainActor in
                            guard self.processGeneration == gen else { return }
                            if self.isPlaying { return }
                            self.status = String(format: "Updating FILE LOUDNESS… %.0f%%", fraction * 100)
                        }
                    }
                    (out, report, gain) = (result.0, result.1, result.2)
                    renderGR = result.3
                } else {
                    (out, report, gain) = try LoudnessEngine.normalize(
                        store,
                        targetLUFS: target,
                        truePeakCeilingDbTP: tp,
                        knownBefore: knownBefore
                    ) { fraction in
                        Task { @MainActor in
                            guard self.processGeneration == gen else { return }
                            self.status = String(
                                format: "Leveling to %.1f LUFS… %.0f%%",
                                target,
                                fraction * 100
                            )
                        }
                    }
                }
                await MainActor.run {
                    guard self.processGeneration == gen else { return }
                    if let stamp {
                        self.scanCache.storeResult(
                            stamp: stamp,
                            key: key,
                            report: report,
                            appliedGainDb: gain,
                            peakGR: renderGR,
                            store: out
                        )
                    }
                    self.levelingMeasureCount += 1
                    self.applyProcessedResult(report: report, gain: gain, peakGR: renderGR, store: out)
                    if maximizer, self.measureAgain {
                        self.process()
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.processGeneration == gen else { return }
                    if maximizer {
                        self.isMeasuring = false
                        self.measureAgain = false
                    } else {
                        self.isBusy = false
                    }
                    self.status = error.localizedDescription
                }
            }
        }
    }

    public var sourceSampleRate: Double { sampleRate }

    public var activePresetTitle: String { preset.title }

    public var activePresetID: String { preset.id }

    public var canExportLeveled: Bool {
        if isBusy || isMeasuring { return false }
        if preset.isMaximizer { return hasFile }
        return hasResult && leveledStore != nil
    }

    public func controlSnapshot() -> LevelerControlSnapshot {
        LevelerControlSnapshot(
            presetID: preset.id,
            customLUFS: customLUFS,
            customTruePeak: customTP,
            musicThresholdDb: musicThresholdDb,
            meterMode: meterMode.rawValue,
            peakHold: peakHold,
            listenPost: playAfter
        )
    }

    /// Applies saved controls. Threshold and A/B wait until the file has finished loading.
    public func applyControls(_ snapshot: LevelerControlSnapshot) {
        customLUFS = min(-10, max(-24, snapshot.customLUFS))
        customTP = min(-0.1, max(-3, snapshot.customTruePeak))
        if let match = listedPresets.first(where: { $0.id == snapshot.presetID }) {
            preset = match
        } else if snapshot.presetID == PlatformPreset.custom.id {
            preset = .custom
        } else {
            preset = .universal
        }
        let threshold = min(Self.musicThresholdMax, max(Self.musicThresholdMin, snapshot.musicThresholdDb))
        musicThresholdDb = threshold
        pendingMusicThreshold = threshold
        if let mode = LevelerMeterMode(rawValue: snapshot.meterMode) {
            meterMode = mode
        }
        peakHold = snapshot.peakHold
        pendingListenPost = snapshot.listenPost
        if hasFile {
            pendingMusicThreshold = nil
            syncLiveMaximizer()
            process()
        }
    }

    /// Shows a finished level. Playback position is left as it is, except a fresh load
    /// which resets the playhead before calling this.
    private func applyProcessedResult(
        report: LoudnessReport,
        gain: Float,
        peakGR renderGR: Float,
        store: PCMStore
    ) {
        leveledStore = store
        after = report
        appliedGainDb = gain
        hasResult = true
        playback.setPost(store)
        syncLiveMaximizer()
        if preset.isMaximizer {
            filePeakGR = renderGR
            peakGR = max(peakGR, renderGR)
            isMeasuring = false
        } else {
            isBusy = false
        }
        consumePendingListen()
        status = isPlaying ? playingStatus() : readyStatus()
    }

    /// Installs a decoded file and, when this preset was already leveled, its result.
    /// Does not run "Analyzing…" when the report is already known.
    private func acceptLoadedFile(
        url: URL,
        name: String,
        stamp: LevelerFileStamp?,
        store: PCMStore,
        report: LoudnessReport
    ) {
        sourceURL = url
        sourceName = name
        loadedStamp = stamp
        sourceStore = store
        before = report
        sampleRate = store.sampleRate
        durationFrames = store.frameCount
        if let pending = pendingMusicThreshold {
            musicThresholdDb = min(Self.musicThresholdMax, max(Self.musicThresholdMin, pending))
            pendingMusicThreshold = nil
        } else {
            musicThresholdDb = min(
                Self.musicThresholdMax,
                max(Self.musicThresholdMin, report.truePeakDbTP)
            )
        }
        liveGR = 0
        peakGR = 0
        filePeakGR = 0
        isMeasuring = false
        measureAgain = false
        resetMeterUI()
        playback.load(pre: store, post: nil)
        playheadFrame = 0
        playAfter = false
        hasResult = false
        after = .empty
        appliedGainDb = 0
        leveledStore = nil
        if preset.isMaximizer {
            isBusy = false
            playAfter = true
            syncLiveMaximizer()
            playback.setPlayPost(true)
        }
        if let stamp,
           let hit = scanCache.result(for: stamp, key: currentProcessKey()),
           let leveled = hit.store {
            applyProcessedResult(
                report: hit.report,
                gain: hit.appliedGainDb,
                peakGR: hit.peakGR,
                store: leveled
            )
            return
        }
        status = String(
            format: "Loaded · %@ · %d ch · %.0f Hz · integrated %.1f LUFS",
            Self.formatTime(seconds: report.durationSec),
            report.channelCount,
            report.sampleRate,
            report.integratedLUFS
        )
        process()
    }

    private func currentProcessKey() -> LevelerScanCache.ProcessKey {
        processKey(musicThreshold: musicThresholdDb)
    }

    private func processKey(musicThreshold: Float) -> LevelerScanCache.ProcessKey {
        LevelerScanCache.ProcessKey(
            presetID: preset.id,
            targetLUFSMilli: LevelerScanCache.milli(activeTargetLUFS),
            truePeakMilli: LevelerScanCache.milli(activeTruePeak),
            musicThresholdMilli: preset.isMaximizer ? LevelerScanCache.milli(musicThreshold) : 0,
            maximizer: preset.isMaximizer
        )
    }

    /// Threshold a freshly opened file will use, matching `acceptLoadedFile`.
    private func prospectiveThreshold(for report: LoudnessReport) -> Float {
        let raw = pendingMusicThreshold ?? report.truePeakDbTP
        return min(Self.musicThresholdMax, max(Self.musicThresholdMin, raw))
    }

    /// Stops playback and drops the working audio. Does not delete depot files.
    /// The scan cache stays for the rest of the app launch.
    public func teardown() {
        stopPlayback()
        loadGeneration += 1
        processGeneration += 1
        restoringAudio = false
        levelWhenAudioReturns = false
        pendingProcessUseCache = true
        isBusy = false
        isExporting = false
        isMeasuring = false
        measureAgain = false
        hasResult = false
        renderFraction = 0
        sourceStore = nil
        leveledStore = nil
        loadedStamp = nil
        playback.load(pre: nil, post: nil)
        sourceURL = nil
        sourceName = ""
        before = .empty
        after = .empty
        appliedGainDb = 0
        playAfter = false
        durationFrames = 0
        resetMeterUI()
    }

    /// Level first (already baked, or MUSIC LOUD rendered here), then sample-rate
    /// conversion, then dither only when the file is 16-bit.
    public func writeLeveled(
        to url: URL,
        output: LevelerOutputSettings,
        releaseBusy: Bool = true
    ) async throws {
        guard let sourceStore else {
            status = "Nothing to export yet."
            throw LevelerError.processFailed("Nothing to export yet.")
        }
        let maximizer = preset.isMaximizer
        if maximizer == false, leveledStore == nil {
            status = "Nothing to export yet."
            throw LevelerError.processFailed("Nothing to export yet.")
        }
        let baked = leveledStore
        let threshold = musicThresholdDb
        let ceiling = Self.musicCeilingDb
        let settings = output
        let generation = loadGeneration
        let knownBefore: LoudnessReport? = before.durationSec > 0.05 && before.channelCount > 0 ? before : nil
        isBusy = true
        isExporting = true
        renderFraction = 0
        status = "Rendering…"
        let holdExporting = !releaseBusy
        defer {
            if !holdExporting {
                isExporting = false
            }
        }
        let report: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in
                guard self.loadGeneration == generation else { return }
                self.renderFraction = fraction
                self.status = String(format: "Rendering… %.0f%%", fraction * 100)
            }
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                let rendered: PCMStore
                if maximizer {
                    let result = try LoudnessEngine.maximize(
                        sourceStore,
                        thresholdDb: threshold,
                        ceilingDb: ceiling,
                        knownBefore: knownBefore
                    ) { fraction in
                        report(0.7 * fraction)
                    }
                    rendered = result.0
                } else if let baked {
                    rendered = baked
                } else {
                    throw LevelerError.processFailed("Nothing to export yet.")
                }
                try LevelerOutputWriter.write(store: rendered, to: url, settings: settings) { fraction in
                    report(0.7 + 0.3 * fraction)
                }
            }.value
            guard loadGeneration == generation else { return }
            renderFraction = 1
            if releaseBusy {
                isBusy = false
            }
            status = "Rendered \(url.lastPathComponent)"
        } catch {
            if loadGeneration == generation {
                renderFraction = 0
                if releaseBusy {
                    isBusy = false
                }
                status = error.localizedDescription
            }
            throw error
        }
    }

    func togglePlayback() {
        if isPlaying {
            playback.pause()
            isPlaying = false
            playheadFrame = playback.currentFrame()
            status = "Paused · \(Self.formatTime(seconds: playheadSeconds))"
            return
        }
        guard sourceStore != nil else { return }
        do {
            try playback.start()
            isPlaying = true
            status = playingStatus()
        } catch {
            isPlaying = false
            status = error.localizedDescription
        }
    }

    func setListenPost(_ listenPost: Bool) {
        let next = listenPost && canListenPost
        playAfter = next
        playback.setPlayPost(next)
        if isPlaying {
            status = playingStatus()
        }
    }

    func scrub(to seconds: Double) {
        isScrubbing = true
        let clamped = max(0, min(durationSeconds, seconds))
        let frame = Int((clamped * sampleRate).rounded(.down))
        playback.seek(frame: frame)
        playheadFrame = frame
    }

    func endScrub() {
        isScrubbing = false
        playheadFrame = playback.currentFrame()
    }

    func setMeterMode(_ mode: LevelerMeterMode) {
        meterMode = mode
        resetPeakHold()
    }

    func resetPeakHold() {
        let pre = livePre.display(mode: meterMode)
        let post = livePost.display(mode: meterMode)
        preHoldL = pre.left
        preHoldR = pre.right
        postHoldL = post.left
        postHoldR = post.right
        preOvers = false
        postOvers = false
        liveGR = 0
        peakGR = filePeakGR
    }

    public func stopPlayback() {
        playback.stop(resetPlayhead: true)
        isPlaying = false
        isScrubbing = false
        playheadFrame = 0
    }

    /// Stops the transport only when it is running, so a paused playhead stays put.
    public func stopTransportIfPlaying() {
        guard isPlaying else { return }
        stopPlayback()
    }

    static func formatTime(seconds: Double) -> String {
        let safe = max(0, seconds)
        let total = Int(safe.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func playingStatus() -> String {
        if playAfter {
            return preset.isMaximizer ? "Playing POST (maximizer)…" : "Playing POST (leveled)…"
        }
        return "Playing PRE (source)…"
    }

    private func syncLiveMaximizer() {
        playback.setLiveMaximizer(
            enabled: preset.isMaximizer && sourceStore != nil,
            makeupDb: musicMakeupDb
        )
    }

    private static func presentationName(_ displayName: String?, url: URL) -> String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return url.lastPathComponent }
        return trimmed
    }

    private func consumePendingListen() {
        guard let listen = pendingListenPost else { return }
        pendingListenPost = nil
        setListenPost(listen)
    }

    private func readyStatus() -> String {
        if hasResult {
            if preset.isMaximizer {
                return String(
                    format: "Ready · MUSIC LOUD · thresh %.1f dB · GR %.1f dB · TP %.1f dBTP",
                    musicThresholdDb,
                    peakGR,
                    after.truePeakDbTP
                )
            }
            return String(
                format: "Ready · gain %+.1f dB → %.1f LUFS · TP %.1f dBTP",
                appliedGainDb,
                after.integratedLUFS,
                after.truePeakDbTP
            )
        }
        if sourceURL != nil {
            if preset.isMaximizer {
                return String(
                    format: "Ready · MUSIC LOUD · thresh %.1f dB · drag THRESHOLD to listen",
                    musicThresholdDb
                )
            }
            return "Ready"
        }
        return "Drop a final mix to begin"
    }

    private func resetMeterUI() {
        livePre = .silent
        livePost = .silent
        preHoldL = -80
        preHoldR = -80
        postHoldL = -80
        postHoldR = -80
        preOvers = false
        postOvers = false
        liveGR = 0
        peakGR = 0
        filePeakGR = 0
    }

    private func ingestMeters(pre: LiveMeterSample, post: LiveMeterSample) {
        livePre = pre
        livePost = post
        let prePair = pre.display(mode: meterMode)
        let postPair = post.display(mode: meterMode)
        if peakHold {
            preHoldL = max(preHoldL, prePair.left)
            preHoldR = max(preHoldR, prePair.right)
            postHoldL = max(postHoldL, postPair.left)
            postHoldR = max(postHoldR, postPair.right)
        } else {
            let fall: Float = 12.0 / 24.0
            preHoldL = max(prePair.left, preHoldL - fall)
            preHoldR = max(prePair.right, preHoldR - fall)
            postHoldL = max(postPair.left, postHoldL - fall)
            postHoldR = max(postPair.right, postHoldR - fall)
        }
        if pre.tpL >= -0.1 || pre.tpR >= -0.1 { preOvers = true }
        if post.tpL >= -0.1 || post.tpR >= -0.1 { postOvers = true }
    }
}
