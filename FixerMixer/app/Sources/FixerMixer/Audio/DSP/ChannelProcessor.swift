import Foundation

/// Cross-channel podcast auto-mixer: rides each active speaker toward a shared target level.
/// Silent channels release to unity (no noise boost). Music is never included.
/// Expansion (gain up) is intentionally slow/mild so speech pauses don’t pump.
struct AutoBalancer {
    var enabled: Bool = false
    var targetDb: Float = -18

    private var envs: [Float] = []
    private var gains: [Float] = []

    mutating func resize(to n: Int) {
        guard envs.count != n else { return }
        envs = Array(repeating: 0, count: n)
        gains = Array(repeating: 1, count: n)
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
        if !enabled || n == 0 {
            for i in gains.indices { gains[i] = 1 }
            return Array(gains.prefix(n))
        }

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
            if muted.indices.contains(i), muted[i] {
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
}

/// Per-channel processing chain used for preview and bounce.
struct ChannelProcessor {
    var isStereo: Bool
    var hasVoiceFX: Bool
    var mute: Bool = false
    var faderDb: Float = 0
    var pan: Float = 0
    var dspBypass: Bool = false
    var eqGains: [Float] = Array(repeating: 0, count: 10)
    var eqBypass: Bool = false
    var paraFreqHz: Float = 1_000
    var paraGainDb: Float = 0
    var paraWidth: ParaEQWidth = .narrow
    var paraBypass: Bool = false

    var deVerbAmount: Float = 0
    var deVerbBypass: Bool = false
    var wetterAmount: Float = 0
    var wetterBypass: Bool = false
    var levelerDrive: Float = 0
    var levelerTargetDb: Float = -18
    var levelerBypass: Bool = false
    var dspOrder: [ChannelDSPSlot] = ChannelDSPSlot.voiceDefault

    private var eqL = GraphicEQ()
    private var eqR = GraphicEQ()
    private var para = ParaEQDSP()
    private var deVerb = DeVerbDSP()
    private var wetter = WetterDSP()
    private var leveler = LevelerDSP()
    private var sampleRate: Double = 44100

    init(isStereo: Bool, hasVoiceFX: Bool) {
        self.isStereo = isStereo
        self.hasVoiceFX = hasVoiceFX
        self.dspOrder = hasVoiceFX ? ChannelDSPSlot.voiceDefault : ChannelDSPSlot.musicDefault
    }

    mutating func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        eqL.configure(sampleRate: sampleRate, gainsDb: eqGains)
        eqR.configure(sampleRate: sampleRate, gainsDb: eqGains)
        if hasVoiceFX {
            para.freqHz = paraFreqHz
            para.gainDb = paraGainDb
            para.width = paraWidth
            para.bypass = paraBypass || dspBypass
            para.configure(sampleRate: sampleRate)
            deVerb.configure(sampleRate: sampleRate)
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
        para.reset()
        deVerb.reset()
        wetter.reset()
        leveler.reset()
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
                if !eqBypass { y = eqL.process(y) }
                if hasVoiceFX && !paraBypass { y = para.process(y) }
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
        if !dspBypass && !eqBypass {
            l = eqL.process(xl)
            r = eqR.process(xr)
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
    var music: ChannelProcessor
    var masterGain: Float
}
