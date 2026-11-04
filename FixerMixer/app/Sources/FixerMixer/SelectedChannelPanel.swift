import AppKit
import SwiftUI

/// Inspector for the selected channel: RTA + full DSP strip (mirrors channel ON/BYP).
struct SelectedChannelPanel: View {
    @Binding var channel: ChannelStripState
    var rtaBins: [Float]
    /// Polled by the clip lamp. True for about 2 seconds after the post-gain input hits 0 dBFS.
    var inputIsClipping: () -> Bool = { false }
    var onChange: () -> Void

    @State private var isRenaming = false
    @FocusState private var nameFieldFocused: Bool

    /// Gaps and the card heights that fit the approved mockup at the real
    /// panel width. EQ, the mid row, and the bottom row stay these heights.
    /// Extra column height goes to the RTA. A shorter window shrinks the RTA
    /// first, and not below `rtaFloor`.
    enum Layout {
        static let gap: CGFloat = 5
        static let sideInset: CGFloat = 4
        static let rtaFloor: CGFloat = 96
        /// Tall enough for a 92 pt fader travel plus the header and HPF knob.
        static let eqCardH: CGFloat = 168
        /// Para EQ and De-ess, same height. Holds the radius-12 knobs.
        static let midRowH: CGFloat = 112
        /// De-verb, Ambience, and Leveler, same height.
        static let bottomRowH: CGFloat = 108
        /// De-verb : Ambience : Leveler, from the mockup. Leveler takes the rest.
        static let deVerbShare: CGFloat = 82
        static let ambienceShare: CGFloat = 96
        static let levelerShare: CGFloat = 110
    }

    /// Floor for this column with the RTA at its 96 pt hard floor.
    /// The reachable window minimum is taller, so the RTA stays above this.
    static let minimumHeight: CGFloat = 600

    private var canRename: Bool { !channel.isStereo }

