import PodLoungeCore
import SwiftUI

struct TrimmerWorkspaceView: View {
    @EnvironmentObject private var session: ProjectSession
    @Environment(\.undoManager) private var undoManager
    @StateObject private var editor = TrimmerEditor()
    @StateObject private var transport = TrimmerTransport()
    @State private var pixelsPerSecond: CGFloat = 10
    @State private var selectedClipID: UUID?
    @State private var selectedTrack: TrimmerTrackID = .episodeMix
    @State private var selectedMarkerID: UUID?
    @State private var editingMarkerID: UUID?
    @State private var editingTitle = ""
    @State private var rangeSelection: CutRange?
    @State private var pendingDelete: PendingCut?
    @State private var faderDraft: [TrimmerTrackID: Double] = [:]
    @State private var exportProgress: Double?
    @State private var viewportWidth: CGFloat = 640
    @State private var dropHoverTrack: TrimmerTrackID?
    @State private var pendingDrop: PendingDepotDrop?
    @State private var rulerScrubbing = false
    @State private var rulerWasPlaying = false
    @State private var clipDrag: ClipDragPreview?
    @State private var userAdjustedZoom = false
    @State private var didFitContent = false

    private static let trackHeaderWidth: CGFloat = 198

    private var shown: TrimmerDocument { editor.document }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            toolRow
            board
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            exportRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LoungeTheme.background)
        .onAppear {
            bindUndo()
            editor.replace(session.trimmerDocument, clearUndo: true)
            session.endTrimmerPlayback = { transport.stop() }
        }
        .onDisappear {
            transport.shutdown()
            session.endTrimmerPlayback = nil
            editor.undoManager.removeAllActions()
            session.trimmerExporting = false
        }
        .onChange(of: session.package?.rootURL) { _, _ in
            transport.stop()
            pendingDelete = nil
            editor.replace(session.trimmerDocument, clearUndo: true)
        }
        .onChange(of: editor.document) { _, newValue in
            if session.trimmerDocument != newValue {
                session.trimmerDocument = newValue
            }
        }
        .onChange(of: pendingDrop) { _, drop in
            // Place from the SwiftUI update, so the drop joins the window's undo list.
            guard let drop else { return }
            pendingDrop = nil
            guard session.trimmerExporting == false else { return }
            let time = DepotAssetDrag.timelineSeconds(dropX: drop.x, pixelsPerSecond: pixelsPerSecond)
            place(assetID: drop.assetID, on: drop.track, at: time)
        }
        .background {
            if editingMarkerID == nil {
                Button("") { performDelete() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .keyboardShortcut(.deleteForward, modifiers: [])
                    .labelsHidden()
                    .frame(width: 0, height: 0)
                Button("") { togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                    .labelsHidden()
                    .frame(width: 0, height: 0)
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Button("← Back to Lounge") { session.leaveWorkspace() }
                .buttonStyle(LoungeButtonStyle())
                .disabled(session.navigationLocked)
                .accessibilityIdentifier("lounge.back")
            VStack(alignment: .leading, spacing: 1) {
                RoomTitleText(workspace: .trimmer, size: 22)
                Text(WorkspaceID.trimmer.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(LoungeTheme.textDim)
            }
            Spacer(minLength: 8)
            if let exportProgress {
                HStack(spacing: 6) {
                    Capsule()
                        .fill(LoungeTheme.cyan.opacity(0.18))
                        .frame(width: 72, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(LoungeTheme.cyan)
                                .frame(width: max(3, 72 * exportProgress))
                        }
                    Text("Exporting \(Int((exportProgress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(LoungeTheme.result)
                        .monospacedDigit()
                }
                .accessibilityIdentifier("thecut.progress")
            } else if let message = transport.message {
                Text(message)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LoungeTheme.amber)
                    .lineLimit(2)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            Button { togglePlay() } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(LoungeButtonStyle(prominent: !transport.isPlaying))
            .disabled(session.trimmerExporting)
            .accessibilityIdentifier("thecut.play")
            .help("Play from the playhead")
            Button { transport.stop() } label: {
                Image(systemName: "stop.fill")
                    .frame(width: 16)
            }
            .buttonStyle(LoungeButtonStyle())
            .accessibilityIdentifier("thecut.stop")
            .help("Stop")
            Text("\(clock(transport.playhead, tenths: true))  /  \(clock(max(shown.timelineEnd, transport.playhead), tenths: false))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(LoungeTheme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(LoungeTheme.field))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(LoungeTheme.cyan.opacity(0.35), lineWidth: 1))
                .accessibilityIdentifier("thecut.time")
            Rectangle().fill(LoungeTheme.cyan.opacity(0.25)).frame(width: 1, height: 18)
            Button("Split") { split() }
                .buttonStyle(LoungeButtonStyle())
                .disabled(session.trimmerExporting)
            Button("Trim") { trimToPlayhead() }
                .buttonStyle(LoungeButtonStyle())
                .disabled(session.trimmerExporting)
            Button("Delete") { performDelete() }
                .buttonStyle(LoungeButtonStyle(prominent: pendingDelete != nil))
                .disabled(session.trimmerExporting)
            Rectangle().fill(LoungeTheme.cyan.opacity(0.25)).frame(width: 1, height: 18)
            Button("Undo") { bindUndo(); editor.undoManager.undo() }
                .buttonStyle(LoungeButtonStyle())
                .disabled(!editor.undoManager.canUndo)
                .help("Undo (⌘Z)")
            Button("Redo") { bindUndo(); editor.undoManager.redo() }
                .buttonStyle(LoungeButtonStyle())
                .disabled(!editor.undoManager.canRedo)
                .help("Redo (⇧⌘Z)")
            Button("Add Chapter") { addChapter() }
                .buttonStyle(LoungeButtonStyle())
                .disabled(session.trimmerExporting)
            Spacer(minLength: 8)
            Button { zoom(by: 1 / TrimmerViewport.zoomFactor) } label: { Image(systemName: "minus") }
                .buttonStyle(LoungeButtonStyle())
                .help("Zoom out")
            Button("Fit") {
                userAdjustedZoom = false
                fit(width: viewportWidth)
                if !shown.clips.isEmpty { didFitContent = true }
            }
                .buttonStyle(LoungeButtonStyle())
                .help("Fit the episode")
            Button { zoom(by: TrimmerViewport.zoomFactor) } label: { Image(systemName: "plus") }
                .buttonStyle(LoungeButtonStyle())
                .help("Zoom in")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var exportRow: some View {
        HStack {
            Spacer()
            Button("Export → Depot & open TheRoof") { exportCut() }
                .buttonStyle(LoungeButtonStyle(prominent: true))
                .disabled(session.package == nil || shown.clips.isEmpty || session.trimmerExporting)
                .accessibilityIdentifier("thecut.export")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var board: some View {
        GeometryReader { geo in
            let headerWidth = Self.trackHeaderWidth
            let rulerHeight: CGFloat = 24
            let markerHeight: CGFloat = 32
            let laneHeight = max(48, (geo.size.height - rulerHeight - markerHeight) / 3)
            let span = max(TrimmerViewport.fitEnd(of: shown), shown.timelineEnd, transport.playhead)
            let timelineWidth = max(geo.size.width - headerWidth, CGFloat(span) * pixelsPerSecond)
            HStack(spacing: 0) {
                headerColumn(rulerHeight: rulerHeight, markerHeight: markerHeight, laneHeight: laneHeight)
                    .frame(width: headerWidth)
                ScrollView(.horizontal, showsIndicators: true) {
                    timeline(
                        width: timelineWidth,
                        rulerHeight: rulerHeight,
                        markerHeight: markerHeight,
                        laneHeight: laneHeight
                    )
                    .frame(width: timelineWidth, height: rulerHeight + markerHeight + laneHeight * 3)
                }
            }
            .onAppear {
                viewportWidth = geo.size.width - headerWidth
                if !userAdjustedZoom {
                    fit(width: viewportWidth)
                    if !shown.clips.isEmpty { didFitContent = true }
                }
            }
            .onChange(of: geo.size.width) { _, width in
                viewportWidth = width - headerWidth
            }
            .onChange(of: shown.clips.isEmpty) { _, empty in
                if !empty && !didFitContent && !userAdjustedZoom {
                    fit(width: viewportWidth)
                    didFitContent = true
                }
            }
        }
        .background(Color(red: 0.04, green: 0.07, blue: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LoungeTheme.cyan.opacity(0.45), lineWidth: 1)
        )
        .overlay { deleteDialog }
    }

    private func headerColumn(rulerHeight: CGFloat, markerHeight: CGFloat, laneHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            Text("MARKERS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(LoungeTheme.textDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: markerHeight)
                .background(LoungeTheme.backgroundRaised)
            ForEach(TrimmerTrackID.allCases) { track in
                trackHeader(track)
                    .frame(height: laneHeight)
            }
        }
        .background(LoungeTheme.backgroundRaised)
    }

    private func trackHeader(_ track: TrimmerTrackID) -> some View {
        let state = shown.trackState(track)
        let gain = faderDraft[track] ?? state.gainDB
        let reading = transport.meters[track] ?? TrimmerMeterReading()
        let selected = selectedTrack == track
        return VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(selected ? CutStripChrome.lime : CutStripChrome.cyan)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text("STEREO")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(CutStripChrome.cyanDim)
            }
            HStack(spacing: 5) {
                msButton("M", lit: state.muted, kind: .mute) {
                    commitMix("Mute") { $0 = $0.settingTrack(track, muted: !state.muted) }
                }
                .help("Mute")
                msButton("S", lit: state.solo, kind: .solo) {
                    commitMix("Solo") { $0 = $0.settingTrack(track, solo: !state.solo) }
                }
                .help("Solo")
                Slider(
                    value: Binding(
                        get: { gain },
                        set: { newValue in
                            faderDraft[track] = newValue
                            var live = shown
                            live = live.settingTrack(track, gainDB: newValue)
                            transport.applyMix(live)
                        }
                    ),
                    in: -24...12,
                    onEditingChanged: { editing in
                        if editing {
                            faderDraft[track] = shown.trackState(track).gainDB
                        } else if let value = faderDraft[track] {
                            faderDraft[track] = nil
                            commitMix("Track Level") { $0 = $0.settingTrack(track, gainDB: value) }
                        }
                    }
                )
                .controlSize(.small)
                .tint(CutStripChrome.cyan)
                Text(dbLabel(gain))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(CutStripChrome.cyan)
                    .frame(width: 46, alignment: .trailing)
            }
            VStack(spacing: 2) {
                meterRow("L", level: reading.left, hold: reading.holdLeft)
                meterRow("R", level: reading.right, hold: reading.holdRight)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Level")
            .accessibilityIdentifier("thecut.meter.\(track.rawValue)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [CutStripChrome.top, CutStripChrome.bottom], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(height: 1)
                .padding(.horizontal, 10)
                .padding(.top, 1)
                .allowsHitTesting(false)
        }
        .overlay(
            Rectangle()
                .stroke(selected ? CutStripChrome.lime.opacity(0.72) : Color.white.opacity(0.07), lineWidth: selected ? 1.35 : 1)
                .shadow(color: selected ? CutStripChrome.lime.opacity(0.28) : .clear, radius: selected ? 4 : 0)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedTrack = track }
        .clipped()
    }

    private func meterRow(_ label: String, level: Float, hold: Float) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(CutStripChrome.cyanDim)
                .frame(width: 10, alignment: .leading)
            CutLEDMeter(level: level, hold: hold)
                .frame(height: 8)
        }
    }

    private func msButton(_ title: String, lit: Bool, kind: CutBevelKind, action: @escaping () -> Void) -> some View {
        let plate = lit ? kind : CutBevelKind.off
        return Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(plate.text)
                .frame(width: 22, height: 18)
                .background {
                    Capsule()
                        .fill(
                            LinearGradient(colors: [plate.top, plate.bottom], startPoint: .top, endPoint: .bottom)
                        )
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(Color.white.opacity(lit ? 0.70 : 0.22))
                                .frame(height: 1)
                                .padding(.horizontal, 4)
                                .padding(.top, 1)
                        }
                        .overlay(Capsule().stroke(Color.black.opacity(0.30), lineWidth: 0.6))
                        .shadow(color: lit ? plate.glow.opacity(0.50) : Color.black.opacity(0.35), radius: lit ? 2.5 : 1, y: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(session.trimmerExporting)
    }

    private func timeline(width: CGFloat, rulerHeight: CGFloat, markerHeight: CGFloat, laneHeight: CGFloat) -> some View {
        let step = tickStep()
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ruler(width: width, height: rulerHeight, step: step)
                markerLane(width: width, height: markerHeight)
                ForEach(TrimmerTrackID.allCases) { track in
                    lane(track, width: width, height: laneHeight, step: step, laneHeight: laneHeight)
                }
            }
            playhead(height: rulerHeight + markerHeight + laneHeight * 3)
            if shown.clips.isEmpty {
                Text("Drag a depot item onto a track.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LoungeTheme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func ruler(width: CGFloat, height: CGFloat, step: Double) -> some View {
        ZStack(alignment: .topLeading) {
            LoungeTheme.backgroundRaised
            ForEach(tickTimes(step: step, through: width), id: \.self) { time in
                let major = abs(time.truncatingRemainder(dividingBy: step)) < 0.001
                Rectangle()
                    .fill(LoungeTheme.textDim.opacity(major ? 0.55 : 0.25))
                    .frame(width: 1, height: major ? height : 8)
                    .offset(x: CGFloat(time) * pixelsPerSecond, y: major ? 0 : height - 8)
                if major {
                    Text(clock(time, tenths: false))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LoungeTheme.textDim)
                        .offset(x: CGFloat(time) * pixelsPerSecond + 4, y: 3)
                }
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !rulerScrubbing {
                        rulerScrubbing = true
                        rulerWasPlaying = transport.isPlaying
                        if transport.isPlaying { transport.stop() }
                    }
                    transport.setPlayhead(max(0, Double(value.location.x / pixelsPerSecond)))
                }
                .onEnded { value in
                    let resume = rulerWasPlaying
                    rulerScrubbing = false
                    rulerWasPlaying = false
                    transport.relocate(
                        to: Double(value.location.x / pixelsPerSecond),
                        resume: resume,
                        document: shown
                    ) { url(for: $0) }
                }
        )
    }

    private func markerLane(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.035, green: 0.06, blue: 0.08)
            ForEach(shown.markers) { marker in
                markerFlag(marker)
                    .offset(x: CGFloat(marker.time) * pixelsPerSecond)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func markerFlag(_ marker: TrimmerMarker) -> some View {
        let selected = selectedMarkerID == marker.id
        return HStack(spacing: 4) {
            Image(systemName: "flag.fill")
                .font(.system(size: 9))
                .foregroundStyle(LoungeTheme.cyan)
            if editingMarkerID == marker.id {
                TextField("Chapter", text: $editingTitle, onCommit: commitMarkerTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 90)
            } else {
                Text(marker.title.isEmpty ? "Chapter" : marker.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LoungeTheme.text)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? LoungeTheme.cyan.opacity(0.22) : Color(red: 0.08, green: 0.16, blue: 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(selected ? LoungeTheme.text : LoungeTheme.cyan.opacity(0.7), lineWidth: 1)
        )
        .offset(y: 5)
        .modifier(FollowDrag(minimum: 3) { translation in
            let time = max(0, marker.time + Double(translation.width / pixelsPerSecond))
            commit("Move Chapter") { $0 = $0.movingMarker(id: marker.id, to: time) }
        })
        .onTapGesture(count: 2) {
            editingMarkerID = marker.id
            editingTitle = marker.title
            selectedMarkerID = marker.id
        }
        .onTapGesture {
            selectedMarkerID = marker.id
            selectedClipID = nil
            rangeSelection = nil
            seek(marker.time)
        }
    }

    private func lane(_ track: TrimmerTrackID, width: CGFloat, height: CGFloat, step: Double, laneHeight: CGFloat) -> some View {
        let clips = shown.clips.filter { $0.track == track }.sorted { $0.start < $1.start }
        return ZStack(alignment: .topLeading) {
            Color(red: 0.03, green: 0.055, blue: 0.075)
            ForEach(tickTimes(step: step, through: width), id: \.self) { time in
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(width: 1, height: height)
                    .offset(x: CGFloat(time) * pixelsPerSecond)
            }
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                if index + 1 < clips.count {
                    let gap = clips[index + 1].start - clip.end
                    if gap >= 0.25 {
                        gapMark(start: clip.end, length: gap, height: height)
                    }
                }
            }
            ForEach(overlapPairs(clips), id: \.id) { pair in
                crossfadeMark(pair, height: height)
            }
            ForEach(clips) { clip in
                clipView(clip, height: height, laneHeight: laneHeight)
            }
            if let range = rangeSelection, range.track == track {
                Rectangle()
                    .fill(LoungeTheme.cyan.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(LoungeTheme.text, lineWidth: 2))
                    .frame(width: max(2, CGFloat(range.range.length) * pixelsPerSecond), height: height - 16)
                    .offset(x: CGFloat(range.start) * pixelsPerSecond, y: 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // A depot drag is handled by LaneDropCatcher. Don't also draw a range.
                    guard dropHoverTrack != track else {
                        rangeSelection = nil
                        return
                    }
                    // A drag that starts on a clip moves or trims that clip. Range select stays a drag on empty lane.
                    guard !pointIsOnClip(value.startLocation, clips: clips, laneHeight: height) else { return }
                    guard hypot(value.translation.width, value.translation.height) >= 4 else { return }
                    let start = Double(value.startLocation.x / pixelsPerSecond)
                    let end = Double(value.location.x / pixelsPerSecond)
                    rangeSelection = CutRange(track: track, start: min(start, end), end: max(start, end))
                    selectedTrack = track
                    selectedClipID = nil
                    selectedMarkerID = nil
                }
                .onEnded { value in
                    guard dropHoverTrack != track else { return }
                    guard !pointIsOnClip(value.startLocation, clips: clips, laneHeight: height) else { return }
                    if hypot(value.translation.width, value.translation.height) < 4 {
                        seek(Double(value.location.x / pixelsPerSecond))
                        selectedTrack = track
                        rangeSelection = nil
                    }
                }
        )
        .overlay {
            LaneDropCatcher(
                onHover: { hovering in
                    if hovering {
                        dropHoverTrack = track
                    } else if dropHoverTrack == track {
                        dropHoverTrack = nil
                    }
                },
                onPerform: { assetID, x in
                    guard session.trimmerExporting == false else { return false }
                    pendingDrop = PendingDepotDrop(assetID: assetID, track: track, x: x, token: UUID())
                    return true
                }
            )
            .allowsHitTesting(false)
        }
        .overlay {
            if dropHoverTrack == track {
                ZStack {
                    LoungeTheme.cyan.opacity(0.20)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(LoungeTheme.cyan, lineWidth: 3)
                    Text("Drop here")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LoungeTheme.cyan)
                }
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Drop here")
                .accessibilityIdentifier("thecut.dropHighlight.\(track.rawValue)")
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(LoungeTheme.cyan.opacity(0.12)).frame(height: 1).allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(track.title)
        .accessibilityIdentifier("thecut.lane.\(track.rawValue)")
    }

    private func clipView(_ clip: TrimmerClip, height: CGFloat, laneHeight: CGFloat) -> some View {
        let width = max(8, CGFloat(clip.length) * pixelsPerSecond)
        let drawn = displayClip(clip)
        let drawnWidth = max(8, CGFloat(drawn.length) * pixelsPerSecond)
        let nudge = displayOffset(clip)
        let selected = selectedClipID == clip.id
        let color = trackColor(clip.track)
        return ZStack(alignment: .topLeading) {
            clipBody(drawn, width: drawnWidth, height: height, selected: selected, color: color)
                .offset(
                    x: CGFloat(drawn.start) * pixelsPerSecond + nudge.width,
                    y: 10 + nudge.height
                )
            CutClipHitView(
                fadeInBoundary: CGFloat(clip.fadeIn) * pixelsPerSecond,
                fadeOutBoundary: CGFloat(clip.fadeOut) * pixelsPerSecond,
                onDown: {
                    selectedClipID = clip.id
                    selectedTrack = clip.track
                    selectedMarkerID = nil
                    rangeSelection = nil
                },
                onClick: { x in
                    clipDrag = nil
                    selectedClipID = clip.id
                    selectedTrack = clip.track
                    selectedMarkerID = nil
                    rangeSelection = nil
                    seek(clip.start + Double(x) / Double(pixelsPerSecond))
                },
                onChanged: { kind, dx, dy in
                    clipDrag = ClipDragPreview(clipID: clip.id, kind: kind, dx: dx, dy: dy)
                },
                onEnded: { kind, dx, dy in
                    clipDrag = nil
                    finishClipDrag(clip, kind: kind, dx: dx, dy: dy, laneHeight: laneHeight)
                }
            )
            .frame(width: width, height: height - 20)
            .offset(x: CGFloat(clip.start) * pixelsPerSecond, y: 10)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name(for: clip.assetID))
        .accessibilityIdentifier("thecut.clip.\(name(for: clip.assetID))")
    }

    private func clipBody(_ clip: TrimmerClip, width: CGFloat, height: CGFloat, selected: Bool, color: Color) -> some View {
        let box: CGFloat = 8
        let inBoundary = clip.length > 0 ? CGFloat(clip.fadeIn / clip.length) * width : 0
        let outBoundary = clip.length > 0 ? width - CGFloat(clip.fadeOut / clip.length) * width : width
        let inX = min(max(0, width - box), max(0, inBoundary - box / 2))
        let outX = min(max(0, width - box), max(0, outBoundary - box / 2))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.22))
            waveform(clip)
                .padding(.top, 14)
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
            CutFadeOverlay(fadeIn: clip.fadeIn, fadeOut: clip.fadeOut, length: clip.length, tint: color)
            Text(name(for: clip.assetID))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.top, 3)
            fadeBox
                .offset(x: inX, y: 1)
            fadeBox
                .offset(x: outX, y: 1)
        }
        .frame(width: width, height: height - 20)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? LoungeTheme.text : color.opacity(0.9), lineWidth: selected ? 2 : 1)
        )
        .allowsHitTesting(false)
    }

    private var fadeBox: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white)
            .frame(width: 8, height: 8)
            .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.black.opacity(0.7), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
    }

    private func waveform(_ clip: TrimmerClip) -> some View {
        CutWaveform(assetID: clip.assetID, url: url(for: clip.assetID), color: trackColor(clip.track), inOffset: clip.inOffset, length: clip.length, sourceDuration: clip.sourceDuration)
    }

    private func gapMark(start: Double, length: Double, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(LoungeTheme.textDim.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Text("GAP")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LoungeTheme.textDim)
        }
        .frame(width: CGFloat(length) * pixelsPerSecond, height: height - 20)
        .offset(x: CGFloat(start) * pixelsPerSecond, y: 10)
        .allowsHitTesting(false)
    }

    private func crossfadeMark(_ pair: OverlapPair, height: CGFloat) -> some View {
        let width = CGFloat(pair.length) * pixelsPerSecond
        return Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: 4))
            path.addLine(to: CGPoint(x: size.width, y: size.height - 4))
            path.move(to: CGPoint(x: 0, y: size.height - 4))
            path.addLine(to: CGPoint(x: size.width, y: 4))
            context.stroke(path, with: .color(LoungeTheme.cyan), lineWidth: 1.6)
        }
        .frame(width: max(4, width), height: height - 20)
        .offset(x: CGFloat(pair.start) * pixelsPerSecond, y: 10)
        .allowsHitTesting(false)
    }

    private func playhead(height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(LoungeTheme.cyan)
                .frame(width: 2, height: height)
                .shadow(color: LoungeTheme.cyan.opacity(0.6), radius: 4)
            PlayheadCap()
                .fill(LoungeTheme.cyan)
                .frame(width: 12, height: 8)
        }
        .offset(x: CGFloat(transport.playhead) * pixelsPerSecond - 1)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var deleteDialog: some View {
        if let pending = pendingDelete {
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete selection")
                    .font(.system(size: 14, weight: .semibold))
                Text("Close the gap pulls everything later on this track forward, and moves clips on the other tracks that start after the cut, so ads and outros stay in sync with the mix. Chapter markers after the cut move too. Leave a gap keeps the silence.")
                    .font(.system(size: 12))
                    .foregroundStyle(LoungeTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Close the gap") { confirmDelete(.closeGap, pending: pending) }
                        .buttonStyle(LoungeButtonStyle(prominent: true))
                        .accessibilityIdentifier("thecut.delete.close")
                    Button("Leave a gap") { confirmDelete(.leaveGap, pending: pending) }
                        .buttonStyle(LoungeButtonStyle())
                        .accessibilityIdentifier("thecut.delete.leave")
                }
                Button("Cancel") { pendingDelete = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LoungeTheme.textDim)
                    .frame(maxWidth: .infinity)
            }
            .padding(14)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.06, green: 0.09, blue: 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LoungeTheme.cyan, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        }
    }

    // MARK: - Actions

    private func bindUndo() {
        if let undoManager {
            editor.undoManager = undoManager
        }
    }

    private func commit(_ label: String, _ body: (inout TrimmerDocument) -> Void) {
        bindUndo()
        transport.stop()
        editor.edit(label, body)
    }

    private func commitMix(_ label: String, _ body: (inout TrimmerDocument) -> Void) {
        bindUndo()
        editor.edit(label, body)
        transport.applyMix(editor.document)
    }

    private func togglePlay() {
        transport.message = nil
        if transport.isPlaying {
            transport.stop()
            return
        }
        if session.fixerRecording {
            transport.message = "TheDecks is recording. Stop the take before playing here."
            return
        }
        session.stopDepotPlayback()
        transport.play(document: shown) { url(for: $0) }
    }

    private func seek(_ time: Double) {
        transport.seek(to: time, document: shown) { url(for: $0) }
    }

    private func pointIsOnClip(_ point: CGPoint, clips: [TrimmerClip], laneHeight: CGFloat) -> Bool {
        let top: CGFloat = 10
        let bottom = laneHeight - 10
        guard point.y >= top, point.y <= bottom else { return false }
        for clip in clips {
            let minX = CGFloat(clip.start) * pixelsPerSecond
            let maxX = minX + max(8, CGFloat(clip.length) * pixelsPerSecond)
            if point.x >= minX && point.x <= maxX { return true }
        }
        return false
    }

    private func displayClip(_ clip: TrimmerClip) -> TrimmerClip {
        guard let drag = clipDrag, drag.clipID == clip.id else { return clip }
        switch drag.kind {
        case .body:
            return clip
        case .trimStart:
            let time = clip.start + Double(drag.dx / pixelsPerSecond)
            return shown.trimming(clipID: clip.id, edge: .start, to: time).clip(clip.id) ?? clip
        case .trimEnd:
            let time = clip.end + Double(drag.dx / pixelsPerSecond)
            return shown.trimming(clipID: clip.id, edge: .end, to: time).clip(clip.id) ?? clip
        case .fadeIn:
            let seconds = clip.fadeIn + Double(drag.dx / pixelsPerSecond)
            return shown.settingFade(clipID: clip.id, edge: .fadeIn, seconds: seconds).clip(clip.id) ?? clip
        case .fadeOut:
            let seconds = clip.fadeOut - Double(drag.dx / pixelsPerSecond)
            return shown.settingFade(clipID: clip.id, edge: .fadeOut, seconds: seconds).clip(clip.id) ?? clip
        }
    }

    private func displayOffset(_ clip: TrimmerClip) -> CGSize {
        guard let drag = clipDrag, drag.clipID == clip.id, drag.kind == .body else { return .zero }
        return CGSize(width: drag.dx, height: drag.dy)
    }

    private func finishClipDrag(_ clip: TrimmerClip, kind: CutHitKind, dx: CGFloat, dy: CGFloat, laneHeight: CGFloat) {
        let translation = CGSize(width: dx, height: dy)
        switch kind {
        case .body:
            applyDrag(.move, clip: clip, translation: translation, laneHeight: laneHeight)
        case .trimStart:
            applyDrag(.trim(.start), clip: clip, translation: translation, laneHeight: laneHeight)
        case .trimEnd:
            applyDrag(.trim(.end), clip: clip, translation: translation, laneHeight: laneHeight)
        case .fadeIn:
            applyDrag(.fade(.fadeIn), clip: clip, translation: translation, laneHeight: laneHeight)
        case .fadeOut:
            applyDrag(.fade(.fadeOut), clip: clip, translation: translation, laneHeight: laneHeight)
        }
    }

    private func split() {
        let time = transport.playhead
        let margin = TrimmerDocument.minimumLength
        let chosen: TrimmerClip?
        if let id = selectedClipID, let clip = shown.clip(id), clip.contains(time, margin: margin) {
            chosen = clip
        } else {
            chosen = shown.clips.first { $0.track == selectedTrack && $0.contains(time, margin: margin) }
        }
        guard let chosen else {
            transport.message = "Move the playhead inside a clip to split it."
            return
        }
        transport.message = nil
        commit("Split") { $0 = $0.splitting(clipID: chosen.id, at: time) }
    }

    private func trimToPlayhead() {
        guard let id = selectedClipID, let clip = shown.clip(id), clip.contains(transport.playhead) else {
            transport.message = "Select a clip and put the playhead inside it to trim."
            return
        }
        let edge: TrimmerEdge = (transport.playhead - clip.start) <= (clip.end - transport.playhead) ? .start : .end
        transport.message = nil
        commit("Trim") { $0 = $0.trimming(clipID: id, edge: edge, to: transport.playhead) }
    }

    private func performDelete() {
        if let range = rangeSelection, range.range.length > TrimmerDocument.epsilon {
            switch shown.planDelete(range: range.range, on: range.track) {
            case .nothing:
                transport.message = "That range does not cover a clip."
            case let .removeClips(ids):
                commit("Delete") { $0 = $0.removingClips(ids: ids) }
                rangeSelection = nil
            case let .choose(span, track):
                pendingDelete = PendingCut(range: span, track: track)
            }
            return
        }
        if let id = selectedClipID {
            switch shown.planDelete(clipID: id) {
            case .nothing:
                break
            case let .removeClips(ids):
                commit("Delete") { $0 = $0.removingClips(ids: ids) }
                selectedClipID = nil
            case let .choose(span, track):
                pendingDelete = PendingCut(range: span, track: track)
            }
            return
        }
        if let id = selectedMarkerID {
            commit("Delete Chapter") { $0 = $0.removingMarkers(ids: [id]) }
            selectedMarkerID = nil
        }
    }

    private func confirmDelete(_ mode: TrimmerDeleteMode, pending: PendingCut) {
        commit("Delete") { $0 = $0.deleting(range: pending.range, on: pending.track, mode: mode) }
        pendingDelete = nil
        rangeSelection = nil
        selectedClipID = nil
    }

    private func addChapter() {
        let title = shown.suggestedChapterTitle()
        commit("Add Chapter") { $0 = $0.addingMarker(at: transport.playhead, title: title) }
    }

    private func commitMarkerTitle() {
        guard let id = editingMarkerID else { return }
        let title = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        commit("Rename Chapter") { $0 = $0.renamingMarker(id: id, title: title.isEmpty ? "Chapter" : title) }
        editingMarkerID = nil
    }

    private func place(assetID: String, on track: TrimmerTrackID, at time: Double) {
        guard let asset = session.assets.first(where: { $0.id == assetID }) else { return }
        guard session.health(of: asset) == .present, let fileURL = url(for: assetID) else {
            session.alertMessage = "That depot file is missing."
            return
        }
        guard let duration = AudioDuration.seconds(for: fileURL), duration >= TrimmerDocument.minimumLength else {
            session.alertMessage = "That file has no audio to place on the timeline."
            return
        }
        let placed = TrimmerClip(
            assetID: asset.id,
            track: track,
            start: max(0, time),
            inOffset: 0,
            length: duration,
            sourceDuration: duration
        )
        commit("Place Clip") { $0 = $0.placing(placed) }
        selectedClipID = placed.id
        selectedTrack = track
        rangeSelection = nil
    }

    private func applyDrag(_ kind: CutDrag, clip: TrimmerClip, translation: CGSize, laneHeight: CGFloat) {
        let seconds = Double(translation.width / pixelsPerSecond)
        let label: String
        let next: TrimmerDocument
        switch kind {
        case .move:
            var track = clip.track
            if laneHeight > 1, let index = TrimmerTrackID.allCases.firstIndex(of: clip.track) {
                let shift = Int((translation.height / laneHeight).rounded())
                let nextIndex = index + shift
                if TrimmerTrackID.allCases.indices.contains(nextIndex) {
                    track = TrimmerTrackID.allCases[nextIndex]
                }
            }
            label = track == clip.track ? "Move Clip" : "Move Clip"
            next = shown.moving(clipID: clip.id, toStart: clip.start + seconds, track: track)
        case let .trim(edge):
            let time = edge == .start ? clip.start + seconds : clip.end + seconds
            label = "Trim"
            next = shown.trimming(clipID: clip.id, edge: edge, to: time)
        case let .fade(edge):
            let current = edge == .fadeIn ? clip.fadeIn : clip.fadeOut
            let delta = edge == .fadeIn ? seconds : -seconds
            label = "Fade"
            next = shown.settingFade(clipID: clip.id, edge: edge, seconds: current + delta)
        }
        bindUndo()
        transport.stop()
        editor.apply(label: label, next)
    }

    private func exportCut() {
        guard !session.fixerRecording else {
            transport.message = "TheDecks is recording. Stop the take before exporting."
            return
        }
        guard session.package != nil else {
            session.alertMessage = "Create or open a project before exporting."
            return
        }
        guard !shown.clips.isEmpty else { return }
        transport.stop()
        session.trimmerDocument = editor.document
        session.trimmerExporting = true
        exportProgress = 0
        let document = editor.document
        var urls: [String: URL] = [:]
        var names: [String: String] = [:]
        for clip in document.clips {
            names[clip.assetID] = name(for: clip.assetID)
            if let fileURL = url(for: clip.assetID) {
                urls[clip.assetID] = fileURL
            }
        }
        let box = TrimmerExporter.ProgressBox()
        let job = Task.detached {
            try TrimmerExporter.export(document: document, urls: urls, names: names) { box.set($0) }
        }
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                exportProgress = box.get()
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        Task { @MainActor in
            do {
                let outcome = try await job.value
                poll.cancel()
                finishExport(outcome)
            } catch {
                poll.cancel()
                session.trimmerExporting = false
                exportProgress = nil
                session.alertMessage = error.localizedDescription
            }
        }
    }

    private func finishExport(_ outcome: TrimmerExporter.Outcome) {
        let episode = session.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (episode.isEmpty ? "Episode" : episode) + " – Cut"
        do {
            let asset = try session.importTrimmerResult(from: outcome.fileURL, displayName: title)
            if let package = session.package, let audioURL = try? package.resolvedURL(for: asset) {
                let chaptersURL = audioURL.deletingLastPathComponent().appendingPathComponent(
                    audioURL.deletingPathExtension().lastPathComponent + " chapters.txt"
                )
                let text = TrimmerChapters.text(markers: editor.document.markers)
                try? Data(text.utf8).write(to: chaptersURL, options: .atomic)
            }
            try? FileManager.default.removeItem(at: outcome.fileURL)
            session.trimmerExporting = false
            exportProgress = nil
            if outcome.peak > 1 {
                session.alertMessage = "This cut peaks at \(TrimmerGain.peakDecibels(outcome.peak)), above 0 dB. It was saved as a 32-bit float file so nothing was clipped. TheRoof sets the final level."
            }
            session.selectedAssetID = asset.id
            session.openWorkspace(.limiter)
        } catch {
            session.trimmerExporting = false
            exportProgress = nil
            try? FileManager.default.removeItem(at: outcome.fileURL)
            session.alertMessage = error.localizedDescription
        }
    }

    private func fit(width: CGFloat) {
        let pps = TrimmerViewport.fitPixelsPerSecond(of: shown, width: Double(max(1, width)))
        pixelsPerSecond = CGFloat(pps)
    }

    private func zoom(by factor: CGFloat) {
        userAdjustedZoom = true
        let fitPPS = TrimmerViewport.fitPixelsPerSecond(of: shown, width: Double(max(1, viewportWidth)))
        let next = TrimmerViewport.zoom(
            pixelsPerSecond: Double(pixelsPerSecond),
            by: Double(factor),
            fitPixelsPerSecond: fitPPS
        )
        pixelsPerSecond = CGFloat(next)
    }

    private func url(for assetID: String) -> URL? {
        guard let package = session.package,
              let asset = session.assets.first(where: { $0.id == assetID }),
              session.health(of: asset) == .present
        else { return nil }
        return try? package.resolvedURL(for: asset)
    }

    private func name(for assetID: String) -> String {
        session.assets.first { $0.id == assetID }?.displayName ?? "Clip"
    }

    private func trackColor(_ track: TrimmerTrackID) -> Color {
        switch track {
        case .episodeMix: LoungeTheme.cyan
        case .introsOutrosAds: LoungeTheme.original
        case .musicBeds: LoungeTheme.result
        }
    }

    private func dbLabel(_ value: Double) -> String {
        if abs(value) < 0.05 { return "0 dB" }
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            let number = Int(rounded)
            if number < 0 { return "−\(abs(number)) dB" }
            return "\(number) dB"
        }
        return String(format: "%+.1f dB", value)
    }

    private func clock(_ seconds: Double, tenths: Bool) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = clamped - Double(hours * 3600 + minutes * 60)
        if hours > 0 {
            if tenths { return String(format: "%d:%02d:%04.1f", hours, minutes, secs) }
            return String(format: "%d:%02d:%02d", hours, minutes, Int(secs))
        }
        if tenths { return String(format: "%d:%04.1f", minutes, secs) }
        return String(format: "%d:%02d", minutes, Int(secs.rounded(.down)))
    }

    private func tickStep() -> Double {
        let raw = Double(80 / max(pixelsPerSecond, 1))
        let steps = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        return steps.first { $0 >= raw } ?? 1800
    }

    private func tickTimes(step: Double, through width: CGFloat) -> [Double] {
        guard step > 0, pixelsPerSecond > 0 else { return [0] }
        let end = Double(width / pixelsPerSecond)
        var times: [Double] = []
        var time = 0.0
        let minor = step / 2
        while time <= end + 0.001 {
            times.append(time)
            time += minor
            if times.count > 4_000 { break }
        }
        return times
    }

    private func overlapPairs(_ clips: [TrimmerClip]) -> [OverlapPair] {
        var pairs: [OverlapPair] = []
        for left in clips {
            for right in clips where right.id != left.id && right.start >= left.start {
                let start = max(left.start, right.start)
                let end = min(left.end, right.end)
                guard end - start > TrimmerDocument.epsilon else { continue }
                pairs.append(OverlapPair(id: "\(left.id.uuidString)-\(right.id.uuidString)", start: start, length: end - start))
            }
        }
        return pairs
    }
}

