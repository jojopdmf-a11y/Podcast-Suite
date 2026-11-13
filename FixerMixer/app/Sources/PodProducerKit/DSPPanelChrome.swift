import SwiftUI

// MARK: - DSP panel chrome
// Shared by the selected-channel cards and the channel strips.
// Master still uses HardwareKnob, BypassToggle, and the classic fader.

enum DSPPanelStyle {
    static let cyan = Color(red: 0.28, green: 0.86, blue: 0.94)
    static let label = Color(white: 0.76)
}

/// One machined rotary for the DSP cards. Drag, fine-drag, and double-click match `HardwareKnob`.
struct DSPPanelKnob: View {
    @Binding var value: Float
    var range: ClosedRange<Float>
    var label: String
    var valueText: (Float) -> String
    var diameter: CGFloat = 34
    var stops: [Float]? = nil
    var defaultValue: Float = 0
    var dragSensitivity: Float = 1
    /// When set, a drag lands on this grid. Mouse-down without movement does not snap.
    /// Card knobs leave it nil.
    var step: Float? = nil
    /// Arc grows from the centre of the travel. GAIN uses this. Other knobs grow from the minimum.
    var bipolar: Bool = false
    /// Wider than the face when the label needs it. Nil keeps the card column (`diameter + 8`).
    var columnWidth: CGFloat? = nil
    /// Value and label beside the face. The header input-gain knob uses this so the row stays short.
    var inline: Bool = false

    @State private var dragStartValue: Float = 0

    private let sweepStart: Double = -140
    private let sweep: Double = 280

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

    private var pointerDegrees: Double { sweepStart + normalized * sweep }

    private var arcStart: Double { bipolar ? sweepStart + sweep / 2 : sweepStart }

    var body: some View {
        Group {
            if inline {
                inlineBody
            } else {
                stackedBody
            }
        }
        .help("Double-click to reset · Option-drag for fine")
    }

    private var stackedBody: some View {
        let column = columnWidth ?? (diameter + 8)
        return VStack(spacing: 2) {
            Text(valueText(displayValue))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(DSPPanelStyle.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: column, height: 13)

            face
                .frame(width: column, height: diameter + 8)

            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(1.15)
                .textCase(.uppercase)
                .foregroundStyle(DSPPanelStyle.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: column, height: 12)
        }
    }

    private var inlineBody: some View {
        HStack(alignment: .center, spacing: 4) {
            face
                .frame(width: diameter + 8, height: diameter + 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(valueText(displayValue))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(DSPPanelStyle.cyan)
                    .lineLimit(1)
                    .frame(height: 12)
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(DSPPanelStyle.label)
                    .lineLimit(1)
                    .frame(height: 11)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var face: some View {
        let art = diameter + 8
        let showArc = abs(pointerDegrees - arcStart) > 0.8
        return ZStack {
            if showArc {
                DSPKnobArc(from: arcStart, to: pointerDegrees)
                    .stroke(DSPPanelStyle.cyan, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                    .frame(width: art, height: art)
                    .shadow(color: DSPPanelStyle.cyan.opacity(0.55), radius: 2)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(white: 0.42),
                            Color(white: 0.22),
                            Color(white: 0.08),
                            Color(white: 0.13)
                        ],
                        center: UnitPoint(x: 0.48, y: 0.38),
                        startRadius: 1,
                        endRadius: diameter * 0.62
                    )
                )
                .overlay(
                    Circle()
                        .fill(
                            AngularGradient(
                                colors: [
                                    Color.white.opacity(0.22),
                                    Color.black.opacity(0.28),
                                    Color.white.opacity(0.08),
                                    Color.black.opacity(0.34),
                                    Color.white.opacity(0.16)
                                ],
                                center: .center
                            )
                        )
                        .blendMode(.softLight)
                        .allowsHitTesting(false)
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [
                                    Color.white.opacity(0.55),
                                    Color.black.opacity(0.45),
                                    Color.white.opacity(0.20),
                                    Color.black.opacity(0.55),
                                    Color.white.opacity(0.40)
                                ],
                                center: .center
                            ),
                            lineWidth: 1.15
                        )
                )
                .overlay(
                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.20), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: diameter * 0.58, height: diameter * 0.20)
                        .offset(y: -diameter * 0.18)
                        .allowsHitTesting(false)
                )
                .frame(width: diameter, height: diameter)
                .shadow(color: Color.black.opacity(0.55), radius: 3, y: 2)

