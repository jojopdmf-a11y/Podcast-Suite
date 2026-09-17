import AppKit
import SwiftUI

struct LevelMeter: View {
    var level: Float
    var label: String

    private var dbNorm: CGFloat {
        let db = 20 * log10(max(level, 1e-5))
        let norm = (db + 60) / 60
        return CGFloat(max(0, min(1, norm)))
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(MixerTheme.cyanFaint)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(meterColor)
                        .frame(height: geo.size.height * dbNorm)
                        .shadow(color: meterColor.opacity(0.5), radius: 3)
                }
            }
            .frame(width: 8)
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

struct VerticalFader: View {
    @Binding var valueDb: Float
    var autoDriven: Bool = false
    var defaultValue: Float = 0
    var range: ClosedRange<Float> = -60...12
    var caption: String? = nil

    private let trackHeight: CGFloat = 110
    private let capHeight: CGFloat = 22
    private let capWidth: CGFloat = 28

    private var normalized: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0.5 }
        return CGFloat((valueDb - range.lowerBound) / span)
    }

    /// Y of cap center: 1 = top (+12), 0 = bottom (−60)
    private var capCenterY: CGFloat {
        let travel = trackHeight - capHeight
        return (1 - normalized) * travel + capHeight / 2
    }

    private var accent: Color {
        autoDriven ? MixerTheme.lime : MixerTheme.cyan
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%+.0f", valueDb))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)

            ZStack(alignment: .top) {
                // Chassis plate behind the slot
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

                // Recessed slot
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.black.opacity(0.85))
                    .frame(width: 5, height: trackHeight - 8)
                    .overlay(
                        // Slot highlight edge
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
                        // 0 dB tick across the slot
                        Rectangle()
                            .fill(accent.opacity(0.7))
                            .frame(width: 14, height: 1)
                            .offset(y: zeroTickOffset)
                    }
                    .offset(y: 4)

                // Fader cap
                FaderCap(accent: accent, autoDriven: autoDriven)
                    .frame(width: capWidth, height: capHeight)
                    .position(x: 18, y: capCenterY)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1.5)
            }
            .frame(width: 36, height: trackHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let y = min(trackHeight, max(0, g.location.y))
                        let travel = trackHeight - capHeight
                        let n = 1 - ((y - capHeight / 2) / max(travel, 1))
                        let clamped = Float(min(1, max(0, n)))
                        let span = range.upperBound - range.lowerBound
                        valueDb = range.lowerBound + clamped * span
                    }
            )
            .onTapGesture(count: 2) {
                guard !autoDriven else { return }
                valueDb = defaultValue
            }

            Text(caption ?? (autoDriven ? "AUTO" : "FADER"))
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(autoDriven ? MixerTheme.lime.opacity(0.8) : MixerTheme.cyanDim)
                .padding(.bottom, 1)
        }
        .help(autoDriven ? "Auto Balance" : "Double-click to zero")
    }

    private var zeroTickOffset: CGFloat {
        let span = range.upperBound - range.lowerBound
        let zeroNorm = CGFloat((0 - range.lowerBound) / span) // 0 dB position from bottom
        let travel = trackHeight - 8
        // Center of slot is mid; offset from center toward top for higher dB
        return travel / 2 - zeroNorm * travel
    }
}

/// Console-style plastic / metal fader knob.
private struct FaderCap: View {
    var accent: Color
    var autoDriven: Bool

    var body: some View {
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
                        .frame(width: 28)
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
        if abs(db) < 0.05 { return "0" }
        return String(format: "%+.0f", db)
    }
}

struct BypassToggle: View {
    @Binding var bypass: Bool

