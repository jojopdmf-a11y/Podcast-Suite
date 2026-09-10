import SwiftUI

// MARK: - Hardware-inspired chrome (original — not affiliated with Waves/API)

enum APILook {
    static let charcoal = Color(red: 0.07, green: 0.08, blue: 0.09)
    static let panelFill = Color(red: 0.11, green: 0.12, blue: 0.13)
    static let panelRaised = Color(red: 0.14, green: 0.15, blue: 0.16)
    static let border = Color(white: 0.58).opacity(0.5)
    static let label = Color(white: 0.94)
    static let labelDim = Color(white: 0.55)
    static let accentBlue = Color(red: 0.38, green: 0.58, blue: 0.82)
    static let metalBlue = Color(red: 0.20, green: 0.36, blue: 0.56)
    static let metalBlueHi = Color(red: 0.42, green: 0.60, blue: 0.80)
    static let cream = Color(red: 0.94, green: 0.91, blue: 0.78)
    static let creamDark = Color(red: 0.82, green: 0.78, blue: 0.62)
    static let needle = Color(red: 0.12, green: 0.10, blue: 0.08)
    static let ledRed = Color(red: 1.0, green: 0.25, blue: 0.22)
    static let ledYellow = Color(red: 0.95, green: 0.82, blue: 0.20)
    static let ledGreen = Color(red: 0.25, green: 0.90, blue: 0.40)
    static let knobRed = Color(red: 0.72, green: 0.10, blue: 0.08)
    static let faderCap = Color(red: 0.85, green: 0.86, blue: 0.88)
}

extension View {
    /// Double-click / double-tap restores `defaultValue`.
    func doubleClickReset<T: Equatable>(_ value: Binding<T>, to defaultValue: T) -> some View {
        simultaneousGesture(
            TapGesture(count: 2).onEnded {
                value.wrappedValue = defaultValue
            }
        )
    }
}

struct APISection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(APILook.label)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(APILook.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(APILook.border, lineWidth: 1)
        )
    }
}

struct HardwareKnob: View {
    @Binding var value: Float
    var range: ClosedRange<Float>
    var label: String
    var valueText: (Float) -> String
    var style: KnobStyle = .metal
    var diameter: CGFloat = 56
    var stops: [Float]? = nil
    var defaultValue: Float = 0

    enum KnobStyle {
        case metal
        case outputRed
    }

    @State private var dragStartValue: Float = 0

    private var displayValue: Float {
        if let stops, !stops.isEmpty {
            return stops.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
        }
        return value
    }

    private var normalized: Double {
        if let stops, stops.count > 1,
           let idx = stops.enumerated().min(by: { abs($0.element - value) < abs($1.element - value) })?.offset {
            return Double(idx) / Double(stops.count - 1)
        }
        return Double((value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound))
    }

    private var bodyColors: [Color] {
        switch style {
        case .metal:
            return [
                Color(white: 0.42),
                Color(white: 0.22),
                Color(white: 0.10),
                Color(white: 0.18)
            ]
        case .outputRed:
            return [
                Color(red: 0.92, green: 0.28, blue: 0.22),
                APILook.knobRed,
                Color(red: 0.35, green: 0.05, blue: 0.04),
                Color(red: 0.55, green: 0.08, blue: 0.06)
            ]
        }
    }

