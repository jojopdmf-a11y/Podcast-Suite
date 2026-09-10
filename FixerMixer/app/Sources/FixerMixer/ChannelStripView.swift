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
        if dbNorm > 0.9 { return MixerTheme.meterRed }
        if dbNorm > 0.7 { return MixerTheme.meterYellow }
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
                        get: { Double(eq[band]) },
                        set: { eq[band] = Float($0) }
                    ), in: -12...12)
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
    var onSelect: () -> Void
    var onChange: () -> Void

    /// Keeps music strip the same height as full speaker strips.
    static let stripHeight: CGFloat = 468

    @State private var dropTargetSlot: ChannelDSPSlot?
    @State private var isRenaming = false
    @FocusState private var nameFieldFocused: Bool

    private var fxDimmed: Bool { channel.dspBypass }
    private var canReorderDSP: Bool { !channel.isStereo && channel.dspOrder.count > 1 }
    private var canRename: Bool { !channel.isStereo }

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 3) {
                HStack(alignment: .center, spacing: 6) {
                    channelNameLabel
                    Spacer(minLength: 0)
                    Button(action: onSelect) {
                        Text(isSelected ? "SEL●" : "SEL")
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .tracking(0.3)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .foregroundStyle(isSelected ? MixerTheme.bgBottom : MixerTheme.cyan)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isSelected ? MixerTheme.lime : MixerTheme.panelRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
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

            VStack(spacing: 2) {
                Text("PAN")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.cyanDim)
                Slider(value: Binding(
                    get: { Double(channel.pan) },
                    set: { channel.pan = Float($0) }
                ), in: -1...1)
                .tint(MixerTheme.lime)
                .frame(width: 100)
                .onTapGesture(count: 2) { channel.pan = 0 }
            }
        }
        .padding(10)
        .frame(width: 156, height: Self.stripHeight, alignment: .top)
        .mixerPanel(glow: isSelected || channel.fileURL != nil)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? MixerTheme.lime : .clear, lineWidth: 2)
                .shadow(color: isSelected ? MixerTheme.lime.opacity(0.45) : .clear, radius: 6)
        )
        .onChange(of: channel) { _, _ in onChange() }
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
            return channel.eq.gains.contains { abs($0) > 0.05 }
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
    var onSeek: (Double) -> Void

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
            }

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(MixerTheme.panelRaised)

                    Canvas { context, size in
                        let count = max(peaks.count, 1)
                        let mid = size.height / 2
                        for (i, peak) in peaks.enumerated() {
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

                    Rectangle()
                        .fill(MixerTheme.lime)
                        .frame(width: 2)
                        .shadow(color: MixerTheme.lime.opacity(0.7), radius: 4)
                        .offset(x: CGFloat(playhead) * (w - 2))

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let t = max(0, min(1, value.location.x / max(w, 1)))
                                    onSeek(Double(t))
                                }
                        )
                }
            }
            .frame(height: 88)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MixerTheme.cyan.opacity(0.35), lineWidth: 1)
            )
        }
        .padding(12)
        .mixerPanel()
    }
}
