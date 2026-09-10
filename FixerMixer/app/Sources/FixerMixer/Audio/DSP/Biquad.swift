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
                bands[i].setPeaking(sampleRate: sampleRate, freq: freqs[i], gainDb: g)
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
