import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var session = MixerSession()
    @State private var isDropTargeted = false
    @State private var spaceMonitor: Any?
    @State private var showAbout = false

    var body: some View {
        ZStack {
            MixerTheme.windowBackground.ignoresSafeArea()
            RadialGradient(
                colors: [MixerTheme.cyan.opacity(0.06), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 500
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                header
                if session.frameCount == 0 {
                    dropZone
                } else {
                    TimelineWaveformView(
                        peaks: session.waveformPeaks,
                        playhead: session.playheadNormalized,
                        channelName: session.selectedChannelName,
                        currentTime: formatTime(session.playheadFrame),
                        duration: formatTime(session.frameCount),
                        onSeek: { session.seekNormalized($0) }
                    )
                    .id(session.sourceFolder?.path ?? "empty")
                    mixerRow
                    transport
                }
                statusBar
            }
            .padding(18)
        }
        .frame(minWidth: mixerMinWidth, idealWidth: mixerMinWidth, minHeight: session.frameCount == 0 ? 620 : 760)
        .preferredColorScheme(.dark)
        .onAppear {
            session.bindEngine()
            installSpacebarMonitor()
        }
        .onDisappear {
            session.engine.stop()
            removeSpacebarMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cougarCalcShowAbout)) { _ in
            showAbout = true
        }
        .sheet(isPresented: $showAbout) {
            AboutSupportPanel(
                appName: "Fixer Mixer",
                tagline: "Polish Stripper stems · bounce mix + stems",
                accent: MixerTheme.cyan
            )
        }
    }

    private func installSpacebarMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak session] event in
            // Space = play/pause (keyCode 49). Only skip while actively editing text.
            guard event.keyCode == 49 else { return event }
            if Self.isActivelyEditingText() { return event }
            guard let session, session.frameCount > 0, !session.isBouncing else { return event }
            session.togglePlay()
            return nil
        }
    }

    private func removeSpacebarMonitor() {
        if let spaceMonitor {
            NSEvent.removeMonitor(spaceMonitor)
            self.spaceMonitor = nil
        }
    }

    /// True only while a text field / field editor is accepting typing (not merely first responder residue).
    private static func isActivelyEditingText() -> Bool {
        guard let fr = NSApp.keyWindow?.firstResponder else { return false }
        if let tf = fr as? NSTextField {
            return tf.currentEditor() != nil
        }
        if let tv = fr as? NSTextView {
            return tv.isEditable && tv.isFieldEditor
        }
        return false
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("FIXER MIXER")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(MixerTheme.cyan)
                    .shadow(color: MixerTheme.cyan.opacity(0.4), radius: 10)
                Text("Stripper stems → polish → bounce")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(MixerTheme.textSecondary)
                Text(CougarCalcBrand.versionLabel)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.lime)
            }
            Spacer()
            Button("ABOUT") { showAbout = true }
                .buttonStyle(MixerGhostButtonStyle())
            if session.frameCount > 0 {
                Button("LOAD OTHER FOLDER…") { pickFolder() }
                    .buttonStyle(MixerGhostButtonStyle())
            }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MixerTheme.panel)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isDropTargeted ? MixerTheme.lime : MixerTheme.cyan.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1.4, dash: [7, 6])
                )
                .shadow(color: MixerTheme.cyan.opacity(0.35), radius: 8)
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack.badge.play")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(MixerTheme.cyan)
                Text("DROP STRIPPER _SPEAKERS FOLDER")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(MixerTheme.textPrimary)
                Text("Builds strips for whatever Speaker_*.wav (+ music) is in the folder")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MixerTheme.textSecondary)
                Button("CHOOSE FOLDER…") { pickFolder() }
                    .buttonStyle(MixerPrimaryButtonStyle())
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .onTapGesture { pickFolder() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var mixerRow: some View {
        let cluster = mixerClusterWidth
        return GeometryReader { geo in
            let selectedW: CGFloat = 460
            let gap: CGFloat = 10
            let available = max(156, geo.size.width - selectedW - gap)
            HStack(alignment: .top, spacing: gap) {
                ScrollView(.horizontal, showsIndicators: cluster > available + 1) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(session.voices.indices), id: \.self) { index in
                            ChannelStripView(
                                channel: $session.voices[index],
                                faderDb: session.voiceFaderBinding(at: index),
                                autoDriven: session.autoBalanceEnabled,
                                isSelected: session.selectedChannelID == session.voices[index].id,
                                onSelect: { session.selectChannel(session.voices[index].id) },
                                onChange: { session.syncParamsToEngine() }
                            )
                        }
                        if session.hasMusic {
                            ChannelStripView(
                                channel: $session.music,
                                faderDb: $session.music.faderDb,
                                autoDriven: false,
                                isSelected: session.selectedChannelID == session.music.id,
                                onSelect: { session.selectChannel(session.music.id) },
                                onChange: { session.syncParamsToEngine() }
                            )
                        }
                        masterStrip
                    }
                    .padding(.vertical, 4)
                }
                .frame(width: min(cluster, available), alignment: .leading)
                Spacer(minLength: 0)
                selectedChannelPane
            }
        }
        .frame(height: ChannelStripView.stripHeight + 8)
    }

    /// Speaker + music strips are 156pt; master is 110pt.
    private var mixerClusterWidth: CGFloat {
        let channels = session.voices.count + (session.hasMusic ? 1 : 0)
        let gaps = CGFloat(max(0, channels)) * 10 // between channels, and before master
        return CGFloat(channels) * 156 + 110 + gaps
    }

    private var mixerMinWidth: CGFloat {
        if session.frameCount == 0 { return 720 }
        // padding 18×2 + selected pane 460 + gap 10
        return mixerClusterWidth + 460 + 10 + 36
    }

    @ViewBuilder
    private var selectedChannelPane: some View {
        if session.selectedChannelID == ChannelStripState.masterID {
            MasterCompressorPanel(
                state: $session.masterComp,
                rtaBins: session.rtaBins,
                inL: session.masterCompInL,
                inR: session.masterCompInR,
                outL: session.masterCompOutL,
                outR: session.masterCompOutR,
                grDb: session.masterCompGRDb,
                onChange: { session.syncParamsToEngine() }
            )
        } else if session.selectedChannelID == ChannelStripState.musicID {
            SelectedChannelPanel(
                channel: $session.music,
                rtaBins: session.rtaBins,
                onChange: { session.syncParamsToEngine() }
            )
        } else if let idx = session.voices.firstIndex(where: { $0.id == session.selectedChannelID }) {
            SelectedChannelPanel(
                channel: $session.voices[idx],
                rtaBins: session.rtaBins,
                onChange: { session.syncParamsToEngine() }
            )
        } else {
            VStack(spacing: 8) {
                Text("SELECTED CHANNEL")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.cyanDim)
                Text("Select a strip")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.textSecondary)
                Spacer()
            }
            .padding(12)
            .frame(width: 460, height: ChannelStripView.stripHeight, alignment: .top)
            .mixerPanel()
        }
    }

    private var masterStrip: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                Text("MASTER")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.lime : MixerTheme.lime.opacity(0.85))
                Spacer(minLength: 0)
                Button {
                    session.selectChannel(ChannelStripState.masterID)
                } label: {
                    Text(session.selectedChannelID == ChannelStripState.masterID ? "SEL●" : "SEL")
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .tracking(0.3)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .foregroundStyle(session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.bgBottom : MixerTheme.cyan)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.lime : MixerTheme.panelRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.lime : MixerTheme.cyan.opacity(0.45), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                BypassToggle(bypass: $session.masterComp.bypass)
                Button {
                    session.selectChannel(ChannelStripState.masterID)
                } label: {
                    Text("COMP")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.4)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(session.masterComp.bypass ? MixerTheme.textSecondary : (session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.bgBottom : MixerTheme.cyan))
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(!session.masterComp.bypass && session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.lime : MixerTheme.panelRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(MixerTheme.cyan.opacity(0.45), lineWidth: 1)
                        )
                        .opacity(session.masterComp.bypass ? 0.55 : 1)
                }
                .buttonStyle(.plain)
            }
            .onChange(of: session.masterComp.bypass) { _, _ in
                session.syncParamsToEngine()
            }

            Button {
                session.setAutoBalanceEnabled(!session.autoBalanceEnabled)
            } label: {
                VStack(spacing: 2) {
                    Text("AUTO")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                    Text(session.autoBalanceEnabled ? "ON" : "OFF")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(session.autoBalanceEnabled ? MixerTheme.bgBottom : MixerTheme.cyan)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(session.autoBalanceEnabled ? MixerTheme.meterGreen : MixerTheme.panelRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(MixerTheme.cyan.opacity(0.45), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Auto Balance rides speaker faders. Drag a fader to favor that speaker.")

            if session.autoBalanceEnabled {
                VStack(spacing: 2) {
                    Text("TARGET")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(MixerTheme.cyanDim)
                    Text(String(format: "%.0f dB", session.autoBalanceTargetDb))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(MixerTheme.lime)
                    Slider(value: Binding(
                        get: { Double(session.autoBalanceTargetDb) },
                        set: {
                            session.autoBalanceTargetDb = Float($0)
                            session.syncParamsToEngine()
                        }
                    ), in: -30...(-6))
                    .tint(MixerTheme.cyan)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                LevelMeter(level: session.masterPeakL, label: "L")
                LevelMeter(level: session.masterPeakR, label: "R")
            }
            .frame(height: 140)
            VerticalFader(
                valueDb: Binding(
                    get: { session.masterDb },
                    set: {
                        session.masterDb = $0
                        session.syncParamsToEngine()
                    }
                ),
                defaultValue: 0,
                range: -24...12,
                caption: "OUT"
            )
        }
        .padding(10)
        .frame(width: 110, height: ChannelStripView.stripHeight, alignment: .top)
        .mixerPanel(glow: true)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.lime : .clear, lineWidth: 2)
        )
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button("BACK TO TOP") {
                session.restartPlay()
            }
            .buttonStyle(MixerGhostButtonStyle())
            .help("Jump to the start of the timeline")

            Button(session.isPlaying ? "PAUSE" : "PLAY") {
                session.togglePlay()
            }
            .buttonStyle(MixerPrimaryButtonStyle())
            .keyboardShortcut(.space, modifiers: [])
            .help("Spacebar toggles play/pause")

            Text("SEL / DSP chip opens the selected-channel panel · scrub waveform to seek")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(MixerTheme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(session.isBouncing ? "BOUNCING…" : "BOUNCE STEMS + MIX") {
                session.bounce()
            }
            .buttonStyle(MixerGhostButtonStyle())
            .disabled(session.isBouncing || session.frameCount == 0)
            .help("Export post-DSP stems + stereo mix")
        }
        .padding(12)
        .mixerPanel()
    }

    private var statusBar: some View {
        Text(session.status)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(MixerTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func formatTime(_ frames: Int) -> String {
        guard session.sampleRate > 0 else { return "0:00" }
        let sec = Double(frames) / session.sampleRate
        return String(format: "%d:%02d", Int(sec) / 60, Int(sec) % 60)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            session.loadStripperFolder(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url else { return }
            DispatchQueue.main.async {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    session.loadStripperFolder(url)
                } else {
                    session.loadStripperFolder(url.deletingLastPathComponent())
                }
            }
        }
        return true
    }
}
