import SwiftUI

enum DorroughLook {
    static let chassisHi = Color(red: 0.30, green: 0.32, blue: 0.34)
    static let chassisMid = Color(red: 0.16, green: 0.17, blue: 0.19)
    static let chassisLo = Color(red: 0.07, green: 0.08, blue: 0.09)
    static let well = Color(red: 0.015, green: 0.02, blue: 0.02)
    static let scale = Color(red: 0.93, green: 0.90, blue: 0.58)
    static let silk = Color(red: 0.78, green: 0.78, blue: 0.72)
    static let ledGreen = Color(red: 0.18, green: 0.96, blue: 0.32)
    static let ledYellow = Color(red: 1.0, green: 0.84, blue: 0.08)
    static let ledRed = Color(red: 1.0, green: 0.14, blue: 0.10)
    static let ledOff = Color(red: 0.06, green: 0.09, blue: 0.06)
    static let cream = Color(red: 0.91, green: 0.89, blue: 0.82)
    static let creamHi = Color(red: 0.97, green: 0.96, blue: 0.92)
    static let lcd = Color(red: 1.0, green: 0.72, blue: 0.18)
    static let ceilingDb: Float = 3
    static let floorDb: Float = -42
    static let segments = 48
    static let verticalInset: CGFloat = 7

    static func fraction(db: Float) -> CGFloat {
        let n = (db - floorDb) / (ceilingDb - floorDb)
        return CGFloat(max(0, min(1, n)))
    }

    static func ledColor(db: Float) -> Color {
        if db >= 0 { return ledRed }
        if db >= -9 { return ledYellow }
        return ledGreen
    }
}

struct DorroughMeterDeck: View {
    @ObservedObject var session: LevelerSession

    var body: some View {
        HStack(alignment: .center, spacing: LevelerLayout.meterDeckSpacing) {
            DorroughFaceplate(
                title: "PRE",
                sample: session.livePre,
                holdL: session.preHoldL,
                holdR: session.preHoldR,
                overs: session.preOvers,
                mode: session.meterMode,
                active: true
            )
            DorroughFaceplate(
                title: "POST",
                sample: session.livePost,
                holdL: session.postHoldL,
                holdR: session.postHoldR,
                overs: session.postOvers,
                mode: session.meterMode,
                active: session.hasResult
            )
            meterControls
        }
        .padding(LevelerLayout.meterDeckPadding)
        .levelerPanel()
    }

    private var meterControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            controlGroup(label: "PEAK") {
                HardwareLitButton(
                    title: "HOLD",
                    lit: session.peakHold,
                    led: DorroughLook.ledYellow
                ) {
                    session.peakHold.toggle()
                }
                .help("Hold keeps the highest reading on each column until you hit Reset.")

                HardwareLitButton(
                    title: "RESET",
                    lit: false,
                    led: DorroughLook.ledRed
                ) {
                    session.resetPeakHold()
                }
                .help("Clear peak holds and overs lamps.")
            }

            controlGroup(label: "METER MODE") {
                HardwareLitButton(
                    title: "RMS",
                    lit: session.meterMode == .rms,
                    led: DorroughLook.ledGreen
                ) {
                    session.setMeterMode(.rms)
                }
                .help("Average level (loudness-style). Slower than peak.")

                HardwareLitButton(
                    title: "TRUE PEAK",
                    lit: session.meterMode == .truePeak,
                    led: DorroughLook.ledYellow
                ) {
                    session.setMeterMode(.truePeak)
                }
                .help("Inter-sample true peak. Best match for the limiter ceiling.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("OVERS")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(DorroughLook.silk)
                HStack(spacing: 10) {
                    oversLamp(title: "PRE", on: session.preOvers)
                    oversLamp(title: "POST", on: session.postOvers)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: LevelerLayout.meterControlsWidth)
        .padding(.vertical, 4)
    }

    private func controlGroup(label: String, @ViewBuilder buttons: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(DorroughLook.silk)
            VStack(spacing: 6) {
                buttons()
            }
        }
    }

    private func oversLamp(title: String, on: Bool) -> some View {
        VStack(spacing: 3) {
            Circle()
                .fill(on ? DorroughLook.ledRed : Color(white: 0.12))
                .frame(width: 10, height: 10)
                .shadow(color: on ? DorroughLook.ledRed.opacity(0.9) : .clear, radius: on ? 5 : 0)
                .overlay(Circle().stroke(Color(white: 0.35), lineWidth: 0.6))
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(DorroughLook.silk)
        }
    }
}

