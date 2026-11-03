import AVFoundation
import CoreAudio
import Foundation
import os
import RecordCore

final class MixerEngine: @unchecked Sendable {
    private let lock = UnfairLock()
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

    /// pre, post, masterL, masterR, autoGainDb, rtaBins, levelerGRDb, levelerBoostDb, deessGRDb, compInL, compInR, compOutL, compOutR, compGRDb
    var onMeters: (([Float], [Float], Float, Float, [Float], [Float], [Float], [Float], [Float], Float, Float, Float, Float, Float) -> Void)?
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
    private var lastLevelerGRDb: [Float] = []
    private var lastLevelerBoostDb: [Float] = []
    private var lastDeessGRDb: [Float] = []
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
    /// Armed at record/standby start. Render reads this; the tap reads `tapArmed`.
    private var armedFlags: [Bool] = []
    private var tapArmed: [(voice: Int, hw: Int)] = []
    private let recordingFlag = PPAtomicU64(0)
    private let inputTapActive = PPAtomicU64(0)
    private let recordPunchStartAtomic = PPAtomicU64(0)
    private let recordFramesCommitted = PPAtomicU64(0)
    private let renderLockMisses = PPAtomicU64(0)
    private let transferredMisses = PPAtomicU64(0)
    private var recordSession: RecordSession?
    private var livePeaks = RecordLivePeaks(count: 1)
    private var recordingFiles: [URL] = []
    private var renameRecording: [Int: URL] = [:]
    private(set) var recordDropoutCount: Int = 0
    /// Disk-write failures during the last take (disk full / I/O error).
    private(set) var recordWriteFailures: Int = 0
    /// `.recording.wav` files from the last take that could not be merged. They are never deleted.
    private(set) var recordKeptFiles: [String] = []
    var onRecordDropouts: ((Int) -> Void)?
    private var tapScratch: UnsafeMutablePointer<Float>?
    private var tapScratchFrames = 0
    private var tapScratchChannels = 0
    private var tapScratchCapacity = 0
    private var tapSessionRate: Double = 48_000
    private var tapInputRate: Double = 48_000
    private var configObserver: NSObjectProtocol?
    private var overloadDevice: AudioDeviceID = 0
    private var overloadBlock: AudioObjectPropertyListenerBlock?
    private var liveWaveform: RecordSession?
    private var liveWaveformPunch: Int = 0
    private var liveWaveformBaseFrames: Int = 0
    /// Block scratch. Resized on the main thread in `start` / when the voice count changes.
    private var scratchPre: [Float] = []
    private var scratchPost: [Float] = []
    private var scratchFX: [Float] = []
    private var scratchLevels: [Float] = []
    private var scratchMuted: [Bool] = []
    private var scratchAutoGains: [Float] = []
    private var recSilentMixer: AVAudioMixerNode?
    /// True only after a record tap is on inputNode. Touching inputNode at any other time makes macOS ask for the mic.
    private var didInstallInputTap = false
    private var lengthEmitCounter = 0

