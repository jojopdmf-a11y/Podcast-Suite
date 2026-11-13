import AppKit
import SwiftUI

/// Mid-Y of the voice-strip link gap, in the `stripCluster` coordinate space.
struct StripLinkGapKey: PreferenceKey {
    static let defaultValue: CGFloat = -1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next >= 0 { value = next }
    }
}

/// Height of the flexible fader block on a voice strip (track + readout + caption).
struct StripFaderSectionKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct LevelMeter: View {
    var level: Float
    var label: String
    /// Strip meters: bar matches the fader track, with the same readout spacer above
    /// and the same label slot below. Nil keeps the master column’s flexible meter.
    var barHeight: CGFloat? = nil
    /// Recessed segmented LEDs, the same drawing as strip IN/OUT. Master L/R pass true.
    var stripChrome: Bool = false

    private var dbNorm: CGFloat {
        let db = 20 * log10(max(level, 1e-5))
        let norm = (db + 60) / 60
        return CGFloat(max(0, min(1, norm)))
    }

    var body: some View {
        if let barHeight {
            VStack(spacing: VerticalFader.stackSpacing) {
                Color.clear.frame(height: VerticalFader.readoutHeight)
                meterBar(height: barHeight)
                meterLabel
                    .frame(height: VerticalFader.captionHeight)
            }
        } else {
            VStack(spacing: 2) {
                GeometryReader { geo in
                    meterBar(height: geo.size.height)
                }
                .frame(width: 8)
                meterLabel
            }
        }
    }

    @ViewBuilder
    private func meterBar(height: CGFloat) -> some View {
        if stripChrome {
            StripLEDMeter(fraction: dbNorm)
                .frame(width: 8, height: height)
        } else {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(MixerTheme.cyanFaint)
                RoundedRectangle(cornerRadius: 2)
                    .fill(meterColor)
                    .frame(height: max(0, height * dbNorm))
                    .shadow(color: meterColor.opacity(0.5), radius: 3)
            }
            .frame(width: 8, height: height)
        }
    }

    @ViewBuilder
    private var meterLabel: some View {
        if stripChrome {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(MixerTheme.cyanDim)
        } else {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(MixerTheme.cyanDim)
        }
    }

    private var meterColor: Color {
        // 60 dB meter: yellow was −18, red −6. Shift both +6 dB.
        if dbNorm >= 1.0 { return MixerTheme.meterRed }
        if dbNorm > 0.8 { return MixerTheme.meterYellow }
        return MixerTheme.meterGreen
    }
}

/// Strip IN/OUT. Segments use the same thresholds as `LevelMeter.meterColor`:
/// red at 0 dBFS, yellow above −12 dB, green below that.
private struct StripLEDMeter: View {
    var fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 1.5
            let innerH = max(4, geo.size.height - inset * 2)
            let innerW = max(2, geo.size.width - inset * 2)
            let count = max(8, Int((innerH / 3.2).rounded()))
            let gap: CGFloat = 1
            let segH = max(1, (innerH - gap * CGFloat(count - 1)) / CGFloat(count))
            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                VStack(spacing: gap) {
                    ForEach(0..<count, id: \.self) { i in
                        let bottom = CGFloat(count - 1 - i) / CGFloat(count)
                        let top = CGFloat(count - i) / CGFloat(count)
                        let on = fraction > bottom + 0.0001
                        let color = segmentColor(top)
                        RoundedRectangle(cornerRadius: 0.4, style: .continuous)
                            .fill(on ? color : Color(white: 0.09))
                            .frame(width: innerW, height: segH)
                            .shadow(color: on ? color.opacity(0.65) : .clear, radius: on ? 1.1 : 0)
                    }
                }
                .padding(inset)
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.black.opacity(0.45), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(6, geo.size.height * 0.18))
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .allowsHitTesting(false)
            }
        }
    }

    private func segmentColor(_ topNorm: CGFloat) -> Color {
        if topNorm >= 1 { return MixerTheme.meterRed }
        if topNorm > 0.8 { return MixerTheme.meterYellow }
        return MixerTheme.meterGreen
    }
}

struct VerticalFader: View {
    @Binding var valueDb: Float
    var autoDriven: Bool = false
    var defaultValue: Float = 0
    var range: ClosedRange<Float> = -60...12
    var caption: String? = nil
    /// Master column: the track grows to the height the parent proposes.
    var expands: Bool = false
    /// Strip faders: exact slot height. dB position is a fraction of this slot, so the
    /// taper stays put when the window gives the strip a different travel.
    var trackHeight: CGFloat? = nil
    /// Recessed slot, dB ticks, machined cap. Master leaves this off.
    var stripChrome: Bool = false

    /// Cap-center travel never goes below this. Slot height is travel plus the cap.
    static let minTravel: CGFloat = 90
    static let capHeight: CGFloat = 22
    static var minTrackHeight: CGFloat { minTravel + capHeight }
    /// Fixed chrome around the moving slot (dB readout, gaps, FADER caption).
    static let readoutHeight: CGFloat = 13
    static let captionHeight: CGFloat = 13
    static let stackSpacing: CGFloat = 4
    static var columnChrome: CGFloat { readoutHeight + captionHeight + stackSpacing * 2 }
    static var minSectionHeight: CGFloat { minTrackHeight + columnChrome }

    private let fixedTrackHeight: CGFloat = 110
    private let capWidth: CGFloat = 28

