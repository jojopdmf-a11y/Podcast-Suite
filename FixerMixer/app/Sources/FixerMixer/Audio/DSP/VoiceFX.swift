import Foundation

/// MV2-style leveler. DRIVE is upward compression (quiet parts up, loud parts left alone).
/// LIMITER is downward only — no make-up — then a fixed −1 dBFS safety ceiling.
/// GATE, when on, keeps the DRIVE boost off silence and room noise.
/// Gains are one-pole smoothed so knob moves and the gate do not click.
struct LevelerDSP {
    /// 0…+24 dB of upward compression.
    var driveDb: Float = 0
    /// Downward threshold, 0…−24 dB.
    var limiterDb: Float = 0
    var gateEnabled: Bool = true
    var bypass: Bool = false
    /// Downward gain reduction in dB (≥ 0). UI GR meter.
    private(set) var meterGRDb: Float = 0
    /// Upward boost actually applied, in dB (≥ 0). UI BOOST meter.
    private(set) var meterBoostDb: Float = 0

    private var envUp: Float = 0
    private var envGate: Float = 0
    private var envDown: Float = 0
    private var boostLin: Float = 1
    private var compLin: Float = 1

    // Levels above this are not boosted. DRIVE raises quieter audio toward it, up to +24 dB.
    private let pivotDb: Float = -12
    // Gate is fully open at and above −46 dBFS, fully closed at −62, gentle in between.
    private let gateOpenDb: Float = -46
    private let gateClosedDb: Float = -62
    /// Extra cut (dB) applied when the gate is fully closed, on top of cancelling the boost.
    private let gateClosedCutDb: Float = 8
    private let limiterRatio: Float = 20
    private let limiterKneeDb: Float = 4
    private let safetyCeilingDb: Float = -1

    mutating func reset() {
        envUp = 0
        envGate = 0
        envDown = 0
        boostLin = 1
        compLin = 1
        meterGRDb = 0
        meterBoostDb = 0
    }

    mutating func process(_ x: Float, sampleRate: Double) -> Float {
        let sr = Float(max(1, sampleRate))
        if bypass {
            meterGRDb *= 0.9
            meterBoostDb *= 0.9
            boostLin += (1 - boostLin) * 0.002
            compLin += (1 - compLin) * 0.002
            return x
        }

        let absx = abs(x)
        Self.follow(&envUp, absx, attack: 0.010, release: 0.120, sampleRate: sr)
        Self.follow(&envGate, absx, attack: 0.008, release: 0.350, sampleRate: sr)

        var desiredBoostDb: Float = 0
        let upDb = Self.ampToDb(envUp)
        let drive = min(24, max(0, driveDb))
        if drive > 0.05, upDb < pivotDb {
            desiredBoostDb = min(drive, pivotDb - upDb)
        }

        var gateCutDb: Float = 0
        if gateEnabled, drive > 0.05 {
            let closure = gateClosure(Self.ampToDb(envGate))
            desiredBoostDb *= (1 - closure)
            gateCutDb = gateClosedCutDb * closure
        }

        let desiredBoostLin = Self.dbToAmp(desiredBoostDb - gateCutDb)
        let boostSmooth = exp(Float(-1) / (0.025 * sr))
        boostLin = boostSmooth * boostLin + (1 - boostSmooth) * desiredBoostLin
        var y = x * boostLin

        Self.follow(&envDown, abs(y), attack: 0.002, release: 0.080, sampleRate: sr)
        let thresh = min(0, max(-24, limiterDb))
        let grDb = downwardGRDb(peakDb: Self.ampToDb(envDown), thresholdDb: thresh)
        // Attenuation only. A lower threshold never raises the level.
        let desiredComp = Self.dbToAmp(grDb)
        let atk = exp(Float(-1) / (0.003 * sr))
        let rel = exp(Float(-1) / (0.120 * sr))
        if desiredComp < compLin {
            compLin = atk * compLin + (1 - atk) * desiredComp
        } else {
            compLin = rel * compLin + (1 - rel) * desiredComp
        }
        y *= compLin

        let ceiling = Self.dbToAmp(safetyCeilingDb)
        y = ceiling * tanhf(y / max(ceiling, 1e-4))

        meterBoostDb = max(0, 20 * log10(max(boostLin, 1e-6)))
        // GR follows the smoothed limiter gain. That gain is only reduction.
        meterGRDb = max(0, -Self.ampToDb(min(compLin, 1)))
        return y
    }

    private func gateClosure(_ levelDb: Float) -> Float {
        if levelDb >= gateOpenDb { return 0 }
        if levelDb <= gateClosedDb { return 1 }
        return (gateOpenDb - levelDb) / (gateOpenDb - gateClosedDb)
    }