private struct FollowDrag: ViewModifier {
    var minimum: CGFloat
    var onEnded: (CGSize) -> Void
    @GestureState private var translation: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .offset(translation)
            .highPriorityGesture(
                DragGesture(minimumDistance: minimum)
                    .updating($translation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { onEnded($0.translation) }
            )
    }
}

private struct PendingDepotDrop: Equatable {
    var assetID: String
    var track: TrimmerTrackID
    var x: CGFloat
    var token: UUID
}

private struct CutRange: Equatable {
    var track: TrimmerTrackID
    var start: Double
    var end: Double
    var range: TrimmerTimeRange { TrimmerTimeRange(start: start, end: end) }
}

private struct PendingCut: Equatable {
    var range: TrimmerTimeRange
    var track: TrimmerTrackID
}

private enum CutDrag {
    case move
    case trim(TrimmerEdge)
    case fade(TrimmerFadeEdge)
}

private struct OverlapPair: Identifiable {
    var id: String
    var start: Double
    var length: Double
}

private struct PlayheadCap: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct ClipDragPreview: Equatable {
    var clipID: UUID
    var kind: CutHitKind
    var dx: CGFloat
    var dy: CGFloat
}

private struct CutWaveform: View {
    var assetID: String
    var url: URL?
    var color: Color
    var inOffset: Double
    var length: Double
    var sourceDuration: Double?
    @State private var pyramid = WaveformPyramid.empty
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            guard size.width > 1, size.height > 1 else { return }
            let mid = size.height / 2
            let columns = max(1, Int((size.width * max(1, displayScale)).rounded(.up)))
            let pairs = columnPairs(columns: columns)
            guard pairs.contains(where: { $0.0 != 0 || $0.1 != 0 }) else {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: mid))
                line.addLine(to: CGPoint(x: size.width, y: mid))
                context.stroke(line, with: .color(color.opacity(0.35)), lineWidth: 1)
                return
            }
            let step = size.width / CGFloat(pairs.count)
            var path = Path()
            path.move(to: CGPoint(x: step * 0.5, y: mid - CGFloat(pairs[0].1) * mid))
            for (index, pair) in pairs.enumerated() where index > 0 {
                path.addLine(to: CGPoint(x: (CGFloat(index) + 0.5) * step, y: mid - CGFloat(pair.1) * mid))
            }
            for (index, pair) in pairs.enumerated().reversed() {
                path.addLine(to: CGPoint(x: (CGFloat(index) + 0.5) * step, y: mid - CGFloat(pair.0) * mid))
            }
            path.closeSubpath()
            context.fill(path, with: .color(color.opacity(0.92)))
        }
        .task(id: assetID) {
            guard let url else { return }
            pyramid = await TrimmerWaveformCache.shared.pyramid(assetID: assetID, url: url)
        }
    }

    private func columnPairs(columns: Int) -> [(Float, Float)] {
        guard pyramid.sampleRate > 0, pyramid.totalFrames > 0 else { return [] }
        let start = Int((inOffset * pyramid.sampleRate).rounded(.down))
        var end = Int(((inOffset + length) * pyramid.sampleRate).rounded(.down))
        if let sourceDuration, sourceDuration > 0 {
            end = min(end, Int((sourceDuration * pyramid.sampleRate).rounded(.down)))
        }
        let span = max(1, end - start)
        return pyramid.columns(startFrame: start, frameCount: span, count: columns)
    }
}

