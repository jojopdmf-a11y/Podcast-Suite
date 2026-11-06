import Combine
import Foundation
import SwiftUI

@MainActor
public final class LevelerSession: ObservableObject {
    @Published public var sourceURL: URL?
    @Published var sourceName: String = ""
    @Published public var status: String = "Drop a final mix to begin"
    @Published var isBusy = false
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

    public init() {
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
        let gen = loadGeneration
        let resolvedName = Self.presentationName(displayName, url: url)
        isBusy = true
        status = "Loading…"
        hasResult = false
        isMeasuring = false
        measureAgain = false
        before = .empty
        after = .empty
        appliedGainDb = 0
        sourceStore = nil
        leveledStore = nil
        playback.load(pre: nil, post: nil)
        playAfter = false
        playheadFrame = 0
        durationFrames = 0
        resetMeterUI()
        sourceURL = url
        sourceName = resolvedName

        Task.detached(priority: .userInitiated) {
            do {
                let store = try AudioFileIO.ingest(url: url) { fraction in
                    Task { @MainActor in
                        guard self.loadGeneration == gen else { return }
                        self.status = String(format: "Loading… %.0f%%", fraction * 100)
                    }
                }
                let report = LoudnessEngine.analyze(store) { fraction in
                    Task { @MainActor in
                        guard self.loadGeneration == gen else { return }
                        self.status = String(format: "Analyzing… %.0f%%", fraction * 100)
                    }
                }
                await MainActor.run {
                    guard self.loadGeneration == gen else { return }
                    self.sourceURL = url
                    self.sourceName = resolvedName
                    self.sourceStore = store
                    self.before = report
                    self.sampleRate = store.sampleRate
                    self.durationFrames = store.frameCount
                    if let pending = self.pendingMusicThreshold {
                        self.musicThresholdDb = min(Self.musicThresholdMax, max(Self.musicThresholdMin, pending))
                        self.pendingMusicThreshold = nil
                    } else {
                        self.musicThresholdDb = min(
                            Self.musicThresholdMax,
                            max(Self.musicThresholdMin, report.truePeakDbTP)
                        )
                    }
                    self.liveGR = 0
                    self.peakGR = 0
                    self.filePeakGR = 0
                    self.playback.load(pre: store, post: nil)
                    if self.preset.isMaximizer {
                        self.isBusy = false
                        self.playAfter = true
                        self.syncLiveMaximizer()
                        self.playback.setPlayPost(true)
                    }
                    self.status = String(
                        format: "Loaded · %@ · %d ch · %.0f Hz · integrated %.1f LUFS",
                        Self.formatTime(seconds: report.durationSec),
                        report.channelCount,
                        report.sampleRate,
                        report.integratedLUFS
                    )
                    self.process()
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == gen else { return }
                    self.isBusy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func setMusicThreshold(_ db: Float) {
        musicThresholdDb = min(Self.musicThresholdMax, max(Self.musicThresholdMin, db))
        syncLiveMaximizer()
    }

    func process() {
        guard let sourceStore else {
            status = "Load a file first."
            return
        }
        let maximizer = preset.isMaximizer
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
                        ceilingDb: ceiling
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
                        truePeakCeilingDbTP: tp
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
                    self.leveledStore = out
                    self.after = report
                    self.appliedGainDb = gain
                    self.hasResult = true
                    self.playback.setPost(out)
                    self.syncLiveMaximizer()
                    if maximizer {
                        self.filePeakGR = renderGR
                        self.peakGR = max(self.peakGR, renderGR)
                        self.isMeasuring = false
                        if self.measureAgain {
                            self.process()
                            return
                        }
                    } else {
                        self.isBusy = false
                    }
                    self.consumePendingListen()
                    self.status = self.isPlaying ? self.playingStatus() : self.readyStatus()
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
        return hasResult
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

    /// Stops playback and drops the working audio. Does not delete depot files.
    public func teardown() {
        stopPlayback()
        loadGeneration += 1
        processGeneration += 1
        isBusy = false
        isMeasuring = false
        measureAgain = false
        hasResult = false
        renderFraction = 0
        sourceStore = nil
        leveledStore = nil
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
        isBusy = true
        renderFraction = 0
        status = "Rendering…"
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
                        ceilingDb: ceiling
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
