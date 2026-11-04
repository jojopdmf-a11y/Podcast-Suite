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

    /// RTA and EQ 2520 split whatever is left above the fixed rows, equally.
    /// Para EQ / De-ess and the bottom row keep these heights at every window size.
    /// The window minimum is the strip bay from job 6; this column’s own floor stays 600.
    enum Layout {
        static let gap: CGFloat = 5
        static let sideInset: CGFloat = 4
        /// Para EQ and De-ess. Fixed. Holds the larger knobs and the De-ess GR meter.
        static let midRowH: CGFloat = 136
        /// De-verb, Ambience, and Leveler. Fixed.
        static let bottomRowH: CGFloat = 150
        /// De-verb : Ambience : Leveler. Leveler takes the rest.
        static let deVerbShare: CGFloat = 82
        static let ambienceShare: CGFloat = 96
        static let levelerShare: CGFloat = 110

        /// Height each of RTA and EQ 2520 gets inside the card column.
        /// They are always equal. A short column shares what is left; it does not
        /// push the window up.
        static func equalShare(columnHeight: CGFloat, voice: Bool) -> CGFloat {
            let fixed = voice ? midRowH + bottomRowH : 0
            let gaps = gap * CGFloat(voice ? 3 : 1)
            let available = max(0, columnHeight - fixed - gaps)
            return available / 2
        }
    }

    /// Does not set the window minimum. The strip bay does (job 6).
    static let minimumHeight: CGFloat = 600

    private var canRename: Bool { !channel.isStereo }

    /// Header INPUT GAIN. Unchanged from the approved header.
    private let headerKnob: CGFloat = 24
    /// One face size for every rotary inside the cards. Header INPUT GAIN stays on HardwareKnob.
    private let cardKnob: CGFloat = 34

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
                diameter: headerKnob,
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

    /// RTA and EQ 2520 are the same height and share everything above the fixed rows.
    private var cardColumn: some View {
        GeometryReader { geo in
            let gap = Layout.gap
            let voice = !channel.isStereo
            let inner = geo.size.width
            let share = Layout.equalShare(columnHeight: geo.size.height, voice: voice)
            let shares = Layout.deVerbShare + Layout.ambienceShare + Layout.levelerShare
            let deVerbW = (inner - gap * 2) * Layout.deVerbShare / shares
            let ambienceW = (inner - gap * 2) * Layout.ambienceShare / shares
            VStack(alignment: .leading, spacing: gap) {
                RTAView(bins: rtaBins, apiStyle: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .frame(height: share)
                eqCard
                    .frame(height: share, alignment: .top)
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
            expands: true,
            fillsBody: true
        ) {
            HStack(alignment: .center, spacing: 4) {
                API560EQView(eq: $channel.eq)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                hpfKnob
                    .frame(width: 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hpfKnob: some View {
        DSPPanelKnob(
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
            diameter: cardKnob,
            defaultValue: 0,
            dragSensitivity: 0.35
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
            ParaEQView(para: $channel.para, knob: cardKnob, showsCaption: false)
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
            DeEsserView(deess: $channel.deess, grDb: channel.deessGRDb, knob: cardKnob)
        }
    }

    private var listenButton: some View {
        Button {
            channel.deessListen.toggle()
        } label: {
            DSPBevelPillLabel(
                title: "LISTEN",
                lit: channel.deessListen,
                kind: channel.deessListen ? .gold : .off,
                fontSize: 8,
                horizontal: 7,
                vertical: 2
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
            expands: true,
            fillsBody: true
        ) {
            DSPPanelKnob(
                value: $channel.voice.deVerb,
                range: 0...1,
                label: "AMOUNT",
                valueText: { String(format: "%.0f%%", $0 * 100) },
                diameter: cardKnob,
                defaultValue: 0
            )
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
            expands: true,
            fillsBody: true
        ) {
            HStack(alignment: .center, spacing: 6) {
                DSPPanelKnob(
                    value: $channel.voice.wetter,
                    range: 0...1,
                    label: "AMOUNT",
                    valueText: { String(format: "%.0f%%", $0 * 100) },
                    diameter: cardKnob,
                    defaultValue: 0
                )
                DSPSegmentedSelector(
                    options: Array(WetterRoom.allCases),
                    title: { $0.title },
                    isSelected: { channel.voice.wetterRoom == $0 },
                    help: { $0.help },
                    select: { channel.voice.wetterRoom = $0 }
                )
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
            expands: true,
            fillsBody: true
        ) {
            VStack(spacing: 4) {
                gateButton
                HStack(alignment: .center, spacing: 4) {
                    driveKnob
                    limiterKnob
                    HStack(alignment: .bottom, spacing: 4) {
                        LevelerDynMeter(db: channel.levelerBoostDb, maxDb: 24, label: "BST", fromBottom: true)
                        LevelerDynMeter(db: channel.levelerGRDb, maxDb: 24, label: "GR", fromBottom: false)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var driveKnob: some View {
        DSPPanelKnob(
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
            diameter: cardKnob,
            defaultValue: 0
        )
        .frame(maxWidth: .infinity)
    }

    private var limiterKnob: some View {
        DSPPanelKnob(
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
            diameter: cardKnob,
            defaultValue: 0
        )
        .frame(maxWidth: .infinity)
    }

    private var gateButton: some View {
        let on = channel.voice.levelerGate
        return Button {
            channel.voice.levelerGate.toggle()
        } label: {
            DSPBevelPillLabel(
                title: "GATE",
                lit: on,
                kind: on ? .blue : .off,
                fontSize: 9,
                vertical: 3,
                expands: true
            )
        }
        .buttonStyle(.plain)
        .help("On: a gentle gate under DRIVE so silence and room noise are not boosted. Default on.")
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
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                CardBypassPill(bypass: bypass)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
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
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(APILook.labelDim)
                    .lineLimit(1)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: fillsBody ? .infinity : nil, alignment: .topLeading)
                .opacity(controlsLocked ? 0.4 : 1)
                .allowsHitTesting(!controlsLocked)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: expands ? .infinity : nil, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: bypass.wrappedValue
                            ? [Color(white: 0.09), Color(white: 0.055)]
                            : [
                                Color(red: 0.15, green: 0.16, blue: 0.185),
                                Color(red: 0.09, green: 0.10, blue: 0.115)
                            ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color.black.opacity(0.38), radius: 2.5, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(APILook.border, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(bypass.wrappedValue ? 0.06 : 0.28))
                .frame(height: 1)
                .padding(.horizontal, 7)
                .padding(.top, 1)
                .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(bypass.wrappedValue ? 0.22 : 0))
                .allowsHitTesting(false)
        )
    }
}

/// Card ON/BYP. Smaller bevelled capsule. Strips and DSP ALL keep `BypassToggle`.
private struct CardBypassPill: View {
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
                fixedSize: CGSize(width: 32, height: 17)
            )
        }
        .buttonStyle(.plain)
        .help(bypass ? "Bypassed — click to engage" : "Engaged — click to bypass")
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

    var body: some View {
        VStack(spacing: 2) {
            DSPLEDSlot(
                fraction: CGFloat(min(1, max(0, db / max(0.001, maxDb)))),
                color: fromBottom ? APILook.ledGreen : APILook.ledYellow,
                fromBottom: fromBottom
            )
            .frame(width: 21)
            .frame(maxHeight: .infinity)
            Text(String(format: fromBottom ? "%+.1f" : "%.1f", max(0, db)))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(db > 0.15 ? APILook.accentBlue : APILook.labelDim)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(APILook.labelDim)
        }
        .frame(width: 28)
        .frame(maxHeight: .infinity)
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
            DSPPanelKnob(
                value: logFreq,
                range: log2(ChannelDeEsser.minHz)...log2(ChannelDeEsser.maxHz),
                label: "FREQ",
                valueText: { Self.freqLabel(hz: exp2($0)) },
                diameter: knob,
                defaultValue: log2(Float(6_000)),
                dragSensitivity: 0.32
            )
            DSPPanelKnob(
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
                dragSensitivity: 0.45
            )
            DeEssGRMeter(grDb: grDb)
            DSPSegmentedSelector(
                options: Array(ParaEQWidth.allCases),
                title: { $0.title },
                isSelected: { deess.width == $0 },
                help: { _ in "Detection / reduction bandwidth — carries split vs wideband" },
                select: { deess.width = $0 }
            )
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

    private static func freqLabel(hz: Float) -> String {
        if hz >= 1000 {
            return String(format: hz >= 10_000 ? "%.1fk" : "%.2fk", hz / 1000)
        }
        return String(format: "%.0f Hz", hz)
    }
}

/// Vertical De-ess gain-reduction bar beside THRESH. Display is 0…12 dB. Yellow while reduction is happening.
private struct DeEssGRMeter: View {
    var grDb: Float
    private let maxDisplay: Float = 12

    var body: some View {
        let active = grDb > 0.15
        VStack(spacing: 2) {
            DSPLEDSlot(
                fraction: CGFloat(min(1, max(0, grDb / maxDisplay))),
                color: active ? APILook.ledYellow : Color(white: 0.34),
                fromBottom: false
            )
            .frame(width: 12, height: 52)
            Text(String(format: "%.1f", max(0, grDb)))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? APILook.ledYellow : APILook.labelDim)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("GR")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(APILook.labelDim)
        }
        .frame(width: 30)
        .help("De-ess gain reduction, 0–12 dB")
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("vs GRAPHIC")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(APILook.labelDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                ForEach(ParaEQPlacement.allCases) { mode in
                    placementButton(mode)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 4) {
                DSPPanelKnob(
                    value: logFreq,
                    range: log2(ChannelParaEQ.minHz)...log2(ChannelParaEQ.maxHz),
                    label: "FREQ",
                    valueText: { Self.freqLabel(hz: exp2($0)) },
                    diameter: knob,
                    defaultValue: log2(Float(1_000)),
                    dragSensitivity: 0.32
                )
                DSPPanelKnob(
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
                    bipolar: true
                )
                DSPSegmentedSelector(
                    options: Array(ParaEQWidth.allCases),
                    title: { $0.title },
                    isSelected: { para.width == $0 },
                    help: { _ in "How quickly the band narrows as you boost or cut" },
                    select: { para.width = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            if showsCaption {
                Text(widthCaption)
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(APILook.accentBlue)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            DSPBevelPillLabel(
                title: mode.title,
                lit: on,
                kind: on ? .blue : .off,
                fontSize: 8,
                horizontal: 7,
                vertical: 2
            )
        }
        .buttonStyle(.plain)
        .help(mode.help)
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

// MARK: - DSP panel chrome
// Used only by the selected-channel cards. Master and strip controls keep HardwareKnob / BypassToggle.

private enum DSPPanelStyle {
    static let cyan = Color(red: 0.28, green: 0.86, blue: 0.94)
    static let label = Color(white: 0.76)
}

/// One machined rotary for the DSP cards. Drag, fine-drag, and double-click match `HardwareKnob`.
private struct DSPPanelKnob: View {
    @Binding var value: Float
    var range: ClosedRange<Float>
    var label: String
    var valueText: (Float) -> String
    var diameter: CGFloat = 34
    var stops: [Float]? = nil
    var defaultValue: Float = 0
    var dragSensitivity: Float = 1
    /// Arc grows from the centre of the travel. GAIN uses this. Other knobs grow from the minimum.
    var bipolar: Bool = false

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
        let column = diameter + 8
        VStack(spacing: 2) {
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
        .help("Double-click to reset · Option-drag for fine")
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

private enum DSPBevelKind {
    case off, blue, green, red, gold

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
        }
    }

    var bottom: Color {
        switch self {
        case .off: return Color(white: 0.12)
        case .blue: return Color(red: 0.24, green: 0.44, blue: 0.73)
        case .green: return Color(red: 0.29, green: 0.66, blue: 0.42)
        case .red: return Color(red: 0.72, green: 0.16, blue: 0.20)
        case .gold: return Color(red: 0.72, green: 0.52, blue: 0.12)
        }
    }

    var glow: Color {
        switch self {
        case .off: return .clear
        case .blue: return Color(red: 0.35, green: 0.60, blue: 0.92)
        case .green: return Color(red: 0.30, green: 0.85, blue: 0.50)
        case .red: return MixerTheme.danger
        case .gold: return Color(red: 0.88, green: 0.70, blue: 0.23)
        }
    }
}

/// Smaller bevelled pill. Lit fills carry a top highlight. Off stays a dark recess.
private struct DSPBevelPillLabel: View {
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
            .contentShape(Capsule())
    }
}

/// NOTCH / NARROW / WIDE and DRUM / STUDIO / STAGE. About 60% of the row, centred.
private struct DSPSegmentedSelector<ID: Hashable>: View {
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
private struct DSPLEDSlot: View {
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