    private var pointerColor: Color {
        style == .outputRed ? .white : Color(red: 0.95, green: 0.92, blue: 0.75)
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(valueText(displayValue))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(style == .outputRed ? APILook.ledRed.opacity(0.9) : APILook.accentBlue)

            ZStack {
                // Skirt / collar
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.28), Color(white: 0.12), Color(white: 0.2)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: diameter + 10, height: diameter + 10)
                    .overlay(
                        Circle()
                            .stroke(Color(white: 0.4).opacity(0.45), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)

                // Tick ring on skirt
                ForEach(0..<11, id: \.self) { i in
                    Capsule()
                        .fill(i % 5 == 0 ? Color(white: 0.7) : Color(white: 0.4))
                        .frame(width: i % 5 == 0 ? 1.6 : 1.1, height: i % 5 == 0 ? 5 : 3.5)
                        .offset(y: -(diameter * 0.5 + 2))
                        .rotationEffect(.degrees(-140 + Double(i) / 10.0 * 280))
                }

                // Knob body — brushed / anodized look
                Circle()
                    .fill(
                        RadialGradient(
                            colors: bodyColors,
                            center: UnitPoint(x: 0.32, y: 0.28),
                            startRadius: 1,
                            endRadius: diameter * 0.65
                        )
                    )
                    .overlay(
                        // Machined concentric rings
                        Circle()
                            .stroke(Color.white.opacity(style == .metal ? 0.12 : 0.18), lineWidth: 1)
                            .padding(diameter * 0.14)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.35), lineWidth: 1)
                            .padding(diameter * 0.28)
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                AngularGradient(
                                    colors: [
                                        Color.white.opacity(0.55),
                                        Color.black.opacity(0.35),
                                        Color.white.opacity(0.25),
                                        Color.black.opacity(0.45),
                                        Color.white.opacity(0.55)
                                    ],
                                    center: .center
                                ),
                                lineWidth: 1.4
                            )
                    )
                    // Specular glint
                    .overlay(
                        Ellipse()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(style == .metal ? 0.45 : 0.35), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: diameter * 0.55, height: diameter * 0.28)
                            .offset(y: -diameter * 0.22)
                            .allowsHitTesting(false)
                    )
                    .frame(width: diameter, height: diameter)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)

                // Pointer
                Capsule()
                    .fill(pointerColor)
                    .frame(width: 2.4, height: diameter * 0.34)
                    .overlay(alignment: .top) {
                        Circle()
                            .fill(pointerColor)
                            .frame(width: 3.5, height: 3.5)
                            .offset(y: -1)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 0.5, y: 0.5)
                    .offset(y: -diameter * 0.16)
                    .rotationEffect(.degrees(-140 + normalized * 280))
            }
            .frame(width: diameter + 12, height: diameter + 12)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if g.translation == .zero {
                            dragStartValue = value
                        }
                        let delta = -Float(g.translation.height) * 0.012
                        if let stops, stops.count > 1 {
                            let startIdx = Float(
                                stops.enumerated().min(by: {
                                    abs($0.element - dragStartValue) < abs($1.element - dragStartValue)
                                })?.offset ?? 0
                            )
                            let next = startIdx + delta * Float(stops.count)
                            let i = max(0, min(stops.count - 1, Int(next.rounded())))
                            value = stops[i]
                        } else {
                            let span = range.upperBound - range.lowerBound
                            value = max(range.lowerBound, min(range.upperBound, dragStartValue + delta * span * 2.2))
                        }
                    }
            )
            .onTapGesture(count: 2) {
                if let stops, !stops.isEmpty {
                    value = stops.min(by: { abs($0 - defaultValue) < abs($1 - defaultValue) }) ?? defaultValue
                } else {
                    value = max(range.lowerBound, min(range.upperBound, defaultValue))
                }
            }

            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(APILook.label)
        }
        .help("Double-click to reset")
    }
}

struct AnalogVUMeter: View {
    /// Peak/linear level 0…1 for IN/OUT, or ignored when `gainReductionDb` is set.
    var level: Float = 0
    /// When non-nil, meter is in GR mode: needle rests at 0 (right) and swings left with GR.
    var gainReductionDb: Float? = nil
    var label: String

    private var isGR: Bool { gainReductionDb != nil }

    // API-style wide VU arc — scale hugs left/right edges of the cream face.
    private let minAngle: Double = -62
    private let zeroAngle: Double = 12
    private let maxAngle: Double = 58

    private var needleAngle: Double {
        if let gr = gainReductionDb {
            // Manual: GR 0 is fully right (0 VU); 20 dB GR is fully left.
            let clamped = Double(min(20, max(0, gr)))
            return zeroAngle + (minAngle - zeroAngle) * (clamped / 20.0)
        }
        let db = Double(20 * log10(max(level, 1e-5)))
        if db <= -20 { return minAngle }
        if db >= 3 { return maxAngle }
        if db <= 0 {
            return minAngle + (zeroAngle - minAngle) * ((db + 20) / 20)
        }
        return zeroAngle + (maxAngle - zeroAngle) * (db / 3)
    }

    private func angleForDb(_ db: Double) -> Double {
        if db <= -20 { return minAngle }
        if db >= 3 { return maxAngle }
        if db <= 0 {
            return minAngle + (zeroAngle - minAngle) * ((db + 20) / 20)
        }
        return zeroAngle + (maxAngle - zeroAngle) * (db / 3)
    }

