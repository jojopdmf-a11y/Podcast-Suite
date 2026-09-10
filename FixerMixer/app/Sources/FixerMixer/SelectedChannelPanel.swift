import AppKit
import SwiftUI

/// Inspector for the selected channel: RTA + full DSP strip (mirrors channel ON/BYP).
struct SelectedChannelPanel: View {
    @Binding var channel: ChannelStripState
    var rtaBins: [Float]
    var onChange: () -> Void

    @State private var isRenaming = false
    @FocusState private var nameFieldFocused: Bool

    private var canRename: Bool { !channel.isStereo }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SELECTED CHANNEL")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(APILook.accentBlue)
                    if canRename && isRenaming {
                        TextField("Channel name", text: $channel.name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(APILook.label)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(APILook.panelRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(APILook.accentBlue.opacity(0.7), lineWidth: 1)
                            )
                            .focused($nameFieldFocused)
                            .onSubmit { commitRename() }
                            .onChange(of: nameFieldFocused) { _, focused in
                                if !focused { commitRename() }
                            }
                    } else {
                        Text(channel.name)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .tracking(1)
                            .foregroundStyle(APILook.label)
                            .help(canRename ? "Double-click to rename" : channel.name)
                            .onTapGesture(count: 2) {
                                guard canRename else { return }
                                isRenaming = true
                                DispatchQueue.main.async { nameFieldFocused = true }
                            }
                    }
                    if canRename {
                        Text("Bounce → \(channel.bounceStemBaseName)_fixed.wav")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(APILook.labelDim)
                    }
                }
                Spacer()
                Text(channel.fileURL?.lastPathComponent ?? "—")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(APILook.labelDim)
                    .lineLimit(1)
            }

            RTAView(bins: rtaBins, apiStyle: true)
                .frame(height: 96)

            if !channel.isStereo {
                HStack(spacing: 6) {
                    BypassToggle(bypass: $channel.dspBypass)
                    Text("DSP ALL")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(channel.dspBypass ? APILook.labelDim : APILook.ledGreen)
                    Spacer()
                    Text(channel.dspBypass ? "Bypassed" : "Processing")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(APILook.labelDim)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(channel.dspOrder) { slot in
                        dspSlotBlock(slot)
                    }
                }
                .padding(.bottom, 4)
                .opacity(channel.dspBypass && !channel.isStereo ? 0.45 : 1)
                .allowsHitTesting(!(channel.dspBypass && !channel.isStereo))
            }
        }
        .padding(12)
        .frame(width: 460, height: ChannelStripView.stripHeight, alignment: .top)
        .background(APILook.charcoal)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(APILook.accentBlue.opacity(0.55), lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: channel) { _, _ in onChange() }
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

    @ViewBuilder
    private func dspSlotBlock(_ slot: ChannelDSPSlot) -> some View {
        switch slot {
        case .eq:
            VStack(alignment: .leading, spacing: 12) {
                dspBlock(title: slot.panelTitle, subtitle: slot.panelSubtitle, bypass: $channel.eq.bypass) {
                    API560EQView(eq: $channel.eq)
                }
                if !channel.isStereo {
                    dspBlock(
                        title: "PARA EQ",
                        subtitle: "Proportional-Q notch · tighter as you boost or cut",
                        bypass: $channel.para.bypass
                    ) {
                        ParaEQView(para: $channel.para)
                    }
                }
            }
        case .deVerb:
            dspBlock(title: slot.panelTitle, subtitle: slot.panelSubtitle, bypass: $channel.voice.deVerbBypass) {
                MixerLabeledSlider(title: "AMOUNT", value: $channel.voice.deVerb, range: 0...1, asPercent: true, defaultValue: 0)
            }
        case .wetter:
            dspBlock(title: slot.panelTitle, subtitle: slot.panelSubtitle, bypass: $channel.voice.wetterBypass) {
                MixerLabeledSlider(title: "AMOUNT", value: $channel.voice.wetter, range: 0...1, asPercent: true, defaultValue: 0)
            }
        case .leveler:
            dspBlock(title: slot.panelTitle, subtitle: slot.panelSubtitle, bypass: $channel.voice.levelerBypass) {
                VStack(spacing: 8) {
                    MixerLabeledSlider(title: "TARGET dB", value: $channel.voice.levelerTargetDb, range: -30...(-6), asPercent: false, defaultValue: -18)
                    MixerLabeledSlider(title: "DRIVE", value: $channel.voice.levelerDrive, range: 0...1, asPercent: true, defaultValue: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func dspBlock<Content: View>(
        title: String,
        subtitle: String,
        bypass: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                BypassToggle(bypass: bypass)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(bypass.wrappedValue ? APILook.labelDim : APILook.label)
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(APILook.labelDim)
                }
                Spacer()
            }
            content()
                .opacity(bypass.wrappedValue ? 0.4 : 1)
                .allowsHitTesting(!bypass.wrappedValue)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(APILook.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(APILook.border, lineWidth: 1)
        )
    }
}

struct RTAView: View {
    var bins: [Float]
    var apiStyle: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("RTA")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(apiStyle ? APILook.accentBlue : MixerTheme.cyanDim)
                Spacer()
                Text("40 Hz  →  16 kHz")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(apiStyle ? APILook.labelDim : MixerTheme.textSecondary)
            }

            GeometryReader { geo in
                let count = max(bins.count, 1)
                let gap: CGFloat = 1.2
                let barW = max(2, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(0..<count, id: \.self) { i in
                        let v = bins.indices.contains(i) ? bins[i] : 0
                        let h = max(2, CGFloat(v) * geo.size.height)
                        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                            .fill(barColor(v))
                            .frame(width: barW, height: h)
                            .shadow(color: (apiStyle ? APILook.accentBlue : MixerTheme.cyan).opacity(0.25), radius: v > 0.55 ? 3 : 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(apiStyle ? Color.black.opacity(0.55) : MixerTheme.bgBottom.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(apiStyle ? APILook.border : MixerTheme.cyan.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private func barColor(_ v: Float) -> Color {
        if v > 0.85 { return apiStyle ? APILook.ledRed : MixerTheme.meterRed }
        if v > 0.65 { return apiStyle ? APILook.ledYellow : MixerTheme.meterYellow }
        return apiStyle ? APILook.accentBlue : MixerTheme.cyan
    }
}

struct ParaEQView: View {
    @Binding var para: ChannelParaEQ

    private var logFreq: Binding<Float> {
        Binding(
            get: { log2(max(ChannelParaEQ.minHz, para.freqHz)) },
            set: {
                para.freqHz = min(ChannelParaEQ.maxHz, max(ChannelParaEQ.minHz, exp2($0)))
                para.clamp()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                HardwareKnob(
                    value: logFreq,
                    range: log2(ChannelParaEQ.minHz)...log2(ChannelParaEQ.maxHz),
                    label: "FREQ",
                    valueText: { Self.freqLabel(hz: exp2($0)) },
                    diameter: 52,
                    defaultValue: log2(Float(1_000))
                )
                HardwareKnob(
                    value: Binding(
                        get: { para.gainDb },
                        set: {
                            para.gainDb = $0
                            para.clamp()
                        }
                    ),
                    range: ChannelParaEQ.minGainDb...ChannelParaEQ.maxGainDb,
                    label: "GAIN",
                    valueText: { abs($0) < 0.05 ? "0.0 dB" : String(format: "%+.1f dB", $0) },
                    diameter: 52,
                    defaultValue: 0
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("WIDTH")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(APILook.labelDim)
                    HStack(spacing: 4) {
                        ForEach(ParaEQWidth.allCases) { mode in
                            widthButton(mode)
                        }
                    }
                    Text(widthCaption)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(APILook.accentBlue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Bandwidth shrinks as |gain| grows. Double-click a knob to reset.")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(APILook.labelDim)
        }
    }

    private var widthCaption: String {
        let bw = para.width.bandwidthOctaves(gainDb: para.gainDb)
        let q = para.width.q(gainDb: para.gainDb)
        if abs(para.gainDb) < 0.05 {
            return "flat · \(para.width.title.lowercased()) ready"
        }
        return String(format: "%.2f oct · Q %.1f", bw, q)
    }

    private func widthButton(_ mode: ParaEQWidth) -> some View {
        let on = para.width == mode
        return Button {
            para.width = mode
        } label: {
            VStack(spacing: 4) {
                LEDDot(on: on, color: APILook.ledGreen)
                Text(mode.title)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.3)
                    .foregroundStyle(APILook.label)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: on
                                ? [Color(white: 0.22), Color(white: 0.14)]
                                : [Color(white: 0.18), Color(white: 0.10)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(on ? APILook.accentBlue.opacity(0.7) : Color(white: 0.35).opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("How quickly the band narrows as you boost or cut")
    }

    private static func freqLabel(hz: Float) -> String {
        if hz >= 1000 {
            return String(format: hz >= 10_000 ? "%.1fk" : "%.2fk", hz / 1000)
        }
        return String(format: "%.0f Hz", hz)
    }
}

struct MixerLabeledSlider: View {
    var title: String
    @Binding var value: Float
    var range: ClosedRange<Float>
    var asPercent: Bool
    var defaultValue: Float = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(APILook.labelDim)
                Spacer()
                Text(asPercent
                       ? String(format: "%.0f%%", value * 100)
                       : String(format: "%.1f", value))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(APILook.accentBlue)
            }
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Float($0) }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
            .tint(APILook.accentBlue)
            .onTapGesture(count: 2) {
                value = max(range.lowerBound, min(range.upperBound, defaultValue))
            }
        }
        .help("Double-click to reset")
    }
}