/// Straight fade, the way Ableton draws one: a line from the corner box down to the clip's bottom corner.
private struct CutFadeOverlay: View {
    var fadeIn: Double
    var fadeOut: Double
    var length: Double
    var tint: Color

    var body: some View {
        Canvas { context, size in
            guard length > 0.000_1, size.width > 1, size.height > 1 else { return }
            let inX = CGFloat(fadeIn / length) * size.width
            let outX = size.width - CGFloat(fadeOut / length) * size.width
            draw(context: context, size: size, boundary: inX, leading: true)
            draw(context: context, size: size, boundary: outX, leading: false)
        }
        .allowsHitTesting(false)
    }

    private func draw(context: GraphicsContext, size: CGSize, boundary: CGFloat, leading: Bool) {
        let span = leading ? boundary : size.width - boundary
        guard span > 0.5 else { return }
        var shade = Path()
        if leading {
            shade.move(to: CGPoint(x: 0, y: 0))
            shade.addLine(to: CGPoint(x: boundary, y: 0))
            shade.addLine(to: CGPoint(x: 0, y: size.height))
        } else {
            shade.move(to: CGPoint(x: size.width, y: 0))
            shade.addLine(to: CGPoint(x: boundary, y: 0))
            shade.addLine(to: CGPoint(x: size.width, y: size.height))
        }
        shade.closeSubpath()
        context.fill(shade, with: .color(tint.opacity(0.50)))
        context.fill(shade, with: .color(Color.black.opacity(0.30)))
        var line = Path()
        line.move(to: CGPoint(x: boundary, y: 0))
        line.addLine(to: CGPoint(x: leading ? 0 : size.width, y: size.height))
        context.stroke(line, with: .color(.white.opacity(0.92)), lineWidth: 1.25)
    }
}

