import Foundation

/// Stereo bus compressor / soft-limiter inspired by classic feed-forward console comps (API 2500–style controls).
/// Linked L/R detection. No thrust / type / shape / unlink.
struct MasterCompressorDSP {
    var bypass: Bool = false
    var thresholdDb: Float = -12
    var attackMs: Float = 1
    var ratio: Float = 4 // use >= 40 for ∞
    var releaseSec: Float = 0.5
    /// 0 hard, 1 medium, 2 soft
    var knee: Int = 1
    var outputDb: Float = 0
    var autoMakeup: Bool = true

    private var env: Float = 0
    private var grLin: Float = 1

    /// Last meter taps (linear absolute).
    private(set) var meterInL: Float = 0
    private(set) var meterInR: Float = 0
    private(set) var meterOutL: Float = 0
    private(set) var meterOutR: Float = 0
    /// Gain reduction in dB (positive number = how much was reduced).
    private(set) var meterGRDb: Float = 0

    mutating func reset() {
        env = 0
        grLin = 1
        meterInL = 0
        meterInR = 0
        meterOutL = 0
        meterOutR = 0
        meterGRDb = 0
    }

    mutating func process(left xl: Float, right xr: Float, sampleRate: Double) -> (Float, Float) {
        meterInL = abs(xl)
        meterInR = abs(xr)

        if bypass {
            meterOutL = abs(xl)
            meterOutR = abs(xr)
            meterGRDb = 0
            grLin = 1
            return (xl, xr)
        }

        let det = max(abs(xl), abs(xr))
        let atk = exp(-1.0 / (max(0.03, attackMs) * 0.001 * Float(sampleRate)))
        let rel = exp(-1.0 / (max(0.05, releaseSec) * Float(sampleRate)))
        if det > env {
            env = atk * env + (1 - atk) * det
        } else {
            env = rel * env + (1 - rel) * det
        }

        let levelDb = 20 * log10(max(env, 1e-8))
        let thresh = thresholdDb
        let kneeWidth: Float
        switch knee {
        case 0: kneeWidth = 0
        case 2: kneeWidth = 12
        default: kneeWidth = 6
        }

        let r = max(ratio, 1.01)
        var grDb: Float = 0
        if kneeWidth < 0.1 {
            if levelDb > thresh {
                grDb = (thresh - levelDb) * (1 - 1 / r)
            }
        } else {
            let half = kneeWidth * 0.5
            if levelDb > (thresh + half) {
                grDb = (thresh - levelDb) * (1 - 1 / r)
            } else if levelDb > (thresh - half) {
                let x = levelDb - thresh + half
                grDb = ((1 / r - 1) * (x * x)) / (2 * kneeWidth)
            }
        }
        // Soft ceiling when ratio is “∞”
        if r >= 40, levelDb > thresh {
            grDb = min(grDb, thresh - levelDb)
        }

        let targetGR = pow(10.0, grDb / 20.0)
        let grAtk = exp(-1.0 / (0.002 * Float(sampleRate)))
        let grRel = exp(-1.0 / (max(0.05, releaseSec) * Float(sampleRate)))
        if targetGR < grLin {
            grLin = grAtk * grLin + (1 - grAtk) * targetGR
        } else {
            grLin = grRel * grLin + (1 - grRel) * targetGR
        }

        meterGRDb = max(0, -20 * log10(max(grLin, 1e-6)))

        var makeup: Float = 1
        if autoMakeup {
            // Mild automatic makeup toward threshold engagement
            let approx = min(8, meterGRDb * 0.35)
            makeup = pow(10.0, approx / 20.0)
        }
        let outGain = pow(10.0, outputDb / 20.0) * makeup

        var ol = xl * grLin * outGain
        var orr = xr * grLin * outGain

        // Gentle bus limiter / soft clip
        ol = softLimit(ol, ceiling: 0.98)
        orr = softLimit(orr, ceiling: 0.98)

        meterOutL = abs(ol)
        meterOutR = abs(orr)
        return (ol, orr)
    }

    private func softLimit(_ x: Float, ceiling: Float) -> Float {
        let c = max(ceiling, 1e-4)
        return c * tanhf(x / c)
    }
}

struct MasterCompressorState: Equatable {
    var bypass: Bool = false
    var thresholdDb: Float = -12
    var attackMs: Float = 1
    var ratio: Float = 4
    var releaseSec: Float = 0.5
    /// 0 hard, 1 medium, 2 soft
    var knee: Int = 1
    var outputDb: Float = 0
    var autoMakeup: Bool = true

    static let attackStops: [Float] = [0.03, 0.1, 0.3, 1, 3, 10, 30]
    static let ratioStops: [Float] = [1.5, 2, 3, 4, 6, 10, 100]
    static let releaseStops: [Float] = [0.05, 0.1, 0.2, 0.5, 1, 2]
}