    /// Upper printed scale (IN / OUT): −20 … +3
    private var levelMarks: [(String, Double, Bool)] {
        [("-20", angleForDb(-20), false),
         ("-10", angleForDb(-10), false),
         ("-7", angleForDb(-7), false),
         ("-5", angleForDb(-5), false),
         ("-3", angleForDb(-3), false),
         ("-1", angleForDb(-1), false),
         ("0", zeroAngle, true),
         ("+1", angleForDb(1), true),
         ("+3", maxAngle, true)]
    }

    /// Lower printed scale (GR): 20 … 0 with 0 at the right (API 2500 layout).
    private var grMarks: [(String, Double)] {
        [("20", angleForDb(-20)),
         ("10", angleForDb(-10)),
         ("7", angleForDb(-7)),
         ("5", angleForDb(-5)),
         ("3", angleForDb(-3)),
         ("1", angleForDb(-1)),
         ("0", zeroAngle)]
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Thin metal bezel — face dominates, like the hardware windows.
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.38), Color(white: 0.12), Color(white: 0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(Color(white: 0.55).opacity(0.65), lineWidth: 1)
                    )

                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    // Minimal chrome lip so cream fills ~94% of the window.
                    let bezel: CGFloat = max(3, min(5, w * 0.025))
                    let faceW = w - bezel * 2
                    let faceH = h - bezel * 2
                    let cx = bezel + faceW * 0.5
                    // Exact bottom-center of the cream face (pivot origin).
                    let pivotY = bezel + faceH
                    let needleLen = faceH * 0.72 // ~20% shorter than previous 0.90
                    let needleW = max(1.5, faceW * 0.010)
                    let outerLabelR = needleLen * 0.98
                    let innerLabelR = needleLen * 0.72
                    let tickOuter = max(8, faceH * 0.11)
                    let tickInner = max(5, faceH * 0.07)
                    let outerFont = max(11, min(15, faceW * 0.095))
                    let innerFont = max(9, min(12, faceW * 0.075))
                    let levelOpacity: Double = isGR ? 0.28 : 1.0
                    let grOpacity: Double = isGR ? 1.0 : 0.28
                    let pivotSize = max(10, faceH * 0.07)

