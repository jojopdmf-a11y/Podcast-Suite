import AppKit
import AVFoundation
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
    @Published var playAfter = false // false = preview source, true = preview leveled

    private var sourceBuffer: WAVIO.Buffer?
    private var leveledBuffer: WAVIO.Buffer?
    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    var activeTargetLUFS: Float {
        preset.isCustom ? customLUFS : preset.targetLUFS
    }

    var activeTruePeak: Float {
        preset.isCustom ? customTP : preset.truePeakDbTP
    }

    func load(url: URL) {
        stopPlayback()
        isBusy = true
        status = "Analyzing…"
        hasResult = false
        after = .empty
        appliedGainDb = 0
        leveledBuffer = nil

        Task.detached(priority: .userInitiated) {
            do {
                let buf = try AudioFileIO.load(url: url)
                let report = LoudnessEngine.analyze(buf)
                await MainActor.run {
                    self.sourceURL = url
                    self.sourceName = url.lastPathComponent
                    self.sourceBuffer = buf
                    self.before = report
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
                    self.isBusy = false
                    self.status = String(
                        format: "Ready · gain %+.1f dB → %.1f LUFS · TP %.1f dBTP",
                        gain,
                        report.integratedLUFS,
                        report.truePeakDbTP
                    )
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

    func togglePlay(after: Bool) {
        if isPlaying, playAfter == after {
            stopPlayback()
            return
        }
        stopPlayback()
        let buf = after ? leveledBuffer : sourceBuffer
        guard let buf else { return }
        playAfter = after
        do {
            try startPlayback(buf)
            isPlaying = true
            status = after ? "Playing leveled…" : "Playing source…"
        } catch {
            status = error.localizedDescription
        }
    }

    func stopPlayback() {
        player?.stop()
        audioEngine?.stop()
        if let node = player {
            audioEngine?.detach(node)
        }
        player = nil
        audioEngine = nil
        isPlaying = false
    }

    private func startPlayback(_ buffer: WAVIO.Buffer) throws {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.sampleRate,
            channels: AVAudioChannelCount(buffer.channelCount),
            interleaved: true
        )!
        engine.connect(node, to: engine.mainMixerNode, format: format)
        let frameCount = AVAudioFrameCount(buffer.frameCount)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw LevelerError.processFailed("Could not build playback buffer.")
        }
        pcm.frameLength = frameCount
        if let dst = pcm.floatChannelData {
            if buffer.channelCount == 1 {
                for i in 0..<buffer.frameCount {
                    dst[0][i] = buffer.samples[i]
                }
            } else {
                // De-interleave for non-interleaved PCM buffer
                for f in 0..<buffer.frameCount {
                    for c in 0..<buffer.channelCount {
                        dst[c][f] = buffer.samples[f * buffer.channelCount + c]
                    }
                }
            }
        }
        try engine.start()
        node.scheduleBuffer(pcm, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
        node.play()
        audioEngine = engine
        player = node
    }
}