    /// Panel knobs match the approved v3 size: radius 12.
    private let knob: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.gap) {
            header
            dspAllRow
            cardColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, Layout.sideInset)
        .padding(.vertical, Layout.gap)
        .frame(width: 460, alignment: .topLeading)
        .frame(minHeight: Self.minimumHeight, maxHeight: .infinity, alignment: .top)
        .background(APILook.charcoal)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(APILook.accentBlue.opacity(0.55), lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: channel) { _, _ in onChange() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("SELECTED CHANNEL")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(APILook.accentBlue)
                if canRename && isRenaming {
                    TextField("Channel name", text: $channel.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(APILook.label)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
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
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(APILook.label)
                        .lineLimit(1)
                        .help(canRename ? "Double-click to rename" : channel.name)
                        .onTapGesture(count: 2) {
                            guard canRename else { return }
                            isRenaming = true
                            DispatchQueue.main.async { nameFieldFocused = true }
                        }
                }
            }
            if canRename {
                Text("Export name → \(channel.bounceStemBaseName)_fixed.wav")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(APILook.labelDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(channel.fileURL?.lastPathComponent ?? "—")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(APILook.labelDim)
                .lineLimit(1)
        }
    }

    private var dspAllRow: some View {
        HStack(alignment: .center, spacing: 6) {
            if !channel.isStereo {
                BypassToggle(bypass: $channel.dspBypass)
                Text("DSP ALL")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(channel.dspBypass ? APILook.labelDim : APILook.ledGreen)
                Text(channel.dspBypass ? "Bypassed" : "Processing")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(APILook.labelDim)
            }
            Spacer(minLength: 8)
            inputGainCluster
        }
    }

    /// Input trim sits in the header. The clip lamp is the signal right after this gain.
    private var inputGainCluster: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(spacing: 0) {
                Text("INPUT")
                Text("GAIN")
            }
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(APILook.labelDim)
            InputClipLamp(isClipping: inputIsClipping)
            HardwareKnob(
                value: Binding(
                    get: { channel.inputGainDb },
                    set: {
                        channel.inputGainDb = $0
                        channel.clampInputGain()
                    }
                ),
                range: ChannelStripState.minInputGainDb...ChannelStripState.maxInputGainDb,
                label: "dB",
                valueText: { abs($0) < 0.05 ? "0.0" : String(format: "%+.1f", $0) },
                diameter: knob,
                defaultValue: 0,
                dragSensitivity: 0.55
            )
            .help("Trim before DSP (−18…+36 dB). The strip IN meter reads after this gain. Double-click to reset.")
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

    private func flowNumber(_ slot: ChannelDSPSlot) -> Int {
        (channel.dspOrder.firstIndex(of: slot) ?? 0) + 1
    }

    /// RTA takes whatever the fixed cards do not. The cards keep their ideal height.
    private var cardColumn: some View {
        GeometryReader { geo in
            let gap = Layout.gap
            let voice = !channel.isStereo
            let inner = geo.size.width
            let shares = Layout.deVerbShare + Layout.ambienceShare + Layout.levelerShare
            let deVerbW = (inner - gap * 2) * Layout.deVerbShare / shares
            let ambienceW = (inner - gap * 2) * Layout.ambienceShare / shares
            VStack(alignment: .leading, spacing: gap) {
                RTAView(bins: rtaBins, apiStyle: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .frame(minHeight: Layout.rtaFloor)
                eqCard
                    .frame(height: Layout.eqCardH, alignment: .top)
                if voice {
                    HStack(alignment: .top, spacing: gap) {
                        paraCard
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        deessCard
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: Layout.midRowH)
                    HStack(alignment: .top, spacing: gap) {
                        deVerbCard
                            .frame(width: deVerbW)
                            .frame(maxHeight: .infinity, alignment: .top)
                        ambienceCard
                            .frame(width: ambienceW)
                            .frame(maxHeight: .infinity, alignment: .top)
                        levelerCard
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: Layout.bottomRowH)
                }
            }
            .frame(width: inner, height: geo.size.height, alignment: .top)
        }
        .opacity(channel.dspBypass && !channel.isStereo ? 0.55 : 1)
    }

    private var eqCard: some View {
        dspCard(
            title: "EQ 2520",
            subtitle: "10-band graphic · ±16 dB · 0.5 dB detents",
            bypass: $channel.eq.bypass,
            flow: flowNumber(.eq),
            dotOn: !channel.eq.bypass && !channel.dspBypass,
            expands: true
        ) {
            HStack(alignment: .center, spacing: 4) {
                API560EQView(eq: $channel.eq)
                hpfKnob
                    .frame(width: 46)
            }
        }
    }

    private var hpfKnob: some View {
        HardwareKnob(
            value: Binding(
                get: { channel.eq.hpfHz < HighPass24DSP.minHz ? 0 : channel.eq.hpfHz },
                set: { raw in
                    if raw < HighPass24DSP.minHz {
                        channel.eq.hpfHz = 0
                    } else {
                        channel.eq.hpfHz = min(HighPass24DSP.maxHz, raw)
                    }
                }
            ),
            range: 0...HighPass24DSP.maxHz,
            label: "HPF",
            valueText: { $0 < HighPass24DSP.minHz ? "OFF" : String(format: "%.0f", $0) },
            diameter: knob,
            defaultValue: 0,
            dragSensitivity: 0.35,
            tight: true
        )
        .help("24 dB/oct high-pass. Double-click for off.")
    }

    private var paraCard: some View {
        dspCard(
            title: "PARA EQ",
            subtitle: nil,
            bypass: $channel.para.bypass,
            flow: flowNumber(.eq),
            dotOn: !channel.para.bypass && !channel.dspBypass,
            expands: true,
            fillsBody: true
        ) {
            ParaEQView(para: $channel.para, knob: knob, showsCaption: false)
        }
    }

    private var deessCard: some View {
        dspCard(
            title: "DE-ESS",
            subtitle: nil,
            bypass: $channel.deess.bypass,
            flow: flowNumber(.deess),
            dotOn: !channel.deess.bypass && !channel.dspBypass,
            expands: true,
            fillsBody: true,
            headerExtra: AnyView(listenButton)
        ) {
            DeEsserView(deess: $channel.deess, grDb: channel.deessGRDb, knob: knob)
        }
    }

    private var listenButton: some View {
        Button {
            channel.deessListen.toggle()
        } label: {
            Text("LISTEN")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .foregroundStyle(channel.deessListen ? Color.black : APILook.label)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(channel.deessListen
                              ? Color(red: 0.88, green: 0.70, blue: 0.23)
                              : Color(white: 0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(channel.deessListen
                                ? Color(red: 0.88, green: 0.70, blue: 0.23)
                                : Color(white: 0.35).opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Monitor only: this channel’s output becomes the de-ess band at FREQ and WIDTH. Not recorded, not exported, and it turns off when a session loads.")
    }

    private var deVerbCard: some View {
        dspCard(
            title: "DE-VERB",
            subtitle: nil,
            bypass: $channel.voice.deVerbBypass,
            flow: flowNumber(.deVerb),
            dotOn: !channel.voice.deVerbBypass && !channel.dspBypass,
            expands: true
        ) {
            VStack(spacing: 0) {
                HardwareKnob(
                    value: $channel.voice.deVerb,
                    range: 0...1,
                    label: "AMOUNT",
                    valueText: { String(format: "%.0f%%", $0 * 100) },
                    diameter: knob,
                    defaultValue: 0,
                    tight: true
                )
                Text("deeper range (+25%)")
                    .font(.system(size: 6, weight: .medium, design: .rounded))
                    .foregroundStyle(APILook.labelDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var ambienceCard: some View {
        dspCard(
            title: "AMBIENCE",
            subtitle: nil,
            bypass: $channel.voice.wetterBypass,
            flow: flowNumber(.wetter),
            dotOn: !channel.voice.wetterBypass && !channel.dspBypass,
            expands: true
        ) {
            HStack(alignment: .center, spacing: 4) {
                HardwareKnob(
                    value: $channel.voice.wetter,
                    range: 0...1,
                    label: "AMOUNT",
                    valueText: { String(format: "%.0f%%", $0 * 100) },
                    diameter: knob,
                    defaultValue: 0,
                    tight: true
                )
                VStack(spacing: 2) {
                    ForEach(WetterRoom.allCases) { mode in
                        wetterRoomButton(mode)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var levelerCard: some View {
        dspCard(
            title: "LEVELER",
            subtitle: nil,
            bypass: $channel.voice.levelerBypass,
            flow: flowNumber(.leveler),
            dotOn: !channel.voice.levelerBypass && !channel.dspBypass,
            expands: true
        ) {
            VStack(spacing: 2) {
                gateButton
                HStack(alignment: .center, spacing: 4) {
                    driveKnob
                    limiterKnob
                    HStack(alignment: .bottom, spacing: 3) {
                        LevelerDynMeter(db: channel.levelerBoostDb, maxDb: 24, label: "BST", fromBottom: true, compact: true)
                        LevelerDynMeter(db: channel.levelerGRDb, maxDb: 24, label: "GR", fromBottom: false, compact: true)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var driveKnob: some View {
        HardwareKnob(
            value: Binding(
                get: { channel.voice.levelerDriveDb },
                set: {
                    channel.voice.levelerDriveDb = $0
                    channel.voice.clampLeveler()
                }
            ),
            range: 0...24,
            label: "DRIVE",
            valueText: { String(format: "%+.1f", $0) },
            diameter: knob,
            defaultValue: 0,
            tight: true
        )
        .frame(maxWidth: .infinity)
    }

    private var limiterKnob: some View {
        HardwareKnob(
            value: Binding(
                get: { channel.voice.levelerLimiterDb },
                set: {
                    channel.voice.levelerLimiterDb = $0
                    channel.voice.clampLeveler()
                }
            ),
            range: -24...0,
            label: "LIMITER",
            valueText: { String(format: "%+.1f", $0) },
            diameter: knob,
            defaultValue: 0,
            tight: true
        )
        .frame(maxWidth: .infinity)
    }

    private var gateButton: some View {
        let on = channel.voice.levelerGate
        return Button {
            channel.voice.levelerGate.toggle()
        } label: {
            Text("GATE")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .foregroundStyle(on ? Color.black : APILook.label)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(on ? APILook.accentBlue : Color(white: 0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(on ? APILook.accentBlue : Color(white: 0.35).opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("On: a gentle gate under DRIVE so silence and room noise are not boosted. Default on.")
    }

    private func wetterRoomButton(_ mode: WetterRoom) -> some View {
        let on = channel.voice.wetterRoom == mode
        return Button {
            channel.voice.wetterRoom = mode
        } label: {
            Text(mode.title)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(0.2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .foregroundStyle(on ? Color.black : APILook.label)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(on ? APILook.accentBlue : Color(white: 0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(on ? APILook.accentBlue : Color(white: 0.35).opacity(0.55), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(mode.help)
    }

    /// Fixed card. The number is this channel’s strip order. Cards themselves do not move.
    private func dspCard<Content: View>(
        title: String,
        subtitle: String?,
        bypass: Binding<Bool>,
        flow: Int,
        dotOn: Bool,
        expands: Bool = false,
        fillsBody: Bool = false,
        headerExtra: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let controlsLocked = bypass.wrappedValue || channel.dspBypass
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                BypassToggle(bypass: bypass, compact: true)
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(controlsLocked ? APILook.labelDim : APILook.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let headerExtra {
                    headerExtra
                }
                Spacer(minLength: 2)
                FlowDot(number: flow, on: dotOn)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(APILook.labelDim)
                    .lineLimit(1)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: fillsBody ? .infinity : nil, alignment: .topLeading)
                .opacity(controlsLocked ? 0.4 : 1)
                .allowsHitTesting(!controlsLocked)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: expands ? .infinity : nil, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(bypass.wrappedValue ? Color(white: 0.07) : APILook.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(APILook.border, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(bypass.wrappedValue ? 0.22 : 0))
                .allowsHitTesting(false)
        )
    }
}

private struct FlowDot: View {
    var number: Int
    var on: Bool

    var body: some View {
        Text("\(number)")
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .foregroundStyle(Color(white: 0.04))
            .frame(width: 12, height: 12)
            .background(
                Circle().fill(on ? Color(red: 0.22, green: 0.89, blue: 0.48) : Color(white: 0.42))
            )
            .help("Signal-flow step on this channel’s strip. Drag the strip chips to change the order.")
    }
}

/// Red while any post-gain, pre-DSP sample is at 0 dBFS, then for about 2 seconds.
private struct InputClipLamp: View {
    var isClipping: () -> Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let on = isClipping()
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(on ? APILook.ledRed : Color(red: 0.32, green: 0.06, blue: 0.05))
                    .frame(width: 18, height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(Color.white.opacity(on ? 0.5 : 0.14), lineWidth: 0.8)
                    )
                    .shadow(color: on ? APILook.ledRed.opacity(0.95) : .clear, radius: on ? 5 : 0)
                Text("CLIP")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(on ? APILook.ledRed : APILook.labelDim)
            }
        }
        .help("Lights when the signal after input gain reaches 0 dBFS, before any DSP. Holds about 2 seconds, then clears.")
    }
}

private struct LevelerDynMeter: View {
    var db: Float
    var maxDb: Float
    var label: String
    /// BOOST fills from the bottom. GR fills from the top.
    var fromBottom: Bool
    /// Short bar beside the leveler knobs. Hides the numeric readout so the row fits.
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(APILook.labelDim)
            GeometryReader { geo in
                let fill = CGFloat(min(1, max(0, db / max(0.001, maxDb))))
                ZStack(alignment: fromBottom ? .bottom : .top) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.55))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fromBottom ? APILook.ledGreen : APILook.ledYellow)
                        .frame(height: max(1, geo.size.height * fill))
                }
            }
            .frame(width: compact ? 7 : 10, height: compact ? 22 : 28)
            if !compact {
                Text(String(format: fromBottom ? "%+.1f" : "%.1f", max(0, db)))
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(db > 0.15 ? APILook.accentBlue : APILook.labelDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .help(fromBottom ? "Leveler upward boost" : "Leveler downward gain reduction")
    }
}

struct DeEsserView: View {
    @Binding var deess: ChannelDeEsser
    var grDb: Float
    var knob: CGFloat = 24

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
        HStack(alignment: .center, spacing: 4) {
            HardwareKnob(
                value: logFreq,
                range: log2(ChannelDeEsser.minHz)...log2(ChannelDeEsser.maxHz),
                label: "FREQ",
                valueText: { Self.freqLabel(hz: exp2($0)) },
                diameter: knob,
                defaultValue: log2(Float(6_000)),
                dragSensitivity: 0.32,
                tight: true
            )
            HardwareKnob(
                value: Binding(
                    get: { deess.thresholdDb },
                    set: {
                        deess.thresholdDb = $0
                        deess.clamp()
                    }
                ),
                range: ChannelDeEsser.minThresholdDb...ChannelDeEsser.maxThresholdDb,
                label: "THRESH",
                valueText: { String(format: "%+.0f", $0) },
                diameter: knob,
                defaultValue: -24,
                dragSensitivity: 0.45,
                tight: true
            )
            VStack(spacing: 2) {
                ForEach(ParaEQWidth.allCases) { mode in
                    widthButton(mode)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .help(widthHelp)
    }

    private var widthHelp: String {
        switch deess.width {
        case .notch: return "Narrow split · surgical. LISTEN solos this band."
        case .narrow: return "Split leaning · voice ess. LISTEN solos this band."
        case .wide: return "Wideband leaning · broader. LISTEN solos this band."
        }
    }

    private func widthButton(_ mode: ParaEQWidth) -> some View {
        let on = deess.width == mode
        return Button {
            deess.width = mode
        } label: {
            Text(mode.title)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .foregroundStyle(on ? Color.black : APILook.label)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(on ? APILook.accentBlue : Color(white: 0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(on ? APILook.accentBlue : Color(white: 0.35).opacity(0.5), lineWidth: 1)
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
    var knob: CGFloat = 24
    /// The panel hides the oct/Q line so the card matches the spacing mockup.
    var showsCaption: Bool = true

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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("vs GRAPHIC")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(APILook.labelDim)
                ForEach(ParaEQPlacement.allCases) { mode in
                    placementButton(mode)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 4) {
                HardwareKnob(
                    value: logFreq,
                    range: log2(ChannelParaEQ.minHz)...log2(ChannelParaEQ.maxHz),
                    label: "FREQ",
                    valueText: { Self.freqLabel(hz: exp2($0)) },
                    diameter: knob,
                    defaultValue: log2(Float(1_000)),
                    dragSensitivity: 0.32,
                    tight: true
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
                    valueText: { abs($0) < 0.05 ? "0.0" : String(format: "%+.1f", $0) },
                    diameter: knob,
                    defaultValue: 0,
                    dragSensitivity: 0.45,
                    tight: true
                )
                VStack(spacing: 2) {
                    ForEach(ParaEQWidth.allCases) { mode in
                        widthButton(mode)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if showsCaption {
                Text(widthCaption)
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(APILook.accentBlue)
                    .lineLimit(1)
            }
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
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(0.3)
                .foregroundStyle(on ? APILook.charcoal : APILook.label)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
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
            Text(mode.title)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .foregroundStyle(on ? Color.black : APILook.label)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(on ? APILook.accentBlue : Color(white: 0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(on ? APILook.accentBlue : Color(white: 0.35).opacity(0.5), lineWidth: 1)
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
