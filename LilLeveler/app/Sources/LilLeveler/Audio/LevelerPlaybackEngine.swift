import AVFoundation
import Foundation

/// Real-time PRE/POST playback via `AVAudioSourceNode`.
///
/// The previous `AVAudioPlayerNode` path created an *interleaved* float format, then
/// wrote samples as if the buffer were non-interleaved (`dst[channel][frame]`).
/// For interleaved float, `floatChannelData` is typically nil, so nothing was copied
/// and Play was silent.
final class LevelerPlaybackEngine {
    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    private var sampleRate: Double = 44100
    private var channelCount: Int = 2
    private var pre: [Float] = []
    private var post: [Float] = []
    private var frameCount: Int = 0
    private var playhead: Int = 0
    private var playing = false
    /// When true (and POST samples exist), the callback reads the leveled buffer.
    private var playPost = false
    private var playheadEmitCounter = 0

    var onPlayhead: ((Int) -> Void)?
    var onEnded: (() -> Void)?

    func currentFrame() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return playhead
    }

    func load(pre buffer: WAVIO.Buffer, post leveled: WAVIO.Buffer?) {
        lock.lock()
        sampleRate = max(1, buffer.sampleRate)
        channelCount = max(1, buffer.channelCount)
        pre = buffer.samples
        post = leveled?.samples ?? []
        frameCount = buffer.frameCount
        playhead = 0
        playPost = false
        lock.unlock()
    }

    func setPost(_ leveled: WAVIO.Buffer?) {
        lock.lock()
        post = leveled?.samples ?? []
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
            let usePost = self.playPost && !self.post.isEmpty
            let samples = usePost ? self.post : self.pre
            let ch = max(1, self.channelCount)
            let total = self.frameCount
            let srLocal = self.sampleRate
            self.lock.unlock()

            if !isPlaying {
                for i in 0..<n {
                    lPtr[i] = 0
                    rPtr[i] = 0
                }
                return noErr
            }

            for i in 0..<n {
                if head < total {
                    let (l, r) = Self.stereoFrame(samples: samples, channels: ch, frame: head)
                    lPtr[i] = l
                    rPtr[i] = r
                    head += 1
                } else {
                    lPtr[i] = 0
                    rPtr[i] = 0
                }
            }

            self.lock.lock()
            self.playhead = head
            self.playheadEmitCounter += n
            let shouldEmit = self.playheadEmitCounter >= Int(srLocal / 30)
            if shouldEmit {
                self.playheadEmitCounter = 0
            }
            let ended = head >= total
            if ended {
                self.playing = false
                self.playhead = 0
            }
            let emitHead = ended ? 0 : head
            self.lock.unlock()

            if shouldEmit || ended {
                DispatchQueue.main.async { [weak self] in
                    self?.onPlayhead?(emitHead)
                }
            }
            if ended {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
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

    /// Read one stereo pair from interleaved PCM (mono is doubled to L/R).
    static func stereoFrame(samples: [Float], channels: Int, frame: Int) -> (Float, Float) {
        let ch = max(1, channels)
        let base = frame * ch
        guard base < samples.count else { return (0, 0) }
        let left = samples[base]
        let right = ch >= 2 && base + 1 < samples.count ? samples[base + 1] : left
        return (left, right)
    }
}