    private var normalized: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0.5 }
        return CGFloat((valueDb - range.lowerBound) / span)
    }

    private var accent: Color {
        autoDriven ? MixerTheme.lime : MixerTheme.cyan
    }

    var body: some View {
        if expands {
            GeometryReader { geo in
                VStack(spacing: 4) {
                    valueReadout
                    GeometryReader { trackGeo in
                        track(height: max(48, trackGeo.size.height))
                    }
                    captionReadout
                }
                .frame(width: 36, height: geo.size.height, alignment: .top)
            }
            .frame(width: 36)
            .frame(maxHeight: .infinity)
        } else if let trackHeight {
            VStack(spacing: Self.stackSpacing) {
                valueReadout
                    .frame(height: Self.readoutHeight)
                track(height: trackHeight)
                captionReadout
                    .frame(height: Self.captionHeight)
            }
        } else {
            VStack(spacing: 4) {
                valueReadout
                track(height: fixedTrackHeight)
                captionReadout
            }
        }
    }

    private var valueReadout: some View {
        Text(String(format: "%+.0f", valueDb))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(accent)
    }

    @ViewBuilder
    private var captionReadout: some View {
        if stripChrome {
            Text(caption ?? "FADER")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(MixerTheme.cyanDim)
                .padding(.bottom, 1)
        } else {
            Text(caption ?? "FADER")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(MixerTheme.cyanDim)
                .padding(.bottom, 1)
        }
    }

    /// Y of cap center: 1 = top of the range, 0 = bottom.
    private func capCenterY(trackHeight: CGFloat) -> CGFloat {
        let travel = trackHeight - Self.capHeight
        return (1 - normalized) * travel + Self.capHeight / 2
    }

    private func zeroTickOffset(trackHeight: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        let zeroNorm = CGFloat((0 - range.lowerBound) / span)
        let travel = trackHeight - 8
        return travel / 2 - zeroNorm * travel
    }

    private func track(height trackHeight: CGFloat) -> some View {
        Group {
            if stripChrome {
                consoleTrack(height: trackHeight)
            } else {
                classicTrack(height: trackHeight)
            }
        }
        .frame(width: 36, height: trackHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let y = min(trackHeight, max(0, g.location.y))
                    let travel = trackHeight - Self.capHeight
                    let n = 1 - ((y - Self.capHeight / 2) / max(travel, 1))
                    let clamped = Float(min(1, max(0, n)))
                    let span = range.upperBound - range.lowerBound
                    valueDb = range.lowerBound + clamped * span
                }
        )
        .onTapGesture(count: 2) {
            valueDb = defaultValue
        }
        .help("Double-click to zero")
    }

    /// Master column. Slot, zero tick, and cap position are unchanged.
    private func classicTrack(height trackHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.14), Color(white: 0.08), Color(white: 0.12)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 36, height: trackHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.black.opacity(0.85))
                .frame(width: 5, height: trackHeight - 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 1.5)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.12), Color.clear, Color.white.opacity(0.06)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .overlay(alignment: .center) {
                    Rectangle()
                        .fill(accent.opacity(0.7))
                        .frame(width: 14, height: 1)
                        .offset(y: zeroTickOffset(trackHeight: trackHeight))
                }
                .offset(y: 4)

            FaderCap(accent: accent, autoDriven: autoDriven)
                .frame(width: capWidth, height: Self.capHeight)
                .position(x: 18, y: capCenterY(trackHeight: trackHeight))
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1.5)
        }
    }

    /// Strip slot. Same cap travel as `classicTrack`. The well, ticks, and cap are paint only.
    private func consoleTrack(height trackHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.05), Color(white: 0.015), Color(white: 0.06)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 36, height: trackHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                )
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.55), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: min(14, trackHeight * 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .allowsHitTesting(false)
                }

            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.black.opacity(0.92))
                .frame(width: 5, height: trackHeight - 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 1.5)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.10), Color.clear, Color.white.opacity(0.05)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .offset(y: 4)

            stripFaderTicks(trackHeight: trackHeight)
                .allowsHitTesting(false)

            FaderCap(accent: accent, autoDriven: autoDriven, machined: true)
                .frame(width: capWidth, height: Self.capHeight)
                .position(x: 18, y: capCenterY(trackHeight: trackHeight))
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1.5)
        }
    }

    /// Side ticks on the cap’s travel, every 12 dB, plus the ends of the strip range.
    private func stripFaderTicks(trackHeight: CGFloat) -> some View {
        let marks: [Float] = [12, 0, -12, -24, -36, -48, -60]
        return ZStack {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, db in
                if range.contains(db) {
                    tickPair(db: db, trackHeight: trackHeight)
                }
            }
        }
        .frame(width: 36, height: trackHeight)
    }

    private func tickPair(db: Float, trackHeight: CGFloat) -> some View {
        let y = tickCenterY(db: db, trackHeight: trackHeight)
        let ink = Color.white.opacity(db == 0 ? 0.40 : 0.16)
        return ZStack {
            Capsule()
                .fill(ink)
                .frame(width: 4, height: 1)
                .position(x: 3, y: y)
            Capsule()
                .fill(ink)
                .frame(width: 4, height: 1)
                .position(x: 33, y: y)
        }
        .frame(width: 36, height: trackHeight)
    }

    private func tickCenterY(db: Float, trackHeight: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        let n = CGFloat((db - range.lowerBound) / max(span, 0.0001))
        let travel = trackHeight - Self.capHeight
        return (1 - n) * travel + Self.capHeight / 2
    }
}

/// Console-style plastic / metal fader knob.
private struct FaderCap: View {
    var accent: Color
    var autoDriven: Bool
    /// Strip cap: machined metal and one centre line. Master keeps the ridged cap.
    var machined: Bool = false

    var body: some View {
        if machined {
            machinedBody
        } else {
            classicBody
        }
    }

    private var machinedBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.84),
                            Color(white: 0.64),
                            Color(white: 0.42),
                            Color(white: 0.56),
                            Color(white: 0.34)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.75), Color.black.opacity(0.45)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                )

            Rectangle()
                .fill(accent.opacity(0.95))
                .frame(height: 1.4)
                .padding(.horizontal, 4)
                .shadow(color: accent.opacity(0.45), radius: 1)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 5)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 2)
                .padding(.top, 1.5)
                .allowsHitTesting(false)
        }
    }

    private var classicBody: some View {
        ZStack {
            // Cap body
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: autoDriven
                            ? [Color(white: 0.55), accent.opacity(0.85), Color(white: 0.28)]
                            : [
                                Color(white: 0.92),
                                Color(white: 0.78),
                                Color(white: 0.55),
                                Color(white: 0.68)
                            ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.65), Color.black.opacity(0.35)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )

            // Grip ridges
            VStack(spacing: 2.2) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(Color.black.opacity(i == 2 ? 0.35 : 0.18))
                        .frame(height: 1.2)
                        .padding(.horizontal, 4)
                }
            }

            // Center indicator line
            Rectangle()
                .fill(accent.opacity(0.9))
                .frame(width: 18, height: 1.5)
                .shadow(color: accent.opacity(0.5), radius: 1)

            // Top specular
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.5), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 6)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(1.5)
                .allowsHitTesting(false)
        }
    }
}

