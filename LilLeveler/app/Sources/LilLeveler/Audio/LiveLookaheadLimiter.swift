import Foundation

/// Realtime clone of `LoudnessEngine.truePeakLimit` for MUSIC LOUD monitoring.
///
/// Makeup is `ceiling − threshold` (L1-style). The delay line stores ungained
/// source so dragging THRESHOLD changes what you hear on the next buffer, not
/// after a full-file rewrite.
struct LiveLookaheadLimiter {
    var makeupLin: Float = 1
    var ceilingLin: Float = pow(10.0, -0.1 / 20.0)

    private(set) var look: Int = 1
    private var rel: Float = 0.999
    private var delayL: [Float] = []
    private var delayR: [Float] = []
    private var write = 0
    private var filled = 0
    private var env: Float = 1
    private var hold = 0
    private var prevL: Float = 0
    private var prevR: Float = 0

    /// Instantaneous gain reduction in dB (0 = no reduction).
    private(set) var lastGRDb: Float = 0

    var isConfigured: Bool { !delayL.isEmpty }

    mutating func configure(sampleRate: Double, ceilingDb: Float = -0.1) {
        let sr = max(sampleRate, 1)
        look = max(1, Int(0.002 * sr))
        let releaseN = max(1.0, Float(0.001 * sr))
        rel = exp(-1.0 / releaseN)
        ceilingLin = pow(10.0, ceilingDb / 20.0)
        delayL = [Float](repeating: 0, count: look)
        delayR = [Float](repeating: 0, count: look)
        resetState()
    }

    mutating func reset() {
        if delayL.isEmpty { return }
        for i in delayL.indices {
            delayL[i] = 0
            delayR[i] = 0
        }
        resetState()
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        let gL = left * makeupLin
        let gR = right * makeupLin

        var peak = max(abs(gL), abs(gR))
        peak = max(peak, abs(prevL + (gL - prevL) * 0.25))
        peak = max(peak, abs(prevL + (gL - prevL) * 0.50))
        peak = max(peak, abs(prevL + (gL - prevL) * 0.75))
        peak = max(peak, abs(prevR + (gR - prevR) * 0.25))
        peak = max(peak, abs(prevR + (gR - prevR) * 0.50))
        peak = max(peak, abs(prevR + (gR - prevR) * 0.75))
        prevL = gL
        prevR = gR

        let needed: Float = (peak > ceilingLin && peak > 1e-12) ? ceilingLin / peak : 1
        if needed < env {
            env = needed
            hold = look
        } else if hold > 0 {
            hold -= 1
        } else {
            env += (needed - env) * (1 - rel)
            if env > 1 { env = 1 }
        }

        var outL: Float = 0
        var outR: Float = 0
        if look > 0, filled == look {
            outL = delayL[write] * makeupLin * env
            outR = delayR[write] * makeupLin * env
        }
        if look > 0 {
            delayL[write] = left
            delayR[write] = right
            write += 1
            if write == look { write = 0 }
            if filled < look { filled += 1 }
        } else {
            outL = gL * env
            outR = gR * env
        }
        let cap = ceilingLin
        outL = min(cap, max(-cap, outL))
        outR = min(cap, max(-cap, outR))

        lastGRDb = env < 1 ? -20 * log10(max(env, 1e-8)) : 0
        return (outL, outR)
    }

    private mutating func resetState() {
        write = 0
        filled = 0
        env = 1
        hold = 0
        prevL = 0
        prevR = 0
        lastGRDb = 0
    }
}
