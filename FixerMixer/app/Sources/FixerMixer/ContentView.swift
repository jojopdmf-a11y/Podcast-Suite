import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var session = MixerSession()
    @State private var isDropTargeted = false
    @State private var spaceMonitor: Any?
    @State private var showAbout = false
    @State private var showExport = false
    @State private var exportItems: [MixerExportItem] = []
    @State private var exportFolder: URL?
    @State private var exportSampleRate: MixerBounceRate = .native
    @State private var exportFormat: MixerBounceFormat = .wav16
    @State private var showAllWaveforms = false
    @State private var reorderStrips = false
    @State private var reorderDropID: Int?
    @State private var confirmRemoveStrip = false

    /// Half/half seam control between adjacent mono strips (no gutter).
    private static let monoLinkSeamWidth: CGFloat = 26

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
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        if session.hasSession {
                            if showAllWaveforms {
                                OverviewWaveformView(
                                    lanes: session.waveformLanes,
                                    playhead: session.playheadNormalized,
                                    currentTime: formatTime(session.playheadFrame),
                                    duration: formatTime(session.frameCount),
                                    onSeek: { session.seekNormalized($0) },
                                    onFocusLane: { focusChannel($0) },
                                    onShowOne: { showAllWaveforms = false }
                                )
                            } else {
                                TimelineWaveformView(
                                    peaks: session.waveformPeaks,
                                    playhead: session.playheadNormalized,
                                    channelName: session.selectedChannelName,
                                    currentTime: formatTime(session.playheadFrame),
                                    duration: formatTime(session.frameCount),
                                    muteSpans: session.selectedMuteSpansNormalized,
                                    onSeek: { session.seekNormalized($0) },
                                    onPaintMute: { session.paintMute(normalizedFrom: $0, to: $1) },
                                    onClearMute: { session.clearMute(normalizedFrom: $0, to: $1) },
                                    onShowAllTracks: { showAllWaveforms = true }
                                )
                                .id(session.sourceFolder?.path ?? "empty")
                            }
                            mixerRow
                            transport
                        } else {
                            dropZone
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                statusBar
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        // Fixed min size so extra strips / ALL TRACKS never shove Mixer off the screen.
        .frame(minWidth: 960, idealWidth: 1100, maxWidth: .infinity, minHeight: 640, idealHeight: 820, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .onAppear {
            session.bindEngine()
            installSpacebarMonitor()
        }
        .onChange(of: session.hasSession) { _, open in
            if open {
                session.refreshInputDevices()
            }
        }
        .onChange(of: session.selectedInputUID) { _, _ in
            session.adoptInterfaceSampleRateIfEmpty()
        }
        .onDisappear {
            session.engine.stop()
            removeSpacebarMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cougarCalcShowAbout)) { _ in
            showAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .fixerMixerUpdateMix)) { _ in
            session.updateMix()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fixerMixerSaveMix)) { _ in
            session.saveMix()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fixerMixerLoadMix)) { _ in
            pickMixFile()
        }
        .sheet(isPresented: $showAbout) {
            AboutSupportPanel(
                appName: "PodProducer",
                tagline: "Record a strip, punch a cough, mix — still not an editor",
                accent: MixerTheme.cyan
            )
        }
        .sheet(isPresented: $showExport) {
            MixerExportSheet(
                items: $exportItems,
                folder: $exportFolder,
                nativeSampleRate: session.sampleRate,
                sampleRate: $exportSampleRate,
                format: $exportFormat,
                onCancel: { showExport = false },
                onExport: {
                    showExport = false
                    if let exportFolder {
                        session.bounce(
                            items: exportItems,
                            folder: exportFolder,
                            sampleRate: exportSampleRate,
                            format: exportFormat
                        )
                    }
                }
            )
        }
    }

    private func installSpacebarMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak session] event in
            // Space = play/pause (keyCode 49). Only skip while actively editing text.
            guard event.keyCode == 49 else { return event }
            if Self.isActivelyEditingText() { return event }
            guard let session, !session.isBouncing else { return event }
            if session.isRecording || session.frameCount > 0 {
                session.togglePlay()
                return nil
            }
            return event
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PODPRODUCER")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(MixerTheme.cyan)
                    .shadow(color: MixerTheme.cyan.opacity(0.4), radius: 10)
                Text("Stripper stems, any audio, or Record from your interface")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(MixerTheme.textSecondary)
                Text(CougarCalcBrand.versionLabel)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.lime)
            }
            Spacer(minLength: 8)
            headerGroup(label: "META") {
                Button("ABOUT") { showAbout = true }
                    .buttonStyle(MixerGhostButtonStyle())
            }
            headerGroup(label: "SESSION") {
                Button("LOAD MIX…") { pickMixFile() }
                    .buttonStyle(MixerGhostButtonStyle())
                    .help("Open a saved mix JSON (loads its _speakers folder when the file lives there)")
            }
            if session.hasSession {
                headerGroup(label: "INPUT + RECORD", accent: MixerTheme.danger.opacity(0.85)) {
                    inputDevicePicker
                    Button("STANDBY") {
                        session.toggleRecordStandby()
                    }
                    .buttonStyle(MixerStandbyButtonStyle(engaged: session.isRecordStandby))
                    .disabled(session.isBouncing || session.isRecording)
                    .help("Live input meters on armed strips — does not write takes. Record starts tape. Monitor mics on your interface.")
                    if session.isRecording {
                        Button("STOP REC") { session.toggleRecord() }
                            .buttonStyle(MixerRecordButtonStyle())
                            .disabled(session.isBouncing)
                            .help("Stop recording. PodProducer writes WAV takes into the session folder on the Desktop.")
                    } else {
                        Button("RECORD") { session.toggleRecord() }
                            .buttonStyle(MixerGhostButtonStyle())
                            .disabled(session.isBouncing)
                            .help("Records every speaker strip that has an IN. Overwrites from the playhead. Monitor mics on your interface — PodProducer does not play the mic back. Standby is optional.")
                    }
                }
                headerGroup(label: "STRIPS") {
                    Button("ADD STRIP") { session.addBlankStrip() }
                        .buttonStyle(MixerGhostButtonStyle())
                        .help("Adds an empty speaker strip (up to 8). Pick IN on it to record. REMOVE if you do not need it.")
                    Button("REMOVE STRIP") { confirmRemoveStrip = true }
                        .buttonStyle(MixerGhostButtonStyle())
                        .disabled(session.isRecording || session.isBouncing || !session.canRemoveStrip(session.selectedChannelID))
                        .help("Removes the selected speaker strip when it is empty (ADD STRIP with no recording).")
                        .confirmationDialog(
                            "Remove this empty strip?",
                            isPresented: $confirmRemoveStrip,
                            titleVisibility: .visible
                        ) {
                            Button("Remove Strip", role: .destructive) {
                                session.removeEmptyStrip(session.selectedChannelID)
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Only empty speaker strips can be removed. This cannot be undone.")
                        }
                    if reorderStrips {
                        Button("REORDER") { reorderStrips = false }
                            .buttonStyle(MixerPrimaryButtonStyle())
                            .disabled(session.isRecording)
                            .help("Reorder is on. Drag a lime DRAG TO REORDER handle onto another strip. Click again when you are done.")
                    } else {
                        Button("REORDER") { reorderStrips = true }
                            .buttonStyle(MixerGhostButtonStyle())
                            .disabled(session.isRecording)
                            .help("Turn on, then drag a strip onto another strip — same idea as dragging DSP chips.")
                    }
                }
                headerGroup(label: "MIX") {
                    Button("UPDATE MIX") { session.updateMix() }
                        .buttonStyle(MixerGhostButtonStyle())
                        .help(session.lastMixURL.map { "Overwrite \($0.lastPathComponent)" } ?? "Writes FixerMixer.mix.json in this folder")
                    Button("SAVE MIX…") { session.saveMix() }
                        .buttonStyle(MixerGhostButtonStyle())
                        .help("Choose a folder and name for this mix. Audio stays in the WAV files. Mute paints are saved here.")
                }
                headerGroup(label: "IMPORT") {
                    Button("LOAD OTHER FOLDER…") { pickFolder() }
                        .buttonStyle(MixerGhostButtonStyle())
                    Button("ADD TRACKS…") { pickFiles(append: true) }
                        .buttonStyle(MixerGhostButtonStyle())
                        .help("Drop or choose more audio files. Mono → speaker (up to 8); stereo → bed (up to 2).")
                }
            }
        }
    }

    private func headerGroup<Content: View>(
        label: String,
        accent: Color = MixerTheme.lime.opacity(0.85),
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(accent)
            HStack(spacing: 6) {
                content()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MixerTheme.panel.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MixerTheme.cyan.opacity(0.18), lineWidth: 1)
        )
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
                Text("DROP AUDIO OR A STRIPPER FOLDER")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(MixerTheme.textPrimary)
                Text("Any WAV, AIFF, MP3, M4A… becomes a channel — mono files are speakers (up to 8), stereo files are beds (up to 2). A _speakers folder still builds the Stripper layout. Or NEW SESSION for an empty mixer.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MixerTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("NEW SESSION") { session.newRecordSession() }
                    .buttonStyle(MixerPrimaryButtonStyle())
                    .padding(.top, 6)
                    .help("Empty mixer, no channels. ADD STRIP or drop audio. Arm IN, then Record. Monitor through your interface.")
                Button("CHOOSE FOLDER…") { pickFolder() }
                    .buttonStyle(MixerGhostButtonStyle())
                Button("CHOOSE FILES…") { pickFiles(append: false) }
                    .buttonStyle(MixerGhostButtonStyle())
                    .help("Pick one or more audio files. Mono → speaker (up to 8); stereo → bed (up to 2).")
                Button("LOAD MIX…") { pickMixFile() }
                    .buttonStyle(MixerGhostButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var mixerRow: some View {
        let cluster = mixerClusterWidth
        return GeometryReader { geo in
            let selectedW: CGFloat = 460
            let masterW: CGFloat = 110
            let gap: CGFloat = 10
            let available = max(ChannelStripView.stripWidth, geo.size.width - selectedW - masterW - gap * 2)
            HStack(alignment: .top, spacing: gap) {
                ScrollView(.horizontal, showsIndicators: cluster > available + 1) {
                    ZStack(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(session.displayChannelOrder.enumerated()), id: \.element) { index, id in
                                stripView(for: id)
                                // Tiny gap only before a non-linkable neighbor (e.g. stereo bed).
                                if shouldGapAfterStrip(at: index) {
                                    Color.clear.frame(width: 8)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        ForEach(monoLinkSeamIndices, id: \.self) { index in
                            let order = session.displayChannelOrder
                            let leftID = order[index]
                            let rightID = order[index + 1]
                            monoLinkSeamButton(leftID: leftID, rightID: rightID)
                                .offset(
                                    x: linkSeamCenterX(afterStripIndex: index) - Self.monoLinkSeamWidth / 2,
                                    y: 184
                                )
                        }
                    }
                }
                .frame(width: min(cluster, available), alignment: .leading)
                Spacer(minLength: 0)
                selectedChannelPane
                masterStrip
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ChannelStripView.stripHeight + 8)
    }

    /// Speaker + stereo strips only (master is pinned beside SEL). Extra strips scroll sideways.
    private var mixerClusterWidth: CGFloat {
        let order = session.displayChannelOrder
        let channels = order.count
        var softGaps = 0
        for i in 0..<max(0, channels - 1) {
            if shouldGapAfterStrip(at: i) { softGaps += 1 }
        }
        return CGFloat(channels) * ChannelStripView.stripWidth
            + CGFloat(softGaps) * 8
    }

    /// Indices `i` where `order[i]` and `order[i+1]` are both mono speakers (LINK seam).
    private var monoLinkSeamIndices: [Int] {
        let order = session.displayChannelOrder
        var result: [Int] = []
        for i in 0..<max(0, order.count - 1) {
            if monoLinkNeighbor(after: i) != nil {
                result.append(i)
            }
        }
        return result
    }

    /// Soft gap when the next strip is not a linkable mono pair (beds / end of row).
    private func shouldGapAfterStrip(at index: Int) -> Bool {
        let order = session.displayChannelOrder
        guard index + 1 < order.count else { return false }
        return monoLinkNeighbor(after: index) == nil
    }

    /// X center of the seam after strip `index`, accounting for soft gaps before it.
    private func linkSeamCenterX(afterStripIndex index: Int) -> CGFloat {
        var x = ChannelStripView.stripWidth * CGFloat(index + 1)
        for i in 0..<index where shouldGapAfterStrip(at: i) {
            x += 8
        }
        return x
    }

    /// Next display id when both this strip and the following are mono speakers.
    private func monoLinkNeighbor(after index: Int) -> Int? {
        let order = session.displayChannelOrder
        guard index >= 0, index + 1 < order.count else { return nil }
        let a = order[index]
        let b = order[index + 1]
        guard session.voices.contains(where: { $0.id == a }),
              session.voices.contains(where: { $0.id == b }) else { return nil }
        return b
    }

    @ViewBuilder
    private func monoLinkSeamButton(leftID: Int, rightID: Int) -> some View {
        let linked = session.voices.first(where: { $0.id == leftID })?.linkedPeerID == rightID
            && session.voices.first(where: { $0.id == rightID })?.linkedPeerID == leftID
        let leftBusy = session.isMonoLinked(leftID) && !linked
        let rightBusy = session.isMonoLinked(rightID) && !linked
        let canToggle = linked || (!leftBusy && !rightBusy)
        let lit = linked
        let dark = !canToggle

        Button {
            session.toggleMonoLink(between: leftID, and: rightID)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: linked ? "link" : "link.badge.plus")
                    .font(.system(size: 10, weight: .bold))
                Text(linked ? "UNLINK" : "LINK")
                    .font(.system(size: 6, weight: .bold, design: .rounded))
                    .tracking(0.2)
            }
            .foregroundStyle(
                lit ? MixerTheme.bgBottom
                    : (dark ? MixerTheme.cyanDim.opacity(0.35) : MixerTheme.cyan)
            )
            .frame(width: Self.monoLinkSeamWidth, height: 56)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        lit ? MixerTheme.lime
                            : (dark ? Color(white: 0.08) : MixerTheme.panelRaised)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        lit ? MixerTheme.lime
                            : (dark ? Color.white.opacity(0.08) : MixerTheme.cyan.opacity(0.45)),
                        lineWidth: 1
                    )
            )
            .opacity(dark ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!canToggle || session.isRecording)
        .help(
            linked
                ? "Unlink these speakers. DSP + fader stay at the last shared values; mute/solo/pan stay independent."
                : (canToggle
                   ? "Link adjacent monos: shared DSP + fader. Mute, solo, pan, and record IN stay independent."
                   : "One of these strips is already linked to another mono.")
        )
        .zIndex(2)
    }

    @ViewBuilder
    private func stripView(for id: Int) -> some View {
        if let index = session.voices.firstIndex(where: { $0.id == id }) {
            ChannelStripView(
                channel: $session.voices[index],
                faderDb: session.voiceFaderBinding(at: index),
                autoDriven: session.autoBalanceEnabled,
                isSelected: session.selectedChannelID == id,
                hardwareInputChannels: session.selectedInputChannelCount,
                isRecording: session.isRecording,
                canRemove: session.canRemoveStrip(id),
                onSelect: { focusChannel(id) },
                onChange: {
                    session.syncParamsToEngine()
                    session.syncLinkedFrom(id)
                },
                onRemove: { session.removeEmptyStrip(id) },
                stripReorderable: reorderStrips,
                isReorderDropTarget: reorderDropID == id,
                onReorderDrop: { session.moveChannel(fromID: $0, toID: id) },
                onReorderTargeted: { targeted in
                    reorderDropID = targeted ? id : (reorderDropID == id ? nil : reorderDropID)
                }
            )
        } else if let index = session.stereos.firstIndex(where: { $0.id == id }) {
            ChannelStripView(
                channel: $session.stereos[index],
                faderDb: $session.stereos[index].faderDb,
                autoDriven: false,
                isSelected: session.selectedChannelID == id,
                onSelect: { focusChannel(id) },
                onChange: { session.syncParamsToEngine() },
                stripReorderable: reorderStrips,
                isReorderDropTarget: reorderDropID == id,
                onReorderDrop: { session.moveChannel(fromID: $0, toID: id) },
                onReorderTargeted: { targeted in
                    reorderDropID = targeted ? id : (reorderDropID == id ? nil : reorderDropID)
                }
            )
        }
    }

    private func focusChannel(_ id: Int) {
        session.selectChannel(id)
        showAllWaveforms = false
    }

    private var inputDevicePicker: some View {
        HStack(spacing: 6) {
            Text("INPUT")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(MixerTheme.cyanDim)
            Picker(
                "Input",
                selection: Binding(
                    get: { session.selectedInputUID ?? "" },
                    set: { session.selectedInputUID = $0.isEmpty ? nil : $0 }
                )
            ) {
                Text(session.inputDevices.isEmpty ? "No interface" : "—").tag("")
                ForEach(session.inputDevices) { device in
                    if let hz = device.nominalSampleRate, hz > 0 {
                        Text("\(device.name) · \(device.inputChannels) in · \(Int(hz.rounded())) Hz").tag(device.uid)
                    } else {
                        Text("\(device.name) · \(device.inputChannels) in").tag(device.uid)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
            .disabled(session.isRecording || session.isRecordStandby)
                    .help("The interface Mixer records from. New recordings use this box’s sample rate. Assign IN 1 / IN 2 on each speaker strip. Standby meters live input on armed strips.")
        }
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
        } else if let idx = session.stereos.firstIndex(where: { $0.id == session.selectedChannelID }) {
            SelectedChannelPanel(
                channel: $session.stereos[idx],
                rtaBins: session.rtaBins,
                onChange: { session.syncParamsToEngine() }
            )
        } else if let idx = session.voices.firstIndex(where: { $0.id == session.selectedChannelID }) {
            SelectedChannelPanel(
                channel: $session.voices[idx],
                rtaBins: session.rtaBins,
                onChange: {
                    session.syncParamsToEngine()
                    session.syncLinkedFrom(session.voices[idx].id)
                }
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
            // Own line so MASTER is never split next to SEL on the narrow strip.
            Text("MASTER")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.lime : MixerTheme.lime.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)

            Button {
                session.selectChannel(ChannelStripState.masterID)
                showAllWaveforms = false
            } label: {
                Text(session.selectedChannelID == ChannelStripState.masterID ? "SEL●" : "SEL")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .foregroundStyle(session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.bgBottom : MixerTheme.cyan)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.lime : MixerTheme.panelRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.lime : MixerTheme.cyan.opacity(0.45), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Select master — compressor / DSP opens in the selected-channel panel; strip stays pinned")

            HStack(spacing: 4) {
                BypassToggle(bypass: $session.masterComp.bypass)
                Button {
                    session.selectChannel(ChannelStripState.masterID)
                    showAllWaveforms = false
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
                .padding(.vertical, 10)
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
                VStack(spacing: 4) {
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
                    .padding(.bottom, 4)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                LevelMeter(level: session.masterPeakL, label: "L")
                LevelMeter(level: session.masterPeakR, label: "R")
            }
            .frame(height: 128)

            VStack(spacing: 2) {
                Text(masterOutLabel)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(masterOutColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("dBFS")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.cyanDim)
            }
            .padding(.vertical, 2)
            .help("Live peak on the master bus after the OUT fader")

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
            .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(width: 110, height: ChannelStripView.stripHeight, alignment: .top)
        .mixerPanel(glow: true)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.lime : .clear, lineWidth: 2)
        )
    }

    private var masterOutDb: Float {
        let peak = max(session.masterPeakL, session.masterPeakR)
        return 20 * log10(max(peak, 1e-5))
    }

    private var masterOutLabel: String {
        masterOutDb <= -59 ? "—" : String(format: "%+.1f", masterOutDb)
    }

    private var masterOutColor: Color {
        if masterOutDb >= 0 { return MixerTheme.meterRed }
        if masterOutDb > -12 { return MixerTheme.meterYellow }
        return MixerTheme.lime
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button("BACK TO TOP") {
                session.restartPlay()
            }
            .buttonStyle(MixerGhostButtonStyle())
            .help("Jump to the start of the timeline")

            Button(session.isPlaying && !session.isRecording && !session.isRecordStandby ? "PAUSE" : "PLAY") {
                session.togglePlay()
            }
            .buttonStyle(MixerPrimaryButtonStyle())
            .keyboardShortcut(.space, modifiers: [])
            .disabled(session.isRecording)
            .help(
                session.isRecording
                    ? "Spacebar stops Record"
                    : (session.isRecordStandby ? "Spacebar leaves Standby" : "Spacebar toggles play/pause")
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("SEL / DSP chip opens the selected-channel panel · master strip stays pinned on the right · pinch or scroll the wave to zoom · swipe left/right to move")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(MixerTheme.textSecondary)
                    .lineLimit(1)
                Text("ALL TRACKS stays in the window · extra lanes scroll · speaker/bed strips scroll sideways (master does not)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(MixerTheme.textSecondary)
                    .lineLimit(1)
                Text("SEL a strip, then Shift-drag the waveform to silence that span (not a cut) · Option-drag clears")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(MixerTheme.textSecondary)
                    .lineLimit(1)
                Text("Monitor mics on your interface. PodProducer does not play the mic back.")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.lime)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(session.isBouncing ? "EXPORTING…" : "EXPORT…") {
                exportItems = session.makeExportItems()
                exportFolder = session.suggestedExportFolder()
                exportSampleRate = .native
                exportFormat = .wav16
                showExport = true
            }
            .buttonStyle(MixerGhostButtonStyle())
            .disabled(session.isBouncing || session.frameCount == 0)
            .help("Choose speaker stems, stereo beds, and the master 2-mix. Pick sample rate and WAV/AIFF here — playback stays at the file rate.")
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

    private func pickFiles(append: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.message = append
            ? "Add audio files — each file becomes a channel"
            : "Choose audio files — each file becomes a channel"
        panel.begin { response in
            guard response == .OK else { return }
            session.importAudioFiles(panel.urls, append: append)
        }
    }

    private func pickMixFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a mix JSON file"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            session.openMixFile(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let collected = NSMutableArray()
        let lock = NSLock()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url else { return }
                lock.lock()
                collected.add(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            let urls = collected.compactMap { $0 as? URL }
            session.importDroppedURLs(urls)
        }
        return true
    }
}