            Capsule()
                .fill(Color.white)
                .frame(width: 1.7, height: diameter * 0.36)
                .shadow(color: Color.black.opacity(0.5), radius: 0.4, y: 0.4)
                .offset(y: -diameter * 0.15)
                .rotationEffect(.degrees(pointerDegrees))
        }
        .frame(width: art, height: art)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if g.translation == .zero {
                        dragStartValue = value
                    }
                    let fine: Float = NSEvent.modifierFlags.contains(.option) ? 0.22 : 1
                    let delta = -Float(g.translation.height) * 0.012 * dragSensitivity * fine
                    if let stops, stops.count > 1 {
                        let startIdx = Float(
                            stops.enumerated().min(by: {
                                abs($0.element - dragStartValue) < abs($1.element - dragStartValue)
                            })?.offset ?? 0
                        )
                        let next = startIdx + delta * Float(stops.count)
                        let i = max(0, min(stops.count - 1, Int(next.rounded())))
                        value = stops[i]
                    } else if let step, step > 0 {
                        if g.translation == .zero { return }
                        let span = range.upperBound - range.lowerBound
                        let raw = dragStartValue + delta * span * 2.2
                        let snapped = (raw / step).rounded() * step
                        value = max(range.lowerBound, min(range.upperBound, snapped))
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
    }
}

/// Knob degrees: 0 is straight up, positive is clockwise. Matches `HardwareKnob`’s −140…+140 sweep.
private struct DSPKnobArc: Shape {
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - 0.9
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(
            center: center,
            radius: max(1, radius),
            startAngle: .degrees(from - 90),
            endAngle: .degrees(to - 90),
            // SwiftUI’s clockwise flag runs opposite the knob’s on-screen direction.
            clockwise: to < from
        )
        return path
    }
}

enum DSPBevelKind {
    case off, blue, green, red, gold
    /// Strip SEL and the link seam, when lit.
    case lime
    /// Strip MUTE, when lit. Same red-orange as `MixerTheme.danger`.
    case mute
    /// Strip SOLO, when lit. Same yellow as `MixerTheme.meterYellow`.
    case solo

    var text: Color {
        switch self {
        case .off: return Color(white: 0.86)
        default: return Color(white: 0.06)
        }
    }

    var top: Color {
        switch self {
        case .off: return Color(white: 0.26)
        case .blue: return Color(red: 0.48, green: 0.70, blue: 0.93)
        case .green: return Color(red: 0.64, green: 0.98, blue: 0.78)
        case .red: return Color(red: 1.0, green: 0.55, blue: 0.56)
        case .gold: return Color(red: 0.96, green: 0.82, blue: 0.42)
        case .lime: return Color(red: 0.90, green: 1.0, blue: 0.55)
        case .mute: return Color(red: 1.0, green: 0.62, blue: 0.55)
        case .solo: return Color(red: 1.0, green: 0.95, blue: 0.55)
        }
    }

    var bottom: Color {
        switch self {
        case .off: return Color(white: 0.12)
        case .blue: return Color(red: 0.24, green: 0.44, blue: 0.73)
        case .green: return Color(red: 0.29, green: 0.66, blue: 0.42)
        case .red: return Color(red: 0.72, green: 0.16, blue: 0.20)
        case .gold: return Color(red: 0.72, green: 0.52, blue: 0.12)
        case .lime: return Color(red: 0.52, green: 0.70, blue: 0.08)
        case .mute: return Color(red: 0.78, green: 0.18, blue: 0.16)
        case .solo: return Color(red: 0.78, green: 0.64, blue: 0.08)
        }
    }

    var glow: Color {
        switch self {
        case .off: return .clear
        case .blue: return Color(red: 0.35, green: 0.60, blue: 0.92)
        case .green: return Color(red: 0.30, green: 0.85, blue: 0.50)
        case .red: return MixerTheme.danger
        case .gold: return Color(red: 0.88, green: 0.70, blue: 0.23)
        case .lime: return MixerTheme.lime
        case .mute: return MixerTheme.danger
        case .solo: return MixerTheme.meterYellow
        }
    }
}

/// Capsule fill shared by the card pills and the strip pills. Lit fills carry a top highlight.
struct DSPBevelPlate: View {
    var lit: Bool
    var kind: DSPBevelKind