                    ZStack {
                        // Cream / ivory illuminated face
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color(red: 0.99, green: 0.96, blue: 0.86),
                                        Color(red: 0.94, green: 0.90, blue: 0.76),
                                        Color(red: 0.88, green: 0.83, blue: 0.66)
                                    ],
                                    center: UnitPoint(x: 0.5, y: 0.08),
                                    startRadius: 1,
                                    endRadius: max(faceW, faceH)
                                )
                            )
                            .frame(width: faceW, height: faceH)
                            .position(x: cx, y: bezel + faceH * 0.5)

                        // Red overload wash on + side (IN/OUT faces)
                        Capsule()
                            .fill(APILook.ledRed.opacity(0.18 * levelOpacity))
                            .frame(width: faceW * 0.34, height: faceH * 0.20)
                            .rotationEffect(.degrees(36))
                            .position(x: bezel + faceW * 0.80, y: bezel + faceH * 0.22)

                        // Outer arc (level scale baseline)
                        Path { path in
                            path.addArc(
                                center: CGPoint(x: cx, y: pivotY),
                                radius: outerLabelR * 0.78,
                                startAngle: .degrees(minAngle - 90),
                                endAngle: .degrees(maxAngle - 90),
                                clockwise: false
                            )
                        }
                        .stroke(APILook.needle.opacity(0.25 * levelOpacity + 0.08), lineWidth: 1.4)

                        // OUTER numerals: IN/OUT (−20…+3)
                        ForEach(Array(levelMarks.enumerated()), id: \.offset) { _, mark in
                            let (text, angle, hot) = mark
                            ZStack {
                                VStack(spacing: 1) {
                                    Text(text)
                                        .font(.system(size: outerFont, weight: .bold, design: .rounded))
                                        .foregroundStyle(hot ? APILook.ledRed.opacity(0.92) : APILook.needle.opacity(0.78))
                                    Capsule()
                                        .fill(hot ? APILook.ledRed.opacity(0.88) : APILook.needle.opacity(0.55))
                                        .frame(width: text == "0" ? 2.0 : 1.5, height: text == "0" ? tickOuter * 1.25 : tickOuter)
                                }
                                .offset(y: -outerLabelR * 0.55)
                            }
                            .opacity(levelOpacity)
                            .frame(width: 1, height: 1)
                            .rotationEffect(.degrees(angle))
                            .position(x: cx, y: pivotY)
                        }

                        // INNER numerals: GR (20…0) — always printed like the real dual-scale face
                        ForEach(Array(grMarks.enumerated()), id: \.offset) { _, mark in
                            let (text, angle) = mark
                            ZStack {
                                VStack(spacing: 1) {
                                    Capsule()
                                        .fill(APILook.needle.opacity(0.5))
                                        .frame(width: 1.2, height: tickInner)
                                    Text(text)
                                        .font(.system(size: innerFont, weight: .semibold, design: .rounded))
                                        .foregroundStyle(APILook.needle.opacity(0.7))
                                }
                                .offset(y: -innerLabelR * 0.55)
                            }
                            .opacity(grOpacity)
                            .frame(width: 1, height: 1)
                            .rotationEffect(.degrees(angle))
                            .position(x: cx, y: pivotY)
                        }

                        // Center badge
                        Text(isGR ? "GR" : "VU")
                            .font(.system(size: outerFont * 1.15, weight: .heavy, design: .rounded))
                            .tracking(1)
                            .foregroundStyle(APILook.needle.opacity(0.14))
                            .position(x: cx, y: bezel + faceH * 0.48)

                        Text("dB")
                            .font(.system(size: innerFont * 0.7, weight: .medium, design: .rounded))
                            .foregroundStyle(APILook.needle.opacity(0.2))
                            .position(x: cx, y: bezel + faceH * 0.58)

                        // Needle pivots around bottom-center of the cream face.
                        // ZStack origin == pivot; capsule is drawn upward from there.
                        ZStack {
                            Capsule()
                                .fill(APILook.needle)
                                .frame(width: needleW, height: needleLen)
                                .overlay(alignment: .top) {
                                    Capsule()
                                        .fill(APILook.ledRed)
                                        .frame(width: 2.2, height: 6)
                                        .offset(y: -1)
                                }
                                .offset(y: -needleLen / 2)
                        }
                        .frame(width: needleW, height: 1)
                        .rotationEffect(.degrees(needleAngle))
                        .shadow(color: .black.opacity(0.4), radius: 0.8, y: 0.5)
                        .position(x: cx, y: pivotY)
                        .animation(.easeOut(duration: 0.07), value: needleAngle)

                        // Pivot cup sits on the rotation origin
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color(white: 0.45), APILook.needle],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 6
                                )
                            )
                            .frame(width: pivotSize, height: pivotSize)
                            .position(x: cx, y: pivotY)

                        // Glass
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.32),
                                        Color.white.opacity(0.06),
                                        Color.clear,
                                        Color.black.opacity(0.08)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: faceW, height: faceH)
                            .position(x: cx, y: bezel + faceH * 0.5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(2)
            }
            .frame(height: 148)
            .frame(maxWidth: .infinity)

            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(APILook.label)
        }
    }
}

struct LEDDot: View {
    var on: Bool
    var color: Color
    var body: some View {
        Circle()
            .fill(on ? color : Color(white: 0.18))
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(on ? 0.35 : 0.08), lineWidth: 0.8)
            )
            .shadow(color: on ? color.opacity(0.85) : .clear, radius: on ? 4 : 0)
    }
}

/// API 560–inspired 10-band graphic EQ (look + feel; original artwork).
struct API560EQView: View {
    @Binding var eq: ChannelEQ

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                // dB scale rail
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(["+12", "+6", "0", "-6", "-12"], id: \.self) { t in
                        Text(t)
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(t == "0" ? APILook.accentBlue : APILook.labelDim)
                            .frame(height: 22)
                    }
                }
                .frame(width: 28, height: 120)

                ForEach(GraphicEQBand.allCases) { band in
                    API560BandFader(value: Binding(
                        get: { eq[band] },
                        set: { eq[band] = $0 }
                    ), label: band.shortLabel)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(APILook.charcoal)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(APILook.border, lineWidth: 1)
            )
        }
    }
}

private struct API560BandFader: View {
    @Binding var value: Float
    var label: String

    private let trackH: CGFloat = 120

