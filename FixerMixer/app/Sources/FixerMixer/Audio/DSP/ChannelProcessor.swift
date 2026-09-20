import Foundation

/// Public auto-mix modes. Never surface “Dugan” in product UI.
enum AutoMixMode: String, Codable, CaseIterable, Equatable {
    /// Manual faders only.
    case off
    /// Per-channel vocal rider around each channel’s manual baseline.
    case mix
    /// Proportional gain-sharing: G_i = L_i / L_sum (baseline-weighted).
    case duck

    var isActive: Bool { self != .off }

    var shortLabel: String {
        switch self {
        case .off: return "OFF"
        case .mix: return "MIX"
        case .duck: return "DUCK"
        }
    }
}

/// Cross-channel auto-mixer: baseline-relative **Mix** or proportional **Duck**.
/// Silent / excluded channels release to unity (no noise boost). Music is never included.
/// Expansion (gain up) in Mix mode is intentionally slow/mild so speech pauses don’t pump.
/// Manual baselines live in `faderDb` on the strip; auto gain here is purely additive while active.
struct AutoBalancer {
    var mode: AutoMixMode = .off
    /// Per-voice pool membership. Missing / short arrays treat as included.
    var included: [Bool] = []
    /// Manual fader baselines (dB). Mix rides around these; Duck weights detectors by them.
    var baselineDb: [Float] = []
    /// Duck only: max attenuation below unity (0 = no duck, …). Default mild.
    var maxAttenuationDb: Float = 9
    /// Internal Mix comfort level (not exposed in UI). Channel target = this + baselineDb.
    private let mixBaseTargetDb: Float = -18

    private var envs: [Float] = []
    private var gains: [Float] = []

    var enabled: Bool {
        get { mode.isActive }
        set { if !newValue { mode = .off } else if mode == .off { mode = .mix } }
    }

    mutating func resize(to n: Int) {
        guard envs.count != n else { return }
        envs = Array(repeating: 0, count: n)
        gains = Array(repeating: 1, count: n)
        if included.count < n {
            included.append(contentsOf: Array(repeating: true, count: n - included.count))
        } else if included.count > n {
            included = Array(included.prefix(n))
        }
        if baselineDb.count < n {
            baselineDb.append(contentsOf: Array(repeating: Float(0), count: n - baselineDb.count))
        } else if baselineDb.count > n {
            baselineDb = Array(baselineDb.prefix(n))
        }
    }

    mutating func reset() {
        for i in envs.indices {
            envs[i] = 0
            gains[i] = 1
        }
    }

    /// `levels` = absolute amplitude of each voice (post-FX, pre-auto/fader).
    mutating func process(levels: [Float], muted: [Bool], sampleRate: Double) -> [Float] {
        let n = levels.count
        resize(to: n)
        if !mode.isActive || n == 0 {
            for i in gains.indices { gains[i] = 1 }
            return Array(gains.prefix(n))
        }
        switch mode {
        case .off:
            for i in gains.indices { gains[i] = 1 }
            return Array(gains.prefix(n))
        case .mix:
            return processMix(levels: levels, muted: muted, sampleRate: sampleRate)
        case .duck:
            return processDuck(levels: levels, muted: muted, sampleRate: sampleRate)
        }
    }

    private func isIncluded(_ i: Int) -> Bool {
        guard included.indices.contains(i) else { return true }
        return included[i]
    }

    private func baseline(at i: Int) -> Float {
        guard baselineDb.indices.contains(i) else { return 0 }
        return baselineDb[i]
    }

    private mutating func processMix(levels: [Float], muted: [Bool], sampleRate: Double) -> [Float] {
        let n = levels.count
        // Envelope: slow release so brief pauses don’t look like “quiet talker”
        let envAtk = exp(-1.0 / (0.05 * Float(sampleRate)))
        let envRel = exp(-1.0 / (1.10 * Float(sampleRate)))
        let gate: Float = 0.012

        // Asymmetric gain ride: slow expand, faster cut
        let expandSmooth = exp(-1.0 / (1.25 * Float(sampleRate)))
        let cutSmooth = exp(-1.0 / (0.40 * Float(sampleRate)))
        let unitySmooth = exp(-1.0 / (0.90 * Float(sampleRate)))

        let maxBoostDb: Float = 5.5
        let maxCutDb: Float = 10
        let strength: Float = 0.5 // only correct half the error

        for i in 0..<n {
            if (muted.indices.contains(i) && muted[i]) || !isIncluded(i) {
                envs[i] *= envRel
                gains[i] = unitySmooth * gains[i] + (1 - unitySmooth) * 1
                continue
            }
            let x = levels[i]
            if x > envs[i] {
                envs[i] = envAtk * envs[i] + (1 - envAtk) * x
            } else {
                envs[i] = envRel * envs[i] + (1 - envRel) * x
            }

            if envs[i] <= gate {
                gains[i] = unitySmooth * gains[i] + (1 - unitySmooth) * 1
                continue
            }

            // Ride around this channel’s baseline weighting (no shared TARGET knob).
            let targetDb = mixBaseTargetDb + baseline(at: i)
            let currentDb = 20 * log10(max(envs[i], 1e-6))
            let error = (targetDb - currentDb) * strength
            let correction = max(-maxCutDb, min(maxBoostDb, error))
            let desired = pow(10.0, correction / 20.0)

            if Float(desired) > gains[i] {
                gains[i] = expandSmooth * gains[i] + (1 - expandSmooth) * Float(desired)
            } else {
                gains[i] = cutSmooth * gains[i] + (1 - cutSmooth) * Float(desired)
            }
        }
        return Array(gains.prefix(n))
    }