/// Pan −1…+1 with ±50 readout; fill grows from center outward toward the thumb.
private struct CenterOutPanSlider: View {
    @Binding var pan: Float

    private var panReadout: Int {
        Int((pan * 50).rounded())
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("PAN")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(MixerTheme.cyanDim)
                Spacer(minLength: 0)
                Text(panReadout == 0 ? "0" : String(format: "%+d", panReadout))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(MixerTheme.lime)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let trackH: CGFloat = 4
                let thumbW: CGFloat = 10
                let travel = max(w - thumbW, 1)
                let norm = CGFloat((pan + 1) / 2) // 0…1
                let thumbX = thumbW / 2 + norm * travel
                let centerX = w / 2
                let fillLeft = min(centerX, thumbX)
                let fillWidth = abs(thumbX - centerX)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.02), Color(white: 0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
                        )
                        .frame(height: trackH)
                        .frame(maxWidth: .infinity)
                        .position(x: w / 2, y: h / 2)

                    Capsule()
                        .fill(MixerTheme.lime.opacity(0.85))
                        .frame(width: max(fillWidth, 0), height: trackH)
                        .position(x: fillLeft + fillWidth / 2, y: h / 2)

                    Rectangle()
                        .fill(MixerTheme.cyan.opacity(0.7))
                        .frame(width: 1.5, height: trackH + 6)
                        .position(x: centerX, y: h / 2)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(white: 0.84), Color(white: 0.55), Color(white: 0.32)],
                                center: UnitPoint(x: 0.38, y: 0.32),
                                startRadius: 0.4,
                                endRadius: thumbW * 0.7
                            )
                        )
                        .overlay(
                            Circle().stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.7), Color.black.opacity(0.45)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.7
                            )
                        )
                        .shadow(color: .black.opacity(0.45), radius: 1, y: 0.5)
                        .frame(width: thumbW, height: thumbW)
                        .position(x: thumbX, y: h / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let x = min(w - thumbW / 2, max(thumbW / 2, g.location.x))
                            let n = (x - thumbW / 2) / travel
                            pan = Float(min(1, max(-1, n * 2 - 1)))
                        }
                )
                .onTapGesture(count: 2) { pan = 0 }
            }
            .frame(height: 16)
        }
        .help("Pan L/R (−50…+50). Double-click to center.")
    }
}

struct GraphicEQView: View {
    @Binding var eq: ChannelEQ

    var body: some View {
        // Keep a compact strip-friendly version; selected panel uses API560EQView
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(GraphicEQBand.allCases) { band in
                VStack(spacing: 3) {
                    Text(gainLabel(eq[band]))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(abs(eq[band]) < 0.05 ? MixerTheme.cyanDim : MixerTheme.lime)
                        .frame(width: 36)
                    Slider(value: Binding(
                        get: { Double(Graphic2520.normalized(fromGainDb: eq[band])) },
                        set: { eq[band] = Graphic2520.gainDb(fromNormalized: Float($0)) }
                    ), in: 0...1)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 120, height: 16)
                    .frame(width: 16, height: 120)
                    .tint(MixerTheme.cyan)
                    .onTapGesture(count: 2) { eq[band] = 0 }
                    Text(band.shortLabel)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(MixerTheme.textSecondary)
                }
            }
        }
    }

    private func gainLabel(_ db: Float) -> String {
        String(format: "%+.1f", db)
    }
}

struct BypassToggle: View {
    @Binding var bypass: Bool
    /// Shorter pill for the DSP cards. Strips keep the full 26 pt control.
    var compact: Bool = false

    var body: some View {
        Button {
            bypass.toggle()
        } label: {
            Text(bypass ? "BYP" : "ON")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .frame(width: 28, height: compact ? 18 : 26)
                .foregroundStyle(MixerTheme.bgBottom)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(bypass ? MixerTheme.danger : MixerTheme.meterGreen)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(bypass ? "Bypassed — click to engage" : "Engaged — click to bypass")
    }
}

private struct StripReorderDrag: ViewModifier {
    var enabled: Bool
    var channelID: Int
    var onDrop: (Int) -> Bool
    var onTargeted: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable("ch:\(channelID)") {
                    Text("MOVE")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(MixerTheme.lime)
                        .foregroundStyle(MixerTheme.bgBottom)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, raw.hasPrefix("ch:"),
                          let moved = Int(raw.dropFirst(3)),
                          moved != channelID else { return false }
                    return onDrop(moved)
                } isTargeted: { targeted in
                    onTargeted(targeted)
                }
        } else {
            content
        }
    }
}

private struct FXChipButton: View {
    var title: String
    var active: Bool
    var bypassed: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(chipForeground)
                .background { StripRecessedPlate(active: active, bypassed: bypassed) }
                .overlay(alignment: .leading) {
                    if active && !bypassed {
                        Circle()
                            .fill(MixerTheme.lime)
                            .frame(width: 4.5, height: 4.5)
                            .shadow(color: MixerTheme.lime.opacity(0.85), radius: 2)
                            .padding(.leading, 5)
                    }
                }
                .opacity(bypassed ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .help("Select channel to edit \(title) in the detail panel")
    }

    private var chipForeground: Color {
        if bypassed { return MixerTheme.textSecondary }
        return MixerTheme.cyan
    }
}

/// Slim recessed chip. Active (the processor is changing the sound) is a lime edge and LED, not a fill.
private struct StripRecessedPlate: View {
    var active: Bool
    var bypassed: Bool