    var body: some View {
        let plate = lit ? kind : DSPBevelKind.off
        Capsule()
            .fill(
                LinearGradient(
                    colors: [plate.top, plate.bottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(lit ? 0.70 : 0.22))
                    .frame(height: 1)
                    .padding(.horizontal, 5)
                    .padding(.top, 1)
            }
            .overlay(
                Capsule()
                    .stroke(Color.black.opacity(0.30), lineWidth: 0.6)
            )
            .shadow(
                color: lit ? plate.glow.opacity(0.50) : Color.black.opacity(0.35),
                radius: lit ? 2.5 : 1,
                y: 1
            )
    }
}

/// Smaller bevelled pill. Lit fills carry a top highlight. Off stays a dark recess.
struct DSPBevelPillLabel: View {
    var title: String
    var lit: Bool
    var kind: DSPBevelKind
    var fontSize: CGFloat = 9
    var horizontal: CGFloat = 8
    var vertical: CGFloat = 3
    var expands: Bool = false
    var fixedSize: CGSize? = nil

    var body: some View {
        let plate = lit ? kind : DSPBevelKind.off
        Text(title)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .tracking(0.45)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(plate.text)
            .padding(.horizontal, fixedSize == nil ? horizontal : 0)
            .padding(.vertical, fixedSize == nil ? vertical : 0)
            .frame(width: fixedSize?.width, height: fixedSize?.height)
            .frame(maxWidth: expands ? .infinity : nil)
            .background {
                DSPBevelPlate(lit: lit, kind: kind)
            }
            .contentShape(Capsule())
    }
}

/// NOTCH / NARROW / WIDE and DRUM / STUDIO / STAGE. About 60% of the row, centred.
struct DSPSegmentedSelector<ID: Hashable>: View {
    var options: [ID]
    var title: (ID) -> String
    var isSelected: (ID) -> Bool
    var help: (ID) -> String
    var select: (ID) -> Void

    var body: some View {
        GeometryReader { geo in
            let trackH = min(geo.size.height, max(40, geo.size.height * 0.60))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        segment(option)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: trackH)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.035), Color(white: 0.075)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.black.opacity(0.85), lineWidth: 1)
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.black.opacity(0.45))
                        .frame(height: 2)
                        .blur(radius: 0.5)
                        .padding(.horizontal, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func segment(_ option: ID) -> some View {
        let on = isSelected(option)
        return Button {
            select(option)
        } label: {
            Text(title(option))
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.7)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .foregroundStyle(on ? Color(white: 0.05) : Color(white: 0.46))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.50, green: 0.72, blue: 0.95),
                                        Color(red: 0.36, green: 0.58, blue: 0.86),
                                        Color(red: 0.24, green: 0.44, blue: 0.73)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.55))
                                    .frame(height: 1)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 1)
                            }
                            .shadow(color: Color(red: 0.35, green: 0.62, blue: 0.95).opacity(0.75), radius: 4)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(help(option))
    }
}

/// Recessed slot with a segmented LED fill. Colour and direction are chosen by the caller.
struct DSPLEDSlot: View {
    var fraction: CGFloat
    var color: Color
    var fromBottom: Bool

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 2
            let innerH = max(4, geo.size.height - inset * 2)
            let innerW = max(2, geo.size.width - inset * 2)
            let count = max(6, Int((innerH / 3.5).rounded()))
            let gap: CGFloat = 1.15
            let segH = max(1, (innerH - gap * CGFloat(count - 1)) / CGFloat(count))
            let clamped = min(1, max(0, fraction))
            let lit = clamped <= 0.001 ? 0 : min(count, Int((clamped * CGFloat(count)).rounded(.up)))
            ZStack {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                VStack(spacing: gap) {
                    ForEach(0..<count, id: \.self) { i in
                        let fromStart = fromBottom ? (count - 1 - i) : i
                        let on = fromStart < lit
                        RoundedRectangle(cornerRadius: 0.4, style: .continuous)
                            .fill(on ? color : Color(white: 0.09))
                            .frame(width: innerW, height: segH)
                            .shadow(color: on ? color.opacity(0.65) : .clear, radius: on ? 1.2 : 0)
                    }
                }
                .padding(inset)
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.black.opacity(0.50), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(7, geo.size.height * 0.22))
                .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                .allowsHitTesting(false)
            }
        }
    }
}
