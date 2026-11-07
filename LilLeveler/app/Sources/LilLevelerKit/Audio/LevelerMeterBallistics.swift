import Foundation

enum LevelerMeterMode: String, CaseIterable, Identifiable {
    case rms = "RMS"
    case truePeak = "TRUE PEAK"
    var id: String { rawValue }
    var unit: String { self == .truePeak ? "dBTP" : "dBFS" }
}

/// One stereo snapshot for the Dorrough faceplates (dB, −80 floor).
struct LiveMeterSample: Equatable, Sendable {
    var rmsL: Float
    var rmsR: Float
    var tpL: Float
    var tpR: Float

    static let silent = LiveMeterSample(rmsL: -80, rmsR: -80, tpL: -80, tpR: -80)

    func display(mode: LevelerMeterMode) -> (left: Float, right: Float) {
        switch mode {
        case .rms: return (rmsL, rmsR)
        case .truePeak: return (tpL, tpR)
        }
    }
}

/// Per-side RMS + 4× true-peak ballistics for the audio thread.
struct MeterBallistics {
    var rmsMsL: Float = 1e-12
    var rmsMsR: Float = 1e-12
    var tpL: Float = 0
    var tpR: Float = 0
    var prevL: Float = 0
    var prevR: Float = 0

    mutating func reset() {
        rmsMsL = 1e-12
        rmsMsR = 1e-12
        tpL = 0
        tpR = 0
        prevL = 0
        prevR = 0
    }

    mutating func process(left: Float, right: Float, sampleRate: Double) {
        let sr = max(sampleRate, 1)
        let atk = Float(1 - exp(-1.0 / (0.010 * sr)))
        let rel = Float(1 - exp(-1.0 / (0.300 * sr)))
        integrateRMS(left, state: &rmsMsL, attack: atk, release: rel)
        integrateRMS(right, state: &rmsMsR, attack: atk, release: rel)

        let decay = Float(exp(-1.0 / (1.5 * sr)))
        truePeak(left, prev: &prevL, state: &tpL, decay: decay)
        truePeak(right, prev: &prevR, state: &tpR, decay: decay)
    }

    var snapshot: LiveMeterSample {
        LiveMeterSample(
            rmsL: Self.toDb(sqrt(max(rmsMsL, 1e-12))),
            rmsR: Self.toDb(sqrt(max(rmsMsR, 1e-12))),
            tpL: Self.toDb(tpL),
            tpR: Self.toDb(tpR)
        )
    }

    static func toDb(_ linear: Float) -> Float {
        20 * log10(max(linear, 1e-4)) // −80 dB floor
    }

    private func integrateRMS(_ x: Float, state: inout Float, attack: Float, release: Float) {
        let sq = x * x
        state += (sq > state ? attack : release) * (sq - state)
    }

    private func truePeak(_ x: Float, prev: inout Float, state: inout Float, decay: Float) {
        var peak = abs(x)
        for k in 1..<4 {
            let t = Float(k) / 4
            peak = max(peak, abs(prev + (x - prev) * t))
        }
        prev = x
        if peak > state {
            state = peak
        } else {
            state *= decay
        }
    }
}