    private var yNorm: CGFloat {
        // +12 at top, -12 at bottom
        CGFloat((12 - value) / 24)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(abs(value) < 0.05 ? "0" : String(format: "%+.0f", value))
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(abs(value) < 0.05 ? APILook.labelDim : APILook.accentBlue)
                .frame(height: 10)

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .top) {
                    // Slot
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.65))
                        .frame(width: 8)
                        .frame(maxWidth: .infinity)

                    // Zero line
                    Rectangle()
                        .fill(APILook.accentBlue.opacity(0.55))
                        .frame(height: 1)
                        .offset(y: trackH * 0.5)

                    // Cap
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.9), APILook.faderCap, Color(white: 0.45)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: max(14, w - 2), height: 14)
                        .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                        .offset(y: max(0, min(trackH - 14, yNorm * (trackH - 14))))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let y = max(0, min(trackH, g.location.y))
                            let n = Float(y / trackH)
                            value = max(-12, min(12, 12 - n * 24))
                        }
                )
                .onTapGesture(count: 2) { value = 0 }
            }
            .frame(height: trackH)

            Text(label)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(APILook.label)
        }
        .frame(maxWidth: .infinity)
        .help("Double-click to zero")
    }
}

private struct RackScrew: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.45), Color(white: 0.22)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 5
                    )
                )
                .frame(width: 9, height: 9)
            Capsule()
                .fill(Color(white: 0.12))
                .frame(width: 5, height: 1.2)
                .rotationEffect(.degrees(35))
        }
    }
}

private struct APIPushButton: View {
    var title: String
    var lit: Bool
    var led: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                LEDDot(on: lit, color: led)
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(APILook.label)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: lit
                                ? [Color(white: 0.22), Color(white: 0.14)]
                                : [Color(white: 0.18), Color(white: 0.10)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color(white: 0.35).opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct MasterCompressorPanel: View {
    @Binding var state: MasterCompressorState
    var rtaBins: [Float]
    var inL: Float
    var inR: Float
    var outL: Float
    var outR: Float
    var grDb: Float
    var onChange: () -> Void

    @State private var meterMode = 1 // 0 GR, 1 OUT, 2 IN

    private var leftMeter: Float {
        switch meterMode {
        case 2: return inL
        default: return outL
        }
    }
    private var rightMeter: Float {
        switch meterMode {
        case 2: return inR
        default: return outR
        }
    }

    private var isCompressing: Bool { !state.bypass && grDb > 0.15 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    faceplateBanner

                    RTAView(bins: rtaBins, apiStyle: true)
                        .frame(height: 118)
                        .opacity(state.bypass ? 0.4 : 1)

                    meterDeck
                        .opacity(state.bypass ? 0.45 : 1)

                    compressorSection
                        .opacity(state.bypass ? 0.4 : 1)
                        .allowsHitTesting(!state.bypass)

                    kneeSection
                        .opacity(state.bypass ? 0.4 : 1)
                        .allowsHitTesting(!state.bypass)

                    Text("Inspired by classic console bus compressors · original UI")
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .foregroundStyle(APILook.labelDim.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
        }
        .frame(width: 460, height: ChannelStripView.stripHeight, alignment: .top)
        .background(APILook.charcoal)
        .overlay(
            HStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [APILook.metalBlueHi, APILook.metalBlue, APILook.metalBlue.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 6)
                Spacer(minLength: 0)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [APILook.metalBlueHi, APILook.metalBlue, APILook.metalBlue.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 6)
            }
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(APILook.accentBlue.opacity(0.55), lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: state) { _, _ in onChange() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            RackScrew()
            VStack(alignment: .leading, spacing: 2) {
                Text("SELECTED CHANNEL")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(APILook.accentBlue)
                Text("MASTER")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(APILook.label)
            }
            Spacer()
            HStack(spacing: 6) {
                BypassToggle(bypass: $state.bypass)
                Text("COMP")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(state.bypass ? APILook.labelDim : APILook.ledGreen)
                LEDDot(on: !state.bypass, color: APILook.ledGreen)
            }
            RackScrew()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color(white: 0.14), Color(white: 0.09)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(APILook.accentBlue.opacity(0.45))
                .frame(height: 1.5)
        }
    }

    private var faceplateBanner: some View {
        HStack(spacing: 10) {
            Text("BUS COMPRESSOR")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(2.2)
                .foregroundStyle(APILook.label)
            Spacer()
            HStack(spacing: 5) {
                LEDDot(on: isCompressing, color: APILook.ledRed)
                Text(isCompressing ? "GR" : "READY")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(isCompressing ? APILook.ledRed : APILook.labelDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.35)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.11)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color(white: 0.35).opacity(0.4), lineWidth: 1)
        )
    }

    private var meterDeck: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                if meterMode == 0 {
                    AnalogVUMeter(gainReductionDb: grDb, label: "LEFT")
                    AnalogVUMeter(gainReductionDb: grDb, label: "RIGHT")
                } else {
                    AnalogVUMeter(
                        level: leftMeter,
                        label: meterMode == 2 ? "IN L" : "OUT L"
                    )
                    AnalogVUMeter(
                        level: rightMeter,
                        label: meterMode == 2 ? "IN R" : "OUT R"
                    )
                }
            }

