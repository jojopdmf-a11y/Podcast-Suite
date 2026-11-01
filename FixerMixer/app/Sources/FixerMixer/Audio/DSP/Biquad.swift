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

    /// RBJ cookbook high-pass. `q = 1/√2` ≈ Butterworth for one 12 dB/oct stage.
    mutating func setHighPass(sampleRate: Double, freq: Double, q: Float = 0.70710678) {
        let f = max(1.0, min(freq, sampleRate * 0.45))
        let w0 = 2.0 * Double.pi * f / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / (2.0 * Double(max(0.1, q)))
        let b0n = (1 + cosw) / 2
        let b1n = -(1 + cosw)
        let b2n = (1 + cosw) / 2
        let a0 = 1 + alpha
        let a1n = -2 * cosw
        let a2n = 1 - alpha
        b0 = Float(b0n / a0)
        b1 = Float(b1n / a0)
        b2 = Float(b2n / a0)
        a1 = Float(a1n / a0)
        a2 = Float(a2n / a0)
    }

    /// RBJ cookbook band-pass (constant 0 dB peak gain).
    mutating func setBandPass(sampleRate: Double, freq: Double, q: Float = 1.0) {
        let f = max(1.0, min(freq, sampleRate * 0.45))
        let w0 = 2.0 * Double.pi * f / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / (2.0 * Double(max(0.1, q)))
        let b0n = alpha
        let b1n = 0.0
        let b2n = -alpha
        let a0 = 1 + alpha
        let a1n = -2 * cosw
        let a2n = 1 - alpha
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

    static func highPass(sampleRate: Double, freq: Double, q: Float = 0.70710678) -> Biquad {
        var f = Biquad()
        f.setHighPass(sampleRate: sampleRate, freq: freq, q: q)
        return f
    }
}

/// Cascaded 2× Butterworth high-pass → 24 dB/octave. `cutoffHz <= 0` = bypass.
struct HighPass24DSP {
    static let minHz: Float = 20
    static let maxHz: Float = 300

    var cutoffHz: Float = 0

    private var stage1 = Biquad()
    private var stage2 = Biquad()
    private var sampleRate: Double = 44_100
    private var lastCutoff: Float = -1
    private var lastRate: Double = 0
    private var active = false

    mutating func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        let on = cutoffHz >= Self.minHz
        if !on {
            if active {
                stage1.reset()
                stage2.reset()
            }
            active = false
            lastCutoff = cutoffHz
            lastRate = sampleRate
            return
        }
        let hz = min(Self.maxHz, max(Self.minHz, cutoffHz))
        if !active
            || abs(hz - lastCutoff) > 0.05
            || abs(sampleRate - lastRate) > 0.5
        {
            stage1.setHighPass(sampleRate: sampleRate, freq: Double(hz))
            stage2.setHighPass(sampleRate: sampleRate, freq: Double(hz))
            lastCutoff = hz
            lastRate = sampleRate
            active = true
        }
    }

    mutating func reset() {
        stage1.reset()
        stage2.reset()
    }

    mutating func process(_ x: Float) -> Float {
        guard active else { return x }
        return stage2.process(stage1.process(x))
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

/// Dynamic de-esser — sidechain band around `freqHz`, GR only.
/// Width blends split-band cut (notch/narrow) toward wideband attenuation (wide).
struct DeEsserDSP {
    var freqHz: Float = 6_000
    var width: ParaEQWidth = .narrow
    var thresholdDb: Float = -24
    var bypass: Bool = true
    /// Live gain reduction in dB (≥ 0) for the GR meter.
    private(set) var meterGRDb: Float = 0

    private var bandPass = Biquad()
    private var env: Float = 0
    private var grLin: Float = 1
    private var sampleRate: Double = 44_100
    private var lastFreq: Float = -1
    private var lastWidth: ParaEQWidth = .narrow
    private var lastRate: Double = 0

    mutating func configure(sampleRate: Double) {
        let rateChanged = abs(self.sampleRate - sampleRate) > 0.5
        self.sampleRate = sampleRate
        if rateChanged
            || abs(freqHz - lastFreq) > 0.05
            || width != lastWidth
            || abs(lastRate - sampleRate) > 0.5
        {
            let nyquist = Float(sampleRate * 0.45)
            let f = min(max(freqHz, ChannelDeEsser.minHz), min(ChannelDeEsser.maxHz, nyquist))
            // Flat gain (0 dB) Q for detection bandwidth.
            let q = width.q(gainDb: 0)
            bandPass.setBandPass(sampleRate: sampleRate, freq: Double(f), q: q)
            lastFreq = freqHz
            lastWidth = width
            lastRate = sampleRate
        }
    }

    mutating func reset() {
        bandPass.reset()
        env = 0
        grLin = 1
        meterGRDb = 0
    }

    mutating func process(_ x: Float) -> Float {
        if bypass {
            meterGRDb *= 0.9
            return x
        }
        let detect = bandPass.process(x)
        let absd = abs(detect)
        let atk = exp(-1.0 / (0.003 * Float(sampleRate)))
        let rel = exp(-1.0 / (0.080 * Float(sampleRate)))
        if absd > env {
            env = atk * env + (1 - atk) * absd
        } else {
            env = rel * env + (1 - rel) * absd
        }

        let threshLin = pow(10.0, thresholdDb / 20.0)
        var desiredGR: Float = 1
        if env > threshLin {
            let overDb = 20 * log10(max(env / max(threshLin, 1e-6), 1))
            // Soft 3:1-ish pull; cap so it never bricks the band.
            let grDb = min(18, overDb * 0.65)
            desiredGR = pow(10.0, -grDb / 20.0)
        }
        let grAtk = exp(-1.0 / (0.004 * Float(sampleRate)))
        let grRel = exp(-1.0 / (0.090 * Float(sampleRate)))
        if desiredGR < grLin {
            grLin = grAtk * grLin + (1 - grAtk) * desiredGR
        } else {
            grLin = grRel * grLin + (1 - grRel) * desiredGR
        }
        meterGRDb = max(0, -20 * log10(max(grLin, 1e-6)))

        // Width carries split ↔ wideband: notch = mostly band cut, wide = mostly broadband.
        let wideBlend: Float
        switch width {
        case .notch: wideBlend = 0.05
        case .narrow: wideBlend = 0.30
        case .wide: wideBlend = 0.85
        }
        let split = x - detect * (1 - grLin)
        let wide = x * grLin
        return split * (1 - wideBlend) + wide * wideBlend
    }
}
