import AVFoundation
import Foundation

final class MixerEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var voiceBuffers: [[Float]] = []
    private var speakerNumbers: [Int] = []
    /// Per-voice bounce stem base names (user-facing channel names, sanitized at write).
    private var stemNames: [String] = []
    private var musicBuffer: [Float] = []
    private var musicChannels: Int = 2
    private var hasMusicTrack = false

    private(set) var sampleRate: Double = 44100
    private(set) var frameCount: Int = 0
    private(set) var voiceCount: Int = 0

    private var playhead: Int = 0
    private var playing = false

    private var processors: [ChannelProcessor] = []
    private var musicProcessor = ChannelProcessor(isStereo: true, hasVoiceFX: false)
    private var autoBalancer = AutoBalancer()
    private var masterComp = MasterCompressorDSP()
    private var masterGain: Float = 1
    private var rta = RTAAnalyzer()
    private var rtaIsMusic = false
    private var rtaIsMaster = false
    private var rtaVoiceIndex = 0

    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    /// pre, post, masterL, masterR, autoGainDb, rtaBins, compInL, compInR, compOutL, compOutR, compGRDb
    var onMeters: (([Float], [Float], Float, Float, [Float], [Float], Float, Float, Float, Float, Float) -> Void)?
    var onPlayhead: ((Int) -> Void)?
    var onPlaybackEnded: (() -> Void)?

    private var meterPre: [Float] = []
    private var meterPost: [Float] = []
    private var meterMasterL: Float = 0
    private var meterMasterR: Float = 0
    private var meterCounter: Int = 0
    private var playheadEmitCounter: Int = 0
    private var lastAutoGainDb: [Float] = []
    private var lastRTABins: [Float] = Array(repeating: 0, count: RTAAnalyzer.displayBins)
    /// Separate from the audio lock so channel-select waveform swaps never stall the render thread.
    private let waveformLock = NSLock()
    private var cachedVoicePeaks: [[Float]] = []
    private var cachedMusicPeaks: [Float] = []
    private var cachedMasterPeaks: [Float] = []
    private let waveformBinCount = 2048

    private var meterSlotCount: Int { voiceCount + 1 } // last slot always music

    func setRTASource(isMusic: Bool, voiceIndex: Int, isMaster: Bool = false) {
        lock.lock()
        if rtaIsMusic != isMusic || rtaVoiceIndex != voiceIndex || rtaIsMaster != isMaster {
            rta.reset()
            lastRTABins = Array(repeating: 0, count: RTAAnalyzer.displayBins)
        }
        rtaIsMusic = isMusic
        rtaIsMaster = isMaster
        rtaVoiceIndex = max(0, voiceIndex)
        lock.unlock()
    }

    /// Peak envelope for UI waveform (0…1). Precomputed at load so channel select never stalls audio.
    func waveformPeaks(channelIndex: Int?, music: Bool, masterMix: Bool = false, binCount: Int = 800) -> [Float] {
        _ = binCount
        waveformLock.lock()
        defer { waveformLock.unlock() }
        if masterMix { return cachedMasterPeaks }
        if music { return cachedMusicPeaks }
        guard let channelIndex, cachedVoicePeaks.indices.contains(channelIndex) else {
            return []
        }
        return cachedVoicePeaks[channelIndex]
    }

    func currentFrame() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return playhead
    }

    func seek(toFrame frame: Int) {
        lock.lock()
        playhead = max(0, min(frameCount, frame))
        for i in processors.indices {
            processors[i].reset()
            processors[i].configure(sampleRate: sampleRate)
        }
        musicProcessor.reset()
        musicProcessor.configure(sampleRate: sampleRate)
        autoBalancer.resize(to: voiceCount)
        autoBalancer.reset()
        masterComp.reset()
        let head = playhead
        lock.unlock()
        onPlayhead?(head)
    }

    /// Downsample interleaved samples to a normalized peak envelope. No full-length copies.
    private func downsampleAbs(_ samples: [Float], binCount: Int, frameCount: Int, channelCount: Int) -> [Float] {
        let frames = max(0, frameCount)
        guard frames > 0, !samples.isEmpty else { return Array(repeating: 0, count: binCount) }
        let ch = max(1, channelCount)
        var out = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            let start = i * frames / binCount
            let end = max(start + 1, (i + 1) * frames / binCount)
            var peak: Float = 0
            for f in start..<min(end, frames) {
                if ch <= 1 {
                    if f < samples.count { peak = max(peak, abs(samples[f])) }
                } else {
                    let base = f * ch
                    if base + 1 < samples.count {
                        peak = max(peak, abs(samples[base]), abs(samples[base + 1]))
                    } else if base < samples.count {
                        peak = max(peak, abs(samples[base]))
                    }
                }
            }
            out[i] = peak
        }
        let maxPeak = out.max() ?? 1
        if maxPeak > 1e-6 {
            for i in 0..<binCount { out[i] /= maxPeak }
        }
        return out
    }

    func load(voiceURLs: [URL?], speakerNumbers: [Int], musicURL: URL?, sampleRateHint: Double?) throws {
        stop()
        lock.lock()
        defer { lock.unlock() }

        var rate: Double?
        var frames = 0
        voiceBuffers = []
        self.speakerNumbers = []
        self.stemNames = []
        voiceBuffers.reserveCapacity(voiceURLs.count)

        for (i, url) in voiceURLs.enumerated() {
            guard let url else { continue }
            let buf = try WAVIO.load(url: url)
            if let r = rate, abs(r - buf.sampleRate) > 0.5 {
                throw MixerError.loadFailed("Sample rate mismatch in \(url.lastPathComponent)")
            }
            rate = buf.sampleRate
            var mono: [Float] = []
            mono.reserveCapacity(buf.frameCount)
            let ch = buf.channelCount
            for f in 0..<buf.frameCount {
                var sum: Float = 0
                for c in 0..<ch {
                    sum += buf.samples[f * ch + c]
                }
                mono.append(sum / Float(ch))
            }
            voiceBuffers.append(mono)
            let num = speakerNumbers.indices.contains(i) ? speakerNumbers[i] : (i + 1)
            self.speakerNumbers.append(num)
            self.stemNames.append("Speaker_\(num)")
            frames = max(frames, mono.count)
        }

        musicBuffer = []
        musicChannels = 2
        hasMusicTrack = false
        if let musicURL {
            let buf = try WAVIO.load(url: musicURL)
            if let r = rate, abs(r - buf.sampleRate) > 0.5 {
                throw MixerError.loadFailed("Sample rate mismatch in music track")
            }
            rate = buf.sampleRate
            if buf.channelCount == 1 {
                var stereo: [Float] = []
                stereo.reserveCapacity(buf.frameCount * 2)
                for s in buf.samples {
                    stereo.append(s)
                    stereo.append(s)
                }
                musicBuffer = stereo
                musicChannels = 2
            } else {
                musicBuffer = buf.samples
                musicChannels = buf.channelCount
            }
            frames = max(frames, buf.frameCount)
            hasMusicTrack = true
        }

        voiceCount = voiceBuffers.count
        sampleRate = rate ?? sampleRateHint ?? 44100
        frameCount = frames
        playhead = 0

        processors = (0..<voiceCount).map { _ in ChannelProcessor(isStereo: false, hasVoiceFX: true) }
        musicProcessor = ChannelProcessor(isStereo: true, hasVoiceFX: false)
        for i in processors.indices {
            processors[i].configure(sampleRate: sampleRate)
            processors[i].reset()
        }
        musicProcessor.configure(sampleRate: sampleRate)
        musicProcessor.reset()

        meterPre = Array(repeating: 0, count: meterSlotCount)
        meterPost = Array(repeating: 0, count: meterSlotCount)
        autoBalancer.resize(to: voiceCount)
        autoBalancer.reset()
        masterComp.reset()
        rebuildWaveformCache()
    }

    private func rebuildWaveformCache() {
        let bins = waveformBinCount
        let voicePeaks = voiceBuffers.map { downsampleAbs($0, binCount: bins, frameCount: $0.count, channelCount: 1) }
        let musicPeaks: [Float]
        if !musicBuffer.isEmpty {
            let frames = musicBuffer.count / max(1, musicChannels)
            musicPeaks = downsampleAbs(musicBuffer, binCount: bins, frameCount: frames, channelCount: musicChannels)
        } else {
            musicPeaks = []
        }

        var master = [Float](repeating: 0, count: bins)
        let total = max(1, frameCount)
        let ch = max(1, musicChannels)
        for i in 0..<bins {
            let start = i * total / bins
            let end = max(start + 1, (i + 1) * total / bins)
            var peak: Float = 0
            for f in start..<min(end, total) {
                for buf in voiceBuffers {
                    if f < buf.count { peak = max(peak, abs(buf[f])) }
                }
                if !musicBuffer.isEmpty {
                    let base = f * ch
                    if ch >= 2, base + 1 < musicBuffer.count {
                        peak = max(peak, abs(musicBuffer[base]), abs(musicBuffer[base + 1]))
                    } else if base < musicBuffer.count {
                        peak = max(peak, abs(musicBuffer[base]))
                    }
                }
            }
            master[i] = peak
        }
        let maxPeak = master.max() ?? 1
        if maxPeak > 1e-6 {
            for i in 0..<bins { master[i] /= maxPeak }
        }

        waveformLock.lock()
        cachedVoicePeaks = voicePeaks
        cachedMusicPeaks = musicPeaks
        cachedMasterPeaks = master
        waveformLock.unlock()
    }

    func updateParams(
        voices: [ChannelStripState],
        music: ChannelStripState,
        masterDb: Float,
        autoBalanceEnabled: Bool,
        autoBalanceTargetDb: Float,
        masterComp state: MasterCompressorState
    ) {
        lock.lock()
        defer { lock.unlock() }
        masterGain = pow(10.0, masterDb / 20.0)
        autoBalancer.enabled = autoBalanceEnabled
        autoBalancer.targetDb = autoBalanceTargetDb
        autoBalancer.resize(to: voices.count)
        masterComp.bypass = state.bypass
        masterComp.thresholdDb = state.thresholdDb
        masterComp.attackMs = state.attackMs
        masterComp.ratio = state.ratio
        masterComp.releaseSec = state.releaseSec
        masterComp.knee = state.knee
        masterComp.outputDb = state.outputDb
        masterComp.autoMakeup = state.autoMakeup
        while processors.count < voices.count {
            var p = ChannelProcessor(isStereo: false, hasVoiceFX: true)
            p.configure(sampleRate: sampleRate)
            processors.append(p)
        }
        if processors.count > voices.count {
            processors = Array(processors.prefix(voices.count))
        }
        for i in 0..<voices.count {
            processors[i].mute = voices[i].mute
            // While auto is on, channel fader becomes the relative bias trim
            processors[i].faderDb = autoBalanceEnabled ? voices[i].autoBiasDb : voices[i].faderDb
            processors[i].pan = voices[i].pan
            processors[i].dspBypass = voices[i].dspBypass
            processors[i].eqGains = voices[i].eq.gains
            processors[i].eqBypass = voices[i].eq.bypass
            processors[i].paraFreqHz = voices[i].para.freqHz
            processors[i].paraGainDb = voices[i].para.gainDb
            processors[i].paraWidth = voices[i].para.width
            processors[i].paraBypass = voices[i].para.bypass
            processors[i].deVerbAmount = voices[i].voice.deVerb
            processors[i].deVerbBypass = voices[i].voice.deVerbBypass
            processors[i].wetterAmount = voices[i].voice.wetter
            processors[i].wetterBypass = voices[i].voice.wetterBypass
            processors[i].wetterRoom = voices[i].voice.wetterRoom
            processors[i].levelerDrive = voices[i].voice.levelerDrive
            processors[i].levelerBypass = voices[i].voice.levelerBypass
            processors[i].levelerTargetDb = voices[i].voice.levelerTargetDb
            processors[i].dspOrder = voices[i].dspOrder
            processors[i].configure(sampleRate: sampleRate)
        }
        musicProcessor.mute = music.mute || !hasMusicTrack
        musicProcessor.faderDb = music.faderDb
        musicProcessor.pan = music.pan
        musicProcessor.dspBypass = false
        musicProcessor.eqGains = music.eq.gains
        musicProcessor.eqBypass = music.eq.bypass
        musicProcessor.dspOrder = music.dspOrder.isEmpty ? ChannelDSPSlot.musicDefault : music.dspOrder
        musicProcessor.configure(sampleRate: sampleRate)
        stemNames = voices.map(\.bounceStemBaseName)
    }

    func start(fromBeginning: Bool = false) throws {
        lock.lock()
        guard frameCount > 0 else {
            lock.unlock()
            throw MixerError.engine("Load tracks first.")
        }
        if fromBeginning {
            playhead = 0
        }
        if playhead >= frameCount {
            playhead = 0
        }
        for i in processors.indices {
            processors[i].reset()
            processors[i].configure(sampleRate: sampleRate)
        }
        musicProcessor.reset()
        musicProcessor.configure(sampleRate: sampleRate)
        autoBalancer.resize(to: voiceCount)
        autoBalancer.reset()
        masterComp.reset()
        lock.unlock()

        if audioEngine != nil {
            stopKeepingPlayhead()
        }

        let engine = AVAudioEngine()
        let sr = sampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false) else {
            throw MixerError.engine("Could not create audio format.")
        }

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let lPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rPtr = abl[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }

            self.lock.lock()
            var head = self.playhead
            let slots = max(1, self.meterSlotCount)
            var pre = Array(repeating: Float(0), count: slots)
            var post = Array(repeating: Float(0), count: slots)
            var mL: Float = 0
            var mR: Float = 0
            let voices = self.voiceBuffers
            let music = self.musicBuffer
            let musicCh = self.musicChannels
            let total = self.frameCount
            let master = self.masterGain
            let voiceN = self.voiceCount
            let musicMeterIdx = voiceN
            let n = Int(frameCount)

            for i in 0..<n {
                var mixL: Float = 0
                var mixR: Float = 0
                if head < total {
                    var fxSamples = [Float](repeating: 0, count: voiceN)
                    var levels = [Float](repeating: 0, count: voiceN)
                    var muted = [Bool](repeating: false, count: voiceN)
                    for c in 0..<voiceN {
                        let sample: Float = (c < voices.count && head < voices[c].count) ? voices[c][head] : 0
                        if self.processors.indices.contains(c) {
                            muted[c] = self.processors[c].mute
                            let fx = self.processors[c].processEffects(sample)
                            fxSamples[c] = fx
                            levels[c] = abs(fx)
                        }
                    }
                    let autoGains = self.autoBalancer.process(
                        levels: levels,
                        muted: muted,
                        sampleRate: self.sampleRate
                    )
                    self.lastAutoGainDb = autoGains.map { g in
                        20 * log10(max(g, 1e-6))
                    }
                    for c in 0..<voiceN {
                        let sample: Float = (c < voices.count && head < voices[c].count) ? voices[c][head] : 0
                        if self.processors.indices.contains(c) {
                            let g = autoGains.indices.contains(c) ? autoGains[c] : 1
                            let (l, r) = self.processors[c].finishMono(
                                fxSamples[c],
                                autoMixGain: g,
                                inputPeak: sample,
                                prePeak: &pre[c],
                                postPeak: &post[c]
                            )
                            mixL += l
                            mixR += r
                            if !self.rtaIsMusic, !self.rtaIsMaster, c == self.rtaVoiceIndex {
                                self.rta.push(fxSamples[c] * g)
                            }
                        }
                    }
                    let ml: Float
                    let mr: Float
                    if musicCh >= 2, head * 2 + 1 < music.count {
                        ml = music[head * 2]
                        mr = music[head * 2 + 1]
                    } else if head < music.count {
                        ml = music[head]
                        mr = music[head]
                    } else {
                        ml = 0
                        mr = 0
                    }
                    let (ol, orr) = self.musicProcessor.processStereo(ml, mr, prePeak: &pre[musicMeterIdx], postPeak: &post[musicMeterIdx])
                    mixL += ol
                    mixR += orr
                    if self.rtaIsMusic && !self.rtaIsMaster {
                        self.rta.push(0.5 * (ol + orr))
                    }
                    head += 1
                }
                // Master bus compressor → output fader
                let (cL, cR) = self.masterComp.process(left: mixL, right: mixR, sampleRate: self.sampleRate)
                mixL = cL * master
                mixR = cR * master
                if self.rtaIsMaster {
                    self.rta.push(0.5 * (mixL + mixR))
                }
                mixL = tanhf(mixL)
                mixR = tanhf(mixR)
                lPtr[i] = mixL
                rPtr[i] = mixR
                mL = max(mL, abs(mixL))
                mR = max(mR, abs(mixR))
            }

            self.playhead = head
            if self.meterPre.count != slots {
                self.meterPre = Array(repeating: 0, count: slots)
                self.meterPost = Array(repeating: 0, count: slots)
            }
            for i in 0..<slots {
                self.meterPre[i] = max(self.meterPre[i] * 0.6, pre[i])
                self.meterPost[i] = max(self.meterPost[i] * 0.6, post[i])
            }
            self.meterMasterL = max(self.meterMasterL * 0.6, mL)
            self.meterMasterR = max(self.meterMasterR * 0.6, mR)
            self.meterCounter += n
            self.playheadEmitCounter += n
            let shouldEmit = self.meterCounter >= Int(self.sampleRate / 20)
            let shouldEmitHead = self.playheadEmitCounter >= Int(self.sampleRate / 30)
            if shouldEmit {
                self.lastRTABins = self.rta.computeBins(sampleRate: self.sampleRate)
            }
            let emitPre = self.meterPre
            let emitPost = self.meterPost
            let emitL = self.meterMasterL
            let emitR = self.meterMasterR
            let emitAuto = self.lastAutoGainDb
            let emitRTA = self.lastRTABins
            let emitCompInL = self.masterComp.meterInL
            let emitCompInR = self.masterComp.meterInR
            let emitCompOutL = self.masterComp.meterOutL
            let emitCompOutR = self.masterComp.meterOutR
            let emitCompGR = self.masterComp.meterGRDb
            let emitHead = head
            if shouldEmit {
                self.meterCounter = 0
                self.meterPre = Array(repeating: 0, count: slots)
                self.meterPost = Array(repeating: 0, count: slots)
                self.meterMasterL = 0
                self.meterMasterR = 0
            }
            if shouldEmitHead {
                self.playheadEmitCounter = 0
            }
            let ended = head >= total
            self.lock.unlock()

            if shouldEmit {
                self.onMeters?(
                    emitPre, emitPost, emitL, emitR, emitAuto, emitRTA,
                    emitCompInL, emitCompInR, emitCompOutL, emitCompOutR, emitCompGR
                )
            }
            if shouldEmitHead {
                self.onPlayhead?(emitHead)
            }
            if ended {
                DispatchQueue.main.async {
                    self.stop()
                    self.onPlaybackEnded?()
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
        playing = true
    }

    func stop() {
        stopKeepingPlayhead()
    }

    private func stopKeepingPlayhead() {
        lock.lock()
        playing = false
        lock.unlock()
        audioEngine?.stop()
        if let node = sourceNode {
            audioEngine?.detach(node)
        }
        sourceNode = nil
        audioEngine = nil
    }

    struct BounceResult {
        var folder: URL
        var stemCount: Int
    }

    func bounce(to folder: URL) throws -> BounceResult {
        lock.lock()
        let total = frameCount
        let sr = sampleRate
        let voices = voiceBuffers
        let nums = speakerNumbers
        let names = stemNames
        let music = musicBuffer
        let musicCh = musicChannels
        var procs = processors
        var musicProc = musicProcessor
        var balancer = autoBalancer
        var busComp = masterComp
        let master = masterGain
        let voiceN = voiceCount
        lock.unlock()

        guard total > 0 else { throw MixerError.engine("Nothing to bounce.") }

        for i in procs.indices {
            procs[i].reset()
            procs[i].configure(sampleRate: sr)
        }
        musicProc.reset()
        musicProc.configure(sampleRate: sr)
        balancer.resize(to: voiceN)
        balancer.reset()
        busComp.reset()

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var stemBuffers: [[Float]] = Array(repeating: [], count: voiceN + 1)
        for i in 0..<(voiceN + 1) { stemBuffers[i].reserveCapacity(total * 2) }
        var mixL = [Float](repeating: 0, count: total)
        var mixR = [Float](repeating: 0, count: total)

        for head in 0..<total {
            var busL: Float = 0
            var busR: Float = 0
            var pre: Float = 0
            var post: Float = 0

            var fxSamples = [Float](repeating: 0, count: voiceN)
            var levels = [Float](repeating: 0, count: voiceN)
            var muted = [Bool](repeating: false, count: voiceN)
            for c in 0..<voiceN {
                let sample: Float = (c < voices.count && head < voices[c].count) ? voices[c][head] : 0
                muted[c] = procs[c].mute
                let fx = procs[c].processEffects(sample)
                fxSamples[c] = fx
                levels[c] = abs(fx)
            }
            let autoGains = balancer.process(levels: levels, muted: muted, sampleRate: sr)
            for c in 0..<voiceN {
                let sample: Float = (c < voices.count && head < voices[c].count) ? voices[c][head] : 0
                pre = 0; post = 0
                let g = autoGains.indices.contains(c) ? autoGains[c] : 1
                let (l, r) = procs[c].finishMono(
                    fxSamples[c],
                    autoMixGain: g,
                    inputPeak: sample,
                    prePeak: &pre,
                    postPeak: &post
                )
                stemBuffers[c].append(l)
                stemBuffers[c].append(r)
                busL += l
                busR += r
            }
            let ml: Float
            let mr: Float
            if musicCh >= 2, head * 2 + 1 < music.count {
                ml = music[head * 2]
                mr = music[head * 2 + 1]
            } else if head < music.count {
                ml = music[head]
                mr = music[head]
            } else {
                ml = 0
                mr = 0
            }
            pre = 0; post = 0
            let (ol, orr) = musicProc.processStereo(ml, mr, prePeak: &pre, postPeak: &post)
            stemBuffers[voiceN].append(ol)
            stemBuffers[voiceN].append(orr)
            busL += ol
            busR += orr
            let (cL, cR) = busComp.process(left: busL, right: busR, sampleRate: sr)
            busL = tanhf(cL * master)
            busR = tanhf(cR * master)
            mixL[head] = busL
            mixR[head] = busR
        }

        var stemCount = 0
        var usedNames = Set<String>()
        for c in 0..<voiceN {
            let has = c < voices.count && !voices[c].isEmpty
            if has {
                let num = nums.indices.contains(c) ? nums[c] : (c + 1)
                var base = names.indices.contains(c) ? names[c] : "Speaker_\(num)"
                if base.isEmpty { base = "Speaker_\(num)" }
                var unique = base
                var suffix = 2
                while usedNames.contains(unique.lowercased()) {
                    unique = "\(base)_\(suffix)"
                    suffix += 1
                }
                usedNames.insert(unique.lowercased())
                let url = folder.appendingPathComponent("\(unique)_fixed.wav")
                try WAVIO.write(url: url, buffer: .init(sampleRate: sr, channelCount: 2, samples: stemBuffers[c]))
                stemCount += 1
            }
        }
        if !music.isEmpty {
            let url = folder.appendingPathComponent("Music_and_SFX_fixed.wav")
            try WAVIO.write(url: url, buffer: .init(sampleRate: sr, channelCount: 2, samples: stemBuffers[voiceN]))
            stemCount += 1
        }
        var mixInterleaved: [Float] = []
        mixInterleaved.reserveCapacity(total * 2)
        for i in 0..<total {
            mixInterleaved.append(mixL[i])
            mixInterleaved.append(mixR[i])
        }
        try WAVIO.write(
            url: folder.appendingPathComponent("mix.wav"),
            buffer: .init(sampleRate: sr, channelCount: 2, samples: mixInterleaved)
        )
        return BounceResult(folder: folder, stemCount: stemCount)
    }
}