            HStack(spacing: 8) {
                Text("METER")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(APILook.label)
                APIPushButton(title: "GR", lit: meterMode == 0, led: APILook.ledRed) { meterMode = 0 }
                    .frame(width: 56)
                APIPushButton(title: "OUT", lit: meterMode == 1, led: APILook.ledYellow) { meterMode = 1 }
                    .frame(width: 56)
                APIPushButton(title: "IN", lit: meterMode == 2, led: APILook.ledGreen) { meterMode = 2 }
                    .frame(width: 56)
                Spacer(minLength: 4)
                Text(String(format: "GR  %.1f dB", grDb))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(APILook.ledRed.opacity(0.9))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(white: 0.3).opacity(0.45), lineWidth: 1)
        )
    }

    private var compressorSection: some View {
        APISection(title: "COMPRESSOR") {
            HStack(alignment: .bottom, spacing: 2) {
                HardwareKnob(
                    value: $state.thresholdDb, range: -40...10, label: "THRESH",
                    valueText: { String(format: "%+.0f", $0) },
                    style: .metal, diameter: 44, defaultValue: -12
                )
                HardwareKnob(
                    value: $state.attackMs, range: 0.03...30, label: "ATTACK",
                    valueText: { String(format: $0 < 1 ? "%.2gms" : "%.0fms", $0) },
                    style: .metal, diameter: 44,
                    stops: MasterCompressorState.attackStops, defaultValue: 1
                )
                HardwareKnob(
                    value: $state.ratio, range: 1.5...100, label: "RATIO",
                    valueText: { $0 >= 40 ? "∞" : String(format: "%.1g:1", $0) },
                    style: .metal, diameter: 44,
                    stops: MasterCompressorState.ratioStops, defaultValue: 4
                )
                HardwareKnob(
                    value: $state.releaseSec, range: 0.05...2, label: "RELEASE",
                    valueText: { String(format: $0 < 1 ? "%.2gs" : "%.0fs", $0) },
                    style: .metal, diameter: 44,
                    stops: MasterCompressorState.releaseStops, defaultValue: 0.5
                )

                // Divider before output stage
                Rectangle()
                    .fill(APILook.border.opacity(0.7))
                    .frame(width: 1, height: 64)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 14)

                HardwareKnob(
                    value: $state.outputDb, range: -24...24, label: "OUTPUT",
                    valueText: { String(format: "%+.0f", $0) },
                    style: .outputRed, diameter: 48, defaultValue: 0
                )

                Button { state.autoMakeup.toggle() } label: {
                    VStack(spacing: 6) {
                        LEDDot(on: state.autoMakeup, color: APILook.ledRed)
                        Text("MAKE-UP")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.3)
                            .foregroundStyle(APILook.label)
                        Text(state.autoMakeup ? "AUTO" : "MAN")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(state.autoMakeup ? APILook.ledRed : APILook.labelDim)
                    }
                    .frame(width: 54)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(white: 0.2), Color(white: 0.11)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 14)
                .help(state.autoMakeup ? "Auto make-up gain on" : "Manual make-up — use OUTPUT")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var kneeSection: some View {
        APISection(title: "KNEE") {
            HStack(spacing: 8) {
                APIPushButton(title: "HARD", lit: state.knee == 0, led: APILook.ledRed) { state.knee = 0 }
                APIPushButton(title: "MED", lit: state.knee == 1, led: APILook.ledYellow) { state.knee = 1 }
                APIPushButton(title: "SOFT", lit: state.knee == 2, led: APILook.ledGreen) { state.knee = 2 }
            }
        }
    }
}
