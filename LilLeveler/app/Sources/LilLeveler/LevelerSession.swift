import AppKit
import Combine
import Foundation
import SwiftUI

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

    private var sourceBuffer: WAVIO.Buffer?
    private var leveledBuffer: WAVIO.Buffer?
    private let playback = LevelerPlaybackEngine()

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

    var listedPresets: [PlatformPreset] {
        PlatformPreset.factory + userPresets.map(\.asPlatformPreset) + [.custom]
    }

    init() {
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
        isBusy = true
        status = "Analyzing…"
        hasResult = false
        after = .empty
        appliedGainDb = 0
        leveledBuffer = nil
        playAfter = false
        playheadFrame = 0
        durationFrames = 0
        resetMeterUI()

        Task.detached(priority: .userInitiated) {
            do {
                let buf = try AudioFileIO.load(url: url)
                let report = LoudnessEngine.analyze(buf)
                await MainActor.run {
                    self.sourceURL = url
                    self.sourceName = url.lastPathComponent
                    self.sourceBuffer = buf
                    self.before = report
                    self.sampleRate = buf.sampleRate
                    self.durationFrames = buf.frameCount
                    self.playback.load(pre: buf, post: nil)
                    self.isBusy = false
                    self.status = String(
                        format: "Loaded · %.0fs · %d ch · %.0f Hz · integrated %.1f LUFS",
                        report.durationSec,
                        report.channelCount,
                        report.sampleRate,
                        report.integratedLUFS
                    )
                    // Auto-preview level to active preset
                    self.process()
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func process() {
        guard let sourceBuffer else {
            status = "Load a file first."
            return
        }
        isBusy = true
        status = "Leveling to \(String(format: "%.1f", activeTargetLUFS)) LUFS…"
        let target = activeTargetLUFS
        let tp = activeTruePeak
        let buf = sourceBuffer

        Task.detached(priority: .userInitiated) {
            do {
                let (out, report, gain) = try LoudnessEngine.normalize(
                    buf,
                    targetLUFS: target,
                    truePeakCeilingDbTP: tp
                )
                await MainActor.run {
                    self.leveledBuffer = out
                    self.after = report
                    self.appliedGainDb = gain
                    self.hasResult = true
                    self.playback.setPost(out)
                    self.isBusy = false
                    self.status = self.isPlaying ? self.playingStatus() : self.readyStatus()
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func exportLeveled() {
        guard let leveledBuffer, let sourceURL else {
            status = "Nothing to export yet."
            return
        }
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let dest = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(base)_leveled.wav")
        do {
            try WAVIO.write(url: dest, buffer: leveledBuffer)
            status = "Exported → \(dest.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            status = error.localizedDescription
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
        guard sourceBuffer != nil else { return }
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
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func playingStatus() -> String {
        playAfter ? "Playing POST (leveled)…" : "Playing PRE (source)…"
    }

    private func readyStatus() -> String {
        if hasResult {
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
