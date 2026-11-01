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
                        Text("Export name → \(channel.bounceStemBaseName)_fixed.wav")
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
            inputGainControl

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
                    VStack(alignment: .leading, spacing: 10) {
                        API560EQView(eq: $channel.eq)
                        HPFControl(hpfHz: $channel.eq.hpfHz)
                    }
                }
                if !channel.isStereo {
                    dspBlock(
                        title: "PARA EQ",
                        subtitle: "Proportional-Q notch · tighter as you boost or cut",
                        bypass: $channel.para.bypass
                    ) {
                        ParaEQView(para: $channel.para)
                    }
                    dspBlock(
                        title: "DE-ESS",
                        subtitle: "Dynamic sibilance · Freq · Width · Threshold · GR only",
                        bypass: $channel.deess.bypass
                    ) {
                        DeEsserView(deess: $channel.deess, grDb: channel.deessGRDb)
                    }
                }
            }
        case .deVerb:
            dspBlock(title: slot.panelTitle, subtitle: slot.panelSubtitle, bypass: $channel.voice.deVerbBypass) {
                MixerLabeledSlider(title: "AMOUNT", value: $channel.voice.deVerb, range: 0...1, asPercent: true, defaultValue: 0)
            }
        case .wetter:
            dspBlock(title: slot.panelTitle, subtitle: slot.panelSubtitle, bypass: $channel.voice.wetterBypass) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(WetterRoom.allCases) { mode in
                            wetterRoomButton(mode)
                        }
                    }
                    MixerLabeledSlider(title: "AMOUNT", value: $channel.voice.wetter, range: 0...1, asPercent: true, defaultValue: 0)
                }
            }
        case .leveler:
            dspBlock(title: slot.panelTitle, subtitle: slot.panelSubtitle, bypass: $channel.voice.levelerBypass) {
                VStack(spacing: 8) {
                    MixerLabeledSlider(title: "TARGET dB", value: $channel.voice.levelerTargetDb, range: -30...0, asPercent: false, defaultValue: -6)
                    MixerLabeledSlider(title: "DRIVE", value: $channel.voice.levelerDrive, range: 0...1, asPercent: true, defaultValue: 0)
                    LevelerGRMeter(grDb: channel.levelerGRDb)
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

    private func wetterRoomButton(_ mode: WetterRoom) -> some View {
        let on = channel.voice.wetterRoom == mode
        return Button {
            channel.voice.wetterRoom = mode
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
        .help(mode.help)
    }

    private var inputGainControl: some View {
        HStack(spacing: 8) {
            Text("INPUT GAIN")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(APILook.labelDim)
            Slider(
                value: Binding(
                    get: { Double(channel.inputGainDb) },
                    set: {
                        channel.inputGainDb = Float($0)
                        channel.clampInputGain()
                    }
                ),
                in: Double(ChannelStripState.minInputGainDb)...Double(ChannelStripState.maxInputGainDb)
            )
            .tint(APILook.accentBlue)
            Text(abs(channel.inputGainDb) < 0.05 ? "0.0 dB" : String(format: "%+.1f dB", channel.inputGainDb))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(APILook.accentBlue)
                .frame(width: 64, alignment: .trailing)
        }
        .help("Trim before DSP (−18…+36 dB). IN meter on the strip reads after this gain. Double-click slider to reset.")
        .onTapGesture(count: 2) {
            channel.inputGainDb = 0
        }
    }
}

struct DeEsserView: View {
    @Binding var deess: ChannelDeEsser
    var grDb: Float

    private var logFreq: Binding<Float> {
        Binding(
            get: { log2(max(ChannelDeEsser.minHz, deess.freqHz)) },
            set: {
                deess.freqHz = min(ChannelDeEsser.maxHz, max(ChannelDeEsser.minHz, exp2($0)))
                deess.clamp()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                HardwareKnob(
                    value: logFreq,
                    range: log2(ChannelDeEsser.minHz)...log2(ChannelDeEsser.maxHz),
                    label: "FREQ",
                    valueText: { Self.freqLabel(hz: exp2($0)) },
                    diameter: 48,
                    defaultValue: log2(Float(6_000)),
                    dragSensitivity: 0.32
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            MixerLabeledSlider(
                title: "THRESHOLD",
                value: Binding(
                    get: { deess.thresholdDb },
                    set: {
                        deess.thresholdDb = $0
                        deess.clamp()
                    }
                ),
                range: ChannelDeEsser.minThresholdDb...ChannelDeEsser.maxThresholdDb,
                asPercent: false,
                defaultValue: -24
            )
            DeEssGRMeter(grDb: grDb)
            Text("Width blends split-band cut toward wideband. No presets.")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(APILook.labelDim)
        }
    }

    private var widthCaption: String {
        switch deess.width {
        case .notch: return "narrow split · surgical"
        case .narrow: return "split leaning · voice ess"
        case .wide: return "wideband leaning · broader"
        }
    }

    private func widthButton(_ mode: ParaEQWidth) -> some View {
        let on = deess.width == mode
        return Button {
            deess.width = mode
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
        .help("Detection / reduction bandwidth — carries split vs wideband")
    }

    private static func freqLabel(hz: Float) -> String {
        if hz >= 1000 {
            return String(format: hz >= 10_000 ? "%.1fk" : "%.2fk", hz / 1000)
        }
        return String(format: "%.0f Hz", hz)
    }
}

/// Compact GR bar for De-ess (0…12 dB display).
private struct DeEssGRMeter: View {
    var grDb: Float
    private let maxDisplay: Float = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("GR")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(APILook.labelDim)
                Spacer()
                Text(String(format: "%.1f dB", max(0, grDb)))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(grDb > 0.15 ? APILook.ledYellow : APILook.labelDim)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let fill = CGFloat(min(1, max(0, grDb / maxDisplay)))
                ZStack(alignment: .trailing) {
                    Capsule()
                        .fill(Color.black.opacity(0.4))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [APILook.ledYellow.opacity(0.85), APILook.ledRed.opacity(0.9)],
                                startPoint: .trailing,
                                endPoint: .leading
                            )
                        )
                        .frame(width: max(2, w * fill))
                }
            }
            .frame(height: 8)
        }
        .help("De-ess gain reduction")
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
                            .shadow(color: (apiStyle ? APILook.accentBlue : MixerTheme.cyan).opacity(0.25), radius: v > 0.64 ? 3 : 0)
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
        // RTA maps −80…−10 dB onto 0…1. Shift yellow/red +6 dB.
        if v > 0.936 { return apiStyle ? APILook.ledRed : MixerTheme.meterRed }
        if v > 0.736 { return apiStyle ? APILook.ledYellow : MixerTheme.meterYellow }
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
            HStack(spacing: 6) {
                Text("vs GRAPHIC")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(APILook.labelDim)
                ForEach(ParaEQPlacement.allCases) { mode in
                    placementButton(mode)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 10) {
                HardwareKnob(
                    value: logFreq,
                    range: log2(ChannelParaEQ.minHz)...log2(ChannelParaEQ.maxHz),
                    label: "FREQ",
                    valueText: { Self.freqLabel(hz: exp2($0)) },
                    diameter: 52,
                    defaultValue: log2(Float(1_000)),
                    dragSensitivity: 0.32
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
                    defaultValue: 0,
                    dragSensitivity: 0.45
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
            Text("Bandwidth shrinks as |gain| grows. Double-click a knob to reset. Option-drag for extra-fine.")
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

    private func placementButton(_ mode: ParaEQPlacement) -> some View {
        let on = para.placement == mode
        return Button {
            para.placement = mode
        } label: {
            Text(mode.title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(on ? APILook.charcoal : APILook.label)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(on ? APILook.accentBlue : Color(white: 0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(on ? APILook.accentBlue : Color(white: 0.35).opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(mode.help)
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

/// 24 dB/oct high-pass under the graphic. Does not move graphic faders. Left = Off.
struct HPFControl: View {
    @Binding var hpfHz: Float

    private var sliderValue: Binding<Double> {
        Binding(
            get: {
                if hpfHz < HighPass24DSP.minHz { return 0 }
                return Double(hpfHz)
            },
            set: { raw in
                if raw < Double(HighPass24DSP.minHz) * 0.5 {
                    hpfHz = 0
                } else {
                    hpfHz = Float(raw)
                    // clamp via ChannelEQ helper path
                    if hpfHz > 0 {
                        hpfHz = min(HighPass24DSP.maxHz, max(HighPass24DSP.minHz, hpfHz))
                    }
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("HPF 24 dB/oct")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(APILook.labelDim)
                Spacer()
                Text(hpfHz < HighPass24DSP.minHz ? "OFF" : String(format: "%.0f Hz", hpfHz))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(hpfHz < HighPass24DSP.minHz ? APILook.labelDim : APILook.accentBlue)
            }
            Slider(
                value: sliderValue,
                in: 0...Double(HighPass24DSP.maxHz)
            )
            .tint(APILook.accentBlue)
            .onTapGesture(count: 2) {
                hpfHz = 0
            }
        }
        .help("Double-click to turn HPF off")
    }
}

/// Compact gain-reduction bar for the Leveler detail panel (0…12 dB display).
private struct LevelerGRMeter: View {
    var grDb: Float
    private let maxDisplay: Float = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("GR")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(APILook.labelDim)
                Spacer()
                Text(String(format: "%.1f dB", max(0, grDb)))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(grDb > 0.15 ? APILook.ledYellow : APILook.labelDim)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let fill = CGFloat(min(1, max(0, grDb / maxDisplay)))
                ZStack(alignment: .trailing) {
                    Capsule()
                        .fill(Color.black.opacity(0.4))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [APILook.ledYellow.opacity(0.85), APILook.ledRed.opacity(0.9)],
                                startPoint: .trailing,
                                endPoint: .leading
                            )
                        )
                        .frame(width: max(2, w * fill))
                }
            }
            .frame(height: 8)
        }
        .help("Leveler gain reduction")
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