    var body: some View {
        Button {
            bypass.toggle()
        } label: {
            Text(bypass ? "BYP" : "ON")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .frame(width: 28, height: 26)
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
                .tracking(0.4)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(chipForeground)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(chipFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(MixerTheme.cyan.opacity(0.45), lineWidth: 1)
                )
                .opacity(bypassed ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .help("Select channel to edit \(title) in the detail panel")
    }

    private var chipForeground: Color {
        if bypassed { return MixerTheme.textSecondary }
        return active ? MixerTheme.bgBottom : MixerTheme.cyan
    }

    private var chipFill: Color {
        if bypassed { return MixerTheme.panelRaised }
        return active ? MixerTheme.lime : MixerTheme.panelRaised
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
            BypassToggle(bypass: $bypass)
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
    /// Keeps music strip the same height as full speaker strips.
    static let stripHeight: CGFloat = 528

    @State private var dropTargetSlot: ChannelDSPSlot?
    @State private var isRenaming = false
    @FocusState private var nameFieldFocused: Bool

    private var fxDimmed: Bool { channel.dspBypass }
    private var canReorderDSP: Bool { !channel.isStereo && channel.dspOrder.count > 1 && !stripReorderable }
    private var canRename: Bool { !channel.isStereo }

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 3) {
                HStack(alignment: .center, spacing: 6) {
                    channelNameLabel
                    Spacer(minLength: 0)
                    Button(action: onSelect) {
                        Text(isSelected ? "SEL●" : "SEL")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(0.4)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .foregroundStyle(isSelected ? MixerTheme.bgBottom : MixerTheme.cyan)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? MixerTheme.lime : MixerTheme.panelRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(isSelected ? MixerTheme.lime : MixerTheme.cyan.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Select this channel for the waveform timeline")
                }
                Text(channel.fileURL?.lastPathComponent ?? "— empty —")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(MixerTheme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if canRemove {
                    Button("REMOVE") { onRemove?() }
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
                }
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
                    BypassToggle(bypass: $channel.dspBypass)
                    Text("DSP")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(channel.dspBypass ? MixerTheme.textSecondary : MixerTheme.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(MixerTheme.panelRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(MixerTheme.cyan.opacity(0.45), lineWidth: 1)
                        )
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
                        .tracking(0.5)
                        .foregroundStyle(MixerTheme.cyanDim)
                        .frame(maxWidth: .infinity)
                }
            }
            .opacity(fxDimmed ? 0.4 : 1)
            .allowsHitTesting(!fxDimmed)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                LevelMeter(level: channel.prePeak, label: "PRE")
                VerticalFader(valueDb: faderDb, autoDriven: autoDriven)
                LevelMeter(level: channel.postPeak, label: "POST")
            }
            .frame(height: 130)
            .help(autoDriven
                  ? "Auto Balance rides this fader. Drag to favor/cut this speaker relative to auto."
                  : "Channel level")

            HStack(spacing: 6) {
                Button {
                    channel.mute.toggle()
                    onChange()
                } label: {
                    Text(channel.mute ? "MUTED" : "MUTE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(channel.mute ? MixerTheme.bgBottom : MixerTheme.cyan)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(channel.mute ? MixerTheme.danger : MixerTheme.panelRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(MixerTheme.cyan.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Mutes the whole strip. To punch a cough, select this strip and Shift-drag on the waveform.")

                Button {
                    channel.solo.toggle()
                    onChange()
                } label: {
                    Text(channel.solo ? "SOLO●" : "SOLO")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(channel.solo ? MixerTheme.bgBottom : MixerTheme.cyan)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(channel.solo ? MixerTheme.meterYellow : MixerTheme.panelRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(MixerTheme.cyan.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Hear this strip alone. Turn SOLO on more than one to hear those together. MUTE still silences a strip.")
            }

            VStack(spacing: 2) {
                Text("PAN")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.cyanDim)
                Slider(value: Binding(
                    get: { Double(channel.pan) },
                    set: { channel.pan = Float($0) }
                ), in: -1...1)
                .tint(MixerTheme.lime)
                .frame(maxWidth: .infinity)
                .onTapGesture(count: 2) { channel.pan = 0 }
            }
        }
        .padding(8)
        .frame(width: Self.stripWidth, height: Self.stripHeight, alignment: .top)
        .mixerPanel(glow: isSelected || channel.fileURL != nil)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isReorderDropTarget ? MixerTheme.lime : (isSelected ? MixerTheme.lime : .clear),
                    lineWidth: isReorderDropTarget ? 3 : 2
                )
                .shadow(color: (isReorderDropTarget || isSelected) ? MixerTheme.lime.opacity(0.45) : .clear, radius: 6)
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

    private var inputRow: some View {
        HStack(spacing: 4) {
            Text("IN")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(MixerTheme.cyanDim)
            Picker(
                "Input",
                selection: Binding(
                    get: { channel.inputChannel.map { $0 + 1 } ?? 0 },
                    set: { channel.inputChannel = $0 == 0 ? nil : $0 - 1 }
                )
            ) {
                Text("—").tag(0)
                if hardwareInputChannels > 0 {
                    ForEach(1...hardwareInputChannels, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .disabled(isRecording || hardwareInputChannels <= 0)
            .help("Which input on the interface this strip records. — means do not record this strip. Monitor on the interface, not through PodProducer.")
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
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(isSelected ? MixerTheme.lime : MixerTheme.cyan)
                .lineLimit(1)
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

    private func isSlotActive(_ slot: ChannelDSPSlot) -> Bool {
        switch slot {
        case .eq:
            return channel.eq.gains.contains { abs($0) > 0.05 } || channel.para.isActive
        case .deVerb:
            return channel.voice.deVerb > 0.02
        case .wetter:
            return channel.voice.wetter > 0.02
        case .leveler:
            return channel.voice.levelerDrive > 0.02
        }
    }

    private func bypassBinding(for slot: ChannelDSPSlot) -> Binding<Bool> {
        switch slot {
        case .eq:
            return $channel.eq.bypass
        case .deVerb:
            return $channel.voice.deVerbBypass
        case .wetter:
            return $channel.voice.wetterBypass
        case .leveler:
            return $channel.voice.levelerBypass
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WAVEFORM · \(channelName)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(MixerTheme.cyanDim)
                Spacer()
                Text("\(currentTime)  /  \(duration)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(MixerTheme.cyan)
                Text(zoom <= 1.01 ? "1×" : String(format: "%.0f×", zoom))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(MixerTheme.cyanDim)
                    .frame(minWidth: 22)
                Button("−") { nudgeZoom(0.5) }
                    .buttonStyle(MixerGhostButtonStyle())
                    .disabled(zoom <= 1.01)
                    .help("Zoom out")
                Button("+") { nudgeZoom(2) }
                    .buttonStyle(MixerGhostButtonStyle())
                    .disabled(zoom >= 15.9)
                    .help("Zoom in")
                Button("RESET") { zoom = 1; start = 0 }
                    .buttonStyle(MixerGhostButtonStyle())
                    .disabled(zoom <= 1.01)
                    .help("Show the whole file")
                if let onShowAllTracks {
                    Button("ALL TRACKS") { onShowAllTracks() }
                        .buttonStyle(MixerGhostButtonStyle())
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
        .padding(12)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WAVEFORM · ALL TRACKS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(MixerTheme.cyanDim)
                Spacer()
                Text("\(currentTime)  /  \(duration)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(MixerTheme.cyan)
                Button("ONE TRACK") { onShowOne() }
                    .buttonStyle(MixerGhostButtonStyle())
                    .help("Back to one channel’s waveform")
            }
            Text("Click a lane to zoom in · drag to seek · extra tracks scroll in this box")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(MixerTheme.textSecondary)

            ScrollView(.vertical, showsIndicators: stackHeight > maxStackHeight) {
                VStack(spacing: laneGap) {
                    ForEach(lanes) { lane in
                        laneRow(lane)
                    }
                }
            }
            .frame(height: min(stackHeight, maxStackHeight))
        }
        .padding(12)
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
