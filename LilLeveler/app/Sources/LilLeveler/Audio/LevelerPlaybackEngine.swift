import AVFoundation
import Foundation

/// Real-time PRE/POST playback via `AVAudioSourceNode`.
///
/// MUSIC LOUD runs a live lookahead maximizer on the source so THRESHOLD
/// changes are audible while dragging. Podcast presets still play a baked POST.
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
    /// When true, the callback reads POST (live maximizer or baked leveled file).
    private var playPost = false
    private var playheadEmitCounter = 0
    private var meterEmitCounter = 0
    private var preBall = MeterBallistics()
    private var postBall = MeterBallistics()

    var onPlayhead: ((Int) -> Void)?
    var onEnded: (() -> Void)?
    var onMeters: ((LiveMeterSample, LiveMeterSample) -> Void)?
    var onGainReduction: ((Float) -> Void)?

    private var makeupLin: Float = 1
    private var liveMaximizer = false
    private var limiter = LiveLookaheadLimiter()

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
        limiter.configure(sampleRate: sampleRate, ceilingDb: -0.1)
        liveMaximizer = false
        lock.unlock()
    }

    func setPost(_ leveled: PCMStore?) {
        lock.lock()
        post = leveled
        if !liveMaximizer {
            postBall.reset()
        }
        lock.unlock()
    }

    /// Enable the live MUSIC LOUD maximizer and/or update makeup (ceiling − threshold).
    func setLiveMaximizer(enabled: Bool, makeupDb: Float) {
        lock.lock()
        let was = liveMaximizer
        liveMaximizer = enabled
        makeupLin = pow(10.0, makeupDb / 20.0)
        limiter.makeupLin = makeupLin
        if enabled {
            if !limiter.isConfigured {
                limiter.configure(sampleRate: sampleRate, ceilingDb: -0.1)
            }
            limiter.makeupLin = makeupLin
            if !was {
                warmLimiterLocked()
            }
        } else if was {
            limiter.reset()
        }
        lock.unlock()
    }

    func setMaximizerMakeup(db: Float, enabled: Bool) {
        setLiveMaximizer(enabled: enabled, makeupDb: db)
    }

    func setPlayPost(_ value: Bool) {
        lock.lock()
        playPost = value
        lock.unlock()
    }

    func seek(frame: Int) {
        lock.lock()
        playhead = max(0, min(frameCount, frame))
        if liveMaximizer {
            warmLimiterLocked()
        }
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
        if liveMaximizer {
            warmLimiterLocked()
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
        if liveMaximizer {
            warmLimiterLocked()
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

    /// Prefill the lookahead delay from audio before the playhead so seeks don’t click.
    private func warmLimiterLocked() {
        limiter.reset()
        limiter.makeupLin = makeupLin
        guard liveMaximizer, let pre else { return }
        let look = limiter.look
        let head = playhead
        let from = max(0, head - look)
        if from >= head { return }
        for i in from..<head {
            let pair = pre.stereoFrame(at: i)
            _ = limiter.process(left: pair.0, right: pair.1)
        }
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
            let live = self.liveMaximizer
            let useLivePost = self.playPost && live
            let useBakedPost = self.playPost && !live && postStore != nil
            let hasBakedPost = postStore != nil
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
                    let prePair = preStore?.stereoFrame(at: head) ?? (0, 0)
                    var outL = prePair.0
                    var outR = prePair.1
                    var postL = outL
                    var postR = outR

                    if live {
                        let limited = self.limiter.process(left: prePair.0, right: prePair.1)
                        postL = limited.0
                        postR = limited.1
                        if useLivePost {
                            outL = limited.0
                            outR = limited.1
                        }
                        self.postBall.process(left: postL, right: postR, sampleRate: srLocal)
                    } else if useBakedPost {
                        let postPair = postStore?.stereoFrame(at: head) ?? (0, 0)
                        outL = postPair.0
                        outR = postPair.1
                        postL = postPair.0
                        postR = postPair.1
                        self.postBall.process(left: postL, right: postR, sampleRate: srLocal)
                    } else if hasBakedPost {
                        let postPair = postStore?.stereoFrame(at: head) ?? (0, 0)
                        self.postBall.process(left: postPair.0, right: postPair.1, sampleRate: srLocal)
                    }

                    lPtr[i] = outL
                    rPtr[i] = outR
                    self.preBall.process(left: prePair.0, right: prePair.1, sampleRate: srLocal)
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
                if live {
                    self.warmLimiterLocked()
                }
            }
            let emitHead = ended ? 0 : head
            let emitPre = self.preBall.snapshot
            let emitPost = (live || hasBakedPost) ? self.postBall.snapshot : LiveMeterSample.silent
            let emitGR = live ? self.limiter.lastGRDb : 0
            self.lock.unlock()

            if shouldEmitHead || ended {
                self.onPlayhead?(emitHead)
            }
            if shouldEmitMeters || ended {
                self.onMeters?(emitPre, emitPost)
                self.onGainReduction?(emitGR)
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
