import Foundation

/// Target-driven leveler: Drive packs level toward Target, then soft-compresses / soft-limits there.
/// (No wet/dry blend — Drive is correction strength + how hard you push into the ceiling.)
struct LevelerDSP {
    var drive: Float = 0
    var targetDb: Float = -18
    var bypass: Bool = false
    private var env: Float = 0
    private var gain: Float = 1
    private var compGR: Float = 1
    private let attack: Float = 0.012
    private let release: Float = 0.22

    mutating func reset() {
        env = 0
        gain = 1
        compGR = 1
    }

    mutating func process(_ x: Float, sampleRate: Double) -> Float {
        if bypass || drive < 0.001 { return x }

        let absx = abs(x)
        let atk = exp(-1.0 / (attack * Float(sampleRate)))
        let rel = exp(-1.0 / (release * Float(sampleRate)))
        if absx > env {
            env = atk * env + (1 - atk) * absx
        } else {
            env = rel * env + (1 - rel) * absx
        }

        let currentDb = 20 * log10(max(env, 1e-6))
        // Auto-level toward target; Drive scales how much of the error we correct
        let errorDb = targetDb - currentDb
        let correctionDb = max(-18, min(12, errorDb)) * drive
        let desired = pow(10.0, correctionDb / 20.0)
        let gainSmooth = exp(-1.0 / (0.07 * Float(sampleRate)))
        gain = gainSmooth * gain + (1 - gainSmooth) * Float(desired)

        var y = x * gain

        // Soft-knee compressor once we're at/above target (peaks that leveling didn't catch)
        let peakDb = 20 * log10(max(abs(y), 1e-6))
        let thresh = targetDb
        let knee: Float = 6
        let ratio = 2.0 + drive * 6.0 // 2:1 … 8:1
        var grDb: Float = 0
        if peakDb > (thresh - knee / 2) {
            if peakDb < (thresh + knee / 2) {
                // Soft knee region
                let xk = peakDb - thresh + knee / 2
                grDb = ((1 / ratio - 1) * (xk * xk)) / (2 * knee)
            } else {
                grDb = (thresh - peakDb) * (1 - 1 / ratio)
            }
        }
        let targetGR = pow(10.0, grDb / 20.0)
        let grAtk = exp(-1.0 / (0.003 * Float(sampleRate)))
        let grRel = exp(-1.0 / (0.12 * Float(sampleRate)))
        if Float(targetGR) < compGR {
            compGR = grAtk * compGR + (1 - grAtk) * Float(targetGR)
        } else {
            compGR = grRel * compGR + (1 - grRel) * Float(targetGR)
        }
        y *= compGR

        // Soft limiter ceiling just above target — Drive leans harder into it
        let ceilingDb = targetDb + (1.0 - drive * 0.5) // ~+1 dB at low drive, +0.5 at full
        let ceiling = pow(10.0, ceilingDb / 20.0)
        y = softLimit(y, ceiling: ceiling)

        return y
    }

    private func softLimit(_ x: Float, ceiling: Float) -> Float {
        let c = max(ceiling, 1e-4)
        // tanh soft clip: transparent well below ceiling, rounds into it
        return c * tanhf(x / c)
    }
}

/// Drum-room reverb: bright, punchy early reflections + short lively decay.
struct WetterDSP {
    var amount: Float = 0
    var bypass: Bool = false
    private var combBufs: [[Float]] = []
    private var combPos: [Int] = []
    private var combDamp: [Float] = []
    private var apBufs: [[Float]] = []
    private var allpassPos: [Int] = []
    private var earlyBuf: [Float] = []
    private var earlyPos: Int = 0
    private var configuredRate: Double = 0

    mutating func configure(sampleRate: Double) {
        guard abs(configuredRate - sampleRate) > 0.5 else { return }
        configuredRate = sampleRate
        rebuildCombs(sampleRate: sampleRate)
    }

    private mutating func rebuildCombs(sampleRate: Double) {
        // Drum booth denseness — slightly longer than studio air, still short of a hall
        let combMs: [Double] = [17.9, 22.3, 26.1, 29.7, 33.3]
        combBufs = combMs.map { Array(repeating: 0, count: max(1, Int(sampleRate * $0 / 1000.0))) }
        combPos = Array(repeating: 0, count: combBufs.count)
        combDamp = Array(repeating: 0, count: combBufs.count)
        let apMs: [Double] = [4.7, 2.3, 1.1]
        apBufs = apMs.map { Array(repeating: 0, count: max(1, Int(sampleRate * $0 / 1000.0))) }
        allpassPos = Array(repeating: 0, count: apBufs.count)
        // Early slap (~12 ms) for room punch
        earlyBuf = Array(repeating: 0, count: max(1, Int(sampleRate * 0.012)))
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

        // Bright early reflection
        let early = earlyBuf.isEmpty ? 0 : earlyBuf[earlyPos]
        if !earlyBuf.isEmpty {
            earlyBuf[earlyPos] = x
            earlyPos += 1
            if earlyPos >= earlyBuf.count { earlyPos = 0 }
        }

        var sum: Float = 0
        // Livlier decay than studio air; light damp keeps it bright (drum room)
        let feedback: Float = 0.58
        let dampCoeff: Float = 0.12
        for i in combBufs.indices {
            let n = combBufs[i].count
            var p = combPos[i]
            let delayed = combBufs[i][p]
            combDamp[i] = delayed + (combDamp[i] - delayed) * dampCoeff
            let y = x + combDamp[i] * feedback
            combBufs[i][p] = y
            p += 1
            if p >= n { p = 0 }
            combPos[i] = p
            sum += delayed
        }
        var wet = sum / Float(max(1, combBufs.count))
        wet = wet * 0.72 + early * 0.45
        let apGain: Float = 0.62
        for i in apBufs.indices {
            let n = apBufs[i].count
            var p = allpassPos[i]
            let buf = apBufs[i][p]
            let y = -wet + buf
            apBufs[i][p] = wet + buf * apGain
            p += 1
            if p >= n { p = 0 }
            allpassPos[i] = p
            wet = y
        }
        let wetMix = amount * 0.38
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
        // Stronger amount curve so mid settings actually audibly dry the room
        let strength = amount * amount * 1.35
        let targetReduce = min(0.92, ratio * 0.55 * strength)
        let smooth = exp(-1.0 / (0.025 * Float(sampleRate)))
        reduce = smooth * reduce + (1 - smooth) * targetReduce

        // Adaptive cancel of delayed energy + HF shelf on the cleaned path
        var cleaned = x - (dS * 0.28 + dL * 0.22) * reduce
        cleaned *= (1 - reduce * 0.35)
        cleaned = shelf.process(cleaned)

        return x * (1 - amount) + cleaned * amount
    }
}