struct DorroughFaceplate: View {
    var title: String
    var sample: LiveMeterSample
    var holdL: Float
    var holdR: Float
    var overs: Bool
    var mode: LevelerMeterMode
    var active: Bool

    private var live: (Float, Float) { sample.display(mode: mode) }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(DorroughLook.silk)
                Spacer()
                Text(mode.unit)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(DorroughLook.scale.opacity(0.8))
            }

            HStack(alignment: .top, spacing: 3) {
                scaleColumn(align: .trailing)
                ledWell(level: live.0, hold: holdL)
                ledWell(level: live.1, hold: holdR)
                scaleColumn(align: .leading)
            }
            .frame(height: LevelerLayout.meterStackHeight)
            .opacity(active ? 1 : 0.38)

            HStack {
                Text("L")
                    .frame(maxWidth: .infinity)
                Text("R")
                    .frame(maxWidth: .infinity)
            }
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(DorroughLook.silk)
            .padding(.horizontal, 8)

            readout
        }
        .padding(8)
        .frame(width: LevelerLayout.faceplateWidth)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [DorroughLook.chassisHi, DorroughLook.chassisMid, DorroughLook.chassisLo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.2
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
    }

    private var readout: some View {
        VStack(spacing: 3) {
            HStack {
                lcdValue("L", live.0)
                Spacer()
                lcdValue("R", live.1)
            }
            HStack {
                lcdValue("PK", holdL)
                Spacer()
                lcdValue("PK", holdR)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func lcdValue(_ label: String, _ db: Float) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(DorroughLook.silk.opacity(0.75))
            Text(formatDb(db))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(db >= 0 ? DorroughLook.ledRed : DorroughLook.lcd)
                .shadow(color: (db >= 0 ? DorroughLook.ledRed : DorroughLook.lcd).opacity(0.45), radius: 3)
        }
    }

    private func formatDb(_ db: Float) -> String {
        if db <= -79.5 { return "—∞" }
        return String(format: "%+.1f", db)
    }

    private func scaleColumn(align: Alignment) -> some View {
        let marks: [Float] = [3, 0, -3, -6, -9, -12, -18, -24, -30, -40]
        return GeometryReader { geo in
            ForEach(marks, id: \.self) { db in
                let y = DorroughLook.verticalInset
                    + (geo.size.height - 2 * DorroughLook.verticalInset)
                    * (1 - DorroughLook.fraction(db: db))
                HStack(spacing: 3) {
                    if align == .leading, db == 0 {
                        Text("FS")
                            .foregroundStyle(DorroughLook.ledYellow)
                    }
                    Text(scaleLabel(db))
                        .foregroundStyle(db >= 0 ? DorroughLook.ledRed : DorroughLook.scale)
                    if align == .trailing, db == 0 {
                        Text("FS")
                            .foregroundStyle(DorroughLook.ledYellow)
                    }
                }
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .frame(width: geo.size.width, alignment: align)
                .position(x: geo.size.width / 2, y: y)
            }
        }
        .frame(width: LevelerLayout.scaleWidth)
    }

    private func scaleLabel(_ db: Float) -> String {
        if db > 0 { return "+\(Int(db))" }
        if db == 0 { return "0" }
        return "\(Int(abs(db)))"
    }

    private func ledWell(level: Float, hold: Float) -> some View {
        Canvas { context, size in
            let segs = DorroughLook.segments
            let gap: CGFloat = 1.1
            let inset = DorroughLook.verticalInset
            let innerH = size.height - inset * 2
            let segH = (innerH - CGFloat(segs - 1) * gap) / CGFloat(segs)
            let span = DorroughLook.ceilingDb - DorroughLook.floorDb

            for i in 0..<segs {
                let segHigh = DorroughLook.ceilingDb - Float(i) * span / Float(segs)
                let segLow = DorroughLook.ceilingDb - Float(i + 1) * span / Float(segs)
                let y = inset + CGFloat(i) * (segH + gap)
                let lit = level >= segLow - 0.01
                var color = DorroughLook.ledColor(db: segHigh - 0.01)
                if !lit {
                    color = DorroughLook.ledOff
                }
                let rect = CGRect(x: 1, y: y, width: size.width - 2, height: max(1.2, segH))
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 0.8),
                    with: .color(color)
                )
                if lit {
                    context.fill(
                        Path(roundedRect: rect.insetBy(dx: 1.2, dy: 0.4), cornerRadius: 0.6),
                        with: .color(Color.white.opacity(segHigh >= 0 ? 0.18 : 0.12))
                    )
                }
            }

            let holdFrac = DorroughLook.fraction(db: hold)
            if hold > DorroughLook.floorDb + 0.5 {
                let y = inset + (1 - holdFrac) * innerH
                let pip = CGRect(x: 0, y: max(0, y - 1.4), width: size.width, height: 2.6)
                context.fill(Path(roundedRect: pip, cornerRadius: 0.8), with: .color(.white))
                context.fill(
                    Path(roundedRect: pip.insetBy(dx: 0.4, dy: 0.4), cornerRadius: 0.5),
                    with: .color(DorroughLook.ledYellow)
                )
            }
        }
        .padding(3)
        .frame(width: LevelerLayout.ledColumnWidth)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(DorroughLook.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.black.opacity(0.8), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if overs {
                Circle()
                    .fill(DorroughLook.ledRed)
                    .frame(width: 6, height: 6)
                    .shadow(color: DorroughLook.ledRed, radius: 4)
                    .offset(x: -3, y: 3)
            }
        }
    }
}