/// Colors copied from TheDecks' channel strip. TheDecks itself is left alone.
private enum CutStripChrome {
    static let cyan = Color(red: 0.20, green: 0.92, blue: 0.95)
    static let cyanDim = Color(red: 0.20, green: 0.92, blue: 0.95).opacity(0.55)
    static let lime = Color(red: 0.78, green: 0.95, blue: 0.20)
    static let meterGreen = Color(red: 0.25, green: 0.90, blue: 0.55)
    static let meterYellow = Color(red: 0.95, green: 0.85, blue: 0.20)
    static let meterRed = Color(red: 1.0, green: 0.30, blue: 0.35)
    static let top = Color(red: 0.12, green: 0.15, blue: 0.18)
    static let bottom = Color(red: 0.065, green: 0.085, blue: 0.105)
}

private enum CutBevelKind {
    case off, mute, solo

    var text: Color {
        switch self {
        case .off: Color(white: 0.86)
        default: Color(white: 0.06)
        }
    }

    var top: Color {
        switch self {
        case .off: Color(white: 0.26)
        case .mute: Color(red: 1.0, green: 0.62, blue: 0.55)
        case .solo: Color(red: 1.0, green: 0.95, blue: 0.55)
        }
    }

    var bottom: Color {
        switch self {
        case .off: Color(white: 0.12)
        case .mute: Color(red: 0.78, green: 0.18, blue: 0.16)
        case .solo: Color(red: 0.78, green: 0.64, blue: 0.08)
        }
    }