    /// Proportional gain-sharing: G_i = L_i_weighted / (L_sum + ε).
    /// Detectors are weighted by baseline linear gain so hotter faders win more share.
    /// `maxAttenuationDb` floors how far a channel can be pulled below unity.
    /// When the pool is silent, share medium gains that sum ≈ unity (not gates / not all-zero).
    private mutating func processDuck(levels: [Float], muted: [Bool], sampleRate: Double) -> [Float] {
        let n = levels.count
        // Faster than the first Duck ship (~30/250/80 ms → ~15/180/30 ms).
        let envAtk = exp(-1.0 / (0.015 * Float(sampleRate)))
        let envRel = exp(-1.0 / (0.18 * Float(sampleRate)))
        let gainSmooth = exp(-1.0 / (0.030 * Float(sampleRate)))
        let epsilon: Float = 1e-4
        let floorLin = pow(10.0, -max(0, maxAttenuationDb) / 20.0)

        var poolIndices: [Int] = []
        poolIndices.reserveCapacity(n)
        for i in 0..<n {
            let x = levels[i]
            if x > envs[i] {
                envs[i] = envAtk * envs[i] + (1 - envAtk) * x
            } else {
                envs[i] = envRel * envs[i] + (1 - envRel) * x
            }
            let inPool = isIncluded(i) && !(muted.indices.contains(i) && muted[i])
            if inPool {
                poolIndices.append(i)
            } else {
                // Excluded / muted: unity (not in the share).
                gains[i] = gainSmooth * gains[i] + (1 - gainSmooth) * 1
            }
        }

        guard !poolIndices.isEmpty else {
            return Array(gains.prefix(n))
        }

        var weighted: [Float] = Array(repeating: 0, count: poolIndices.count)
        var sum: Float = 0
        for (k, i) in poolIndices.enumerated() {
            let w = pow(10.0, baseline(at: i) / 20.0)
            let lw = envs[i] * w
            weighted[k] = lw
            sum += lw
        }

        let desired: [Float]
        if sum <= epsilon {
            // Shared medium gains summing ~unity — equal weights MVP.
            let share = 1.0 / Float(poolIndices.count)
            desired = poolIndices.map { _ in max(share, floorLin) }
        } else {
            let denom = sum + epsilon
            desired = weighted.map { max($0 / denom, floorLin) }
        }

        for (k, i) in poolIndices.enumerated() {
            let d = desired[k]
            gains[i] = gainSmooth * gains[i] + (1 - gainSmooth) * d
        }
        return Array(gains.prefix(n))
    }
}

/// Per-channel processing chain used for preview and bounce.
struct ChannelProcessor {
    var isStereo: Bool
    var hasVoiceFX: Bool
    var mute: Bool = false
    var solo: Bool = false
    var faderDb: Float = 0
    var pan: Float = 0
    var dspBypass: Bool = false
    var eqGains: [Float] = Array(repeating: 0, count: 10)
    var eqBypass: Bool = false
    var eqHpfHz: Float = 0
    var paraFreqHz: Float = 1_000
    var paraGainDb: Float = 0
    var paraWidth: ParaEQWidth = .narrow
    var paraBypass: Bool = false
    var paraPlacement: ParaEQPlacement = .post

    var deVerbAmount: Float = 0
    var deVerbBypass: Bool = false
    var wetterAmount: Float = 0
    var wetterBypass: Bool = false
    var wetterRoom: WetterRoom = .drumRoom
    var levelerDrive: Float = 0
    var levelerTargetDb: Float = -6
    var levelerBypass: Bool = false
    var dspOrder: [ChannelDSPSlot] = ChannelDSPSlot.voiceDefault

    private var eqL = GraphicEQ()
    private var eqR = GraphicEQ()
    private var hpfL = HighPass24DSP()
    private var hpfR = HighPass24DSP()
    private var para = ParaEQDSP()
    private var deVerb = DeVerbDSP()
    private var wetter = WetterDSP()
    private var leveler = LevelerDSP()
    private var sampleRate: Double = 44100

    /// Live Leveler gain-reduction (dB ≥ 0) for the selected-channel GR meter.
    var levelerMeterGRDb: Float { leveler.meterGRDb }

    init(isStereo: Bool, hasVoiceFX: Bool) {
        self.isStereo = isStereo
        self.hasVoiceFX = hasVoiceFX
        self.dspOrder = hasVoiceFX ? ChannelDSPSlot.voiceDefault : ChannelDSPSlot.musicDefault
    }