    private var glowing: Bool { active && !bypassed }

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                LinearGradient(
                    colors: bypassed
                        ? [Color(white: 0.07), Color(white: 0.045)]
                        : [Color(white: 0.04), Color(white: 0.085)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.black.opacity(0.85), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(hairline, lineWidth: glowing ? 1.15 : 0.8)
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(height: 2)
                    .blur(radius: 0.4)
                    .padding(.horizontal, 5)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: glowing ? MixerTheme.lime.opacity(0.45) : Color.black.opacity(0.35), radius: glowing ? 3 : 1, y: 1)
    }

    private var hairline: Color {
        if bypassed { return Color.white.opacity(0.08) }
        if glowing { return MixerTheme.lime.opacity(0.9) }
        return DSPPanelStyle.cyan.opacity(0.7)
    }
}

/// Strip ON/BYP. Same 28×26 slot as `BypassToggle`. Master and DSP ALL keep that control.
private struct StripBypassPill: View {
    @Binding var bypass: Bool

    var body: some View {
        Button {
            bypass.toggle()
        } label: {
            DSPBevelPillLabel(
                title: bypass ? "BYP" : "ON",
                lit: true,
                kind: bypass ? .red : .green,
                fontSize: 8,
                fixedSize: CGSize(width: 28, height: 26)
            )
        }
        .buttonStyle(.plain)
        .help(bypass ? "Bypassed — click to engage" : "Engaged — click to bypass")
    }
}

private struct FXRow: View {
    var title: String
    var active: Bool
    @Binding var bypass: Bool
    var onSelect: () -> Void
    var isDropTarget: Bool = false
    var reorderable: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            StripBypassPill(bypass: $bypass)
            FXChipButton(title: title, active: active && !bypass, bypassed: bypass, action: onSelect)
            if reorderable {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MixerTheme.cyanDim)
                    .frame(width: 14)
                    .help("Drag to reorder DSP")
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isDropTarget ? MixerTheme.lime.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isDropTarget ? MixerTheme.lime.opacity(0.7) : Color.clear, lineWidth: 1)
        )
    }
}

struct ChannelStripView: View {
    @Binding var channel: ChannelStripState
    var faderDb: Binding<Float>
    var autoDriven: Bool
    /// Live applied auto-mix / auto-duck gain in dB (nil when off).
    var autoGainDb: Float? = nil
    /// Show per-mono AUTO include checkbox.
    var showAutoInclude: Bool = false
    var isSelected: Bool
    var hardwareInputChannels: Int = 0
    var isRecording: Bool = false
    var canRemove: Bool = false
    var onSelect: () -> Void
    var onChange: () -> Void
    var onRemove: (() -> Void)? = nil
    var stripReorderable: Bool = false
    var isReorderDropTarget: Bool = false
    var onReorderDrop: ((Int) -> Void)? = nil
    var onReorderTargeted: ((Bool) -> Void)? = nil

    /// 15% narrower than the original 156pt desk.
    static let stripWidth: CGFloat = 133
    /// Nominal full-strip height from the fixed layout. The bay may grow past this;
    /// the extra goes into fader travel.
    static let stripHeight: CGFloat = 548
    /// Open slot between the last DSP chip and the fader. The link seam sits here.
    static let linkGap: CGFloat = 22
    /// Stereo beds pin their fader block to the voice strips so the faders line up.
    var alignedFaderSectionHeight: CGFloat? = nil

    @State private var dropTargetSlot: ChannelDSPSlot?
    @State private var isRenaming = false
    @State private var confirmRemove = false
    @FocusState private var nameFieldFocused: Bool

