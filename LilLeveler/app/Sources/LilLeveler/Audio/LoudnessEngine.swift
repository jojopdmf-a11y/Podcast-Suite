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

    /// Gain toward target integrated LUFS, then true-peak limit to the ceiling.
    /// The returned gain is the net PRE → POST integrated-loudness change.
    static func normalize(
        _ buffer: WAVIO.Buffer,
        targetLUFS: Float,
        truePeakCeilingDbTP: Float
    ) throws -> (WAVIO.Buffer, LoudnessReport, Float) {
        let before = analyze(buffer)
        guard before.durationSec > 0.05 else {
            throw LevelerError.processFailed("Audio too short to level.")
        }

        var gainDb = targetLUFS - before.integratedLUFS
        gainDb = max(-24, min(24, gainDb))
        let gain = pow(10.0, gainDb / 20.0)
        var out = buffer.samples.map { $0 * gain }

        // Sit a hair under the printed ceiling so round-trip measurement does not tick over.
        let ceilingDb = truePeakCeilingDbTP - 0.05
        let ceiling = pow(10.0, ceilingDb / 20.0)
        out = truePeakLimit(
            samples: out,
            channels: buffer.channelCount,
            sampleRate: buffer.sampleRate,
            ceiling: ceiling
        )

        var result = WAVIO.Buffer(
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount,
            samples: out
        )
        var after = analyze(result)

        // If the limiter left unused true-peak headroom, spend it chasing LUFS once.
        let lufsShort = targetLUFS - after.integratedLUFS
        let tpHeadroom = ceilingDb - after.truePeakDbTP
        if lufsShort > 0.15 && tpHeadroom > 0.15 {
            let extraDb = min(min(lufsShort, tpHeadroom), 6)
            let extra = pow(10.0, extraDb / 20.0)
            out = result.samples.map { $0 * extra }
            out = truePeakLimit(
                samples: out,
                channels: buffer.channelCount,
                sampleRate: buffer.sampleRate,
                ceiling: ceiling
            )
            result = WAVIO.Buffer(
                sampleRate: buffer.sampleRate,
                channelCount: buffer.channelCount,
                samples: out
            )
            after = analyze(result)
        }

        let netGainDb = after.integratedLUFS - before.integratedLUFS
        return (result, after, netGainDb)
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

    /// Lookahead true-peak limiter. Turns down only around peaks that would break
    /// the ceiling, so average loudness can stay close to the LUFS target.
    private static func truePeakLimit(
        samples: [Float],
        channels: Int,
        sampleRate: Double,
        ceiling: Float
    ) -> [Float] {
        let ch = max(1, channels)
        let frames = samples.count / ch
        guard frames > 0 else { return samples }

        let ceilingLin = max(ceiling, 1e-4)
        let tpLin = pow(10.0, truePeakDbTP(samples: samples, channels: ch) / 20.0)
        if tpLin <= ceilingLin || tpLin < 1e-8 {
            return samples
        }

        let look = max(1, Int(0.002 * sampleRate))
        let releaseN = max(1.0, Float(0.05 * sampleRate))
        let rel = exp(-1.0 / releaseN)

        var out = [Float](repeating: 0, count: samples.count)
        var env: Float = 1

        func interpolatedPeak(at frame: Int) -> Float {
            guard frame >= 0, frame < frames else { return 0 }
            let next = min(frame + 1, frames - 1)
            var peak: Float = 0
            for c in 0..<ch {
                let x = samples[frame * ch + c]
                let xn = samples[next * ch + c]
                peak = max(peak, abs(x))
                peak = max(peak, abs(x + (xn - x) * 0.25))
                peak = max(peak, abs(x + (xn - x) * 0.50))
                peak = max(peak, abs(x + (xn - x) * 0.75))
            }
            return peak
        }

        // Sidechain sees the current frame; audio is delayed by `look` so gain
        // drops before that peak is written.
        for i in 0..<(frames + look) {
            let peak = interpolatedPeak(at: i)
            let needed: Float = (peak > ceilingLin && peak > 1e-12) ? ceilingLin / peak : 1
            if needed < env {
                env = needed
            } else {
                env += (needed - env) * (1 - rel)
                if env > 1 { env = 1 }
            }

            let src = i - look
            if src >= 0 {
                let g = env
                let base = src * ch
                for c in 0..<ch {
                    out[base + c] = samples[base + c] * g
                }
            }
        }

        let leftover = pow(10.0, truePeakDbTP(samples: out, channels: ch) / 20.0)
        if leftover > ceilingLin && leftover > 1e-8 {
            let scale = ceilingLin / leftover
            for i in 0..<out.count {
                out[i] *= scale
            }
        }
        return out
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