    /// Soft-knee downward gain reduction in dB (≤ 0).
    private func downwardGRDb(peakDb: Float, thresholdDb: Float) -> Float {
        let knee = limiterKneeDb
        let ratio = limiterRatio
        let kneeLow = thresholdDb - knee / 2
        let kneeHigh = thresholdDb + knee / 2
        if peakDb <= kneeLow { return 0 }
        if peakDb < kneeHigh {
            let xk = peakDb - thresholdDb + knee / 2
            return ((1 / ratio - 1) * (xk * xk)) / (2 * knee)
        }
        return (thresholdDb - peakDb) * (1 - 1 / ratio)
    }

    private static func follow(_ env: inout Float, _ x: Float, attack: Float, release: Float, sampleRate sr: Float) {
        let coeff = exp(Float(-1) / ((x > env ? attack : release) * sr))
        env = coeff * env + (1 - coeff) * x
    }

    private static func ampToDb(_ amp: Float) -> Float {
        20 * log10(max(amp, 1e-8))
    }

    private static func dbToAmp(_ db: Float) -> Float {
        pow(Float(10), db / 20)
    }
}

/// Small-space voice reverb. Three tones, all short of a hall — just air for dry podcast mics.
struct WetterDSP {
    var amount: Float = 0
    var bypass: Bool = false
    var room: WetterRoom = .drumRoom
    private var combBufs: [[Float]] = []
    private var combPos: [Int] = []
    private var combDamp: [Float] = []
    private var apBufs: [[Float]] = []
    private var allpassPos: [Int] = []
    private var earlyBuf: [Float] = []
    private var earlyPos: Int = 0
    private var configuredRate: Double = 0
    private var configuredRoom: WetterRoom?

    mutating func configure(sampleRate: Double) {
        let rateChanged = abs(configuredRate - sampleRate) > 0.5
        let roomChanged = configuredRoom != room
        guard rateChanged || roomChanged || combBufs.isEmpty else { return }
        configuredRate = sampleRate
        configuredRoom = room
        rebuildCombs(sampleRate: sampleRate)
    }

    private struct Tone {
        var combMs: [Double]
        var apMs: [Double]
        var earlyMs: Double
        var feedback: Float
        var dampCoeff: Float
        var combGain: Float
        var earlyGain: Float
        var apGain: Float
    }

    private var tone: Tone {
        switch room {
        case .drumRoom:
            // Original Wetter: bright, punchy, still short.
            return Tone(
                combMs: [17.9, 22.3, 26.1, 29.7, 33.3],
                apMs: [4.7, 2.3, 1.1],
                earlyMs: 12,
                feedback: 0.58,
                dampCoeff: 0.12,
                combGain: 0.72,
                earlyGain: 0.45,
                apGain: 0.62
            )
        case .studio:
            // Treated booth / control-room air. Tighter, warmer, less slap.
            return Tone(
                combMs: [11.3, 13.9, 16.7, 19.1, 21.8],
                apMs: [3.1, 1.7, 0.9],
                earlyMs: 7,
                feedback: 0.38,
                dampCoeff: 0.38,
                combGain: 0.88,
                earlyGain: 0.20,
                apGain: 0.52
            )
        case .stage:
            // Small live floor / club talker. A little more space, not a hall.
            return Tone(
                combMs: [23.1, 28.4, 34.2, 39.6, 44.8],
                apMs: [6.8, 3.4, 1.8],
                earlyMs: 18,
                feedback: 0.44,
                dampCoeff: 0.24,
                combGain: 0.78,
                earlyGain: 0.34,
                apGain: 0.58
            )
        }
    }

    private mutating func rebuildCombs(sampleRate: Double) {
        let t = tone
        combBufs = t.combMs.map { Array(repeating: 0, count: max(1, Int(sampleRate * $0 / 1000.0))) }
        combPos = Array(repeating: 0, count: combBufs.count)
        combDamp = Array(repeating: 0, count: combBufs.count)
        apBufs = t.apMs.map { Array(repeating: 0, count: max(1, Int(sampleRate * $0 / 1000.0))) }
        allpassPos = Array(repeating: 0, count: apBufs.count)
        earlyBuf = Array(repeating: 0, count: max(1, Int(sampleRate * t.earlyMs / 1000.0)))
        earlyPos = 0
    }

    mutating func reset() {
        for i in combBufs.indices { combBufs[i] = Array(repeating: 0, count: combBufs[i].count) }
        for i in apBufs.indices { apBufs[i] = Array(repeating: 0, count: apBufs[i].count) }
        combPos = Array(repeating: 0, count: combBufs.count)
        combDamp = Array(repeating: 0, count: combBufs.count)
        allpassPos = Array(repeating: 0, count: apBufs.count)
        earlyBuf = Array(repeating: 0, count: earlyBuf.count)
        earlyPos = 0
    }