struct HardwareLitButton: View {
    var title: String
    var lit: Bool
    var led: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Circle()
                    .fill(lit ? led : Color(white: 0.18))
                    .frame(width: 8, height: 8)
                    .shadow(color: lit ? led.opacity(0.95) : .clear, radius: lit ? 4 : 0)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.6))
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.3)
                    .foregroundStyle(Color(white: 0.15))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: lit
                                ? [DorroughLook.creamHi, DorroughLook.cream]
                                : [Color(white: 0.78), Color(white: 0.58)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }
}

struct LoudnessCompareBoard: View {
    var before: LoudnessReport
    var after: LoudnessReport
    var gainDb: Float
    var hasResult: Bool
    var targetLUFS: Float
    var targetTP: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("FILE LOUDNESS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(LevelerTheme.cyanDim)
                Spacer()
                Text(String(format: "TARGET  %.1f LUFS  ·  %.1f dBTP", targetLUFS, targetTP))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(LevelerTheme.cyan)
            }

            HStack(alignment: .top, spacing: 8) {
                loudnessCard(title: "PRE", report: before, glow: false)
                gainPill
                loudnessCard(title: "POST", report: after, glow: hasResult)
            }
        }
        .padding(12)
        .levelerPanel(glow: hasResult)
    }

    private var gainPill: some View {
        VStack(spacing: 4) {
            Text("GAIN")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(LevelerTheme.cyanDim)
            Text(hasResult ? String(format: "%+.1f", gainDb) : "—")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(hasResult ? LevelerTheme.lime : LevelerTheme.textSecondary)
            Text("dB")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(LevelerTheme.textSecondary)
        }
        .frame(width: 58)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LevelerTheme.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(LevelerTheme.lime.opacity(hasResult ? 0.55 : 0.15), lineWidth: 1)
        )
        .padding(.top, 18)
    }

    private func loudnessCard(title: String, report: LoudnessReport, glow: Bool) -> some View {
        let accent = glow ? LevelerTheme.lime : LevelerTheme.cyan
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(formatLUFS(report.integratedLUFS))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(0.35), radius: 6)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("INTEGRATED LUFS")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(LevelerTheme.textSecondary)
            }

            VStack(spacing: 4) {
                metric("SHORT-TERM", formatLUFS(report.shortTermLUFS), unit: "LUFS", accent: accent)
                metric("MOMENTARY", formatLUFS(report.momentaryLUFS), unit: "LUFS", accent: accent)
                metric("TRUE PEAK", formatPeak(report.truePeakDbTP), unit: "dBTP", accent: peakColor(report.truePeakDbTP, fallback: accent))
                metric("SAMPLE PEAK", formatPeak(report.samplePeakDbFS), unit: "dBFS", accent: accent)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LevelerTheme.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accent.opacity(glow ? 0.85 : 0.35), lineWidth: glow ? 1.4 : 1)
        )
    }

    private func metric(_ label: String, _ value: String, unit: String, accent: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(LevelerTheme.textSecondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(unit)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(LevelerTheme.textSecondary)
                .frame(width: 32, alignment: .leading)
        }
    }

    private func formatLUFS(_ value: Float) -> String {
        value <= -69 ? "—" : String(format: "%.1f", value)
    }

    private func formatPeak(_ value: Float) -> String {
        value <= -80 ? "—" : String(format: "%+.1f", value)
    }

    private func peakColor(_ value: Float, fallback: Color) -> Color {
        if value > -0.1 { return LevelerTheme.meterRed }
        if value > -1.0 { return LevelerTheme.meterYellow }
        return fallback
    }
}