    mutating func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        eqL.configure(sampleRate: sampleRate, gainsDb: eqGains)
        eqR.configure(sampleRate: sampleRate, gainsDb: eqGains)
        hpfL.cutoffHz = eqHpfHz
        hpfR.cutoffHz = eqHpfHz
        hpfL.configure(sampleRate: sampleRate)
        hpfR.configure(sampleRate: sampleRate)
        if hasVoiceFX {
            para.freqHz = paraFreqHz
            para.gainDb = paraGainDb
            para.width = paraWidth
            para.bypass = paraBypass || dspBypass
            para.configure(sampleRate: sampleRate)
            deVerb.configure(sampleRate: sampleRate)
            wetter.room = wetterRoom
            wetter.configure(sampleRate: sampleRate)
            deVerb.amount = deVerbAmount
            deVerb.bypass = deVerbBypass || dspBypass
            wetter.amount = wetterAmount
            wetter.bypass = wetterBypass || dspBypass
            leveler.drive = levelerDrive
            leveler.targetDb = levelerTargetDb
            leveler.bypass = levelerBypass || dspBypass
        }
    }

    mutating func reset() {
        eqL.reset()
        eqR.reset()
        hpfL.reset()
        hpfR.reset()
        para.reset()
        deVerb.reset()
        wetter.reset()
        leveler.reset()
    }

    /// Graphic + HPF (+ optional para) for the `.eq` slot. Order: para PRE → HPF → graphic → para POST.
    private mutating func processEQSlot(_ x: Float, useLeft: Bool) -> Float {
        var y = x
        let paraPre = hasVoiceFX && !paraBypass && paraPlacement == .pre
        let paraPost = hasVoiceFX && !paraBypass && paraPlacement == .post
        if paraPre { y = para.process(y) }
        if !eqBypass {
            if useLeft {
                y = hpfL.process(y)
                y = eqL.process(y)
            } else {
                y = hpfR.process(y)
                y = eqR.process(y)
            }
        }
        if paraPost { y = para.process(y) }
        return y
    }

    /// FX only, in this channel’s `dspOrder`. Mute returns 0.
    mutating func processEffects(_ x: Float) -> Float {
        if mute { return 0 }
        var y = x
        if dspBypass { return y }
        let order = dspOrder.isEmpty
            ? (hasVoiceFX ? ChannelDSPSlot.voiceDefault : ChannelDSPSlot.musicDefault)
            : dspOrder
        for slot in order {
            switch slot {
            case .eq:
                y = processEQSlot(y, useLeft: true)
            case .deVerb:
                if hasVoiceFX { y = deVerb.process(y, sampleRate: sampleRate) }
            case .wetter:
                if hasVoiceFX { y = wetter.process(y, sampleRate: sampleRate) }
            case .leveler:
                if hasVoiceFX { y = leveler.process(y, sampleRate: sampleRate) }
            }
        }
        return y
    }

    /// Auto-mix gain → fader → pan. `inputPeak` is usually the raw stem sample.
    mutating func finishMono(
        _ fx: Float,
        autoMixGain: Float,
        inputPeak: Float,
        prePeak: inout Float,
        postPeak: inout Float
    ) -> (Float, Float) {
        prePeak = max(prePeak, abs(inputPeak))
        if mute {
            postPeak = max(postPeak, 0)
            return (0, 0)
        }
        var y = fx * autoMixGain
        y *= pow(10.0, faderDb / 20.0)
        let angle = (pan + 1) * Float.pi / 4
        let l = y * cos(angle)
        let r = y * sin(angle)
        postPeak = max(postPeak, max(abs(l), abs(r)))
        return (l, r)
    }

    /// Process one mono sample → stereo L/R (no auto-mix).
    mutating func processMono(_ x: Float, prePeak: inout Float, postPeak: inout Float) -> (Float, Float) {
        let fx = processEffects(x)
        return finishMono(fx, autoMixGain: 1, inputPeak: x, prePeak: &prePeak, postPeak: &postPeak)
    }

    /// Process stereo frame → stereo out.
    mutating func processStereo(_ xl: Float, _ xr: Float, prePeak: inout Float, postPeak: inout Float) -> (Float, Float) {
        prePeak = max(prePeak, max(abs(xl), abs(xr)))
        if mute {
            return (0, 0)
        }
        var l = xl
        var r = xr
        if !dspBypass {
            // Stereo beds: HPF + graphic only (no para).
            if !eqBypass {
                l = hpfL.process(xl)
                r = hpfR.process(xr)
                l = eqL.process(l)
                r = eqR.process(r)
            }
        }
        let g = pow(10.0, faderDb / 20.0)
        l *= g
        r *= g
        let leftGain = min(1, max(0, 1 - pan))
        let rightGain = min(1, max(0, 1 + pan))
        l *= leftGain
        r *= rightGain
        postPeak = max(postPeak, max(abs(l), abs(r)))
        return (l, r)
    }
}

struct MixerParamsSnapshot {
    var voices: [ChannelProcessor]
    var stereos: [ChannelProcessor]
    var masterGain: Float
}