    mutating func process(_ x: Float, sampleRate: Double) -> Float {
        configure(sampleRate: sampleRate)
        if bypass || amount < 0.001 { return x }
        if combBufs.isEmpty { rebuildCombs(sampleRate: sampleRate) }

        let t = tone
        let early = earlyBuf.isEmpty ? 0 : earlyBuf[earlyPos]
        if !earlyBuf.isEmpty {
            earlyBuf[earlyPos] = x
            earlyPos += 1
            if earlyPos >= earlyBuf.count { earlyPos = 0 }
        }

        var sum: Float = 0
        for i in combBufs.indices {
            let n = combBufs[i].count
            var p = combPos[i]
            let delayed = combBufs[i][p]
            combDamp[i] = delayed + (combDamp[i] - delayed) * t.dampCoeff
            let y = x + combDamp[i] * t.feedback
            combBufs[i][p] = y
            p += 1
            if p >= n { p = 0 }
            combPos[i] = p
            sum += delayed
        }
        var wet = sum / Float(max(1, combBufs.count))
        wet = wet * t.combGain + early * t.earlyGain
        for i in apBufs.indices {
            let n = apBufs[i].count
            var p = allpassPos[i]
            let buf = apBufs[i][p]
            let y = -wet + buf
            apBufs[i][p] = wet + buf * t.apGain
            p += 1
            if p >= n { p = 0 }
            allpassPos[i] = p
            wet = y
        }
        // 30% less than the original full-wet mix (0.38 → 0.266).
        let wetMix = amount * 0.266
        return x * (1 - wetMix) + wet * wetMix
    }
}

/// Clarity-inspired de-reverb: estimate late energy vs direct, then attenuate it.
/// Not a full spectral Clarity clone — stronger adaptive dual-tap cancel + HF damp.
struct DeVerbDSP {
    var amount: Float = 0
    var bypass: Bool = false
    private var delayShort: [Float] = []
    private var delayLong: [Float] = []
    private var posS: Int = 0
    private var posL: Int = 0
    private var shelf = Biquad()
    private var configuredRate: Double = 0
    private var envFast: Float = 0
    private var envSlow: Float = 0
    private var reverbEnv: Float = 0
    private var reduce: Float = 0

    mutating func configure(sampleRate: Double) {
        if abs(configuredRate - sampleRate) < 0.5 { return }
        configuredRate = sampleRate
        delayShort = Array(repeating: 0, count: max(1, Int(sampleRate * 0.028)))
        delayLong = Array(repeating: 0, count: max(1, Int(sampleRate * 0.072)))
        posS = 0
        posL = 0
        shelf.setHighShelf(sampleRate: sampleRate, freq: 2800, gainDb: -8)
    }

    mutating func reset() {
        delayShort = Array(repeating: 0, count: delayShort.count)
        delayLong = Array(repeating: 0, count: delayLong.count)
        posS = 0
        posL = 0
        shelf.reset()
        envFast = 0
        envSlow = 0
        reverbEnv = 0
        reduce = 0
    }

    mutating func process(_ x: Float, sampleRate: Double) -> Float {
        configure(sampleRate: sampleRate)
        if bypass || amount < 0.001 { return x }
        if delayShort.isEmpty || delayLong.isEmpty { return x }

        let dS = delayShort[posS]
        delayShort[posS] = x
        posS += 1
        if posS >= delayShort.count { posS = 0 }

        let dL = delayLong[posL]
        delayLong[posL] = x
        posL += 1
        if posL >= delayLong.count { posL = 0 }

        let absx = abs(x)
        let af = exp(-1.0 / (0.004 * Float(sampleRate)))
        let aslow = exp(-1.0 / (0.18 * Float(sampleRate)))
        envFast = af * envFast + (1 - af) * absx
        envSlow = aslow * envSlow + (1 - aslow) * absx

        // Late/ambience residual: slow envelope above attack peaks + delayed copies
        let lateProxy = abs(dS) * 0.45 + abs(dL) * 0.55
        let ambience = max(0, envSlow - envFast * 0.7) + lateProxy * 0.35
        let ar = exp(-1.0 / (0.04 * Float(sampleRate)))
        reverbEnv = ar * reverbEnv + (1 - ar) * ambience

        let direct = max(envFast, 1e-5)
        let ratio = min(2.5, reverbEnv / direct)
        // 25% stronger than the previous 1.35 factor (1.35 × 1.25 = 1.6875). Cap raised so the top isn't clipped.
        let strength = amount * amount * 1.6875
        let targetReduce = min(0.95, ratio * 0.55 * strength)
        let smooth = exp(-1.0 / (0.025 * Float(sampleRate)))
        reduce = smooth * reduce + (1 - smooth) * targetReduce

        // Adaptive cancel of delayed energy + HF shelf on the cleaned path
        var cleaned = x - (dS * 0.28 + dL * 0.22) * reduce
        cleaned *= (1 - reduce * 0.35)
        cleaned = shelf.process(cleaned)

        return x * (1 - amount) + cleaned * amount
    }
}