    /// Preferred Core Audio tap size for multi-channel record headroom.
    private static let recordTapFrames: AVAudioFrameCount = 4096
    private static let tapScratchFrameCapacity = 16_384

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
    /// While recording, armed strips combine the frozen cache with the writer-thread peak cache.
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
        if let live = liveWaveform, live.isArmed(voiceIndex: channelIndex) {
            return liveVoicePeaks(channelIndex: channelIndex, session: live)
        }
        return cachedVoicePeaks[channelIndex]
    }

    private func liveVoicePeaks(channelIndex: Int, session: RecordSession) -> [Float] {
        let bins = waveformBinCount
        let old = cachedVoicePeaks[channelIndex]
        let punch = liveWaveformPunch
        let base = liveWaveformBaseFrames
        let committed = Int(session.framesCommitted)
        let length = max(1, max(base, punch + committed))
        var out = [Float](repeating: 0, count: bins)
        let takeEnd = punch + committed
        for i in 0..<bins {
            let start = i * length / bins
            let end = max(start + 1, (i + 1) * length / bins)
            var peak: Float = 0
            if base > 0, !old.isEmpty {
                if start < punch {
                    peak = max(peak, oldRangePeak(old, frames: base, start: start, end: min(end, punch)))
                }
                if end > takeEnd {
                    peak = max(peak, oldRangePeak(old, frames: base, start: max(start, takeEnd), end: end))
                }
            }
            if committed > 0, end > punch, start < takeEnd {
                let a = max(0, start - punch)
                let b = min(committed, end - punch)
                peak = max(peak, session.livePeak(voiceIndex: channelIndex, from: a, to: b))
            }
            out[i] = peak
        }
        let maxPeak = out.max() ?? 1
        if maxPeak > 1e-6 {
            for i in 0..<bins { out[i] /= maxPeak }
        }
        return out
    }

    private func oldRangePeak(_ old: [Float], frames: Int, start: Int, end: Int) -> Float {
        let a = max(0, min(frames, start))
        let b = max(0, min(frames, end))
        if b <= a || old.isEmpty || frames <= 0 { return 0 }
        let b0 = min(old.count - 1, a * old.count / frames)
        let b1 = min(old.count - 1, (b - 1) * old.count / frames)
        var peak: Float = 0
        if b1 >= b0 {
            for i in b0...b1 { peak = max(peak, old[i]) }
        }
        return peak
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

    func load(
        voiceURLs: [URL?],
        speakerNumbers: [Int],
        stereoURLs: [URL],
        sampleRateHint: Double?,
        progress: ((Double, String) -> Void)? = nil
    ) throws {
        stop()
        lock.lock()
        var holdsLock = true
        defer { if holdsLock { lock.unlock() } }

        var rate: Double?
        var frames = 0
        voiceBuffers = []
        self.speakerNumbers = []
        self.stemNames = []
        voiceBuffers.reserveCapacity(voiceURLs.count)

        let totalSteps = max(1, voiceURLs.count + min(stereoURLs.count, StripperFolderLoader.maxStereo))
        var step = 0

        for (i, url) in voiceURLs.enumerated() {
            let num = speakerNumbers.indices.contains(i) ? speakerNumbers[i] : (i + 1)
            self.speakerNumbers.append(num)
            self.stemNames.append("Speaker_\(num)")
            guard let url else {
                voiceBuffers.append([])
                step += 1
                progress?(Double(step) / Double(totalSteps), "Loading speakers…")
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
            step += 1
            progress?(Double(step) / Double(totalSteps), url.lastPathComponent)
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
            step += 1
            progress?(Double(step) / Double(totalSteps), url.lastPathComponent)
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
        let snapVoices = voiceBuffers
        let snapStereos = stereoBuffers
        let snapChannels = stereoChannelCounts
        let snapFrames = frameCount
        lock.unlock()
        holdsLock = false
        publishWaveformCache(voices: snapVoices, stereos: snapStereos, stereoChannels: snapChannels, frames: snapFrames)
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
        lock.unlock()
        rebuildWaveformCache()
    }


    func appendSilentVoice(speakerNumber: Int) {
        lock.lock()
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
        lock.unlock()
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
        guard voiceBuffers.indices.contains(index) else {
            lock.unlock()
            return
        }
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
        lock.unlock()
        rebuildWaveformCache()
    }

    func rebuildPeaks() {
        rebuildWaveformCache()
    }

    /// Snapshot under the audio lock, then build the cache outside it.
    private func rebuildWaveformCache() {
        lock.lock()
        let voices = voiceBuffers
        let stereos = stereoBuffers
        let stereoChs = stereoChannelCounts
        let frames = frameCount
        lock.unlock()
        publishWaveformCache(voices: voices, stereos: stereos, stereoChannels: stereoChs, frames: frames)
    }

    private func publishWaveformCache(
        voices: [[Float]],
        stereos: [[Float]],
        stereoChannels: [Int],
        frames: Int
    ) {
        let bins = waveformBinCount
        let voicePeaks = voices.map { downsampleAbs($0, binCount: bins, frameCount: $0.count, channelCount: 1) }
        var stereoPeaks: [[Float]] = []
        for i in stereos.indices {
            let ch = max(1, stereoChannels.indices.contains(i) ? stereoChannels[i] : 2)
            let count = stereos[i].count / ch
            stereoPeaks.append(downsampleAbs(stereos[i], binCount: bins, frameCount: count, channelCount: ch))
        }

        var master = [Float](repeating: 0, count: bins)
        let total = max(1, frames)
        for i in 0..<bins {
            let start = i * total / bins
            let end = max(start + 1, (i + 1) * total / bins)
            var peak: Float = 0
            for f in start..<min(end, total) {
                for buf in voices {
                    if f < buf.count { peak = max(peak, abs(buf[f])) }
                }
                for s in stereos.indices {
                    let ch = max(1, stereoChannels.indices.contains(s) ? stereoChannels[s] : 2)
                    let buf = stereos[s]
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
        autoMixMode: AutoMixMode,
        autoDuckMaxAttenuationDb: Float,
        masterComp state: MasterCompressorState
    ) {
        lock.lock()
        defer { lock.unlock() }
        masterGain = pow(10.0, masterDb / 20.0)
        autoBalancer.mode = autoMixMode
        autoBalancer.included = voices.map(\.includeInAutoMix)
        autoBalancer.baselineDb = voices.map(\.faderDb)
        autoBalancer.maxAttenuationDb = autoDuckMaxAttenuationDb
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
            // Baseline always lives in faderDb; auto gain is purely additive while active.
            processors[i].faderDb = voices[i].faderDb
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
            processors[i].deessFreqHz = voices[i].deess.freqHz
            processors[i].deessWidth = voices[i].deess.width
            processors[i].deessThresholdDb = voices[i].deess.thresholdDb
            processors[i].deessBypass = voices[i].deess.bypass
            processors[i].deessListen = voices[i].deessListen
            processors[i].inputGainDb = voices[i].inputGainDb
            processors[i].deVerbAmount = voices[i].voice.deVerb
            processors[i].deVerbBypass = voices[i].voice.deVerbBypass
            processors[i].wetterAmount = voices[i].voice.wetter
            processors[i].wetterBypass = voices[i].voice.wetterBypass
            processors[i].wetterRoom = voices[i].voice.wetterRoom
            processors[i].levelerDriveDb = voices[i].voice.levelerDriveDb
            processors[i].levelerLimiterDb = voices[i].voice.levelerLimiterDb
            processors[i].levelerGate = voices[i].voice.levelerGate
            processors[i].levelerBypass = voices[i].voice.levelerBypass
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
            stereoProcessors[i].inputGainDb = stereos[i].inputGainDb
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
        prepareRenderScratchLocked()
        if !recording {
            armedFlags = Array(repeating: false, count: voiceCount)
            for index in recordMap.keys where index >= 0 && index < armedFlags.count {
                armedFlags[index] = true
            }
        }
    }

    func start(
        fromBeginning: Bool = false,
        recording: Bool = false,
        inputMetering: Bool = false,
        inputDeviceUID: String? = nil,
        recordFolder: URL? = nil
    ) throws {
        if recording, recordFolder == nil {
            throw MixerError.engine("No session folder")
        }
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
        prepareRenderScratchLocked()
        applyArmedFlagsLocked()
        recordPunchStartAtomic.store(UInt64(max(0, playhead)))
        recordFramesCommitted.store(0)
        renderLockMisses.store(0)
        transferredMisses.store(0)
        recordDropoutCount = 0
        recordWriteFailures = 0
        recordKeptFiles = []
        lengthEmitCounter = 0
        var punch = max(0, playhead)
        var baseFrames = frameCount
        lock.unlock()

        if audioEngine != nil {
            stopKeepingPlayhead()
            lock.lock()
            self.recording = recording
            self.inputMetering = inputMetering || recording
            prepareRenderScratchLocked()
            applyArmedFlagsLocked()
            punch = max(0, playhead)
            baseFrames = frameCount
            recordPunchStartAtomic.store(UInt64(punch))
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

            let n = Int(frameCount)
            if !self.lock.tryLock() {
                for i in 0..<n {
                    lPtr[i] = 0
                    rPtr[i] = 0
                }
                if self.recordingFlag.load() != 0 {
                    self.renderLockMisses.fetchAdd(1)
                }
                return noErr
            }
            var head = self.playhead
            let slots = max(1, self.meterSlotCount)
            let preN = min(slots, self.scratchPre.count, self.scratchPost.count)
            for i in 0..<preN {
                self.scratchPre[i] = 0
                self.scratchPost[i] = 0
            }
            var mL: Float = 0
            var mR: Float = 0
            let punch = Int(self.recordPunchStartAtomic.load())
            let committed = Int(self.recordFramesCommitted.load())
            var total = self.frameCount
            let liveRecord = self.recording
            if liveRecord {
                let extended = punch + committed
                if extended > total { total = extended }
            }

            // Buffer headers only. Armed takes are on disk, so this does not copy samples.
            let voices = self.voiceBuffers
            let stereos = self.stereoBuffers
            let stereoChs = self.stereoChannelCounts
            let master = self.masterGain
            let voiceN = self.voiceCount
            let fadeFrames = MuteSpanStore.fadeFrames(sampleRate: self.sampleRate)
            let meterFromInput = self.inputMetering || self.recording
            let anySolo = self.processors.contains(where: \.solo) || self.stereoProcessors.contains(where: \.solo)

            for i in 0..<n {
                var mixL: Float = 0
                var mixR: Float = 0
                if head < total {
                    let fxN = min(voiceN, self.scratchFX.count, self.scratchLevels.count, self.scratchMuted.count)
                    for c in 0..<fxN {
                        self.scratchFX[c] = 0
                        self.scratchLevels[c] = 0
                        self.scratchMuted[c] = false
                    }
                    for c in 0..<voiceN {
                        var sample: Float = (c < voices.count && head < voices[c].count) ? voices[c][head] : 0
                        let armedSilent = liveRecord && c < self.armedFlags.count && self.armedFlags[c]
                        if armedSilent {
                            // Armed strips are written from the input tap and stay silent in the mix.
                            sample = 0
                        } else {
                            let spans = c < self.voiceMuteSpans.count ? self.voiceMuteSpans[c] : []
                            sample *= MuteSpanStore.gain(at: head, spans: spans, fadeFrames: fadeFrames)
                        }
                        if self.processors.indices.contains(c), c < fxN {
                            self.scratchMuted[c] = self.processors[c].mute || (anySolo && !self.processors[c].solo)
                            if armedSilent {
                                self.scratchFX[c] = 0
                                self.scratchLevels[c] = 0
                                self.processors[c].deessListenTap = 0
                            } else {
                                let gained = self.processors[c].inputGained(sample)
                                let fx = self.processors[c].processEffects(gained)
                                self.scratchFX[c] = fx
                                self.scratchLevels[c] = abs(fx)
                            }
                        }
                    }
                    if voiceN > 0 {
                        Self.mixAuto(
                            balancer: &self.autoBalancer,
                            levels: &self.scratchLevels,
                            muted: &self.scratchMuted,
                            gains: &self.scratchAutoGains,
                            voiceN: voiceN,
                            sampleRate: self.sampleRate
                        )
                    }
                    for c in 0..<voiceN {
                        var sample: Float = (c < voices.count && head < voices[c].count) ? voices[c][head] : 0
                        if liveRecord, c < self.armedFlags.count, self.armedFlags[c] {
                            sample = 0
                        } else {
                            let spans = c < self.voiceMuteSpans.count ? self.voiceMuteSpans[c] : []
                            sample *= MuteSpanStore.gain(at: head, spans: spans, fadeFrames: fadeFrames)
                        }
                        if self.processors.indices.contains(c) {
                            let g = c < self.scratchAutoGains.count ? self.scratchAutoGains[c] : 1
                            let gained = self.processors[c].inputGained(sample)
                            var preC: Float = c < self.scratchPre.count ? self.scratchPre[c] : 0
                            var postC: Float = c < self.scratchPost.count ? self.scratchPost[c] : 0
                            let fx = c < self.scratchFX.count ? self.scratchFX[c] : 0
                            // LISTEN replaces this channel's monitor output only. Auto-mix still
                            // sees `fx` above. Bounce never reads this tap.
                            let audible = self.processors[c].deessListen ? self.processors[c].deessListenTap : fx
                            let (l, r) = self.processors[c].finishMono(
                                audible,
                                autoMixGain: g,
                                inputPeak: gained,
                                prePeak: &preC,
                                postPeak: &postC
                            )
                            if c < self.scratchPre.count { self.scratchPre[c] = preC }
                            if c < self.scratchPost.count { self.scratchPost[c] = postC }
                            if !anySolo || self.processors[c].solo {
                                mixL += l
                                mixR += r
                            }
                            if !self.rtaIsMusic, !self.rtaIsMaster, c == self.rtaVoiceIndex {
                                let shown = self.processors[c].deessListen ? self.processors[c].deessListenTap : fx
                                self.rta.push(shown * g)
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
                        var preS = meterIdx < self.scratchPre.count ? self.scratchPre[meterIdx] : Float(0)
                        var postS = meterIdx < self.scratchPost.count ? self.scratchPost[meterIdx] : Float(0)
                        if self.stereoProcessors.indices.contains(s) {
                            let (ol, orr) = self.stereoProcessors[s].processStereo(ml, mr, prePeak: &preS, postPeak: &postS)
                            if !anySolo || self.stereoProcessors[s].solo {
                                mixL += ol
                                mixR += orr
                            }
                            if meterIdx < self.scratchPre.count { self.scratchPre[meterIdx] = preS }
                            if meterIdx < self.scratchPost.count { self.scratchPost[meterIdx] = postS }
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
            let gainN = min(voiceN, self.scratchAutoGains.count, self.lastAutoGainDb.count)
            for c in 0..<gainN {
                self.lastAutoGainDb[c] = 20 * log10(max(self.scratchAutoGains[c], 1e-6))
            }
            let grN = min(voiceN, self.processors.count)
            for c in 0..<grN {
                if c < self.lastLevelerGRDb.count {
                    self.lastLevelerGRDb[c] = self.processors[c].levelerMeterGRDb
                }
                if c < self.lastLevelerBoostDb.count {
                    self.lastLevelerBoostDb[c] = self.processors[c].levelerMeterBoostDb
                }
                if c < self.lastDeessGRDb.count {
                    self.lastDeessGRDb[c] = self.processors[c].deessMeterGRDb
                }
            }
            let meterN = min(slots, self.meterPre.count, self.meterPost.count, self.scratchPre.count, self.scratchPost.count)
            for i in 0..<meterN {
                self.meterPre[i] = max(self.meterPre[i] * 0.6, self.scratchPre[i])
                self.meterPost[i] = max(self.meterPost[i] * 0.6, self.scratchPost[i])
            }
            if meterFromInput {
                let armedN = min(slots, self.armedFlags.count)
                for voiceIndex in 0..<armedN where self.armedFlags[voiceIndex] {
                    let peak = self.livePeaks.load(index: voiceIndex)
                    if voiceIndex < self.meterPre.count {
                        self.meterPre[voiceIndex] = max(self.meterPre[voiceIndex], peak)
                    }
                    if voiceIndex < self.meterPost.count {
                        self.meterPost[voiceIndex] = max(self.meterPost[voiceIndex], peak)
                    }
                }
            }
            self.meterMasterL = max(self.meterMasterL * 0.6, mL)
            self.meterMasterR = max(self.meterMasterR * 0.6, mR)
            self.meterCounter += n
            self.playheadEmitCounter += n
            let shouldEmit = self.meterCounter >= Int(self.sampleRate / 20)
            let shouldEmitHead = self.playheadEmitCounter >= Int(self.sampleRate / 30)
            let emitL = self.meterMasterL
            let emitR = self.meterMasterR
            let emitCompInL = self.masterComp.meterInL
            let emitCompInR = self.masterComp.meterInR
            let emitCompOutL = self.masterComp.meterOutL
            let emitCompOutR = self.masterComp.meterOutR
            let emitCompGR = self.masterComp.meterGRDb
            var sentPre: [Float]?
            var sentPost: [Float]?
            var sentAuto: [Float]?
            var sentLeveler: [Float]?
            var sentLevelerBoost: [Float]?
            var sentDeess: [Float]?
            var sentRTA: [Float]?
            if shouldEmit {
                self.lastRTABins = self.rta.computeBins(sampleRate: self.sampleRate)
                sentPre = self.meterPre
                sentPost = self.meterPost
                sentAuto = self.lastAutoGainDb
                sentLeveler = self.lastLevelerGRDb
                sentLevelerBoost = self.lastLevelerBoostDb
                sentDeess = self.lastDeessGRDb
                sentRTA = self.lastRTABins
                self.meterCounter = 0
                for i in 0..<min(slots, self.meterPre.count) { self.meterPre[i] = 0 }
                for i in 0..<min(slots, self.meterPost.count) { self.meterPost[i] = 0 }
                self.meterMasterL = 0
                self.meterMasterR = 0
                if meterFromInput {
                    self.livePeaks.decayAll(by: 0.6)
                }
            }
            let emitHead = head
            if shouldEmitHead {
                self.playheadEmitCounter = 0
            }
            let holdOpen = self.recording || self.inputMetering
            let ended = !holdOpen && self.frameCount > 0 && head >= total
            let emitLength = self.recording && (self.lengthEmitCounter >= Int(self.sampleRate / 4))
            if emitLength { self.lengthEmitCounter = 0 }
            let lengthCommitted = Int(self.recordFramesCommitted.load())
            let newLength = self.recording ? max(self.frameCount, punch + lengthCommitted) : self.frameCount
            if self.recording {
                self.lengthEmitCounter += n
            }
            self.lock.unlock()

            if shouldEmit, let sentPre, let sentPost, let sentAuto, let sentRTA, let sentLeveler, let sentLevelerBoost, let sentDeess {
                self.onMeters?(
                    sentPre, sentPost, emitL, emitR, sentAuto, sentRTA, sentLeveler, sentLevelerBoost, sentDeess,
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
        var startedSession: RecordSession?
        if wantsInput {
            let hooked = try connectSilentInput(engine)
            if recording, let folder = recordFolder {
                let session = try openRecordSession(
                    folder: folder,
                    punch: punch,
                    baseFrames: baseFrames,
                    channels: Int(hooked.format.channelCount),
                    inputRate: hooked.format.sampleRate,
                    deviceID: hooked.deviceID
                )
                startedSession = session
                recordSession = session
                waveformLock.lock()
                liveWaveform = session
                liveWaveformPunch = punch
                liveWaveformBaseFrames = baseFrames
                waveformLock.unlock()
                installRecordObservers(on: engine, session: session, deviceID: hooked.deviceID)
            }
            installInputTap(on: engine, format: hooked.format, session: startedSession)
        }
        recordingFlag.store(recording ? 1 : 0)
        inputTapActive.store(wantsInput ? 1 : 0)
        do {
            try engine.start()
        } catch {
            abandonStart(engine, session: startedSession)
            throw error
        }
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
        lock.unlock()

        recordingFlag.store(0)
        inputTapActive.store(0)
        let running = audioEngine
        if didInstallInputTap, let running {
            running.inputNode.removeTap(onBus: 0)
            recSilentMixer.map { running.disconnectNodeOutput($0) }
        }
        didInstallInputTap = false
        removeRecordObservers()
        running?.stop()
        if let node = sourceNode {
            running?.detach(node)
        }
        if let mixer = recSilentMixer {
            running?.detach(mixer)
        }
        sourceNode = nil
        recSilentMixer = nil
        audioEngine = nil
        freeTapScratch()

        lock.lock()
        recording = false
        inputMetering = false
        lock.unlock()

        if wasRecording, let session = recordSession {
            transferRenderLockMisses(to: session)
            var totals = RecordTotals()
            do {
                totals = try session.finish()
            } catch {
                totals = session.finishedTotals()
            }
            recordDropoutCount = totals.dropouts
            recordWriteFailures = totals.writeFailures
            let failed = mergeRecording(session)
            if !failed.isEmpty {
                // Keep the raw takes: no rename, no delete.
                let keep = Set(failed.map { session.folder.appendingPathComponent($0.file) })
                recordingFiles.removeAll { keep.contains($0) }
                for item in failed { renameRecording[item.voiceIndex] = nil }
                recordKeptFiles = failed.map(\.file)
            }
        }
        recordSession = nil
        waveformLock.lock()
        liveWaveform = nil
        waveformLock.unlock()
        if wasRecording {
            rebuildWaveformCache()
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

    func bounce(
        to folder: URL,
        plan: BounceWritePlan,
        progress: ((Double) -> Void)? = nil
    ) throws -> BounceResult {
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
            procs[i].deessListen = false
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
        let progressStep = max(1, total / 100)

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
                let gained = procs[c].inputGained(sample)
                let fx = procs[c].processEffects(gained)
                fxSamples[c] = fx
                levels[c] = abs(fx)
            }
            let autoGains = balancer.process(levels: levels, muted: muted, sampleRate: sr)
            for c in 0..<voiceN {
                let sample: Float = (c < voices.count && head < voices[c].count) ? voices[c][head] : 0
                pre = 0; post = 0
                let g = autoGains.indices.contains(c) ? autoGains[c] : 1
                let gained = procs[c].inputGained(sample)
                let (l, r) = procs[c].finishMono(
                    fxSamples[c],
                    autoMixGain: g,
                    inputPeak: gained,
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

            if head % progressStep == 0 || head + 1 == total {
                progress?(Double(head + 1) / Double(total))
            }
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
    /// A take that started on an empty strip at frame 0 is renamed from `Speaker_N.recording.wav`.
    func writeWorkingTakes(to folder: URL) throws -> [Int: URL] {
        lock.lock()
        let sr = sampleRate
        let voices = voiceBuffers
        let nums = speakerNumbers
        let renames = renameRecording
        lock.unlock()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [Int: URL] = [:]
        for (i, buf) in voices.enumerated() {
            let num = nums.indices.contains(i) ? nums[i] : (i + 1)
            let url = folder.appendingPathComponent("Speaker_\(num).wav")
            if let src = renames[i], FileManager.default.fileExists(atPath: src.path) {
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try FileManager.default.moveItem(at: src, to: url)
                    written[i] = url
                    continue
                } catch {
                    // Fall through and write the in-memory buffer.
                }
            }
            guard !buf.isEmpty else { continue }
            try WAVIO.write(
                url: url,
                buffer: .init(sampleRate: sr, channelCount: 1, samples: buf)
            )
            written[i] = url
        }
        return written
    }

    /// Removes leftover `Speaker_N.recording.wav` files after the canonical takes are saved.
    func deleteRecordingFiles() {
        for url in recordingFiles {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        recordingFiles = []
        renameRecording = [:]
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

    private func openRecordSession(
        folder: URL,
        punch: Int,
        baseFrames: Int,
        channels: Int,
        inputRate: Double,
        deviceID: AudioDeviceID
    ) throws -> RecordSession {
        let armed = armedList(punch: punch)
        let devices = MixerInputDevices.list()
        let input = devices.first { $0.uid == (inputDeviceUID ?? "") }
        let output = MixerInputDevices.defaultOutputDevice()
        let inRate = input?.nominalSampleRate ?? inputRate
        let outRate = output?.nominalSampleRate ?? 0
        let inUID = input?.uid ?? (inputDeviceUID ?? "")
        let outUID = output?.uid ?? ""
        let header = RecordLogHeader(
            startedAt: Date(),
            sampleRate: sampleRate,
            inputDeviceUID: inUID,
            inputDeviceName: input?.name ?? "",
            outputDeviceName: output?.name ?? "",
            inputNominalRate: inRate,
            outputNominalRate: outRate,
            clockDomainsDiffer: inUID != outUID || abs(inRate - outRate) > 0.5,
            punchStartFrame: punch,
            armed: armed
        )
        _ = deviceID
        let session = try RecordSession(
            folder: folder,
            sampleRate: sampleRate,
            inputSampleRate: inputRate,
            punchStartFrame: punch,
            baseFrameCount: baseFrames,
            armed: armed,
            hwChannels: channels,
            header: header,
            onDropouts: { [weak self] count in
                self?.onRecordDropouts?(count)
            }
        )
        recordingFiles = armed.map { folder.appendingPathComponent($0.file) }
        var renames: [Int: URL] = [:]
        for item in armed where item.renameWhenDone {
            renames[item.voiceIndex] = folder.appendingPathComponent(item.file)
        }
        renameRecording = renames
        return session
    }

    private func armedList(punch: Int) -> [RecordArmedChannel] {
        var list: [RecordArmedChannel] = []
        for index in recordMap.keys.sorted() {
            guard let hw = recordMap[index] else { continue }
            let num = speakerNumbers.indices.contains(index) ? speakerNumbers[index] : (index + 1)
            let empty = !voiceBuffers.indices.contains(index) || voiceBuffers[index].isEmpty
            list.append(RecordArmedChannel(
                voiceIndex: index,
                speakerNumber: num,
                hwChannel: hw,
                file: "Speaker_\(num).recording.wav",
                renameWhenDone: punch == 0 && empty
            ))
        }
        return list
    }

    private func connectSilentInput(_ engine: AVAudioEngine) throws -> (format: AVAudioFormat, deviceID: AudioDeviceID) {
        let deviceID = applyInputDevice(engine, uid: inputDeviceUID)
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
        prepareTapScratch(channels: Int(hwFormat.channelCount))
        livePeaks = RecordLivePeaks(count: max(voiceCount, 1))
        tapSessionRate = sampleRate
        tapInputRate = hwFormat.sampleRate
        return (hwFormat, deviceID)
    }

    private func installInputTap(on engine: AVAudioEngine, format: AVAudioFormat, session: RecordSession?) {
        engine.inputNode.installTap(onBus: 0, bufferSize: Self.recordTapFrames, format: format) { [weak self] buffer, when in
            self?.ingestRecordBuffer(buffer, when: when, session: session)
        }
        didInstallInputTap = true
    }

    private func installRecordObservers(on engine: AVAudioEngine, session: RecordSession, deviceID: AudioDeviceID) {
        removeRecordObservers()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            session.noteConfigChange()
        }
        guard deviceID != 0 else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            session.noteDeviceOverload()
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, nil, block) == noErr {
            overloadDevice = deviceID
            overloadBlock = block
        }
    }

    private func removeRecordObservers() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if overloadDevice != 0, let overloadBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDeviceProcessorOverload,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(overloadDevice, &address, nil, overloadBlock)
            self.overloadDevice = 0
            self.overloadBlock = nil
        }
    }

    private func abandonStart(_ engine: AVAudioEngine, session: RecordSession?) {
        recordingFlag.store(0)
        inputTapActive.store(0)
        if didInstallInputTap {
            engine.inputNode.removeTap(onBus: 0)
            didInstallInputTap = false
        }
        removeRecordObservers()
        engine.stop()
        freeTapScratch()
        if let session {
            transferRenderLockMisses(to: session)
            _ = try? session.finish()
            for item in session.armed {
                try? FileManager.default.removeItem(at: session.folder.appendingPathComponent(item.file))
            }
        }
        recordSession = nil
        waveformLock.lock()
        liveWaveform = nil
        waveformLock.unlock()
        lock.lock()
        recording = false
        inputMetering = false
        playing = false
        lock.unlock()
    }

    private func transferRenderLockMisses(to session: RecordSession) {
        let misses = renderLockMisses.load()
        let prev = transferredMisses.load()
        if misses > prev {
            session.addRenderLockMisses(misses - prev)
            transferredMisses.store(misses)
        }
    }

    private func prepareRenderScratchLocked() {
        let slots = max(1, meterSlotCount)
        let voices = max(1, voiceCount)
        if scratchPre.count != slots {
            scratchPre = [Float](repeating: 0, count: slots)
            scratchPost = [Float](repeating: 0, count: slots)
        }
        if scratchFX.count != voices {
            scratchFX = [Float](repeating: 0, count: voices)
            scratchLevels = [Float](repeating: 0, count: voices)
            scratchMuted = [Bool](repeating: false, count: voices)
            scratchAutoGains = [Float](repeating: 1, count: voices)
        }
        if lastAutoGainDb.count != voiceCount {
            lastAutoGainDb = [Float](repeating: 0, count: voiceCount)
        }
        if lastLevelerGRDb.count != voiceCount {
            lastLevelerGRDb = [Float](repeating: 0, count: voiceCount)
        }
        if lastLevelerBoostDb.count != voiceCount {
            lastLevelerBoostDb = [Float](repeating: 0, count: voiceCount)
        }
        if lastDeessGRDb.count != voiceCount {
            lastDeessGRDb = [Float](repeating: 0, count: voiceCount)
        }
        if meterPre.count != slots {
            meterPre = [Float](repeating: 0, count: slots)
            meterPost = [Float](repeating: 0, count: slots)
        }
    }

    private func applyArmedFlagsLocked() {
        if armedFlags.count != voiceCount {
            armedFlags = [Bool](repeating: false, count: voiceCount)
        } else {
            for i in armedFlags.indices { armedFlags[i] = false }
        }
        tapArmed.removeAll(keepingCapacity: true)
        for (index, hw) in recordMap where index >= 0 && index < armedFlags.count {
            armedFlags[index] = true
            tapArmed.append((voice: index, hw: hw))
        }
        tapArmed.sort { $0.voice < $1.voice }
    }

    private static func mixAuto(
        balancer: inout AutoBalancer,
        levels: inout [Float],
        muted: inout [Bool],
        gains: inout [Float],
        voiceN: Int,
        sampleRate: Double
    ) {
        let n = voiceN
        levels.withUnsafeBufferPointer { levelBuf in
            muted.withUnsafeBufferPointer { muteBuf in
                gains.withUnsafeMutableBufferPointer { gainBuf in
                    guard let levelPtr = levelBuf.baseAddress,
                          let mutePtr = muteBuf.baseAddress,
                          let gainPtr = gainBuf.baseAddress
                    else { return }
                    let count = min(n, levelBuf.count, muteBuf.count, gainBuf.count)
                    balancer.process(
                        levels: UnsafeBufferPointer(start: levelPtr, count: count),
                        muted: UnsafeBufferPointer(start: mutePtr, count: count),
                        sampleRate: sampleRate,
                        out: UnsafeMutableBufferPointer(start: gainPtr, count: count)
                    )
                }
            }
        }
    }

    private func prepareTapScratch(channels: Int) {
        freeTapScratch()
        let ch = max(1, channels)
        let frames = Self.tapScratchFrameCapacity
        let count = frames * ch
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: count)
        ptr.initialize(repeating: 0, count: count)
        tapScratch = ptr
        tapScratchFrames = frames
        tapScratchChannels = ch
        tapScratchCapacity = count
    }

    private func freeTapScratch() {
        if let tapScratch {
            tapScratch.deinitialize(count: tapScratchCapacity)
            tapScratch.deallocate()
        }
        tapScratch = nil
        tapScratchFrames = 0
        tapScratchChannels = 0
        tapScratchCapacity = 0
    }

    private func ingestRecordBuffer(_ buffer: AVAudioPCMBuffer, when: AVAudioTime, session: RecordSession?) {
        if inputTapActive.load() == 0 { return }
        let frames = Int(buffer.frameLength)
        if frames <= 0 { return }
        let ch = max(1, Int(buffer.format.channelCount))
        if let session {
            transferRenderLockMisses(to: session)
        }
        let srcRate = buffer.format.sampleRate
        let destRate = tapSessionRate
        let writing = recordingFlag.load() != 0 && session != nil
        if writing, let session, abs(srcRate - destRate) > 0.5, srcRate > 0, destRate > 0 {
            session.noteFormatChangeResample()
            let copied = copyInterleaved(buffer)
            copied.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                noteInputPeaks(base, frames: frames, channels: ch)
            }
            if let resampled = try? MixerAudioIO.resampleInterleaved(copied, channels: ch, from: srcRate, to: destRate) {
                let outFrames = ch > 0 ? resampled.count / ch : 0
                ingestResampled(
                    session,
                    resampled,
                    channels: ch,
                    outFrames: outFrames,
                    inputFrames: frames,
                    sampleTime: when.isSampleTimeValid ? when.sampleTime : 0,
                    sampleTimeValid: when.isSampleTimeValid
                )
            }
            recordFramesCommitted.store(session.framesCommitted)
            return
        }
        guard let scratch = tapScratch, tapScratchFrames > 0 else { return }
        if ch != tapScratchChannels {
            // Input channel count changed mid-take: can't map strips safely. Log it (once) and skip the buffer.
            if writing, let session { session.noteChannelCountChange(channels: ch) }
            return
        }
        let valid = when.isSampleTimeValid
        var offset = 0
        while offset < frames {
            let n = min(tapScratchFrames, frames - offset)
            writeInterleaved(from: buffer, start: offset, frames: n, channels: ch, into: scratch)
            noteInputPeaks(scratch, frames: n, channels: ch)
            if writing, let session {
                let time = valid ? when.sampleTime + Int64(offset) : 0
                session.ingest(interleaved: scratch, frames: n, sampleTime: time, sampleTimeValid: valid)
            }
            offset += n
        }
        if writing, let session {
            recordFramesCommitted.store(session.framesCommitted)
        }
    }

    private func ingestResampled(
        _ session: RecordSession,
        _ resampled: [Float],
        channels: Int,
        outFrames: Int,
        inputFrames: Int,
        sampleTime: Int64,
        sampleTimeValid: Bool
    ) {
        let plan = session.beginInputBuffer(
            sampleTime: sampleTime,
            sampleTimeValid: sampleTimeValid,
            inputFrames: inputFrames
        )
        if plan.ignore { return }
        if plan.zeroSessionFrames > 0 {
            session.writeTimelineZeros(plan.zeroSessionFrames)
        }
        let dropIn = min(max(0, plan.dropInputFrames), inputFrames)
        var dropOut = 0
        if inputFrames > 0, dropIn > 0 {
            dropOut = Int((Double(dropIn) * Double(outFrames) / Double(inputFrames)).rounded())
            if dropOut > outFrames { dropOut = outFrames }
        }
        let keep = outFrames - dropOut
        if keep > 0 {
            resampled.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                session.writeTimelineAudio(base.advanced(by: dropOut * channels), frames: keep)
            }
        }
    }

    private func noteInputPeaks(_ src: UnsafePointer<Float>, frames: Int, channels: Int) {
        for arm in tapArmed {
            if arm.hw < 0 || arm.hw >= channels || arm.voice < 0 { continue }
            var peak: Float = 0
            let hw = arm.hw
            for f in 0..<frames {
                let sample = src[f * channels + hw]
                let mag = sample < 0 ? -sample : sample
                if mag > peak { peak = mag }
            }
            let prev = livePeaks.load(index: arm.voice)
            if peak > prev {
                livePeaks.store(index: arm.voice, peak: peak)
            }
        }
    }

    private func copyInterleaved(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let ch = max(1, Int(buffer.format.channelCount))
        var out = [Float](repeating: 0, count: frames * ch)
        out.withUnsafeMutableBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            writeInterleaved(from: buffer, start: 0, frames: frames, channels: ch, into: base)
        }
        return out
    }

    private func writeInterleaved(
        from buffer: AVAudioPCMBuffer,
        start: Int,
        frames: Int,
        channels: Int,
        into dst: UnsafeMutablePointer<Float>
    ) {
        let ch = channels
        if let planar = buffer.floatChannelData {
            for f in 0..<frames {
                let src = start + f
                for c in 0..<ch {
                    dst[f * ch + c] = planar[c][src]
                }
            }
            return
        }
        if let planar = buffer.int16ChannelData {
            for f in 0..<frames {
                let src = start + f
                for c in 0..<ch {
                    dst[f * ch + c] = Float(planar[c][src]) / 32768.0
                }
            }
            return
        }
        if let planar = buffer.int32ChannelData {
            for f in 0..<frames {
                let src = start + f
                for c in 0..<ch {
                    dst[f * ch + c] = Float(planar[c][src]) / Float(Int32.max)
                }
            }
            return
        }
        if buffer.format.isInterleaved, let data = buffer.audioBufferList.pointee.mBuffers.mData {
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                let ptr = data.assumingMemoryBound(to: Float.self).advanced(by: start * ch)
                dst.update(from: ptr, count: frames * ch)
            case .pcmFormatInt16:
                let ptr = data.assumingMemoryBound(to: Int16.self).advanced(by: start * ch)
                let n = frames * ch
                for i in 0..<n {
                    dst[i] = Float(ptr[i]) / 32768.0
                }
            case .pcmFormatInt32:
                let ptr = data.assumingMemoryBound(to: Int32.self).advanced(by: start * ch)
                let scale = Float(Int32.max)
                let n = frames * ch
                for i in 0..<n {
                    dst[i] = Float(ptr[i]) / scale
                }
            default:
                let n = frames * ch
                for i in 0..<n { dst[i] = 0 }
            }
            return
        }
        let n = frames * ch
        for i in 0..<n { dst[i] = 0 }
    }

    /// Returns the armed takes that could not be loaded (their `.recording.wav` must be kept).
    @discardableResult
    private func mergeRecording(_ session: RecordSession) -> [RecordArmedChannel] {
        var failed: [RecordArmedChannel] = []
        let punch = max(0, session.punchStartFrame)
        lock.lock()
        var voices = voiceBuffers
        lock.unlock()
        var longest = 0
        for item in session.armed {
            let url = session.folder.appendingPathComponent(item.file)
            guard let take = try? WAVIO.load(url: url) else {
                failed.append(item)
                continue
            }
            let samples = Self.monoTake(take)
            let old = item.voiceIndex < voices.count ? voices[item.voiceIndex] : []
            let merged = Self.spliceTake(old: old, punch: punch, take: samples)
            while voices.count <= item.voiceIndex {
                voices.append([])
            }
            voices[item.voiceIndex] = merged
            if merged.count > longest { longest = merged.count }
        }
        lock.lock()
        for buf in voices where buf.count > longest {
            longest = buf.count
        }
        voiceBuffers = voices
        if longest > frameCount {
            ensureCapacityLocked(longest)
        } else if longest > 0 {
            frameCount = max(frameCount, longest)
        }
        lock.unlock()
        return failed
    }

    private static func monoTake(_ buffer: WAVIO.Buffer) -> [Float] {
        if buffer.channelCount <= 1 { return buffer.samples }
        let ch = buffer.channelCount
        var mono: [Float] = []
        mono.reserveCapacity(buffer.frameCount)
        for f in 0..<buffer.frameCount {
            mono.append(buffer.samples[f * ch])
        }
        return mono
    }

    private static func spliceTake(old: [Float], punch: Int, take: [Float]) -> [Float] {
        let punch = max(0, punch)
        var merged: [Float] = []
        merged.reserveCapacity(max(old.count, punch + take.count))
        let prefix = min(punch, old.count)
        if prefix > 0 {
            merged.append(contentsOf: old[..<prefix])
        }
        if punch > prefix {
            merged.append(contentsOf: repeatElement(Float(0), count: punch - prefix))
        }
        merged.append(contentsOf: take)
        let resume = punch + take.count
        if old.count > resume {
            merged.append(contentsOf: old[resume...])
        }
        return merged
    }

    @discardableResult
    private func applyInputDevice(_ engine: AVAudioEngine, uid: String?) -> AudioDeviceID {
        guard let uid,
              let device = MixerInputDevices.list().first(where: { $0.uid == uid })
        else { return 0 }
        var id = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard let audioUnit = engine.inputNode.audioUnit else { return device.id }
        _ = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            size
        )
        return device.id
    }
}

final class UnfairLock: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    init() {
        pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    func lock() { os_unfair_lock_lock(pointer) }
    func unlock() { os_unfair_lock_unlock(pointer) }
    func tryLock() -> Bool { os_unfair_lock_trylock(pointer) }
}
