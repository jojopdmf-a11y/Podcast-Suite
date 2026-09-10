import Foundation

/// ITU-R BS.1770–style loudness measurement + gain/normalize with true-peak ceiling.
enum LoudnessEngine {

    // MARK: - Public API

    static func analyze(_ buffer: WAVIO.Buffer) -> LoudnessReport {
        let ch = max(1, buffer.channelCount)
        let sr = buffer.sampleRate
        let frames = buffer.frameCount
        guard frames > 0, sr > 0 else { return .empty }

        let integrated = integratedLUFS(samples: buffer.samples, channels: ch, sampleRate: sr)
        let short = shortTermLUFS(samples: buffer.samples, channels: ch, sampleRate: sr)
        let mom = momentaryLUFS(samples: buffer.samples, channels: ch, sampleRate: sr)
        let samplePeak = samplePeakDb(samples: buffer.samples)
        let truePeak = truePeakDbTP(samples: buffer.samples, channels: ch)

        return LoudnessReport(
            integratedLUFS: integrated,
            shortTermLUFS: short,
            momentaryLUFS: mom,
            truePeakDbTP: truePeak,
            samplePeakDbFS: samplePeak,
            durationSec: Double(frames) / sr,
            channelCount: ch,
            sampleRate: sr
        )
    }

    /// Gain toward target integrated LUFS, then soft-limit to true-peak ceiling.
    static func normalize(
        _ buffer: WAVIO.Buffer,
        targetLUFS: Float,
        truePeakCeilingDbTP: Float
    ) throws -> (WAVIO.Buffer, LoudnessReport, Float) {
        let before = analyze(buffer)
        guard before.durationSec > 0.05 else {
            throw LevelerError.processFailed("Audio too short to level.")
        }

        // Gain needed to hit target integrated loudness
        var gainDb = targetLUFS - before.integratedLUFS
        // Cap wild gains (silence / near-silence)
        gainDb = max(-24, min(24, gainDb))
        let gain = pow(10.0, gainDb / 20.0)

        var out = buffer.samples.map { $0 * gain }

        // Soft brickwall toward true-peak ceiling (with a little margin)
        let ceiling = pow(10.0, truePeakCeilingDbTP / 20.0) * 0.98
        let limited = softLimitTruePeak(samples: out, channels: buffer.channelCount, ceiling: ceiling)
        out = limited

        let result = WAVIO.Buffer(
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount,
            samples: out
        )
        let after = analyze(result)
        return (result, after, gainDb)
    }

    // MARK: - BS.1770 K-weighting + gating

    /// Integrated loudness (gated).
    static func integratedLUFS(samples: [Float], channels: Int, sampleRate: Double) -> Float {
        let blockSec = 0.4
        let hopSec = 0.1
        let block = max(1, Int(blockSec * sampleRate))
        let hop = max(1, Int(hopSec * sampleRate))
        let frames = samples.count / max(1, channels)
        guard frames >= block else { return -70 }

        var filtered = kWeight(samples: samples, channels: channels, sampleRate: sampleRate)
        var blockLoudness: [Float] = []
        var i = 0
        while i + block <= frames {
            let z = meanSquare(samples: filtered, channels: channels, startFrame: i, frameCount: block)
            let lk = -0.691 + 10 * log10(max(z, 1e-12))
            blockLoudness.append(lk)
            i += hop
        }
        guard !blockLoudness.isEmpty else { return -70 }

        // Absolute gate −70 LUFS
        let absGate: Float = -70
        let aboveAbs = blockLoudness.filter { $0 > absGate }
        guard !aboveAbs.isEmpty else { return -70 }
        let relativeRef = averageLUFS(aboveAbs)
        let relGate = relativeRef - 10
        let gated = aboveAbs.filter { $0 > relGate }
        guard !gated.isEmpty else { return relativeRef }
        return averageLUFS(gated)
    }

    static func shortTermLUFS(samples: [Float], channels: Int, sampleRate: Double) -> Float {
        windowLUFS(samples: samples, channels: channels, sampleRate: sampleRate, windowSec: 3.0)
    }

    static func momentaryLUFS(samples: [Float], channels: Int, sampleRate: Double) -> Float {
        windowLUFS(samples: samples, channels: channels, sampleRate: sampleRate, windowSec: 0.4)
    }

