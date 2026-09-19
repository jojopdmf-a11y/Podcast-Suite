import AVFoundation
import CoreAudio
import Foundation

final class MixerEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var voiceBuffers: [[Float]] = []
    private var speakerNumbers: [Int] = []
    /// Per-voice bounce stem base names (user-facing channel names, sanitized at write).
    private var stemNames: [String] = []
    private var stereoBuffers: [[Float]] = []
    private var stereoChannelCounts: [Int] = []
    private var stereoProcessors: [ChannelProcessor] = []
    private var stereoMuteSpans: [[MuteSpan]] = []
    private var cachedStereoPeaks: [[Float]] = []

    private(set) var sampleRate: Double = 44100
    private(set) var frameCount: Int = 0
    private(set) var voiceCount: Int = 0

    private var playhead: Int = 0
    private var playing = false

    private var processors: [ChannelProcessor] = []
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
    var onSessionLength: ((Int) -> Void)?

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
    private var cachedMasterPeaks: [Float] = []
    private let waveformBinCount = 2048

    private var voiceMuteSpans: [[MuteSpan]] = []
    private var recording = false
    /// Live input tap for strip meters without writing takes (Record Standby).
    private var inputMetering = false
    /// Voice index → hardware input channel (0-based). Empty = not recording that strip.
    private var recordMap: [Int: Int] = [:]
    private var inputDeviceUID: String?
    private let recLock = NSLock()
    private var recPending: [Float] = []
    private var recPendingChannels = 1
    /// Peak per voice from the input tap (armed strips). Used for PRE meters in standby/record.
    private var liveInputPeaks: [Float] = []
    private var recConverter: AVAudioConverter?
    private var recSourceFormat: AVAudioFormat?
    private var recDestFormat: AVAudioFormat?
    private var recSilentMixer: AVAudioMixerNode?
    /// True only after a record tap is on inputNode. Touching inputNode at any other time makes macOS ask for the mic.
    private var didInstallInputTap = false
    private var lengthEmitCounter = 0

    private var meterSlotCount: Int { voiceCount + stereoBuffers.count }

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
    func waveformPeaks(channelIndex: Int?, music: Bool, masterMix: Bool = false, stereoIndex: Int? = nil, binCount: Int = 800) -> [Float] {
        _ = binCount
        waveformLock.lock()
        defer { waveformLock.unlock() }
        if masterMix { return cachedMasterPeaks }
        if music {
            let idx = stereoIndex ?? 0
            guard cachedStereoPeaks.indices.contains(idx) else { return [] }
            return cachedStereoPeaks[idx]
        }
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
        for i in stereoProcessors.indices {
            stereoProcessors[i].reset()
            stereoProcessors[i].configure(sampleRate: sampleRate)
        }
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

    func load(voiceURLs: [URL?], speakerNumbers: [Int], stereoURLs: [URL], sampleRateHint: Double?) throws {
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
            let num = speakerNumbers.indices.contains(i) ? speakerNumbers[i] : (i + 1)
            self.speakerNumbers.append(num)
            self.stemNames.append("Speaker_\(num)")
            guard let url else {
                voiceBuffers.append([])
                continue
            }
            let buf = try MixerAudioIO.load(url: url, targetSampleRate: rate)
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
            frames = max(frames, mono.count)
        }

        stereoBuffers = []
        stereoChannelCounts = []
        stereoProcessors = []
        stereoMuteSpans = []
        for url in stereoURLs.prefix(StripperFolderLoader.maxStereo) {
            let buf = try MixerAudioIO.load(url: url, targetSampleRate: rate)
            if let r = rate, abs(r - buf.sampleRate) > 0.5 {
                throw MixerError.loadFailed("Sample rate mismatch in \(url.lastPathComponent)")
            }
            rate = buf.sampleRate
            let stereo = Self.interleavedStereo(buf)
            stereoBuffers.append(stereo.samples)
            stereoChannelCounts.append(stereo.channels)
            frames = max(frames, buf.frameCount)
            var proc = ChannelProcessor(isStereo: true, hasVoiceFX: false)
            proc.configure(sampleRate: rate ?? sampleRateHint ?? 44100)
            stereoProcessors.append(proc)
            stereoMuteSpans.append([])
        }

        for i in voiceBuffers.indices {
            if voiceBuffers[i].count < frames {
                voiceBuffers[i].append(contentsOf: repeatElement(Float(0), count: frames - voiceBuffers[i].count))
            }
        }
        for i in stereoBuffers.indices {
            let ch = max(1, stereoChannelCounts.indices.contains(i) ? stereoChannelCounts[i] : 2)
            let need = frames * ch
            if stereoBuffers[i].count < need {
                stereoBuffers[i].append(contentsOf: repeatElement(Float(0), count: need - stereoBuffers[i].count))
            }
        }

        voiceCount = voiceBuffers.count
        sampleRate = rate ?? sampleRateHint ?? 44100
        frameCount = frames
        playhead = 0

        processors = (0..<voiceCount).map { _ in ChannelProcessor(isStereo: false, hasVoiceFX: true) }
        for i in processors.indices {
            processors[i].configure(sampleRate: sampleRate)
            processors[i].reset()
        }
        for i in stereoProcessors.indices {
            stereoProcessors[i].configure(sampleRate: sampleRate)
            stereoProcessors[i].reset()
        }

        meterPre = Array(repeating: 0, count: meterSlotCount)
        meterPost = Array(repeating: 0, count: meterSlotCount)
        autoBalancer.resize(to: voiceCount)
        autoBalancer.reset()
        masterComp.reset()
        voiceMuteSpans = Array(repeating: [], count: voiceCount)
        rebuildWaveformCache()
    }

    private static func interleavedStereo(_ buf: WAVIO.Buffer) -> (samples: [Float], channels: Int) {
        if buf.channelCount == 1 {
            var stereo: [Float] = []
            stereo.reserveCapacity(buf.frameCount * 2)
            for s in buf.samples {
                stereo.append(s)
                stereo.append(s)
            }
            return (stereo, 2)
        }
        if buf.channelCount == 2 {
            return (buf.samples, 2)
        }
        var stereo: [Float] = []
        stereo.reserveCapacity(buf.frameCount * 2)
        let ch = buf.channelCount
        for f in 0..<buf.frameCount {
            stereo.append(buf.samples[f * ch])
            stereo.append(buf.samples[f * ch + 1])
        }
        return (stereo, 2)
    }

    func prepareBlankSession(voiceCount: Int, sampleRate: Double) {
        stop()
        lock.lock()
        defer { lock.unlock() }
        let n = max(0, min(voiceCount, StripperFolderLoader.maxSpeakers))
        if n == 0 {
            voiceBuffers = []
            speakerNumbers = []
            stemNames = []
        } else {
            voiceBuffers = Array(repeating: [], count: n)
            speakerNumbers = Array(1...n)
            stemNames = (1...n).map { "SPK \($0)" }
        }
        stereoBuffers = []
        stereoChannelCounts = []
        stereoProcessors = []
        stereoMuteSpans = []
        self.voiceCount = n
        self.sampleRate = sampleRate
        frameCount = 0
        playhead = 0
        processors = (0..<n).map { _ in ChannelProcessor(isStereo: false, hasVoiceFX: true) }
        for i in processors.indices {
            processors[i].configure(sampleRate: sampleRate)
            processors[i].reset()
        }
        meterPre = Array(repeating: 0, count: meterSlotCount)
        meterPost = Array(repeating: 0, count: meterSlotCount)
        autoBalancer.resize(to: n)
        autoBalancer.reset()
        masterComp.reset()
        voiceMuteSpans = Array(repeating: [], count: n)
        rebuildWaveformCache()
    }


    func appendSilentVoice(speakerNumber: Int) {
        lock.lock()
        defer { lock.unlock() }
        let silent = [Float](repeating: 0, count: frameCount)
        voiceBuffers.append(silent)
        speakerNumbers.append(speakerNumber)
        stemNames.append("SPK \(speakerNumber)")
        voiceCount = voiceBuffers.count
        var p = ChannelProcessor(isStereo: false, hasVoiceFX: true)
        p.configure(sampleRate: sampleRate)
        processors.append(p)
        voiceMuteSpans.append([])
        autoBalancer.resize(to: voiceCount)
        rebuildWaveformCache()
    }

    /// Empty NEW SESSION / unused ADD STRIP: take the interface clock so Record is not labeled 48 kHz.
    func adoptSampleRate(_ rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard frameCount == 0, rate > 0, abs(rate - sampleRate) > 0.5 else { return }
        applySampleRateLocked(rate)
    }

    private func applySampleRateLocked(_ rate: Double) {
        sampleRate = rate
        for i in processors.indices {
            processors[i].configure(sampleRate: rate)
            processors[i].reset()
        }
        for i in stereoProcessors.indices {
            stereoProcessors[i].configure(sampleRate: rate)
            stereoProcessors[i].reset()
        }
    }

    func voiceHasAudio(at index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard voiceBuffers.indices.contains(index) else { return false }
        return voiceBuffers[index].contains { abs($0) > 1e-4 }
    }

    func removeVoice(at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard voiceBuffers.indices.contains(index) else { return }
        voiceBuffers.remove(at: index)
        if speakerNumbers.indices.contains(index) { speakerNumbers.remove(at: index) }
        if stemNames.indices.contains(index) { stemNames.remove(at: index) }
        if processors.indices.contains(index) { processors.remove(at: index) }
        if voiceMuteSpans.indices.contains(index) { voiceMuteSpans.remove(at: index) }
        voiceCount = voiceBuffers.count
        var nextMap: [Int: Int] = [:]
        for (voiceIndex, hwCh) in recordMap where voiceIndex != index {
            nextMap[voiceIndex > index ? voiceIndex - 1 : voiceIndex] = hwCh
        }
        recordMap = nextMap
        autoBalancer.resize(to: voiceCount)
        autoBalancer.reset()
        meterPre = Array(repeating: 0, count: meterSlotCount)
        meterPost = Array(repeating: 0, count: meterSlotCount)
        rebuildWaveformCache()
    }

    func rebuildPeaks() {
        lock.lock()
        rebuildWaveformCache()
        lock.unlock()
    }

    private func rebuildWaveformCache() {
        let bins = waveformBinCount
        let voicePeaks = voiceBuffers.map { downsampleAbs($0, binCount: bins, frameCount: $0.count, channelCount: 1) }
        var stereoPeaks: [[Float]] = []
        for i in stereoBuffers.indices {
            let ch = max(1, stereoChannelCounts.indices.contains(i) ? stereoChannelCounts[i] : 2)
            let frames = stereoBuffers[i].count / ch
            stereoPeaks.append(downsampleAbs(stereoBuffers[i], binCount: bins, frameCount: frames, channelCount: ch))
        }

        var master = [Float](repeating: 0, count: bins)
        let total = max(1, frameCount)
        for i in 0..<bins {
            let start = i * total / bins
            let end = max(start + 1, (i + 1) * total / bins)
            var peak: Float = 0
            for f in start..<min(end, total) {
                for buf in voiceBuffers {
                    if f < buf.count { peak = max(peak, abs(buf[f])) }
                }
                for s in stereoBuffers.indices {
                    let ch = max(1, stereoChannelCounts.indices.contains(s) ? stereoChannelCounts[s] : 2)
                    let buf = stereoBuffers[s]
                    let base = f * ch
                    if ch >= 2, base + 1 < buf.count {
                        peak = max(peak, abs(buf[base]), abs(buf[base + 1]))
                    } else if base < buf.count {
                        peak = max(peak, abs(buf[base]))
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
        cachedStereoPeaks = stereoPeaks
        cachedMasterPeaks = master
        waveformLock.unlock()
    }

    func updateParams(
        voices: [ChannelStripState],
        stereos: [ChannelStripState],
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
            processors[i].solo = voices[i].solo
            // While auto is on, channel fader becomes the relative bias trim
            processors[i].faderDb = autoBalanceEnabled ? voices[i].autoBiasDb : voices[i].faderDb
            processors[i].pan = voices[i].pan
            processors[i].dspBypass = voices[i].dspBypass
            processors[i].eqGains = voices[i].eq.gains
            processors[i].eqBypass = voices[i].eq.bypass
            processors[i].eqHpfHz = voices[i].eq.hpfHz
            processors[i].paraFreqHz = voices[i].para.freqHz
            processors[i].paraGainDb = voices[i].para.gainDb
            processors[i].paraWidth = voices[i].para.width
            processors[i].paraBypass = voices[i].para.bypass
            processors[i].paraPlacement = voices[i].para.placement
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
        while stereoProcessors.count < stereos.count {
            var p = ChannelProcessor(isStereo: true, hasVoiceFX: false)
            p.configure(sampleRate: sampleRate)
            stereoProcessors.append(p)
            stereoMuteSpans.append([])
        }
        if stereoProcessors.count > stereos.count {
            stereoProcessors = Array(stereoProcessors.prefix(stereos.count))
            stereoMuteSpans = Array(stereoMuteSpans.prefix(stereos.count))
        }
        for i in 0..<stereos.count {
            guard stereoProcessors.indices.contains(i) else { continue }
            stereoProcessors[i].mute = stereos[i].mute
            stereoProcessors[i].solo = stereos[i].solo
            stereoProcessors[i].faderDb = stereos[i].faderDb
            stereoProcessors[i].pan = stereos[i].pan
            stereoProcessors[i].dspBypass = false
            stereoProcessors[i].eqGains = stereos[i].eq.gains
            stereoProcessors[i].eqBypass = stereos[i].eq.bypass
            stereoProcessors[i].eqHpfHz = stereos[i].eq.hpfHz
            stereoProcessors[i].dspOrder = stereos[i].dspOrder.isEmpty ? ChannelDSPSlot.musicDefault : stereos[i].dspOrder
            stereoProcessors[i].configure(sampleRate: sampleRate)
            if stereoMuteSpans.indices.contains(i) {
                stereoMuteSpans[i] = stereos[i].muteSpans
            }
        }
        stemNames = voices.map(\.bounceStemBaseName)
        voiceMuteSpans = voices.map(\.muteSpans)
        recordMap = [:]
        for (index, voice) in voices.enumerated() {
            if let ch = voice.inputChannel {
                recordMap[index] = ch
            }
        }
    }

    func start(
        fromBeginning: Bool = false,
        recording: Bool = false,
        inputMetering: Bool = false,
        inputDeviceUID: String? = nil
    ) throws {
        lock.lock()
        let wantsInput = recording || inputMetering
        if !wantsInput, frameCount <= 0 {
            lock.unlock()
            throw MixerError.engine("Load tracks first, or ADD STRIP and Record.")
        }
        if wantsInput, recordMap.isEmpty {
            lock.unlock()
            throw MixerError.engine("Pick an input on a speaker strip (IN 1, IN 2…) before Record.")
        }
        self.recording = recording
        self.inputMetering = inputMetering || recording
        self.inputDeviceUID = inputDeviceUID
        if wantsInput, frameCount == 0,
           let hwRate = MixerInputDevices.nominalSampleRate(uid: inputDeviceUID),
           hwRate > 0 {
            applySampleRateLocked(hwRate)
        }
        if fromBeginning {
            playhead = 0
        }
        if !recording, !inputMetering, playhead >= frameCount {
            playhead = 0
        }
        for i in processors.indices {
            processors[i].reset()
            processors[i].configure(sampleRate: sampleRate)
        }
        for i in stereoProcessors.indices {
            stereoProcessors[i].reset()
            stereoProcessors[i].configure(sampleRate: sampleRate)
        }
        autoBalancer.resize(to: voiceCount)
        autoBalancer.reset()
        masterComp.reset()
        recLock.lock()
        recPending = []
        liveInputPeaks = Array(repeating: 0, count: max(voiceCount, 1))
        recLock.unlock()
        lengthEmitCounter = 0
        lock.unlock()

        if audioEngine != nil {
            stopKeepingPlayhead()
            lock.lock()
            self.recording = recording
            self.inputMetering = inputMetering || recording
            lock.unlock()
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
            var total = self.frameCount
            let n = Int(frameCount)

            if self.recording {
                self.ensureCapacityLocked(head + n)
                self.consumeRecordLocked(from: head, frames: n)
                total = self.frameCount
            }

            // Copy buffers after the record write so CoW does not play a stale take.
            let voices = self.voiceBuffers
            let stereos = self.stereoBuffers
            let stereoChs = self.stereoChannelCounts
            let master = self.masterGain
            let voiceN = self.voiceCount
            let fadeFrames = MuteSpanStore.fadeFrames(sampleRate: self.sampleRate)
            let liveRecord = self.recording
            let meterFromInput = self.inputMetering || self.recording
            let anySolo = self.processors.contains(where: \.solo) || self.stereoProcessors.contains(where: \.solo)

            for i in 0..<n {
                var mixL: Float = 0
                var mixR: Float = 0
                if head < total {
                    var fxSamples = [Float](repeating: 0, count: voiceN)
                    var levels = [Float](repeating: 0, count: voiceN)
                    var muted = [Bool](repeating: false, count: voiceN)
                    for c in 0..<voiceN {
                        var sample: Float = (c < voices.count && head < voices[c].count) ? voices[c][head] : 0
                        if liveRecord, self.recordMap[c] != nil {
                            // Armed strips write to disk but stay silent in Mixer — monitor on the interface.
                            sample = 0
                        } else {
                            let spans = c < self.voiceMuteSpans.count ? self.voiceMuteSpans[c] : []
                            sample *= MuteSpanStore.gain(at: head, spans: spans, fadeFrames: fadeFrames)
                        }
                        if self.processors.indices.contains(c) {
                            muted[c] = self.processors[c].mute || (anySolo && !self.processors[c].solo)
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
                        var sample: Float = (c < voices.count && head < voices[c].count) ? voices[c][head] : 0
                        if liveRecord, self.recordMap[c] != nil {
                            sample = 0
                        } else {
                            let spans = c < self.voiceMuteSpans.count ? self.voiceMuteSpans[c] : []
                            sample *= MuteSpanStore.gain(at: head, spans: spans, fadeFrames: fadeFrames)
                        }
                        if self.processors.indices.contains(c) {
                            let g = autoGains.indices.contains(c) ? autoGains[c] : 1
                            let (l, r) = self.processors[c].finishMono(
                                fxSamples[c],
                                autoMixGain: g,
                                inputPeak: sample,
                                prePeak: &pre[c],
                                postPeak: &post[c]
                            )
                            if !anySolo || self.processors[c].solo {
                                mixL += l
                                mixR += r
                            }
                            if !self.rtaIsMusic, !self.rtaIsMaster, c == self.rtaVoiceIndex {
                                self.rta.push(fxSamples[c] * g)
                            }
                        }
                    }
                    for s in stereos.indices {
                        let ch = max(1, stereoChs.indices.contains(s) ? stereoChs[s] : 2)
                        let buf = stereos[s]
                        let spans = s < self.stereoMuteSpans.count ? self.stereoMuteSpans[s] : []
                        let gain = MuteSpanStore.gain(at: head, spans: spans, fadeFrames: fadeFrames)
                        let ml: Float
                        let mr: Float
                        if ch >= 2, head * ch + 1 < buf.count {
                            ml = buf[head * ch] * gain
                            mr = buf[head * ch + 1] * gain
                        } else if head < buf.count {
                            ml = buf[head] * gain
                            mr = buf[head] * gain
                        } else {
                            ml = 0
                            mr = 0
                        }
                        let meterIdx = voiceN + s
                        var preS = meterIdx < pre.count ? pre[meterIdx] : Float(0)
                        var postS = meterIdx < post.count ? post[meterIdx] : Float(0)
                        if self.stereoProcessors.indices.contains(s) {
                            let (ol, orr) = self.stereoProcessors[s].processStereo(ml, mr, prePeak: &preS, postPeak: &postS)
                            if !anySolo || self.stereoProcessors[s].solo {
                                mixL += ol
                                mixR += orr
                            }
                            if meterIdx < pre.count { pre[meterIdx] = preS }
                            if meterIdx < post.count { post[meterIdx] = postS }
                            if self.rtaIsMusic, !self.rtaIsMaster, s == self.rtaVoiceIndex {
                                self.rta.push(0.5 * (ol + orr))
                            }
                        }
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
            // Armed strips: PRE/POST show live input while standby or recording (mix stays silent).
            if meterFromInput {
                self.recLock.lock()
                let live = self.liveInputPeaks
                self.recLock.unlock()
                for (voiceIndex, _) in self.recordMap {
                    guard voiceIndex < slots, voiceIndex < live.count else { continue }
                    let peak = live[voiceIndex]
                    self.meterPre[voiceIndex] = max(self.meterPre[voiceIndex], peak)
                    self.meterPost[voiceIndex] = max(self.meterPost[voiceIndex], peak)
                }
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
                // Decay live peaks so meters fall when input goes quiet.
                if meterFromInput {
                    self.recLock.lock()
                    for i in self.liveInputPeaks.indices {
                        self.liveInputPeaks[i] *= 0.6
                    }
                    self.recLock.unlock()
                }
            }
            if shouldEmitHead {
                self.playheadEmitCounter = 0
            }
            let holdOpen = self.recording || self.inputMetering
            let ended = !holdOpen && self.frameCount > 0 && head >= total
            let emitLength = self.recording && (self.lengthEmitCounter >= Int(self.sampleRate / 4))
            if emitLength { self.lengthEmitCounter = 0 }
            let newLength = self.frameCount
            if self.recording {
                self.lengthEmitCounter += n
            }
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
            if emitLength {
                self.onSessionLength?(newLength)
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
        if recording || inputMetering {
            try attachSilentInput(engine)
        }
        try engine.start()
        audioEngine = engine
        sourceNode = node
        playing = true
        lock.lock()
        self.recording = recording
        self.inputMetering = inputMetering || recording
        lock.unlock()
    }

    func stop() {
        stopKeepingPlayhead()
    }

    private func stopKeepingPlayhead() {
        lock.lock()
        let wasRecording = recording
        playing = false
        recording = false
        inputMetering = false
        lock.unlock()
        if didInstallInputTap, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            recSilentMixer.map { engine.disconnectNodeOutput($0) }
        }
        didInstallInputTap = false
        audioEngine?.stop()
        if let node = sourceNode {
            audioEngine?.detach(node)
        }
        if let mixer = recSilentMixer {
            audioEngine?.detach(mixer)
        }
        sourceNode = nil
        recSilentMixer = nil
        recConverter = nil
        recSourceFormat = nil
        recDestFormat = nil
        audioEngine = nil
        recLock.lock()
        recPending = []
        liveInputPeaks = []
        recLock.unlock()
        if wasRecording {
            lock.lock()
            rebuildWaveformCache()
            lock.unlock()
        }
    }

    struct BounceResult {
        var folder: URL
        var fileCount: Int
    }

    /// Which rendered buffers to write, and the file names inside `folder` (no extension).
    struct BounceWritePlan: Sendable {
        var voiceFiles: [Int: String]
        var stereoFiles: [Int: String]
        var mixFile: String?
        var sampleRate: Double?
        var format: MixerBounceFormat
        var isEmpty: Bool {
            voiceFiles.isEmpty && stereoFiles.isEmpty && mixFile == nil
        }
    }

    func bounce(to folder: URL, plan: BounceWritePlan) throws -> BounceResult {
        lock.lock()
        let total = frameCount
        let sr = sampleRate
        let voices = voiceBuffers
        let nums = speakerNumbers
        let names = stemNames
        let stereos = stereoBuffers
        let stereoChs = stereoChannelCounts
        var procs = processors
        var stereoProcs = stereoProcessors
        var balancer = autoBalancer
        var busComp = masterComp
        let master = masterGain
        let voiceN = voiceCount
        let stereoN = stereos.count
        let voiceMuteSpansCopy = voiceMuteSpans
        let stereoMuteSpansCopy = stereoMuteSpans
        let fade = MuteSpanStore.fadeFrames(sampleRate: sr)
        lock.unlock()

        guard total > 0 else { throw MixerError.engine("Nothing to bounce.") }
        guard !plan.isEmpty else { throw MixerError.engine("Pick at least one output to export.") }
        let destRate = plan.sampleRate.flatMap { $0 > 0 ? $0 : nil } ?? sr
        let ext = plan.format.pathExtension

        for i in procs.indices {
            procs[i].reset()
            procs[i].configure(sampleRate: sr)
        }
        for i in stereoProcs.indices {
            stereoProcs[i].reset()
            stereoProcs[i].configure(sampleRate: sr)
        }
        balancer.resize(to: voiceN)
        balancer.reset()
        busComp.reset()

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var stemBuffers: [[Float]] = Array(repeating: [], count: voiceN + stereoN)
        for i in 0..<(voiceN + stereoN) { stemBuffers[i].reserveCapacity(total * 2) }
        var mixL = [Float](repeating: 0, count: total)
        var mixR = [Float](repeating: 0, count: total)
        let anySolo = procs.contains(where: \.solo) || stereoProcs.contains(where: \.solo)

        for head in 0..<total {
            var busL: Float = 0
            var busR: Float = 0
            var pre: Float = 0
            var post: Float = 0

            var fxSamples = [Float](repeating: 0, count: voiceN)
            var levels = [Float](repeating: 0, count: voiceN)
            var muted = [Bool](repeating: false, count: voiceN)
            for c in 0..<voiceN {
                var sample: Float = (c < voices.count && head < voices[c].count) ? voices[c][head] : 0
                let spans = c < voiceMuteSpansCopy.count ? voiceMuteSpansCopy[c] : []
                sample *= MuteSpanStore.gain(at: head, spans: spans, fadeFrames: fade)
                muted[c] = procs[c].mute || (anySolo && !procs[c].solo)
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
                if !anySolo || procs[c].solo {
                    busL += l
                    busR += r
                }
            }
            for s in 0..<stereoN {
                let ch = max(1, stereoChs.indices.contains(s) ? stereoChs[s] : 2)
                let buf = stereos[s]
                let spans = s < stereoMuteSpansCopy.count ? stereoMuteSpansCopy[s] : []
                let gain = MuteSpanStore.gain(at: head, spans: spans, fadeFrames: fade)
                let ml: Float
                let mr: Float
                if ch >= 2, head * ch + 1 < buf.count {
                    ml = buf[head * ch] * gain
                    mr = buf[head * ch + 1] * gain
                } else if head < buf.count {
                    ml = buf[head] * gain
                    mr = buf[head] * gain
                } else {
                    ml = 0
                    mr = 0
                }
                pre = 0; post = 0
                let (ol, orr): (Float, Float)
                if stereoProcs.indices.contains(s) {
                    (ol, orr) = stereoProcs[s].processStereo(ml, mr, prePeak: &pre, postPeak: &post)
                } else {
                    (ol, orr) = (ml, mr)
                }
                stemBuffers[voiceN + s].append(ol)
                stemBuffers[voiceN + s].append(orr)
                if !anySolo || (stereoProcs.indices.contains(s) && stereoProcs[s].solo) {
                    busL += ol
                    busR += orr
                }
            }
            let (cL, cR) = busComp.process(left: busL, right: busR, sampleRate: sr)
            busL = tanhf(cL * master)
            busR = tanhf(cR * master)
            mixL[head] = busL
            mixR[head] = busR
        }

        var fileCount = 0
        var usedNames = Set<String>()
        func uniqueName(_ raw: String, fallback: String) -> String {
            var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = base.lowercased()
            for suffix in [".wav", ".aiff", ".aif"] where lower.hasSuffix(suffix) {
                base = String(base.dropLast(suffix.count))
                break
            }
            base = ChannelStripState.sanitizeFilenameComponent(base)
            if base.isEmpty { base = fallback }
            var unique = base
            var suffixN = 2
            while usedNames.contains(unique.lowercased()) {
                unique = "\(base)_\(suffixN)"
                suffixN += 1
            }
            usedNames.insert(unique.lowercased())
            return "\(unique).\(ext)"
        }

        for c in 0..<voiceN {
            guard let requested = plan.voiceFiles[c] else { continue }
            let has = c < voices.count && !voices[c].isEmpty
            if has {
                let num = nums.indices.contains(c) ? nums[c] : (c + 1)
                let fallback = names.indices.contains(c) ? names[c] : "Speaker_\(num)"
                let filename = uniqueName(requested, fallback: fallback.isEmpty ? "Speaker_\(num)" : fallback)
                let url = folder.appendingPathComponent(filename)
                try MixerAudioIO.writeExport(
                    url: url,
                    buffer: .init(sampleRate: sr, channelCount: 2, samples: stemBuffers[c]),
                    format: plan.format,
                    sampleRate: destRate
                )
                fileCount += 1
            }
        }
        for s in 0..<stereoN {
            guard let requested = plan.stereoFiles[s] else { continue }
            let has = s < stereos.count && !stereos[s].isEmpty
            if has {
                let fallback = s == 0 ? "Music_and_SFX_fixed" : "SFX_fixed"
                let filename = uniqueName(requested, fallback: fallback)
                let url = folder.appendingPathComponent(filename)
                try MixerAudioIO.writeExport(
                    url: url,
                    buffer: .init(sampleRate: sr, channelCount: 2, samples: stemBuffers[voiceN + s]),
                    format: plan.format,
                    sampleRate: destRate
                )
                fileCount += 1
            }
        }
        if let requested = plan.mixFile {
            var mixInterleaved: [Float] = []
            mixInterleaved.reserveCapacity(total * 2)
            for i in 0..<total {
                mixInterleaved.append(mixL[i])
                mixInterleaved.append(mixR[i])
            }
            let filename = uniqueName(requested, fallback: "mix")
            try MixerAudioIO.writeExport(
                url: folder.appendingPathComponent(filename),
                buffer: .init(sampleRate: sr, channelCount: 2, samples: mixInterleaved),
                format: plan.format,
                sampleRate: destRate
            )
            fileCount += 1
        }
        return BounceResult(folder: folder, fileCount: fileCount)
    }

    /// Writes each non-empty speaker buffer as `Speaker_N.wav` so the folder can be dropped later.
    func writeWorkingTakes(to folder: URL) throws -> [Int: URL] {
        lock.lock()
        let sr = sampleRate
        let voices = voiceBuffers
        let nums = speakerNumbers
        lock.unlock()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [Int: URL] = [:]
        for (i, buf) in voices.enumerated() {
            guard !buf.isEmpty else { continue }
            let num = nums.indices.contains(i) ? nums[i] : (i + 1)
            let url = folder.appendingPathComponent("Speaker_\(num).wav")
            try WAVIO.write(
                url: url,
                buffer: .init(sampleRate: sr, channelCount: 1, samples: buf)
            )
            written[i] = url
        }
        return written
    }

    private func ensureCapacityLocked(_ frames: Int) {
        let need = max(0, frames)
        guard need > 0 else { return }
        for i in voiceBuffers.indices {
            if voiceBuffers[i].count < need {
                voiceBuffers[i].append(contentsOf: repeatElement(Float(0), count: need - voiceBuffers[i].count))
            }
        }
        for i in stereoBuffers.indices {
            let ch = max(1, stereoChannelCounts.indices.contains(i) ? stereoChannelCounts[i] : 2)
            let stereoNeed = need * ch
            if stereoBuffers[i].count < stereoNeed {
                stereoBuffers[i].append(contentsOf: repeatElement(Float(0), count: stereoNeed - stereoBuffers[i].count))
            }
        }
        frameCount = max(frameCount, need)
    }

    private func consumeRecordLocked(from head: Int, frames n: Int) {
        recLock.lock()
        let pending = recPending
        let ch = max(1, recPendingChannels)
        recPending.removeAll(keepingCapacity: true)
        recLock.unlock()
        let pendingFrames = ch > 0 ? pending.count / ch : 0
        guard n > 0 else { return }
        if pendingFrames > n {
            recLock.lock()
            recPending = Array(pending[(n * ch)...])
            recPendingChannels = ch
            recLock.unlock()
        }
        for i in 0..<n {
            let src = i < pendingFrames ? i : -1
            for (voiceIndex, hwCh) in recordMap {
                guard voiceBuffers.indices.contains(voiceIndex) else { continue }
                let dest = head + i
                guard dest < voiceBuffers[voiceIndex].count else { continue }
                var sample: Float = 0
                if src >= 0 {
                    let idx = src * ch + min(max(0, hwCh), ch - 1)
                    if idx < pending.count {
                        sample = pending[idx]
                    }
                }
                voiceBuffers[voiceIndex][dest] = sample
            }
        }
    }

    private func attachSilentInput(_ engine: AVAudioEngine) throws {
        applyInputDevice(engine, uid: inputDeviceUID)
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw MixerError.engine("No input from that interface. Pick another INPUT.")
        }
        let silent = AVAudioMixerNode()
        engine.attach(silent)
        engine.connect(input, to: silent, format: hwFormat)
        let silentOut = AVAudioFormat(standardFormatWithSampleRate: hwFormat.sampleRate, channels: 2)
        engine.connect(silent, to: engine.mainMixerNode, format: silentOut)
        silent.outputVolume = 0
        recSilentMixer = silent

        recSourceFormat = hwFormat
        recDestFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: hwFormat.channelCount,
            interleaved: true
        )
        // Keep the interface clock. Convert to float at that rate; only resample if this
        // session already has audio at a different rate (mixing onto an existing timeline).
        recConverter = nil

        recLock.lock()
        recPending = []
        recPendingChannels = Int(hwFormat.channelCount)
        recLock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.ingestRecordBuffer(buffer)
        }
        didInstallInputTap = true
    }

    private func applyInputDevice(_ engine: AVAudioEngine, uid: String?) {
        guard let uid,
              let device = MixerInputDevices.list().first(where: { $0.uid == uid })
        else { return }
        var id = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        _ = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            size
        )
    }

    private func ingestRecordBuffer(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let ch = max(1, Int(buffer.format.channelCount))
        var out = interleavedFloats(from: buffer)
        var outCh = ch
        let srcRate = buffer.format.sampleRate
        let destRate = sampleRate
        if abs(srcRate - destRate) > 0.5, srcRate > 0, destRate > 0 {
            if let resampled = try? MixerAudioIO.resampleInterleaved(
                out,
                channels: ch,
                from: srcRate,
                to: destRate
            ) {
                out = resampled
                outCh = ch
            }
        }

        lock.lock()
        let map = recordMap
        let voiceN = voiceCount
        let writing = recording
        lock.unlock()

        var peaks = Array(repeating: Float(0), count: max(voiceN, 1))
        let pendingFrames = outCh > 0 ? out.count / outCh : 0
        for (voiceIndex, hwCh) in map {
            guard voiceIndex < peaks.count else { continue }
            let channel = min(max(0, hwCh), outCh - 1)
            var peak: Float = 0
            for f in 0..<pendingFrames {
                let idx = f * outCh + channel
                if idx < out.count {
                    peak = max(peak, abs(out[idx]))
                }
            }
            peaks[voiceIndex] = peak
        }

        recLock.lock()
        if liveInputPeaks.count < peaks.count {
            liveInputPeaks.append(contentsOf: Array(repeating: 0, count: peaks.count - liveInputPeaks.count))
        }
        for i in peaks.indices {
            if i < liveInputPeaks.count {
                liveInputPeaks[i] = max(liveInputPeaks[i], peaks[i])
            }
        }
        if writing {
            recPending.append(contentsOf: out)
            recPendingChannels = outCh
        }
        recLock.unlock()
    }

    /// Dante / interfaces often deliver int PCM. Store float at the file’s native rate.
    private func interleavedFloats(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let ch = max(1, Int(buffer.format.channelCount))
        if let planar = buffer.floatChannelData {
            var out = [Float](repeating: 0, count: frames * ch)
            for f in 0..<frames {
                for c in 0..<ch {
                    out[f * ch + c] = planar[c][f]
                }
            }
            return out
        }
        if let planar = buffer.int16ChannelData {
            var out = [Float](repeating: 0, count: frames * ch)
            for f in 0..<frames {
                for c in 0..<ch {
                    out[f * ch + c] = Float(planar[c][f]) / 32768.0
                }
            }
            return out
        }
        if let planar = buffer.int32ChannelData {
            var out = [Float](repeating: 0, count: frames * ch)
            for f in 0..<frames {
                for c in 0..<ch {
                    out[f * ch + c] = Float(planar[c][f]) / Float(Int32.max)
                }
            }
            return out
        }
        if buffer.format.isInterleaved, let data = buffer.audioBufferList.pointee.mBuffers.mData {
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                let ptr = data.assumingMemoryBound(to: Float.self)
                return Array(UnsafeBufferPointer(start: ptr, count: frames * ch))
            case .pcmFormatInt16:
                let ptr = data.assumingMemoryBound(to: Int16.self)
                return UnsafeBufferPointer(start: ptr, count: frames * ch).map { Float($0) / 32768.0 }
            case .pcmFormatInt32:
                let ptr = data.assumingMemoryBound(to: Int32.self)
                return UnsafeBufferPointer(start: ptr, count: frames * ch).map { Float($0) / Float(Int32.max) }
            default:
                break
            }
        }
        return [Float](repeating: 0, count: frames * ch)
    }
}