    var glow: Color {
        switch self {
        case .off: .clear
        case .mute: Color(red: 1.0, green: 0.35, blue: 0.38)
        case .solo: CutStripChrome.meterYellow
        }
    }
}

/// Horizontal L/R meter. Same thresholds as TheDecks' strip LEDs: red at 0 dB, yellow above −12 dB, green below.
private struct CutLEDMeter: View {
    var level: Float
    var hold: Float

    var body: some View {
        GeometryReader { geo in
            let fraction = Self.fraction(level)
            let holdFraction = Self.fraction(hold)
            let inset: CGFloat = 1
            let innerW = max(4, geo.size.width - inset * 2)
            let count = max(8, Int((innerW / 3.2).rounded()))
            let gap: CGFloat = 1
            let segW = max(1, (innerW - gap * CGFloat(count - 1)) / CGFloat(count))
            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                HStack(spacing: gap) {
                    ForEach(0..<count, id: \.self) { index in
                        let start = CGFloat(index) / CGFloat(count)
                        let end = CGFloat(index + 1) / CGFloat(count)
                        let on = fraction > start + 0.000_1
                        let held = holdFraction >= start && holdFraction < end
                        let color = Self.segmentColor(end)
                        RoundedRectangle(cornerRadius: 0.4, style: .continuous)
                            .fill(on || held ? color : Color(white: 0.09))
                            .frame(width: segW)
                            .shadow(color: (on || held) ? color.opacity(0.65) : .clear, radius: (on || held) ? 1.1 : 0)
                    }
                }
                .padding(inset)
            }
        }
    }

    private static func fraction(_ level: Float) -> CGFloat {
        guard level > 1e-5, level.isFinite else { return 0 }
        let db = 20 * log10(Double(level))
        return CGFloat(max(0, min(1, (db + 60) / 60)))
    }

    private static func segmentColor(_ endNorm: CGFloat) -> Color {
        if endNorm >= 1 { return CutStripChrome.meterRed }
        if endNorm > 0.8 { return CutStripChrome.meterYellow }
        return CutStripChrome.meterGreen
    }
}