    private var fxDimmed: Bool { channel.dspBypass }
    private var canReorderDSP: Bool { !channel.isStereo && channel.dspOrder.count > 1 && !stripReorderable }
    private var canRename: Bool { !channel.isStereo }

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 3) {
                HStack(alignment: .center, spacing: 4) {
                    channelNameLabel
                    Spacer(minLength: 2)
                    SelectChannelButton(isSelected: isSelected, chrome: .bevel, action: onSelect)
                        .help("Select this channel for the waveform timeline")
                }
                Text(channel.fileURL?.lastPathComponent ?? "— empty —")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(MixerTheme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !channel.isStereo {
                    inputRow
                }
                if stripReorderable {
                    Text("DRAG TO REORDER")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(MixerTheme.bgBottom)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(MixerTheme.lime)
                        )
                        .help("Drag this strip onto another strip to change order")
                }
            }

            if !channel.isStereo {
                // Global DSP bypass — speaker channels only
                HStack(spacing: 4) {
                    StripBypassPill(bypass: $channel.dspBypass)
                    Text("DSP")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(channel.dspBypass ? MixerTheme.textSecondary : MixerTheme.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background { StripRecessedPlate(active: false, bypassed: channel.dspBypass) }
                        .opacity(channel.dspBypass ? 0.55 : 1)
                }
                .help("Bypass all EQ / FX on this channel (fader & pan still active)")
            }

            // FX chips — drag to reorder this channel’s DSP chain
            VStack(spacing: 5) {
                ForEach(channel.dspOrder) { slot in
                    FXRow(
                        title: slot.title,
                        active: isSlotActive(slot),
                        bypass: bypassBinding(for: slot),
                        onSelect: onSelect,
                        isDropTarget: dropTargetSlot == slot,
                        reorderable: canReorderDSP
                    )
                    .draggable(slot.rawValue) {
                        Text(slot.title)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(MixerTheme.lime)
                            .foregroundStyle(MixerTheme.bgBottom)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard canReorderDSP,
                              let raw = items.first,
                              let moved = ChannelDSPSlot(rawValue: raw) else { return false }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            channel.moveDSP(from: moved, to: slot)
                        }
                        dropTargetSlot = nil
                        return true
                    } isTargeted: { targeted in
                        guard canReorderDSP else { return }
                        dropTargetSlot = targeted ? slot : (dropTargetSlot == slot ? nil : dropTargetSlot)
                    }
                }
                if canReorderDSP {
                    Text("DRAG TO REORDER")
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(MixerTheme.cyanDim)
                        .frame(maxWidth: .infinity)
                }
            }
            .opacity(fxDimmed ? 0.4 : 1)
            .allowsHitTesting(!fxDimmed)

            if channel.isStereo {
                Spacer(minLength: 0)
            } else {
                Color.clear
                    .frame(height: Self.linkGap)
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: StripLinkGapKey.self,
                                value: geo.frame(in: .named("stripCluster")).midY
                            )
                        }
                    }
            }

            if showAutoInclude, !channel.isStereo {
                Toggle(isOn: Binding(
                    get: { channel.includeInAutoMix },
                    set: {
                        channel.includeInAutoMix = $0
                        onChange()
                    }
                )) {
                    Text("AUTO")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(channel.includeInAutoMix ? MixerTheme.lime : MixerTheme.cyanDim)
                }
                .toggleStyle(.checkbox)
                .help("Include this mono in Auto Mix / Auto Duck. Unchecked = bypass (unity).")
            }

            faderSection
                .help(autoDriven
                      ? "Fader sets baseline weighting while Auto Mix / Auto Duck is on. Live ride is the readout under the fader."
                      : "Channel level")

            HStack(spacing: 6) {
                stripBevelButton(
                    title: channel.mute ? "MUTED" : "MUTE",
                    lit: channel.mute,
                    kind: .mute,
                    help: "Mutes the whole strip. Linked monos share mute. To punch a cough, select this strip and Shift-drag on the waveform."
                ) {
                    channel.mute.toggle()
                    onChange()
                }
                stripBevelButton(
                    title: channel.solo ? "SOLO●" : "SOLO",
                    lit: channel.solo,
                    kind: .solo,
                    help: "Hear this strip alone. Turn SOLO on more than one to hear those together. MUTE still silences a strip."
                ) {
                    channel.solo.toggle()
                    onChange()
                }
            }

            CenterOutPanSlider(pan: Binding(
                get: { channel.pan },
                set: {
                    channel.pan = $0
                    onChange()
                }
            ))

            if canRemove {
                Button("REMOVE") { confirmRemove = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(MixerTheme.panelRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(MixerTheme.danger.opacity(0.55), lineWidth: 1)
                    )
                    .help("This strip has no audio. Remove it if you added it by mistake.")
                    .disabled(isRecording)
                    .confirmationDialog(
                        "Remove \(channel.name)?",
                        isPresented: $confirmRemove,
                        titleVisibility: .visible
                    ) {
                        Button("Remove Track", role: .destructive) { onRemove?() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Only empty speaker strips can be removed. This cannot be undone.")
                    }
            }
        }
        .padding(8)
        .frame(width: Self.stripWidth, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.15, blue: 0.18),
                            Color(red: 0.065, green: 0.085, blue: 0.105)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color.black.opacity(0.40), radius: 2.5, y: 1)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.top, 1)
                .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(stripOutlineColor, lineWidth: stripOutlineWidth)
                .shadow(color: stripOutlineGlow, radius: (isReorderDropTarget || isSelected) ? 6 : 0)
        )
        .modifier(
            StripReorderDrag(
                enabled: stripReorderable,
                channelID: channel.id,
                onDrop: { moved in
                    onReorderDrop?(moved)
                    return true
                },
                onTargeted: { targeted in
                    onReorderTargeted?(targeted)
                }
            )
        )
        .onChange(of: channel) { _, _ in onChange() }
    }

    /// Travel plus the fixed readout and caption. Grows and shrinks with the bay.
    /// The dB law uses this slot’s height, so +0 stays at the same fraction of the throw.
    private var faderSection: some View {
        let autoExtra: CGFloat = (autoDriven && autoGainDb != nil) ? 14 : 0
        return Group {
            if let pinned = alignedFaderSectionHeight {
                faderColumn(sectionHeight: max(VerticalFader.minSectionHeight, pinned), autoExtra: autoExtra)
                    .frame(height: max(VerticalFader.minSectionHeight, pinned), alignment: .top)
            } else {
                GeometryReader { geo in
                    faderColumn(sectionHeight: geo.size.height, autoExtra: autoExtra)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .preference(key: StripFaderSectionKey.self, value: geo.size.height)
                }
                .frame(minHeight: VerticalFader.minSectionHeight + autoExtra, maxHeight: .infinity)
            }
        }
    }

    private func faderColumn(sectionHeight: CGFloat, autoExtra: CGFloat) -> some View {
        let track = max(
            VerticalFader.minTrackHeight,
            sectionHeight - VerticalFader.columnChrome - autoExtra
        )
        return VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                LevelMeter(level: channel.prePeak, label: "IN", barHeight: track, stripChrome: true)
                VerticalFader(valueDb: faderDb, autoDriven: false, trackHeight: track, stripChrome: true)
                LevelMeter(level: channel.postPeak, label: "OUT", barHeight: track, stripChrome: true)
            }
            if autoDriven, let g = autoGainDb {
                Text(String(format: "%+.1f", g))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(MixerTheme.lime.opacity(0.9))
                    .frame(height: 12)
                    .help("Applied auto-mix / auto-duck gain (dB). Fader = baseline weighting.")
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 4) {
            Text("IN")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(MixerTheme.cyanDim)
            inputPicker
                .frame(maxWidth: .infinity)
                .disabled(isRecording || hardwareInputChannels <= 0)
                .help("Which input on the interface this strip records. — means do not record this strip. Monitor on the interface, not through TheDecks.")
            if isRecording, channel.inputChannel != nil {
                Text("REC")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.bgBottom)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(MixerTheme.danger))
            }
        }
    }

    /// Same choices as the old menu picker. The closed control is a recessed field.
    private var inputPicker: some View {
        let current = channel.inputChannel
        return Menu {
            Button {
                channel.inputChannel = nil
            } label: {
                if current == nil {
                    Label("—", systemImage: "checkmark")
                } else {
                    Text("—")
                }
            }
            if hardwareInputChannels > 0 {
                ForEach(1...hardwareInputChannels, id: \.self) { n in
                    Button {
                        channel.inputChannel = n - 1
                    } label: {
                        if current == n - 1 {
                            Label("\(n)", systemImage: "checkmark")
                        } else {
                            Text("\(n)")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.map { "\($0 + 1)" } ?? "—")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(MixerTheme.cyan)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(MixerTheme.cyanDim)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.035), Color(white: 0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.7)
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(height: 1)
                    .padding(.horizontal, 4)
                    .allowsHitTesting(false)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private var channelNameLabel: some View {
        if canRename && isRenaming {
            TextField("Name", text: $channel.name)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(MixerTheme.lime)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(MixerTheme.panelRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(MixerTheme.lime.opacity(0.7), lineWidth: 1)
                )
                .focused($nameFieldFocused)
                .onSubmit { commitRename() }
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused { commitRename() }
                }
        } else {
            Text(channel.name)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(isSelected ? MixerTheme.lime : MixerTheme.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .help(canRename ? "Double-click to rename (used for bounce filenames)" : channel.name)
                .onTapGesture(count: 2) {
                    guard canRename else { return }
                    isRenaming = true
                    DispatchQueue.main.async { nameFieldFocused = true }
                }
        }
    }

    private func commitRename() {
        let cleaned = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty, let n = channel.speakerNumber {
            channel.name = "SPK \(n)"
        } else {
            channel.name = cleaned
        }
        isRenaming = false
        nameFieldFocused = false
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private var stripOutlineColor: Color {
        if isReorderDropTarget { return MixerTheme.lime }
        if isSelected { return MixerTheme.lime.opacity(0.72) }
        return Color.white.opacity(0.07)
    }

    private var stripOutlineWidth: CGFloat {
        if isReorderDropTarget { return 2.5 }
        if isSelected { return 1.35 }
        return 1
    }

    private var stripOutlineGlow: Color {
        if isReorderDropTarget { return MixerTheme.lime.opacity(0.50) }
        if isSelected { return MixerTheme.lime.opacity(0.28) }
        return .clear
    }

    /// MUTE / SOLO. Same font and vertical padding as the old rectangles, drawn as a bevelled pill.
    private func stripBevelButton(
        title: String,
        lit: Bool,
        kind: DSPBevelKind,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let plate = lit ? kind : DSPBevelKind.off
        return Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(plate.text)
                .background { DSPBevelPlate(lit: lit, kind: kind) }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func isSlotActive(_ slot: ChannelDSPSlot) -> Bool {
        switch slot {
        case .eq:
            return channel.eq.gains.contains { abs($0) > 0.05 } || channel.para.isActive || channel.eq.hpfIsActive
        case .deess:
            // Engaged and actually able to reduce. 0 dB THRESH is the top of the knob, so it
            // must not light the chip. `ChannelDeEsser.isActive` stays “not bypassed”.
            return !channel.deess.bypass && channel.deess.thresholdDb < -0.05
        case .deVerb:
            return channel.voice.deVerb > 0.02
        case .wetter:
            return channel.voice.wetter > 0.02
        case .leveler:
            return channel.voice.levelerDriveDb > 0.2 || channel.voice.levelerLimiterDb < -0.2
        }
    }

    private func bypassBinding(for slot: ChannelDSPSlot) -> Binding<Bool> {
        switch slot {
        case .eq:
            return $channel.eq.bypass
        case .deess:
            return $channel.deess.bypass
        case .deVerb:
            return $channel.voice.deVerbBypass
        case .wetter:
            return $channel.voice.wetterBypass
        case .leveler:
            return $channel.voice.levelerBypass
        }
    }
}

/// Compact transport chrome so time, −, +, RESET, and ALL TRACKS fit the narrower waveform.
private struct WaveformTransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(configuration.isPressed ? MixerTheme.lime : MixerTheme.cyan)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(MixerTheme.panelRaised))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(MixerTheme.cyan.opacity(0.45), lineWidth: 1)
            )
    }
}

struct TimelineWaveformView: View {
    var peaks: [Float]
    var playhead: Double
    var channelName: String
    var currentTime: String
    var duration: String
    var muteSpans: [(Double, Double)] = []
    var onSeek: (Double) -> Void
    var onPaintMute: (Double, Double) -> Void = { _, _ in }
    var onClearMute: (Double, Double) -> Void = { _, _ in }
    var onShowAllTracks: (() -> Void)? = nil

    @State private var zoom: Double = 1
    @State private var start: Double = 0
    @State private var dragKind: WaveDragKind?
    @State private var dragStart: Double?
    @State private var dragCurrent: Double?

    private enum WaveDragKind {
        case seek, mute, clear
    }

    private var window: Double { 1 / max(1, zoom) }

    private var visiblePeaks: [Float] {
        guard peaks.count > 1, zoom > 1.001 else { return peaks }
        let last = Double(peaks.count - 1)
        let i0 = max(0, Int((start * last).rounded(.down)))
        let i1 = min(peaks.count - 1, max(i0 + 1, Int(((start + window) * last).rounded(.up))))
        return Array(peaks[i0...i1])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WAVEFORM · \(channelName)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(MixerTheme.cyanDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Text("\(currentTime)  /  \(duration)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(MixerTheme.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(zoom <= 1.01 ? "1×" : String(format: "%.0f×", zoom))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(MixerTheme.cyanDim)
                    .lineLimit(1)
                Button("−") { nudgeZoom(0.5) }
                    .buttonStyle(WaveformTransportButtonStyle())
                    .disabled(zoom <= 1.01)
                    .help("Zoom out")
                Button("+") { nudgeZoom(2) }
                    .buttonStyle(WaveformTransportButtonStyle())
                    .disabled(zoom >= 15.9)
                    .help("Zoom in")
                Button("RESET") { zoom = 1; start = 0 }
                    .buttonStyle(WaveformTransportButtonStyle())
                    .disabled(zoom <= 1.01)
                    .help("Show the whole file")
                if let onShowAllTracks {
                    Button("ALL TRACKS") { onShowAllTracks() }
                        .buttonStyle(WaveformTransportButtonStyle())
                        .help("Stack every strip’s waveform in one box. Extra lanes scroll; Mixer stays on screen. Click a lane to zoom in.")
                }
            }

            GeometryReader { geo in
                let w = geo.size.width
                let localPlayhead = (playhead - start) / window
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(MixerTheme.panelRaised)

                    Canvas { context, size in
                        let display = visiblePeaks
                        let count = max(display.count, 1)
                        let mid = size.height / 2
                        for (i, peak) in display.enumerated() {
                            let x = size.width * CGFloat(i) / CGFloat(count)
                            let amp = CGFloat(peak) * (size.height * 0.42)
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: mid - amp))
                            path.addLine(to: CGPoint(x: x, y: mid + amp))
                            context.stroke(
                                path,
                                with: .color(MixerTheme.cyan.opacity(0.75)),
                                lineWidth: max(1, size.width / CGFloat(count))
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    ForEach(Array(muteSpans.enumerated()), id: \.offset) { _, span in
                        muteOverlay(span: span, width: w, color: MixerTheme.danger.opacity(0.32))
                    }

                    if let kind = dragKind, kind != .seek, let a = dragStart, let b = dragCurrent {
                        muteOverlay(
                            span: (min(a, b), max(a, b)),
                            width: w,
                            color: kind == .mute ? MixerTheme.danger.opacity(0.45) : MixerTheme.lime.opacity(0.35)
                        )
                    }

                    if localPlayhead >= 0, localPlayhead <= 1 {
                        Rectangle()
                            .fill(MixerTheme.lime)
                            .frame(width: 2)
                            .shadow(color: MixerTheme.lime.opacity(0.7), radius: 4)
                            .offset(x: CGFloat(localPlayhead) * (w - 2))
                    }

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let t = xToNormalized(value.location.x, width: w)
                                    if dragKind == nil {
                                        let flags = NSEvent.modifierFlags
                                        if flags.contains(.shift) {
                                            dragKind = .mute
                                        } else if flags.contains(.option) {
                                            dragKind = .clear
                                        } else {
                                            dragKind = .seek
                                        }
                                        dragStart = t
                                    }
                                    dragCurrent = t
                                    if dragKind == .seek {
                                        onSeek(t)
                                    }
                                }
                                .onEnded { value in
                                    let t = xToNormalized(value.location.x, width: w)
                                    let a = dragStart ?? t
                                    let b = t
                                    let kind = dragKind
                                    dragKind = nil
                                    dragStart = nil
                                    dragCurrent = nil
                                    let minNorm = (3.0 / max(Double(w), 1)) * window
                                    if kind == .mute, abs(b - a) >= minNorm {
                                        onPaintMute(a, b)
                                    } else if kind == .clear, abs(b - a) >= minNorm {
                                        onClearMute(a, b)
                                    } else {
                                        onSeek(b)
                                    }
                                }
                        )
                        .overlay {
                            WaveformPointerZoom { event in
                                handlePointerScroll(event, width: w)
                            }
                        }
                }
            }
            .frame(height: 88)
            .help("Click to seek · SEL a strip first · Shift-drag to silence that span (show stays this long) · Option-drag to clear · pinch or scroll up/down to zoom · swipe left/right to move when zoomed · RESET shows the whole file")
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MixerTheme.cyan.opacity(0.35), lineWidth: 1)
            )
            .onChange(of: playhead) { _, p in
                keepPlayheadVisible(p)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .mixerPanel()
    }

    @ViewBuilder
    private func muteOverlay(span: (Double, Double), width w: CGFloat, color: Color) -> some View {
        let left = (span.0 - start) / window
        let right = (span.1 - start) / window
        let lo = max(0.0, min(1.0, left))
        let hi = max(0.0, min(1.0, right))
        if hi > lo {
            Rectangle()
                .fill(color)
                .frame(width: max(1, CGFloat(hi - lo) * w))
                .frame(maxHeight: .infinity)
                .offset(x: CGFloat(lo) * w)
                .allowsHitTesting(false)
        }
    }

    private func xToNormalized(_ x: CGFloat, width w: CGFloat) -> Double {
        let tVis = max(0, min(1, x / max(w, 1)))
        return start + tVis * window
    }

    private func nudgeZoom(_ factor: Double) {
        zoomAroundPlayhead(zoom * factor)
    }

    private func zoomAroundPlayhead(_ newZoom: Double) {
        zoomAroundAnchor(newZoom, anchor: playhead, fractionInWindow: 0.5)
    }

    private func zoomAroundAnchor(_ newZoom: Double, anchor: Double, fractionInWindow: Double) {
        let z = min(16, max(1, newZoom))
        let nextWindow = 1 / z
        let frac = max(0, min(1, fractionInWindow))
        start = min(max(0, anchor - frac * nextWindow), max(0, 1 - nextWindow))
        zoom = z
    }

    /// Returns true when the gesture was used (zoom or pan) so the parent mixer scroll does not also move.
    private func handlePointerScroll(_ event: NSEvent, width: CGFloat) -> Bool {
        if event.type == .scrollWheel,
           abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            return panVisible(deltaX: event.scrollingDeltaX, width: width, precise: event.hasPreciseScrollingDeltas)
        }
        handlePointerZoom(event, width: width)
        return true
    }

    private func panVisible(deltaX: CGFloat, width: CGFloat, precise: Bool) -> Bool {
        guard zoom > 1.001, width > 1 else { return false }
        var dx = deltaX
        if !precise {
            dx *= 8
        }
        // scrollingDeltaX already follows the Mac “natural scroll” preference:
        // swipe right moves the wave with your fingers (earlier audio).
        let next = start - (Double(dx) / Double(width)) * window
        start = min(max(0, next), max(0, 1 - window))
        return true
    }

    private func handlePointerZoom(_ event: NSEvent, width: CGFloat) {
        let tVis = pointerFraction(width: width)
        let anchor = start + tVis * window
        let factor: Double
        if event.type == .magnify {
            factor = max(0.5, 1 + Double(event.magnification) * 1.35)
        } else {
            let dy = Double(event.scrollingDeltaY)
            let unit = event.hasPreciseScrollingDeltas ? dy / 90.0 : dy * 0.18
            factor = pow(2.0, unit)
        }
        zoomAroundAnchor(zoom * factor, anchor: anchor, fractionInWindow: tVis)
    }

    private func pointerFraction(width: CGFloat) -> Double {
        let x = WaveformPointerZoom.lastLocalX ?? (width / 2)
        return max(0, min(1, Double(x / max(width, 1))))
    }

    private func keepPlayheadVisible(_ p: Double) {
        let w = window
        if p < start {
            start = max(0, p - w * 0.08)
        } else if p > start + w {
            start = min(1 - w, p - w * 0.92)
        }
    }
}

