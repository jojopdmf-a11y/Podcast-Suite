import AVFoundation
import Darwin
import Foundation
import PodLoungeCore

struct TrimmerMeterReading: Equatable {
    var left: Float = 0
    var right: Float = 0
    var holdLeft: Float = 0
    var holdRight: Float = 0
}

/// One player node per clip, mixed by a fader for each of the three tracks.
@MainActor
final class TrimmerTransport: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var playhead: Double = 0
    @Published var message: String?
    @Published private(set) var meters: [TrimmerTrackID: TrimmerMeterReading] = TrimmerTransport.silentMeters

    private let engine = AVAudioEngine()
    private var trackMixers: [TrimmerTrackID: AVAudioMixerNode] = [:]
    private var meterMixers: [TrimmerTrackID: AVAudioMixerNode] = [:]
    private var peakBoxes: [TrimmerTrackID: TrackPeakBox] = [:]
    private var meterBallistics: [TrimmerTrackID: MeterBallistic] = [:]
    private var graphReady = false
    private var tapsInstalled = false
    private var players: [AVAudioPlayerNode] = []
    private var voices: [Voice] = []
    private var timer: Timer?
    private var startedAt = Date()
    private var startedPlayhead = 0.0

    private static var silentMeters: [TrimmerTrackID: TrimmerMeterReading] {
        var meters: [TrimmerTrackID: TrimmerMeterReading] = [:]
        for track in TrimmerTrackID.allCases {
            meters[track] = TrimmerMeterReading()
        }
        return meters
    }

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
        clearMeters()
    }

    func shutdown() {
        stop()
        message = nil
    }

    func setPlayhead(_ time: Double) {
        guard !isPlaying else { return }
        playhead = max(0, time.isFinite ? time : 0)
    }

    /// Moves the playhead. When audio is already running, it keeps running from the new time.
    func seek(to time: Double, document: TrimmerDocument, urlFor: (String) -> URL?) {
        let decision = TrimmerSeek.decide(isPlaying: isPlaying, time: time)
        relocate(to: decision.time, resume: decision.keepPlaying, document: document, urlFor: urlFor)
    }

    /// `resume` is remembered from mouse-down, because a ruler drag stops the engine before mouse-up.
    func relocate(to time: Double, resume: Bool, document: TrimmerDocument, urlFor: (String) -> URL?) {
        let target = time.isFinite ? max(0, time) : 0
        if isPlaying { stop() }
        playhead = target
        guard resume else { return }
        play(document: document, urlFor: urlFor)
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
        installMeters()
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
        publishMeters()
    }

    private func prepareGraph() {
        guard !graphReady else { return }
        for track in TrimmerTrackID.allCases {
            let mixer = AVAudioMixerNode()
            let meter = AVAudioMixerNode()
            engine.attach(mixer)
            engine.attach(meter)
            // Players feed the fader. The meter node sits after it, so a tap there is post-fader and post-mute.
            engine.connect(mixer, to: meter, format: nil)
            engine.connect(meter, to: engine.mainMixerNode, format: nil)
            meter.outputVolume = 1
            trackMixers[track] = mixer
            meterMixers[track] = meter
            peakBoxes[track] = TrackPeakBox()
        }
        graphReady = true
    }

    private func installMeters() {
        guard !tapsInstalled else { return }
        var installed = 0
        for track in TrimmerTrackID.allCases {
            guard let meter = meterMixers[track], let box = peakBoxes[track] else { continue }
            let format = meter.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { continue }
            let frames = AVAudioFrameCount(min(format.sampleRate * 0.30, max(format.sampleRate * 0.10, 256)))
            // nil keeps the connection format. The meter node is downstream of the fader, so this tap is post-fader.
            meter.installTap(onBus: 0, bufferSize: frames, format: nil) { buffer, _ in
                box.store(buffer)
            }
            installed += 1
        }
        if installed == TrimmerTrackID.allCases.count {
            tapsInstalled = true
        }
    }

    private func publishMeters() {
        let now = Date()
        var next: [TrimmerTrackID: TrimmerMeterReading] = [:]
        for track in TrimmerTrackID.allCases {
            let instant = peakBoxes[track]?.read() ?? (0, 0)
            var ballistic = meterBallistics[track] ?? MeterBallistic()
            ballistic.advance(left: instant.0, right: instant.1, now: now)
            meterBallistics[track] = ballistic
            next[track] = ballistic.reading
        }
        meters = next
    }

    private func clearMeters() {
        for box in peakBoxes.values {
            box.reset()
        }
        meterBallistics.removeAll()
        meters = Self.silentMeters
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

/// Latest buffer peak. The audio thread writes it; the meter timer reads it.
private final class TrackPeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Float = 0
    private var right: Float = 0

    func store(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let count = Int(buffer.format.channelCount)
        var peakL: Float = 0
        var peakR: Float = 0
        if count >= 1 {
            for index in 0..<frames {
                peakL = max(peakL, abs(channels[0][index]))
            }
        }
        if count >= 2 {
            for index in 0..<frames {
                peakR = max(peakR, abs(channels[1][index]))
            }
        } else {
            peakR = peakL
        }
        lock.lock()
        left = peakL
        right = peakR
        lock.unlock()
    }

    func read() -> (Float, Float) {
        lock.lock()
        let value = (left, right)
        lock.unlock()
        return value
    }

    func reset() {
        lock.lock()
        left = 0
        right = 0
        lock.unlock()
    }
}

private struct MeterBallistic {
    var left: Float = 0
    var right: Float = 0
    var holdLeft: Float = 0
    var holdRight: Float = 0
    var holdLeftUntil = Date.distantPast
    var holdRightUntil = Date.distantPast

    var reading: TrimmerMeterReading {
        TrimmerMeterReading(left: left, right: right, holdLeft: holdLeft, holdRight: holdRight)
    }

    mutating func advance(left instantL: Float, right instantR: Float, now: Date) {
        left = instantL >= left ? instantL : left * 0.78
        right = instantR >= right ? instantR : right * 0.78
        if instantL >= holdLeft {
            holdLeft = instantL
            holdLeftUntil = now.addingTimeInterval(0.85)
        } else if now > holdLeftUntil {
            holdLeft *= 0.86
        }
        if instantR >= holdRight {
            holdRight = instantR
            holdRightUntil = now.addingTimeInterval(0.85)
        } else if now > holdRightUntil {
            holdRight *= 0.86
        }
    }
}
