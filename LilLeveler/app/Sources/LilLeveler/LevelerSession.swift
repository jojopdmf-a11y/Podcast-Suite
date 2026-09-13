import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LevelerSession: ObservableObject {
    @Published var sourceURL: URL?
    @Published var sourceName: String = ""
    @Published var status: String = "Drop a final mix to begin"
    @Published var isBusy = false
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

    private var sourceStore: PCMStore?
    private var leveledStore: PCMStore?
    private let playback = LevelerPlaybackEngine()
    private var loadGeneration: UInt64 = 0
    private var processGeneration: UInt64 = 0

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

    var listedPresets: [PlatformPreset] {
        PlatformPreset.factory + userPresets.map(\.asPlatformPreset) + [.custom]
    }

    init() {
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

    func load(url: URL) {
        stopPlayback()
        loadGeneration += 1
        processGeneration += 1
        let gen = loadGeneration
        isBusy = true
        status = "Loading…"
        hasResult = false
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
        sourceName = url.lastPathComponent

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
                    self.sourceName = url.lastPathComponent
                    self.sourceStore = store
                    self.before = report
                    self.sampleRate = store.sampleRate
                    self.durationFrames = store.frameCount
                    self.musicThresholdDb = min(
                        Self.musicThresholdMax,
                        max(Self.musicThresholdMin, report.truePeakDbTP)
                    )
                    self.liveGR = 0
                    self.peakGR = 0
                    self.filePeakGR = 0
                    self.playback.load(pre: store, post: nil)
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

    func process() {
        guard let sourceStore else {
            status = "Load a file first."
            return
        }
        processGeneration += 1
        let gen = processGeneration
        isBusy = true
        let maximizer = preset.isMaximizer
        let target = activeTargetLUFS
        let tp = activeTruePeak
        let store = sourceStore
        status = maximizer
            ? "Maximizing…"
            : "Leveling to \(String(format: "%.1f", target)) LUFS…"
        let threshold = musicThresholdDb
        let ceiling = Self.musicCeilingDb
        playback.setMaximizerMakeup(db: musicMakeupDb, enabled: maximizer)

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
                            self.status = String(format: "Maximizing… %.0f%%", fraction * 100)
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
                    self.playback.setMaximizerMakeup(db: self.musicMakeupDb, enabled: maximizer)
                    if maximizer {
                        self.liveGR = 0
                        self.filePeakGR = renderGR
                        self.peakGR = renderGR
                    }
                    self.isBusy = false
                    self.status = self.isPlaying ? self.playingStatus() : self.readyStatus()
                }
            } catch {
                await MainActor.run {
                    guard self.processGeneration == gen else { return }
                    self.isBusy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func exportLeveled() {
        guard let leveledStore, let sourceURL else {
            status = "Nothing to export yet."
            return
        }
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let panel = NSSavePanel()
        panel.title = "Export Leveled"
        panel.message = "WAV file after leveling. Pick a folder and a name."
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(base)_leveled.wav"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.level = .modalPanel
        guard panel.runModal() == .OK, var dest = panel.url else {
            status = "Export cancelled"
            return
        }
        if dest.pathExtension.lowercased() != "wav" {
            dest = dest.appendingPathExtension("wav")
        }
        isBusy = true
        status = "Exporting…"
        let store = leveledStore
        let destURL = dest
        let gen = loadGeneration
        Task.detached(priority: .userInitiated) {
            do {
                try WAVIO.write(url: destURL, store: store) { fraction in
                    Task { @MainActor in
                        guard self.loadGeneration == gen else { return }
                        self.status = String(format: "Exporting… %.0f%%", fraction * 100)
                    }
                }
                await MainActor.run {
                    guard self.loadGeneration == gen else { return }
                    self.isBusy = false
                    self.status = "Exported → \(destURL.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([destURL])
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
        let next = listenPost && hasResult
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

    func stopPlayback() {
        playback.stop(resetPlayhead: true)
        isPlaying = false
        isScrubbing = false
        playheadFrame = 0
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
        playAfter ? "Playing POST (leveled)…" : "Playing PRE (source)…"
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