/// Stacked waveforms for every loaded strip. Visual overview — click a lane to zoom in on that channel.
struct OverviewWaveformView: View {
    var lanes: [MixerWaveformLane]
    var playhead: Double
    var currentTime: String
    var duration: String
    var onSeek: (Double) -> Void
    var onFocusLane: (Int) -> Void
    var onShowOne: () -> Void

    @State private var draggingLane: Int?
    @State private var didSeek = false

    private let nameWidth: CGFloat = 78
    private let laneHeight: CGFloat = 44
    private let laneGap: CGFloat = 4
    /// Extra lanes scroll inside this box so Mixer stays on screen.
    private let maxStackHeight: CGFloat = 220

    private var stackHeight: CGFloat {
        let n = max(1, lanes.count)
        return CGFloat(n) * laneHeight + CGFloat(max(0, n - 1)) * laneGap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WAVEFORM · ALL TRACKS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(MixerTheme.cyanDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                Text("\(currentTime)  /  \(duration)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(MixerTheme.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Button("ONE TRACK") { onShowOne() }
                    .buttonStyle(WaveformTransportButtonStyle())
                    .help("Back to one channel’s waveform")
            }
            Text("Click a lane to zoom in · drag to seek · extra tracks scroll in this box")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(MixerTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: stackHeight > geo.size.height + 1) {
                    VStack(spacing: laneGap) {
                        ForEach(lanes) { lane in
                            laneRow(lane)
                        }
                    }
                }
            }
            .frame(maxHeight: min(stackHeight, maxStackHeight))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .mixerPanel()
    }

