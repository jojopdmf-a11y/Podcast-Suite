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

    init() {
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
}
