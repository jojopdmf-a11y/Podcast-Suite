import Foundation

struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    mutating func reset() { z1 = 0; z2 = 0 }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        // Soft clamp runaway from coeff swaps / denormals
        if !y.isFinite {
            z1 = 0; z2 = 0
            return 0
        }
        return y
    }

    /// Update peaking coeffs in place — keeps z1/z2 so live EQ moves don't click.
    mutating func setPeaking(sampleRate: Double, freq: Double, gainDb: Float, q: Float = 1.15) {
        if abs(gainDb) < 0.01 {
            b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0
            return
        }
        let A = pow(10.0, Double(gainDb) / 40.0)
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let alpha = sin(w0) / (2.0 * Double(q))
        let cosw = cos(w0)
        let b0n = 1 + alpha * A
        let b1n = -2 * cosw
        let b2n = 1 - alpha * A
        let a0 = 1 + alpha / A
        let a1n = -2 * cosw
        let a2n = 1 - alpha / A
        b0 = Float(b0n / a0)
        b1 = Float(b1n / a0)
        b2 = Float(b2n / a0)
        a1 = Float(a1n / a0)
        a2 = Float(a2n / a0)
    }

    mutating func setHighShelf(sampleRate: Double, freq: Double, gainDb: Float) {
        let A = pow(10.0, Double(gainDb) / 40.0)
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / 2.0 * sqrt(max(0.0, (A + 1 / A) * (1 / 0.7 - 1) + 2))
        let twoSqrtAAlpha = 2 * sqrt(A) * alpha
        let b0n = A * ((A + 1) + (A - 1) * cosw + twoSqrtAAlpha)
        let b1n = -2 * A * ((A - 1) + (A + 1) * cosw)
        let b2n = A * ((A + 1) + (A - 1) * cosw - twoSqrtAAlpha)
        let a0 = (A + 1) - (A - 1) * cosw + twoSqrtAAlpha
        let a1n = 2 * ((A - 1) - (A + 1) * cosw)
        let a2n = (A + 1) - (A - 1) * cosw - twoSqrtAAlpha
        b0 = Float(b0n / a0)
        b1 = Float(b1n / a0)
        b2 = Float(b2n / a0)
        a1 = Float(a1n / a0)
        a2 = Float(a2n / a0)
    }

    static func peaking(sampleRate: Double, freq: Double, gainDb: Float, q: Float = 1.15) -> Biquad {
        var f = Biquad()
        f.setPeaking(sampleRate: sampleRate, freq: freq, gainDb: gainDb, q: q)
        return f
    }

    static func highShelf(sampleRate: Double, freq: Double, gainDb: Float) -> Biquad {
        var f = Biquad()
        f.setHighShelf(sampleRate: sampleRate, freq: freq, gainDb: gainDb)
        return f
    }
}

/// 560-style proportional-Q curves for the 10-band graphic (named EQ 2520 in the UI).
/// Wide at small boost/cut, tighter toward ±12 dB. Extra fader travel in the ±4 dB region.
enum Graphic2520 {
    static func bandwidthOctaves(gainDb: Float) -> Float {
        let g = abs(gainDb)
        // ~1.7 oct at 2 dB (smooth overlap), ~0.55 oct at 12 dB (~12 dB/oct slope).
        let bw0: Float = 2.92
        let k: Float = 0.359
        return max(0.35, bw0 / (1 + k * g))
    }

    static func q(gainDb: Float) -> Float {
        let bw = Double(max(0.35, bandwidthOctaves(gainDb: gainDb)))
        let q = 1.0 / (2.0 * sinh(log(2.0) / 2.0 * bw))
        return Float(min(8, max(0.4, q)))
    }

    /// 0 = −12 dB (bottom), 1 = +12 dB (top). Inner half of travel is ±4 dB.
    static func gainDb(fromNormalized t: Float) -> Float {
        let x = max(0, min(1, t))
        let db: Float
        if x < 0.25 {
            db = -12 + (x / 0.25) * 8
        } else if x <= 0.75 {
            db = -4 + ((x - 0.25) / 0.5) * 8
        } else {
            db = 4 + ((x - 0.75) / 0.25) * 8
        }
        return max(-12, min(12, db))
    }

    static func normalized(fromGainDb db: Float) -> Float {
        let g = max(-12, min(12, db))
        if g < -4 {
            return 0.25 * (g + 12) / 8
        }
        if g <= 4 {
            return 0.25 + 0.5 * (g + 4) / 8
        }
        return 0.75 + 0.25 * (g - 4) / 8
    }
}

struct GraphicEQ {
    private var bands: [Biquad] = Array(repeating: Biquad(), count: 10)
    private var sampleRate: Double = 44100
    private var lastGains: [Float] = Array(repeating: 0, count: 10)

    mutating func configure(sampleRate: Double, gainsDb: [Float]) {
        let rateChanged = abs(self.sampleRate - sampleRate) > 0.5
        self.sampleRate = sampleRate
        let freqs = GraphicEQBand.allCases.map(\.hz)
        for i in 0..<min(10, gainsDb.count) {
            let g = gainsDb[i]
            // Only rewrite coeffs when needed — never resets filter memory
            if rateChanged || abs(g - lastGains[i]) > 0.001 {
                bands[i].setPeaking(
                    sampleRate: sampleRate,
                    freq: freqs[i],
                    gainDb: g,
                    q: Graphic2520.q(gainDb: g)
                )
                lastGains[i] = g
            }
        }
    }

    mutating func reset() {
        for i in bands.indices { bands[i].reset() }
    }

    mutating func process(_ x: Float) -> Float {
        var y = x
        for i in bands.indices {
            y = bands[i].process(y)
        }
        return y
    }
}

/// Speaker-only proportional-Q peaking band. Bandwidth narrows as |gain| grows.
struct ParaEQDSP {
    var freqHz: Float = 1_000
    var gainDb: Float = 0
    var width: ParaEQWidth = .narrow
    var bypass: Bool = false

    private var filter = Biquad()
    private var sampleRate: Double = 44_100
    private var lastFreq: Float = -1
    private var lastGain: Float = 999
    private var lastWidth: ParaEQWidth = .narrow
    private var lastRate: Double = 0

    mutating func configure(sampleRate: Double) {
        let rateChanged = abs(self.sampleRate - sampleRate) > 0.5
        self.sampleRate = sampleRate
        if rateChanged
            || abs(freqHz - lastFreq) > 0.05
            || abs(gainDb - lastGain) > 0.01
            || width != lastWidth
            || abs(lastRate - sampleRate) > 0.5
        {
            let nyquist = Float(sampleRate * 0.45)
            let f = min(max(freqHz, ChannelParaEQ.minHz), min(ChannelParaEQ.maxHz, nyquist))
            filter.setPeaking(
                sampleRate: sampleRate,
                freq: Double(f),
                gainDb: gainDb,
                q: width.q(gainDb: gainDb)
            )
            lastFreq = freqHz
            lastGain = gainDb
            lastWidth = width
            lastRate = sampleRate
        }
    }

    mutating func reset() {
        filter.reset()
    }

    mutating func process(_ x: Float) -> Float {
        if bypass || abs(gainDb) < 0.01 { return x }
        return filter.process(x)
    }
}