    private func laneRow(_ lane: MixerWaveformLane) -> some View {
        HStack(spacing: 8) {
            Text(lane.name)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(MixerTheme.cyan)
                .lineLimit(1)
                .frame(width: nameWidth, alignment: .leading)
                .help("Click to zoom in on \(lane.name)")
                .onTapGesture { onFocusLane(lane.id) }

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(MixerTheme.panelRaised)
                    WaveformPeaksCanvas(peaks: lane.peaks)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    ForEach(Array(lane.muteSpans.enumerated()), id: \.offset) { _, span in
                        overviewMute(span: span, width: w)
                    }
                    if playhead >= 0, playhead <= 1 {
                        Rectangle()
                            .fill(MixerTheme.lime)
                            .frame(width: 2)
                            .shadow(color: MixerTheme.lime.opacity(0.7), radius: 3)
                            .offset(x: CGFloat(playhead) * max(w - 2, 1))
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if draggingLane == nil {
                                        draggingLane = lane.id
                                        didSeek = false
                                    }
                                    guard draggingLane == lane.id else { return }
                                    if abs(value.translation.width) >= 4 {
                                        didSeek = true
                                        onSeek(xToNormalized(value.location.x, width: w))
                                    }
                                }
                                .onEnded { value in
                                    guard draggingLane == lane.id else { return }
                                    let seeked = didSeek
                                    draggingLane = nil
                                    didSeek = false
                                    if seeked {
                                        onSeek(xToNormalized(value.location.x, width: w))
                                    } else {
                                        onFocusLane(lane.id)
                                    }
                                }
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(MixerTheme.cyan.opacity(0.35), lineWidth: 1)
                )
            }
            .frame(height: laneHeight)
        }
        .frame(height: laneHeight)
    }

    @ViewBuilder
    private func overviewMute(span: (Double, Double), width w: CGFloat) -> some View {
        let lo = max(0.0, min(1.0, span.0))
        let hi = max(0.0, min(1.0, span.1))
        if hi > lo {
            Rectangle()
                .fill(MixerTheme.danger.opacity(0.32))
                .frame(width: max(1, CGFloat(hi - lo) * w))
                .frame(maxHeight: .infinity)
                .offset(x: CGFloat(lo) * w)
                .allowsHitTesting(false)
        }
    }

    private func xToNormalized(_ x: CGFloat, width w: CGFloat) -> Double {
        max(0, min(1, x / max(w, 1)))
    }
}

