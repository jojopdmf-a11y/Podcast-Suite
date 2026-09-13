import Foundation

/// ITU-R BS.1770–style loudness measurement + gain/normalize with true-peak ceiling.
/// Walks a mapped PCM store in chunks so a 4-hour show never sits in RAM as `[Float]`.
enum LoudnessEngine {

    private static let chunkFrames = 16_384

    // MARK: - Public API

    static func analyze(
        _ store: PCMStore,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> LoudnessReport {
        let ch = max(1, store.channelCount)
        let sr = store.sampleRate
        let frames = store.frameCount
        guard frames > 0, sr > 0 else { return .empty }

        store.adviseSequential()

        let blockLen = max(1, Int(0.4 * sr))
        let hopLen = max(1, Int(0.1 * sr))
        let shortLen = max(1, Int(3.0 * sr))
        let momLen = max(1, Int(0.4 * sr))

        var shelf = (0..<ch).map { _ in Biquad.highShelf(sampleRate: sr, freq: 1681.0, gainDb: 4.0, q: 0.7071) }
        var hp = (0..<ch).map { _ in Biquad.highpass(sampleRate: sr, freq: 38.0, q: 0.5) }

        var kRing = [Float](repeating: 0, count: shortLen * ch)
        var kWrite = 0
        var kFilled = 0

        var blockLoudness: [Float] = []
        blockLoudness.reserveCapacity(max(1, frames / hopLen + 1))

        var samplePeak: Float = 1e-12
        var truePeak: Float = 1e-12
        var tpPrev = [Float](repeating: 0, count: ch)

        var tmp = [Float](repeating: 0, count: chunkFrames * ch)
        var processed = 0
        var lastPct = -1

        while processed < frames {
            let n = store.copyFrames(
                start: processed,
                count: min(chunkFrames, frames - processed),
                into: &tmp
            )
            guard n > 0 else { break }

            for f in 0..<n {
                let base = f * ch
                for c in 0..<ch {
                    let x = tmp[base + c]
                    samplePeak = max(samplePeak, abs(x))
                    truePeak = max(truePeak, abs(x))
                    let prev = tpPrev[c]
                    truePeak = max(truePeak, abs(prev + (x - prev) * 0.25))
                    truePeak = max(truePeak, abs(prev + (x - prev) * 0.50))
                    truePeak = max(truePeak, abs(prev + (x - prev) * 0.75))
                    tpPrev[c] = x

                    var y = x
                    y = shelf[c].process(y)
                    y = hp[c].process(y)
                    kRing[kWrite * ch + c] = y
                }
                kWrite += 1
                if kWrite == shortLen { kWrite = 0 }
                if kFilled < shortLen { kFilled += 1 }
                processed += 1

                if processed >= blockLen && (processed - blockLen) % hopLen == 0 {
                    let z = meanSquareFromRing(
                        kRing,
                        channels: ch,
                        write: kWrite,
                        capacity: shortLen,
                        filled: kFilled,
                        window: blockLen
                    )
                    let lk = -0.691 + 10 * log10(max(z, 1e-12))
                    blockLoudness.append(lk)
                }
            }

            let pct = Int((Double(processed) / Double(frames)) * 100.0)
            if pct != lastPct {
                lastPct = pct
                progress?(Double(processed) / Double(frames))
            }
        }

        let integrated: Float
        if blockLoudness.isEmpty {
            integrated = -70
        } else {
            let aboveAbs = blockLoudness.filter { $0 > -70 }
            if aboveAbs.isEmpty {
                integrated = -70
            } else {
                let relativeRef = averageLUFS(aboveAbs)
                let gated = aboveAbs.filter { $0 > relativeRef - 10 }
                integrated = gated.isEmpty ? relativeRef : averageLUFS(gated)
            }
        }

        let shortZ = meanSquareFromRing(
            kRing,
            channels: ch,
            write: kWrite,
            capacity: shortLen,
            filled: kFilled,
            window: min(shortLen, kFilled)
        )
        let momZ = meanSquareFromRing(
            kRing,
            channels: ch,
            write: kWrite,
            capacity: shortLen,
            filled: kFilled,
            window: min(momLen, kFilled)
        )

        return LoudnessReport(
            integratedLUFS: integrated,
            shortTermLUFS: -0.691 + 10 * log10(max(shortZ, 1e-12)),
            momentaryLUFS: -0.691 + 10 * log10(max(momZ, 1e-12)),
            truePeakDbTP: 20 * log10(truePeak),
            samplePeakDbFS: 20 * log10(samplePeak),
            durationSec: Double(frames) / sr,
            channelCount: ch,
            sampleRate: sr
        )
    }

    /// Gain toward target integrated LUFS, then true-peak limit to the ceiling.
    /// The returned gain is the net PRE → POST integrated-loudness change.
    static func normalize(
        _ store: PCMStore,
        targetLUFS: Float,
        truePeakCeilingDbTP: Float,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> (PCMStore, LoudnessReport, Float) {
        let before = analyze(store) { progress?(0.45 * $0) }
        guard before.durationSec > 0.05 else {
            throw LevelerError.processFailed("Audio too short to level.")
        }

        var gainDb = targetLUFS - before.integratedLUFS
        gainDb = max(-24, min(24, gainDb))
        let gain = pow(10.0, gainDb / 20.0)

        if let needed = PCMStore.estimatedByteCount(frames: store.frameCount, channels: store.channelCount) {
            try PCMStore.ensureDiskSpace(
                bytes: Int64(needed) + 32_000_000,
                near: FileManager.default.temporaryDirectory
            )
        }

        let dest = try PCMStore.createTemporary(
            sampleRate: store.sampleRate,
            channelCount: store.channelCount,
            frameCount: store.frameCount
        )

        let ceilingDb = truePeakCeilingDbTP - 0.05
        let ceiling = pow(10.0, ceilingDb / 20.0)
        let gainedTP = before.truePeakDbTP + gainDb

        if gainedTP <= ceilingDb {
            copyGained(from: store, to: dest, gain: gain) { progress?(0.45 + 0.35 * $0) }
        } else {
            truePeakLimit(from: store, to: dest, gain: gain, ceiling: ceiling) { progress?(0.45 + 0.35 * $0) }
        }
        dest.sync()

        var result = dest
        var after = analyze(result) { progress?(0.80 + 0.12 * $0) }

        let lufsShort = targetLUFS - after.integratedLUFS
        let tpHeadroom = ceilingDb - after.truePeakDbTP
        if lufsShort > 0.15 && tpHeadroom > 0.15 {
            let extraDb = min(min(lufsShort, tpHeadroom), 6)
            let extra = pow(10.0, extraDb / 20.0)
            let dest2 = try PCMStore.createTemporary(
                sampleRate: result.sampleRate,
                channelCount: result.channelCount,
                frameCount: result.frameCount
            )
            truePeakLimit(from: result, to: dest2, gain: extra, ceiling: ceiling) { progress?(0.92 + 0.04 * $0) }
            dest2.sync()
            result = dest2
            after = analyze(result) { progress?(0.96 + 0.04 * $0) }
        }

        progress?(1)
        let netGainDb = after.integratedLUFS - before.integratedLUFS
        return (result, after, netGainDb)
    }

    /// Raise a mixed music track as far as the ceiling allows: makeup into a
    /// tanh soft-clip, hard clip at the printed max, then true-peak limit leftovers.
    static func maximize(
        _ store: PCMStore,
        truePeakCeilingDbTP: Float,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> (PCMStore, LoudnessReport, Float) {
        let before = analyze(store) { progress?(0.40 * $0) }
        guard before.durationSec > 0.05 else {
            throw LevelerError.processFailed("Audio too short to level.")
        }

        // Sit on the printed ceiling (no extra 0.05 dB podcast safety).
        let ceilingDb = truePeakCeilingDbTP
        let ceiling = pow(10.0, ceilingDb / 20.0)
        let peakGainDb = ceilingDb - before.truePeakDbTP
        let clipDriveDb: Float = 4
        var gainDb = peakGainDb + clipDriveDb
        gainDb = max(-24, min(24, gainDb))
        let gain = pow(10.0, gainDb / 20.0)

        if let needed = PCMStore.estimatedByteCount(frames: store.frameCount, channels: store.channelCount) {
            try PCMStore.ensureDiskSpace(
                bytes: Int64(needed) + 32_000_000,
                near: FileManager.default.temporaryDirectory
            )
        }

        let clipped = try PCMStore.createTemporary(
            sampleRate: store.sampleRate,
            channelCount: store.channelCount,
            frameCount: store.frameCount
        )
        softClip(
            from: store,
            to: clipped,
            gain: gain,
            ceiling: ceiling
        ) { progress?(0.40 + 0.35 * $0) }
        clipped.sync()

        let dest = try PCMStore.createTemporary(
            sampleRate: store.sampleRate,
            channelCount: store.channelCount,
            frameCount: store.frameCount
        )
        truePeakLimit(from: clipped, to: dest, gain: 1, ceiling: ceiling) { progress?(0.75 + 0.12 * $0) }
        dest.sync()

        let after = analyze(dest) { progress?(0.87 + 0.13 * $0) }
        progress?(1)
        let netGainDb = after.integratedLUFS - before.integratedLUFS
        return (dest, after, netGainDb)
    }

    // MARK: - Streaming helpers

    private static func meanSquareFromRing(
        _ ring: [Float],
        channels: Int,
        write: Int,
        capacity: Int,
        filled: Int,
        window: Int
    ) -> Float {
        let win = min(window, filled)
        guard win > 0, capacity > 0 else { return 0 }
        var acc: Float = 0
        var n: Float = 0
        var idx = write - win
        if idx < 0 { idx += capacity }
        for _ in 0..<win {
            let base = idx * channels
            for c in 0..<channels {
                let x = ring[base + c]
                acc += x * x
                n += 1
            }
            idx += 1
            if idx == capacity { idx = 0 }
        }
        return n > 0 ? acc / n : 0
    }

    private static func averageLUFS(_ blocks: [Float]) -> Float {
        var sum: Float = 0
        for l in blocks {
            sum += pow(10.0, l / 10.0)
        }
        let mean = sum / Float(blocks.count)
        return 10 * log10(max(mean, 1e-12))
    }

    private static func copyGained(
        from source: PCMStore,
        to dest: PCMStore,
        gain: Float,
        progress: (@Sendable (Double) -> Void)? = nil
    ) {
        let ch = source.channelCount
        let frames = source.frameCount
        var tmp = [Float](repeating: 0, count: chunkFrames * ch)
        var pos = 0
        var lastPct = -1
        source.adviseSequential()
        dest.adviseSequential()
        while pos < frames {
            let n = source.copyFrames(start: pos, count: min(chunkFrames, frames - pos), into: &tmp)
            guard n > 0 else { break }
            if gain != 1 {
                let count = n * ch
                for i in 0..<count { tmp[i] *= gain }
            }
            dest.write(interleaved: tmp, startFrame: pos, frames: n)
            pos += n
            let pct = Int((Double(pos) / Double(frames)) * 100.0)
            if pct != lastPct {
                lastPct = pct
                progress?(Double(pos) / Double(frames))
            }
        }
    }

    /// Makeup gain → tanh soft clip → hard clip at `ceiling`.
    private static func softClip(
        from source: PCMStore,
        to dest: PCMStore,
        gain: Float,
        ceiling: Float,
        progress: (@Sendable (Double) -> Void)? = nil
    ) {
        let ch = source.channelCount
        let frames = source.frameCount
        let ceilingLin = max(ceiling, 1e-4)
        let drive: Float = 1.8
        var tmp = [Float](repeating: 0, count: chunkFrames * ch)
        var pos = 0
        var lastPct = -1
        source.adviseSequential()
        dest.adviseSequential()
        while pos < frames {
            let n = source.copyFrames(start: pos, count: min(chunkFrames, frames - pos), into: &tmp)
            guard n > 0 else { break }
            let count = n * ch
            for i in 0..<count {
                let x = tmp[i] * gain
                var y = ceilingLin * tanh(drive * x / ceilingLin)
                if y > ceilingLin { y = ceilingLin }
                if y < -ceilingLin { y = -ceilingLin }
                tmp[i] = y
            }
            dest.write(interleaved: tmp, startFrame: pos, frames: n)
            pos += n
            let pct = Int((Double(pos) / Double(frames)) * 100.0)
            if pct != lastPct {
                lastPct = pct
                progress?(Double(pos) / Double(frames))
            }
        }
    }

    /// Lookahead true-peak limiter. Turns down only around peaks that would break
    /// the ceiling, so average loudness can stay close to the LUFS target.
    private static func truePeakLimit(
        from source: PCMStore,
        to dest: PCMStore,
        gain: Float,
        ceiling: Float,
        progress: (@Sendable (Double) -> Void)? = nil
    ) {
        let ch = max(1, source.channelCount)
        let sr = source.sampleRate
        let frames = source.frameCount
        guard frames > 0 else { return }

        let ceilingLin = max(ceiling, 1e-4)
        let look = max(1, Int(0.002 * sr))
        let releaseN = max(1.0, Float(0.05 * sr))
        let rel = exp(-1.0 / releaseN)

        var env: Float = 1
        var delay = [Float](repeating: 0, count: look * ch)
        var delayWrite = 0
        var delayFilled = 0
        var tmp = [Float](repeating: 0, count: (chunkFrames + 1) * ch)
        var outChunk = [Float](repeating: 0, count: chunkFrames * ch)
        var outCount = 0
        var destPos = 0
        var lastPct = -1

        source.adviseSequential()
        dest.adviseSequential()

        func updateEnv(peak: Float) {
            let needed: Float = (peak > ceilingLin && peak > 1e-12) ? ceilingLin / peak : 1
            if needed < env {
                env = needed
            } else {
                env += (needed - env) * (1 - rel)
                if env > 1 { env = 1 }
            }
        }

        func flushOut() {
            guard outCount > 0 else { return }
            dest.write(interleaved: outChunk, startFrame: destPos, frames: outCount)
            destPos += outCount
            outCount = 0
        }

        func emitOldest() {
            let g = env
            let base = delayWrite * ch
            for c in 0..<ch {
                outChunk[outCount * ch + c] = delay[base + c] * g
            }
            outCount += 1
            if outCount == chunkFrames {
                flushOut()
            }
        }

        func pushGainedFrame(_ base: Int) {
            if delayFilled == look {
                emitOldest()
            }
            for c in 0..<ch {
                delay[delayWrite * ch + c] = tmp[base + c]
            }
            delayWrite += 1
            if delayWrite == look { delayWrite = 0 }
            if delayFilled < look { delayFilled += 1 }
        }

        func peakAt(base: Int, nextBase: Int) -> Float {
            var peak: Float = 0
            for c in 0..<ch {
                let x = tmp[base + c]
                let xn = tmp[nextBase + c]
                peak = max(peak, abs(x))
                peak = max(peak, abs(x + (xn - x) * 0.25))
                peak = max(peak, abs(x + (xn - x) * 0.50))
                peak = max(peak, abs(x + (xn - x) * 0.75))
            }
            return peak
        }

        var pos = 0
        while pos < frames {
            let n = source.copyFrames(start: pos, count: min(chunkFrames, frames - pos), into: &tmp)
            guard n > 0 else { break }
            let count = n * ch
            if gain != 1 {
                for i in 0..<count { tmp[i] *= gain }
            }
            if pos + n < frames {
                tmp.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    _ = source.copyFrames(start: pos + n, count: 1, into: base.advanced(by: n * ch))
                }
                if gain != 1 {
                    for c in 0..<ch { tmp[n * ch + c] *= gain }
                }
            } else {
                for c in 0..<ch { tmp[n * ch + c] = tmp[(n - 1) * ch + c] }
            }

            for f in 0..<n {
                updateEnv(peak: peakAt(base: f * ch, nextBase: (f + 1) * ch))
                pushGainedFrame(f * ch)
            }

            pos += n
            let pct = Int((Double(pos) / Double(frames)) * 100.0)
            if pct != lastPct {
                lastPct = pct
                progress?(Double(pos) / Double(max(1, frames)))
            }
        }

        for _ in 0..<look {
            updateEnv(peak: 0)
            if delayFilled == look {
                emitOldest()
                delayWrite += 1
                if delayWrite == look { delayWrite = 0 }
            }
        }

        flushOut()

        let leftover = leftoverTruePeak(store: dest)
        if leftover > ceilingLin && leftover > 1e-8 {
            copyGained(from: dest, to: dest, gain: ceilingLin / leftover)
        }
    }

    private static func leftoverTruePeak(store: PCMStore) -> Float {
        let ch = store.channelCount
        let frames = store.frameCount
        var peak: Float = 1e-12
        var prev = [Float](repeating: 0, count: ch)
        var tmp = [Float](repeating: 0, count: chunkFrames * ch)
        var pos = 0
        while pos < frames {
            let n = store.copyFrames(start: pos, count: min(chunkFrames, frames - pos), into: &tmp)
            guard n > 0 else { break }
            for f in 0..<n {
                let base = f * ch
                for c in 0..<ch {
                    let x = tmp[base + c]
                    peak = max(peak, abs(x))
                    let p = prev[c]
                    peak = max(peak, abs(p + (x - p) * 0.25))
                    peak = max(peak, abs(p + (x - p) * 0.50))
                    peak = max(peak, abs(p + (x - p) * 0.75))
                    prev[c] = x
                }
            }
            pos += n
        }
        return peak
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
