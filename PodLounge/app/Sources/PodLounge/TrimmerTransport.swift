import AVFoundation
import Darwin
import Foundation
import PodLoungeCore

/// One player node per clip, mixed by a fader for each of the three tracks.
@MainActor
final class TrimmerTransport: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var playhead: Double = 0
    @Published var message: String?

    private let engine = AVAudioEngine()
    private var trackMixers: [TrimmerTrackID: AVAudioMixerNode] = [:]
    private var graphReady = false
    private var players: [AVAudioPlayerNode] = []
    private var voices: [Voice] = []
    private var timer: Timer?
    private var startedAt = Date()
    private var startedPlayhead = 0.0

    func stop() {
        if isPlaying {
            playhead = min(86_400, max(0, startedPlayhead + Date().timeIntervalSince(startedAt)))
        }
        timer?.invalidate()
        timer = nil
        for player in players {
            player.stop()
            engine.detach(player)
        }
        players.removeAll()
        voices.removeAll()
        engine.stop()
        isPlaying = false
    }

    func shutdown() {
        stop()
        message = nil
    }

    func setPlayhead(_ time: Double) {
        guard !isPlaying else { return }
        playhead = max(0, time)
    }

    func applyMix(_ document: TrimmerDocument) {
        guard isPlaying else { return }
        for track in TrimmerTrackID.allCases {
            let audible = document.isAudible(track)
            let gain = TrimmerGain.linear(decibels: document.trackState(track).gainDB)
            trackMixers[track]?.outputVolume = audible ? gain : 0
        }
    }

    func play(document: TrimmerDocument, urlFor: (String) -> URL?) {
        stop()
        message = nil
        prepareGraph()
        let start = playhead
        var scheduled = 0
        let lead = 0.05
        let base = mach_absolute_time() + hostTicks(lead)
        for track in TrimmerTrackID.allCases {
            guard let mixer = trackMixers[track] else { continue }
            let audible = document.isAudible(track)
            let trackGain = TrimmerGain.linear(decibels: document.trackState(track).gainDB)
            mixer.outputVolume = audible ? trackGain : 0
            let mates = document.clips.filter { $0.track == track }
            for clip in mates where clip.end > start + 0.02 {
                guard let url = urlFor(clip.assetID), let file = try? AVAudioFile(forReading: url) else { continue }
                let fileRate = file.processingFormat.sampleRate
                guard fileRate > 0, file.length > 0 else { continue }
                let into = max(0, start - clip.start)
                let sourceStart = clip.inOffset + into
                let timelineLength = clip.end - max(clip.start, start)
                let startFrame = AVAudioFramePosition(max(0, sourceStart * fileRate).rounded(.down))
                let want = AVAudioFrameCount(max(1, timelineLength * fileRate).rounded(.down))
                let available = file.length > startFrame ? AVAudioFrameCount(file.length - startFrame) : 0
                let count = min(want, available)
                guard count > 0 else { continue }
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: mixer, format: file.processingFormat)
                let delay = max(0, clip.start - start)
                let when = AVAudioTime(hostTime: base + hostTicks(delay))
                player.scheduleSegment(file, startingFrame: startFrame, frameCount: count, at: when, completionCallbackType: .dataPlayedBack) { _ in }
                let opening = TrimmerEnvelope.gain(of: clip, among: mates, at: max(clip.start, start))
                player.volume = opening * TrimmerGain.linear(decibels: clip.gainDB)
                players.append(player)
                voices.append(Voice(player: player, clip: clip, mates: mates))
                scheduled += 1
            }
        }
        guard scheduled > 0 else {
            stop()
            playhead = start
            message = "Nothing to play at the playhead."
            return
        }
        do {
            try engine.start()
        } catch {
            stop()
            playhead = start
            message = "Playback could not start."
            return
        }
        for player in players {
            player.play()
        }
        startedAt = Date().addingTimeInterval(lead)
        startedPlayhead = start
        isPlaying = true
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick(documentEnd: document.timelineEnd)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick(documentEnd: Double) {
        guard isPlaying else { return }
        let time = startedPlayhead + Date().timeIntervalSince(startedAt)
        if time >= max(documentEnd, startedPlayhead) + 0.05 {
            stop()
            playhead = max(documentEnd, 0)
            return
        }
        playhead = max(0, time)
        for voice in voices {
            let envelope = TrimmerEnvelope.gain(of: voice.clip, among: voice.mates, at: time)
            voice.player.volume = envelope * TrimmerGain.linear(decibels: voice.clip.gainDB)
        }
    }

    private func prepareGraph() {
        guard !graphReady else { return }
        for track in TrimmerTrackID.allCases {
            let mixer = AVAudioMixerNode()
            engine.attach(mixer)
            engine.connect(mixer, to: engine.mainMixerNode, format: nil)
            trackMixers[track] = mixer
        }
        graphReady = true
    }

    private func hostTicks(_ seconds: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = max(0, seconds) * 1_000_000_000
        let ticks = nanos * Double(info.denom) / Double(info.numer)
        return UInt64(ticks)
    }

    private struct Voice {
        var player: AVAudioPlayerNode
        var clip: TrimmerClip
        var mates: [TrimmerClip]
    }
}