private struct WaveformPeaksCanvas: View {
    var peaks: [Float]

    var body: some View {
        Canvas { context, size in
            let display = peaks
            let count = max(display.count, 1)
            let mid = size.height / 2
            for (i, peak) in display.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(count)
                let amp = CGFloat(peak) * (size.height * 0.42)
                var path = Path()
                path.move(to: CGPoint(x: x, y: mid - amp))
                path.addLine(to: CGPoint(x: x, y: mid + amp))
                context.stroke(
                    path,
                    with: .color(MixerTheme.cyan.opacity(0.75)),
                    lineWidth: max(1, size.width / CGFloat(count))
                )
            }
        }
    }
}

/// Trackpad pinch / scroll zoom and sideways pan, without stealing click-drag seek.
private struct WaveformPointerZoom: NSViewRepresentable {
    static var lastLocalX: CGFloat?

    /// Return true to consume the event (zoom or pan). False leaves it for the rest of Mixer.
    var onEvent: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.onEvent = onEvent
        return v
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onEvent = onEvent
    }

    final class MonitorView: NSView {
        var onEvent: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                install()
            } else {
                remove()
            }
        }

        private func install() {
            remove()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, self.window != nil else { return event }
                let loc = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(loc) else { return event }
                WaveformPointerZoom.lastLocalX = loc.x
                if self.onEvent?(event) == true {
                    return nil
                }
                return event
            }
        }

        private func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit { remove() }
    }
}
