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
    @State private var showInputPicker = false
    /// Voice-strip fader block, so stereo beds use the same throw.
    @State private var voiceFaderSectionHeight: CGFloat = VerticalFader.minSectionHeight
    /// Link-gap center in the strip cluster. Negative until the first layout.
    @State private var linkGapMidY: CGFloat = -1

    /// Half/half seam control between adjacent mono strips (no gutter).
    private static let monoLinkSeamWidth: CGFloat = 36
    private static let monoLinkSeamHeight: CGFloat = 22
    /// Content height that fits a voice strip at `VerticalFader.minTravel`.
    /// Measured from the live layout: chrome outside the desk 80, one-track
    /// waveform 140, column spacing 10, strip 556, cluster padding 8.
    /// 80 + 140 + 10 + 556 + 8 = 794. The 600 pt DSP floor is inside this.
    private static let minimumContentHeight: CGFloat = 794
    private static let oneTrackWaveformHeight: CGFloat = 140
    /// All-tracks panel with its 220 pt stack cap. 147 pt taller than one track.
    private static let allTracksWaveformHeight: CGFloat = 287
    /// Voice strip at minimum fader travel, plus the cluster's 8 pt of vertical padding.
    private static let minimumStripBayHeight: CGFloat = 564
    private static let stripColumnSpacing: CGFloat = 10

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

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    if session.hasSession {
                        // Waveform sits over the strips only. DSP + master fill the full column
                        // beside it, so the panel is taller than a strip and is not clipped.
                        sessionDesk
                            .frame(maxWidth: .infinity, minHeight: SelectedChannelPanel.minimumHeight, maxHeight: .infinity)
                    } else {
                        dropZone
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                statusBar
                    .padding(.top, 6)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        // Min height keeps the fader throw usable and the DSP column on screen.
        .frame(
            minWidth: 960,
            idealWidth: 1100,
            maxWidth: .infinity,
            minHeight: Self.minimumContentHeight,
            idealHeight: 820,
            maxHeight: .infinity,
            alignment: .top
        )
        .preferredColorScheme(.dark)
        .onAppear(perform: startSession)
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
        .onReceive(NotificationCenter.default.publisher(for: .fixerMixerAddStrip)) { _ in
            guard session.hasSession else { return }
            session.addBlankStrip()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fixerMixerRemoveStrip)) { _ in
            guard session.hasSession, session.canRemoveStrip(session.selectedChannelID) else { return }
            confirmRemoveStrip = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .fixerMixerToggleReorder)) { _ in
            guard session.hasSession, !session.isRecording else { return }
            reorderStrips.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fixerMixerImportFolder)) { _ in
            pickFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fixerMixerImportFiles)) { _ in
            pickFiles(append: session.hasSession)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fixerMixerExport)) { _ in
            guard session.hasSession, session.frameCount > 0, !session.isBouncing else { return }
            exportItems = session.makeExportItems()
            exportFolder = session.suggestedExportFolder()
            exportSampleRate = .native
            exportFormat = .wav16
            showExport = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .fixerMixerPickInput)) { _ in
            guard session.hasSession else { return }
            session.refreshInputDevices()
            showInputPicker = true
        }
        .popover(isPresented: $showInputPicker, arrowEdge: .top) {
            inputDeviceMenuContent
                .padding(12)
                .frame(minWidth: 280)
        }
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

    private func startSession() {
        session.bindEngine()
        installSpacebarMonitor()
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("PODPRODUCER")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(MixerTheme.cyan)
                Text(CougarCalcBrand.versionLabel)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.lime)
            }
            Spacer(minLength: 8)
            if session.hasSession {
                HStack(spacing: 8) {
                    Button("BACK TO TOP") {
                        session.restartPlay()
                    }
                    .buttonStyle(MixerGhostButtonStyle())
                    .help("Jump to the start of the timeline")

                    Button(session.isPlaying && !session.isRecording && !session.isRecordStandby ? "PAUSE" : "PLAY") {
                        session.togglePlay()
                    }
                    .buttonStyle(MixerPrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(session.isRecording)
                    .help(
                        session.isRecording
                            ? "Spacebar stops Record"
                            : (session.isRecordStandby ? "Spacebar leaves Standby" : "Spacebar toggles play/pause")
                    )

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
                    if session.isRecording {
                        Text("Dropouts: \(session.recordDropouts)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(session.recordDropouts > 0 ? Color.red : MixerTheme.textSecondary)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button("ABOUT") { showAbout = true }
                        .buttonStyle(MixerGhostButtonStyle())
                    Button("LOAD MIX…") { pickMixFile() }
                        .buttonStyle(MixerGhostButtonStyle())
                }
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

    /// Waveform over the strips; selected-channel DSP and master share the column to the right.
    private var sessionDesk: some View {
        HStack(alignment: .top, spacing: 10) {
            stripColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            selectedChannelPane
                .frame(maxHeight: .infinity, alignment: .top)
                .layoutPriority(1)

            masterStrip
                .layoutPriority(1)
        }
    }

    /// Waveform keeps its height until the strip would drop below its minimum.
    /// All Tracks then scrolls in a shorter box so the fader, meters, and the
    /// rows under them stay on screen.
    private var stripColumn: some View {
        GeometryReader { geo in
            let available = max(0, geo.size.height)
            let waveIdeal = showAllWaveforms ? Self.allTracksWaveformHeight : Self.oneTrackWaveformHeight
            let room = max(0, available - Self.stripColumnSpacing)
            let bay = min(room, max(Self.minimumStripBayHeight, room - waveIdeal))
            let wave = room - bay
            VStack(alignment: .leading, spacing: Self.stripColumnSpacing) {
                waveformPane
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: max(0, wave))
                stripBay
                    .frame(maxWidth: .infinity)
                    .frame(height: max(0, bay))
            }
        }
    }

    @ViewBuilder
    private var waveformPane: some View {
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
    }

    /// Strips fill this bay from the top. Fader travel absorbs the height; the rest of
    /// the strip stays put. Extra channels scroll sideways.
    private var stripBay: some View {
        GeometryReader { geo in
            let cluster = mixerClusterWidth
            ScrollView(.horizontal, showsIndicators: cluster > geo.size.width + 1) {
                stripCluster
                    .frame(height: max(0, geo.size.height), alignment: .top)
            }
            .frame(width: max(0, geo.size.width), height: max(0, geo.size.height))
        }
    }

    private var stripCluster: some View {
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
                        y: linkGapMidY - Self.monoLinkSeamHeight / 2
                    )
                    .opacity(linkGapMidY >= 0 ? 1 : 0)
            }
        }
        .coordinateSpace(name: "stripCluster")
        .onPreferenceChange(StripFaderSectionKey.self) { height in
            guard height > 1, abs(height - voiceFaderSectionHeight) > 0.5 else { return }
            voiceFaderSectionHeight = height
        }
        .onPreferenceChange(StripLinkGapKey.self) { y in
            guard y >= 0, abs(y - linkGapMidY) > 0.5 else { return }
            linkGapMidY = y
        }
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
            DSPBevelPillLabel(
                title: "link",
                lit: lit && !dark,
                kind: .lime,
                fontSize: 9,
                fixedSize: CGSize(width: Self.monoLinkSeamWidth, height: Self.monoLinkSeamHeight)
            )
            .opacity(dark ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!canToggle || session.isRecording)
        .help(
            linked
                ? "Unlink these speakers. DSP + fader + mute stay at the last shared values; solo/pan stay independent."
                : (canToggle
                   ? "Link adjacent monos: shared DSP + fader + mute. Solo, pan, and record IN stay independent."
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
                autoDriven: session.autoMixMode.isActive,
                autoGainDb: session.autoGainDb.indices.contains(index) ? session.autoGainDb[index] : nil,
                showAutoInclude: session.autoMixMode.isActive,
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
                },
                alignedFaderSectionHeight: voiceFaderSectionHeight
            )
        }
    }

    private func focusChannel(_ id: Int) {
        session.selectChannel(id)
        showAllWaveforms = false
    }

    private var inputDeviceMenuContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INPUT DEVICE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(MixerTheme.cyanDim)
            Picker(
                "Input",
                selection: Binding(
                    get: { session.selectedInputUID ?? "" },
                    set: {
                        session.selectedInputUID = $0.isEmpty ? nil : $0
                        showInputPicker = false
                    }
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
            .frame(maxWidth: 320)
            .disabled(session.isRecording || session.isRecordStandby)
            .help("The interface Mixer records from. New recordings use this box’s sample rate. Assign IN 1 / IN 2 on each speaker strip. Standby meters live input on armed strips.")
            Text("Also available from File → Input Device…")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(MixerTheme.textSecondary)
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
            let channelID = session.stereos[idx].id
            SelectedChannelPanel(
                channel: $session.stereos[idx],
                rtaBins: session.rtaBins,
                inputIsClipping: { session.inputIsClipping(channelID: channelID) },
                onChange: { session.syncParamsToEngine() }
            )
        } else if let idx = session.voices.firstIndex(where: { $0.id == session.selectedChannelID }) {
            let channelID = session.voices[idx].id
            SelectedChannelPanel(
                channel: $session.voices[idx],
                rtaBins: session.rtaBins,
                inputIsClipping: { session.inputIsClipping(channelID: channelID) },
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
            .frame(width: 460, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .mixerPanel()
        }
    }

    private var masterStrip: some View {
        VStack(spacing: 6) {
            Text("MASTER")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(session.selectedChannelID == ChannelStripState.masterID ? MixerTheme.lime : MixerTheme.lime.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)

            SelectChannelButton(
                isSelected: session.selectedChannelID == ChannelStripState.masterID,
                expandsHorizontally: true
            ) {
                session.selectChannel(ChannelStripState.masterID)
                showAllWaveforms = false
            }
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
                        .padding(.vertical, 5)
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
                session.toggleAutoMix()
            } label: {
                VStack(spacing: 1) {
                    Text("AUTO")
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                    Text("MIX")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(session.autoMixMode == .mix ? MixerTheme.bgBottom : MixerTheme.cyan)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(session.autoMixMode == .mix ? MixerTheme.meterGreen : MixerTheme.panelRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(MixerTheme.cyan.opacity(0.45), lineWidth: 1)
                )
                .opacity(session.autoMixMode == .duck ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(session.autoMixMode == .duck)
            .help("Auto Mix: per-channel vocal rider around each fader baseline. Click again for OFF. Greys Auto Duck while on.")

            Button {
                session.toggleAutoDuck()
            } label: {
                VStack(spacing: 1) {
                    Text("AUTO")
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                    Text("DUCK")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(session.autoMixMode == .duck ? MixerTheme.bgBottom : MixerTheme.cyan)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(session.autoMixMode == .duck ? MixerTheme.meterGreen : MixerTheme.panelRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(MixerTheme.cyan.opacity(0.45), lineWidth: 1)
                )
                .opacity(session.autoMixMode == .mix ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(session.autoMixMode == .mix)
            .help("Auto Duck: hold featured talker at baseline; duck other included monos. Click again for OFF. Greys Auto Mix while on.")

            if session.autoMixMode == .duck {
                VStack(spacing: 2) {
                    Text("MAX PULL")
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(MixerTheme.cyanDim)
                    Text(String(format: "%.0f dB", session.autoDuckMaxAttenuationDb))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(MixerTheme.lime)
                    Slider(value: Binding(
                        get: { Double(session.autoDuckMaxAttenuationDb) },
                        set: {
                            session.autoDuckMaxAttenuationDb = Float($0)
                            session.syncParamsToEngine()
                        }
                    ), in: 0...18)
                    .tint(MixerTheme.cyan)
                }
                .help("Limits how far Auto Duck can attenuate a channel (0 = no duck).")
            }

            VStack(spacing: 2) {
                Text(masterOutLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(masterOutColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                Text("dBFS")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.cyanDim)
                    .frame(maxWidth: .infinity)
                HStack(alignment: .bottom, spacing: 6) {
                    LevelMeter(level: session.masterPeakL, label: "L", stripChrome: true)
                        .frame(maxHeight: .infinity)
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
                        caption: "OUT",
                        expands: true
                    )
                    LevelMeter(level: session.masterPeakR, label: "R", stripChrome: true)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .help("Live peak on the master bus after the OUT fader")
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: 110)
        .frame(maxHeight: .infinity, alignment: .top)
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

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let progress = session.busyProgress {
                HStack(spacing: 6) {
                    Capsule()
                        .fill(MixerTheme.cyan.opacity(0.18))
                        .frame(width: 160, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(MixerTheme.cyan)
                                .frame(width: max(3, 160 * CGFloat(min(1, max(0, progress)))))
                        }
                    Text(session.busyProgressLabel.map { "\($0) · \(Int(progress * 100))%" } ?? String(format: "%.0f%%", progress * 100))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(MixerTheme.lime)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Text(session.status)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(MixerTheme.textPrimary)
            if session.hasSession {
                Text("File menu · Load/Save/Import/Export/Input · SEL opens DSP · Shift-drag waveform to silence · Option-drag clears")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(MixerTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