    private static func windowLUFS(samples: [Float], channels: Int, sampleRate: Double, windowSec: Double) -> Float {
        let frames = samples.count / max(1, channels)
        let win = max(1, Int(windowSec * sampleRate))
        guard frames > 0 else { return -70 }
        let start = max(0, frames - win)
        let count = frames - start
        var filtered = kWeight(samples: samples, channels: channels, sampleRate: sampleRate)
        let z = meanSquare(samples: filtered, channels: channels, startFrame: start, frameCount: count)
        return -0.691 + 10 * log10(max(z, 1e-12))
    }

    private static func averageLUFS(_ blocks: [Float]) -> Float {
        // Average of linear mean-square power, not arithmetic mean of LUFS
        var sum: Float = 0
        for l in blocks {
            sum += pow(10.0, l / 10.0)
        }
        let mean = sum / Float(blocks.count)
        return 10 * log10(max(mean, 1e-12))
    }

    private static func meanSquare(samples: [Float], channels: Int, startFrame: Int, frameCount: Int) -> Float {
        // Channel weighting: stereo L/R = 1.0 each (BS.1770)
        var acc: Float = 0
        var n: Float = 0
        let end = startFrame + frameCount
        for f in startFrame..<end {
            for c in 0..<channels {
                let idx = f * channels + c
                guard idx < samples.count else { continue }
                let x = samples[idx]
                acc += x * x
                n += 1
            }
        }
        return n > 0 ? acc / n : 0
    }

    /// Two-stage K-weighting (high shelf + highpass), applied per channel.
    private static func kWeight(samples: [Float], channels: Int, sampleRate: Double) -> [Float] {
        var out = samples
        for c in 0..<channels {
            var shelf = Biquad.highShelf(sampleRate: sampleRate, freq: 1681.0, gainDb: 4.0, q: 0.7071)
            var hp = Biquad.highpass(sampleRate: sampleRate, freq: 38.0, q: 0.5)
            var i = c
            while i < out.count {
                var x = out[i]
                x = shelf.process(x)
                x = hp.process(x)
                out[i] = x
                i += channels
            }
        }
        return out
    }

    // MARK: - Peaks

    static func samplePeakDb(samples: [Float]) -> Float {
        var peak: Float = 1e-12
        for s in samples { peak = max(peak, abs(s)) }
        return 20 * log10(peak)
    }

    /// Lightweight true-peak estimate via 4× linear upsample peak hold.
    static func truePeakDbTP(samples: [Float], channels: Int) -> Float {
        var peak: Float = 1e-12
        let frames = samples.count / max(1, channels)
        for c in 0..<channels {
            var prev: Float = 0
            for f in 0..<frames {
                let x = samples[f * channels + c]
                peak = max(peak, abs(x))
                // 3 interpolated points between prev and x
                for k in 1..<4 {
                    let t = Float(k) / 4.0
                    let y = prev + (x - prev) * t
                    peak = max(peak, abs(y))
                }
                prev = x
            }
        }
        return 20 * log10(peak)
    }

    private static func softLimitTruePeak(samples: [Float], channels: Int, ceiling: Float) -> [Float] {
        // First pass: find post-gain true peak, scale if needed, then soft clip
        let tp = truePeakDbTP(samples: samples, channels: channels)
        let tpLin = pow(10.0, tp / 20.0)
        var scale: Float = 1
        if tpLin > ceiling && tpLin > 1e-8 {
            scale = ceiling / tpLin
        }
        return samples.map { x in
            let y = x * scale
            let c = max(ceiling, 1e-4)
            return c * tanhf(y / c)
        }
    }
}

/// Minimal biquad for K-weighting stages.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func highpass(sampleRate: Double, freq: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * freq / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let b0 = (1 + cosw) / 2
        let b1 = -(1 + cosw)
        let b2 = (1 + cosw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw
        let a2 = 1 - alpha
        return Biquad(
            b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
            a1: Float(a1 / a0), a2: Float(a2 / a0)
        )
    }

    static func highShelf(sampleRate: Double, freq: Double, gainDb: Double, q: Double) -> Biquad {
        let a = pow(10.0, gainDb / 40.0)
        let w0 = 2 * Double.pi * freq / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) + (a - 1) * cosw + twoSqrtAAlpha)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
        let b2 = a * ((a + 1) + (a - 1) * cosw - twoSqrtAAlpha)
        let a0 = (a + 1) - (a - 1) * cosw + twoSqrtAAlpha
        let a1 = 2 * ((a - 1) - (a + 1) * cosw)
        let a2 = (a + 1) - (a - 1) * cosw - twoSqrtAAlpha
        return Biquad(
            b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
            a1: Float(a1 / a0), a2: Float(a2 / a0)
        )
    }
}
