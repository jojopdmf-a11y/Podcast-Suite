import AVFoundation
import Foundation

/// Real-time PRE/POST playback via `AVAudioSourceNode`.
///
/// The previous `AVAudioPlayerNode` path created an *interleaved* float format, then
/// wrote samples as if the buffer were non-interleaved (`dst[channel][frame]`).
/// For interleaved float, `floatChannelData` is typically nil, so nothing was copied
/// and Play was silent.
final class LevelerPlaybackEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    private var sampleRate: Double = 44100
    private var pre: PCMStore?
    private var post: PCMStore?
    private var frameCount: Int = 0
    private var playhead: Int = 0
    private var playing = false
    /// When true (and POST samples exist), the callback reads the leveled buffer.
    private var playPost = false
    private var playheadEmitCounter = 0
    private var meterEmitCounter = 0
    private var preBall = MeterBallistics()
    private var postBall = MeterBallistics()

    var onPlayhead: ((Int) -> Void)?
    var onEnded: (() -> Void)?
    var onMeters: ((LiveMeterSample, LiveMeterSample) -> Void)?

    func currentFrame() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return playhead
    }

    func load(pre buffer: PCMStore?, post leveled: PCMStore?) {
        lock.lock()
        sampleRate = max(1, buffer?.sampleRate ?? 44100)
        pre = buffer
        post = leveled
        frameCount = buffer?.frameCount ?? 0
        playhead = 0
        playPost = false
        preBall.reset()
        postBall.reset()
        lock.unlock()
    }

    func setPost(_ leveled: PCMStore?) {
        lock.lock()
        post = leveled
        postBall.reset()
        lock.unlock()
    }

    func setPlayPost(_ value: Bool) {
        lock.lock()
        playPost = value
        lock.unlock()
    }

    func seek(frame: Int) {
        lock.lock()
        playhead = max(0, min(frameCount, frame))
        lock.unlock()
    }

    func start() throws {
        lock.lock()
        guard frameCount > 0 else {
            lock.unlock()
            throw LevelerError.processFailed("Load a file first.")
        }
        if playhead >= frameCount {
            playhead = 0
        }
        let sr = sampleRate
        playing = true
        lock.unlock()

        if audioEngine != nil {
            return
        }
        do {
            try buildEngine(sampleRate: sr)
        } catch {
            lock.lock()
            playing = false
            lock.unlock()
            throw error
        }
    }

    func pause() {
        lock.lock()
        playing = false
        lock.unlock()
        tearDownEngine()
    }

    func stop(resetPlayhead: Bool) {
        pause()
        lock.lock()
        if resetPlayhead {
            playhead = 0
        }
        lock.unlock()
        tearDownEngine()
    }

    private func tearDownEngine() {
        audioEngine?.stop()
        if let node = sourceNode {
            audioEngine?.detach(node)
        }
        sourceNode = nil
        audioEngine = nil
    }

    private func buildEngine(sampleRate sr: Double) throws {
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sr,
            channels: 2,
            interleaved: false
        ) else {
            throw LevelerError.processFailed("Could not create playback format.")
        }

        let node = AVAudioSourceNode { [weak self] _, _, requestedFrames, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let lPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rPtr = abl[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }

            let n = Int(requestedFrames)

            self.lock.lock()
            let isPlaying = self.playing
            var head = self.playhead
            let preStore = self.pre
            let postStore = self.post
            let usePost = self.playPost && postStore != nil
            let playStore = usePost ? postStore : preStore
            let hasPost = postStore != nil
            let total = self.frameCount
            let srLocal = self.sampleRate

            if !isPlaying {
                self.lock.unlock()
                for i in 0..<n {
                    lPtr[i] = 0
                    rPtr[i] = 0
                }
                return noErr
            }

            for i in 0..<n {
                if head < total {
                    let (l, r) = playStore?.stereoFrame(at: head) ?? (0, 0)
                    lPtr[i] = l
                    rPtr[i] = r
                    let prePair = preStore?.stereoFrame(at: head) ?? (0, 0)
                    self.preBall.process(left: prePair.0, right: prePair.1, sampleRate: srLocal)
                    if hasPost {
                        let postPair = postStore?.stereoFrame(at: head) ?? (0, 0)
                        self.postBall.process(left: postPair.0, right: postPair.1, sampleRate: srLocal)
                    }
                    head += 1
                } else {
                    lPtr[i] = 0
                    rPtr[i] = 0
                }
            }

            self.playhead = head
            self.playheadEmitCounter += n
            self.meterEmitCounter += n
            let shouldEmitHead = self.playheadEmitCounter >= Int(srLocal / 30)
            let shouldEmitMeters = self.meterEmitCounter >= Int(srLocal / 24)
            if shouldEmitHead {
                self.playheadEmitCounter = 0
            }
            if shouldEmitMeters {
                self.meterEmitCounter = 0
            }
            let ended = head >= total
            if ended {
                self.playing = false
                self.playhead = 0
            }
            let emitHead = ended ? 0 : head
            let emitPre = self.preBall.snapshot
            let emitPost = hasPost ? self.postBall.snapshot : LiveMeterSample.silent
            self.lock.unlock()

            if shouldEmitHead || ended {
                self.onPlayhead?(emitHead)
            }
            if shouldEmitMeters || ended {
                self.onMeters?(emitPre, emitPost)
            }
            if ended {
                DispatchQueue.main.async {
                    self.lock.lock()
                    let stillStopped = !self.playing
                    self.lock.unlock()
                    guard stillStopped else { return }
                    self.tearDownEngine()
                    self.onEnded?()
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        try engine.start()
        audioEngine = engine
        sourceNode = node
    }

}
