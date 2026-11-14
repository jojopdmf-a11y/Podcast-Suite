import Accelerate
import Foundation

/// Real-time analyzer: Hann-windowed FFT → log-spaced magnitude bins with smooth decay.
final class RTAAnalyzer: @unchecked Sendable {
    static let fftSize = 2048
    static let displayBins = 52

    private var ring: [Float]
    private var writePos = 0
    private var samplesSeen = 0
    private var window: [Float]
    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length = 11
    private var display: [Float]
    private var splitReal: [Float]
    private var splitImag: [Float]
    private var magnitudes: [Float]

    init() {
        ring = Array(repeating: 0, count: Self.fftSize)
        window = Array(repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        display = Array(repeating: 0, count: Self.displayBins)
        splitReal = Array(repeating: 0, count: Self.fftSize / 2)
        splitImag = Array(repeating: 0, count: Self.fftSize / 2)
        magnitudes = Array(repeating: 0, count: Self.fftSize / 2)
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func reset() {
        ring = Array(repeating: 0, count: Self.fftSize)
        writePos = 0
        samplesSeen = 0
        display = Array(repeating: 0, count: Self.displayBins)
    }

    func push(_ sample: Float) {
        ring[writePos] = sample
        writePos += 1
        if writePos >= Self.fftSize { writePos = 0 }
        samplesSeen += 1
    }

    /// Returns 0…1 display bins (log frequency). Call on the UI/meter cadence, not every sample.
    func computeBins(sampleRate: Double) -> [Float] {
        guard let fftSetup, samplesSeen >= Self.fftSize / 8 else {
            // Idle decay
            for i in display.indices { display[i] *= 0.85 }
            return display
        }

        var timeDomain = [Float](repeating: 0, count: Self.fftSize)
        let start = writePos
        for i in 0..<Self.fftSize {
            timeDomain[i] = ring[(start + i) % Self.fftSize] * window[i]
        }

        // Pack for vDSP FFT (even→real, odd→imag of split complex)
        timeDomain.withUnsafeBufferPointer { src in
            splitReal.withUnsafeMutableBufferPointer { real in
                splitImag.withUnsafeMutableBufferPointer { imag in
                    var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
                }
            }
        }

        // Fix DC / Nyquist packing scale a bit
        magnitudes[0] *= 0.5

        let nyquist = sampleRate * 0.5
        let fMin = 40.0
        let fMax = min(16_000.0, nyquist * 0.98)
        let binHz = sampleRate / Double(Self.fftSize)

        var peaks = [Float](repeating: 0, count: Self.displayBins)
        for b in 0..<Self.displayBins {
            let t0 = Double(b) / Double(Self.displayBins)
            let t1 = Double(b + 1) / Double(Self.displayBins)
            let f0 = fMin * pow(fMax / fMin, t0)
            let f1 = fMin * pow(fMax / fMin, t1)
            let i0 = max(1, Int(f0 / binHz))
            let i1 = min(magnitudes.count - 1, max(i0 + 1, Int(f1 / binHz)))
            var peak: Float = 0
            for i in i0..<i1 {
                peak = max(peak, magnitudes[i])
            }
            // dB-ish normalize into 0…1
            let db = 20 * log10(max(peak / Float(Self.fftSize), 1e-8))
            let norm = (db + 80) / 70 // roughly -80…-10 → 0…1
            peaks[b] = max(0, min(1, norm))
        }

        // Fast attack / slower release for a lively but readable RTA
        for i in 0..<Self.displayBins {
            if peaks[i] > display[i] {
                display[i] = display[i] * 0.35 + peaks[i] * 0.65
            } else {
                display[i] = display[i] * 0.82 + peaks[i] * 0.18
            }
        }
        return display
    }
}
