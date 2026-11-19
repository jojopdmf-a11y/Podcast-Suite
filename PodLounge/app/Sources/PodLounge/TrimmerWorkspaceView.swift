import AppKit
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
    @State private var scrollBridge = CutScrollBridge()

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
        .background(
            CutZoomKeyHost(
                editingMarker: editingMarkerID != nil,
                onZoomIn: { zoom(by: TrimmerViewport.zoomFactor) },
                onZoomOut: { zoom(by: 1 / TrimmerViewport.zoomFactor) }
            )
        )
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
            Button("Add Marker") { addMarker() }
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
            Button("Export → TheValet & open TheRoof") { exportCut() }
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
                    .background(CutScrollSpy(bridge: scrollBridge))
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
        .background {
            CutTimelineGestureHost(
                onZoom: { zoom(by: CGFloat($0)) },
                onNudge: { scrollBridge.nudge(by: $0) }
            )
        }
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
        let level = max(reading.left, reading.right)
        let hold = max(reading.holdLeft, reading.holdRight)
        return VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 0) {
                Text(track.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(selected ? CutStripChrome.lime : CutStripChrome.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("STEREO")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(CutStripChrome.cyanDim)
            }
            HStack(alignment: .top, spacing: 6) {
                CutConsoleFader(
                    value: gain,
                    enabled: session.trimmerExporting == false,
                    onLive: { newValue in
                        faderDraft[track] = newValue
                        var live = shown
                        live = live.settingTrack(track, gainDB: newValue)
                        transport.applyMix(live)
                    },
                    onCommit: { value in
                        faderDraft[track] = nil
                        commitMix("Track Level") { $0 = $0.settingTrack(track, gainDB: value) }
                    },
                    onReset: {
                        guard abs(shown.trackState(track).gainDB) > 0.05 else { return }
                        faderDraft[track] = nil
                        commitMix("Track Level") { $0 = $0.settingTrack(track, gainDB: TrimmerFaderDrag.unityDB) }
                    }
                )
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("thecut.fader.\(track.rawValue)")
                VStack(spacing: 0) {
                    Color.clear.frame(height: CutConsoleFader.readoutHeight)
                    CutVerticalLEDMeter(level: level, hold: hold)
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 8)
                .frame(maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Level")
                .accessibilityIdentifier("thecut.meter.\(track.rawValue)")
                VStack(spacing: 3) {
                    Color.clear.frame(height: CutConsoleFader.readoutHeight)
                    msButton("M", lit: state.muted, kind: .mute) {
                        commitMix("Mute") { $0 = $0.settingTrack(track, muted: !state.muted) }
                    }
                    .help("Mute")
                    msButton("S", lit: state.solo, kind: .solo) {
                        commitMix("Solo") { $0 = $0.settingTrack(track, solo: !state.solo) }
                    }
                    .help("Solo")
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ruler(width: width, height: rulerHeight)
                markerLane(width: width, height: markerHeight)
                ForEach(TrimmerTrackID.allCases) { track in
                    lane(track, width: width, height: laneHeight, laneHeight: laneHeight)
                }
            }
            playhead(height: rulerHeight + markerHeight + laneHeight * 3)
            if shown.clips.isEmpty {
                Text("Drag an item from TheValet onto a track.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LoungeTheme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func ruler(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            LoungeTheme.backgroundRaised
            CutRulerMarks(pixelsPerSecond: pixelsPerSecond)
                .frame(width: width, height: height)
                .allowsHitTesting(false)
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
                TextField("Marker", text: $editingTitle, onCommit: commitMarkerTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 90)
            } else {
                Text(marker.title.isEmpty ? "Marker" : marker.title)
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
            commit("Move Marker") { $0 = $0.movingMarker(id: marker.id, to: time) }
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

    private func lane(_ track: TrimmerTrackID, width: CGFloat, height: CGFloat, laneHeight: CGFloat) -> some View {
        let clips = shown.clips.filter { $0.track == track }.sorted { $0.start < $1.start }
        return ZStack(alignment: .topLeading) {
            Color(red: 0.03, green: 0.055, blue: 0.075)
            CutLaneGrid(pixelsPerSecond: pixelsPerSecond)
                .frame(width: width, height: height)
                .allowsHitTesting(false)
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
                },
                onResetCurve: { kind in
                    guard kind == .fadeIn || kind == .fadeOut else { return }
                    let edge: TrimmerFadeEdge = kind == .fadeIn ? .fadeIn : .fadeOut
                    clipDrag = nil
                    commit("Fade") { $0 = $0.resettingFadeCurve(clipID: clip.id, edge: edge) }
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
            CutClipCanvas(
                assetID: clip.assetID,
                url: url(for: clip.assetID),
                track: clip.track,
                inOffset: clip.inOffset,
                length: clip.length,
                sourceDuration: clip.sourceDuration,
                pixelsPerSecond: pixelsPerSecond,
                fadeIn: clip.fadeIn,
                fadeOut: clip.fadeOut,
                fadeInCurve: clip.fadeInCurve,
                fadeOutCurve: clip.fadeOutCurve
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
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
                Text("Close the gap pulls everything later on this track forward, and moves clips on the other tracks that start after the cut, so ads and outros stay in sync with the mix. Markers after the cut move too. Leave a gap keeps the silence.")
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
            let curve = TrimmerFadeCurve.bent(clip.fadeInCurve, upPoints: -Double(drag.dy))
            return shown.settingFade(clipID: clip.id, edge: .fadeIn, seconds: seconds, curve: curve).clip(clip.id) ?? clip
        case .fadeOut:
            let seconds = clip.fadeOut - Double(drag.dx / pixelsPerSecond)
            let curve = TrimmerFadeCurve.bent(clip.fadeOutCurve, upPoints: -Double(drag.dy))
            return shown.settingFade(clipID: clip.id, edge: .fadeOut, seconds: seconds, curve: curve).clip(clip.id) ?? clip
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
            commit("Delete Marker") { $0 = $0.removingMarkers(ids: [id]) }
            selectedMarkerID = nil
        }
    }

    private func confirmDelete(_ mode: TrimmerDeleteMode, pending: PendingCut) {
        commit("Delete") { $0 = $0.deleting(range: pending.range, on: pending.track, mode: mode) }
        pendingDelete = nil
        rangeSelection = nil
        selectedClipID = nil
    }

    private func addMarker() {
        let title = shown.suggestedChapterTitle()
        commit("Add Marker") { $0 = $0.addingMarker(at: transport.playhead, title: title) }
    }

    private func commitMarkerTitle() {
        guard let id = editingMarkerID else { return }
        let title = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        commit("Rename Marker") { $0 = $0.renamingMarker(id: id, title: title.isEmpty ? "Marker" : title) }
        editingMarkerID = nil
    }

    private func place(assetID: String, on track: TrimmerTrackID, at time: Double) {
        guard let asset = session.assets.first(where: { $0.id == assetID }) else { return }
        guard session.health(of: asset) == .present, let fileURL = url(for: assetID) else {
            session.alertMessage = "That file is missing from TheValet."
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
            let currentCurve = edge == .fadeIn ? clip.fadeInCurve : clip.fadeOutCurve
            let delta = edge == .fadeIn ? seconds : -seconds
            // dy is positive when the pointer moves down. Up bends the fade toward a fast start.
            let curve = TrimmerFadeCurve.bent(currentCurve, upPoints: -Double(translation.height))
            label = "Fade"
            next = shown.settingFade(clipID: clip.id, edge: edge, seconds: current + delta, curve: curve)
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

    private func contentSpan() -> Double {
        max(TrimmerViewport.fitEnd(of: shown), shown.timelineEnd, transport.playhead)
    }

    private func fit(width: CGFloat) {
        let pps = TrimmerViewport.fitPixelsPerSecond(of: shown, width: Double(max(1, width)))
        pixelsPerSecond = CGFloat(pps)
        scrollBridge.pin(to: 0)
    }

    private func zoom(by factor: CGFloat) {
        userAdjustedZoom = true
        let fitPPS = TrimmerViewport.fitPixelsPerSecond(of: shown, width: Double(max(1, viewportWidth)))
        let next = TrimmerViewport.zoom(
            pixelsPerSecond: Double(pixelsPerSecond),
            by: Double(factor),
            fitPixelsPerSecond: fitPPS
        )
        let newPPS = CGFloat(next)
        guard abs(newPPS - pixelsPerSecond) > 0.000_1 else { return }
        let target = TrimmerViewport.zoomedScroll(
            scrollX: Double(scrollBridge.x),
            viewportWidth: Double(max(1, viewportWidth)),
            pixelsPerSecond: Double(pixelsPerSecond),
            nextPixelsPerSecond: Double(newPPS),
            playhead: transport.playhead,
            contentSpan: contentSpan()
        )
        pixelsPerSecond = newPPS
        scrollBridge.pin(to: CGFloat(target))
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

/// One stereo meter for a track. Same thresholds as TheDecks' strip LEDs: red at 0 dB, yellow above −12 dB, green below.
private struct CutVerticalLEDMeter: View {
    var level: Float
    var hold: Float

    var body: some View {
        GeometryReader { geo in
            let fraction = Self.fraction(level)
            let holdFraction = Self.fraction(hold)
            let inset: CGFloat = 1
            let innerH = max(4, geo.size.height - inset * 2)
            let count = max(6, Int((innerH / 3.2).rounded()))
            let gap: CGFloat = 1
            let segH = max(1, (innerH - gap * CGFloat(count - 1)) / CGFloat(count))
            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                VStack(spacing: gap) {
                    ForEach(0..<count, id: \.self) { index in
                        let top = CGFloat(count - index) / CGFloat(count)
                        let bottom = CGFloat(count - 1 - index) / CGFloat(count)
                        let on = fraction > bottom + 0.000_1
                        let held = holdFraction >= bottom && holdFraction < top
                        let color = Self.segmentColor(top)
                        RoundedRectangle(cornerRadius: 0.4, style: .continuous)
                            .fill(on || held ? color : Color(white: 0.09))
                            .frame(height: segH)
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

/// Short TheDecks-style fader. The range matches the slider it replaces. Option slows the drag.
private struct CutConsoleFader: View {
    static let readoutHeight: CGFloat = 12
    var value: Double
    var enabled: Bool
    var onLive: (Double) -> Void
    var onCommit: (Double) -> Void
    var onReset: () -> Void

    private var shown: Double { TrimmerFaderDrag.clamped(value) }

    var body: some View {
        VStack(spacing: 1) {
            Text(readout(value))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(CutStripChrome.cyan)
                .frame(height: Self.readoutHeight)
                .frame(maxWidth: .infinity)
            GeometryReader { geo in
                let slot = geo.size.height
                ZStack {
                    slotWell(height: slot)
                    ticks(height: slot)
                    cap
                        .frame(width: 22, height: capHeight(slot))
                        .position(x: geo.size.width / 2, y: capCenter(slot: slot))
                        .allowsHitTesting(false)
                    CutFaderHit(
                        enabled: enabled,
                        origin: shown,
                        onLive: onLive,
                        onCommit: onCommit,
                        onReset: onReset
                    )
                }
            }
        }
        .frame(width: 34)
        .help("Drag to set the level. Hold Option to move slowly. Double-click for 0 dB.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level")
        .accessibilityValue(readout(value))
    }

    private func readout(_ decibels: Double) -> String {
        let shown = decibels.isFinite ? decibels : 0
        return String(format: "%+.0f", shown.rounded())
    }

    private func capHeight(_ slot: CGFloat) -> CGFloat {
        min(16, max(8, slot * 0.32))
    }

    private func capCenter(slot: CGFloat) -> CGFloat {
        let span = TrimmerFaderDrag.maximumDB - TrimmerFaderDrag.minimumDB
        let fraction = (shown - TrimmerFaderDrag.minimumDB) / span
        let cap = capHeight(slot)
        let travel = max(1, slot - cap)
        return (1 - fraction) * travel + cap / 2
    }

    private func slotWell(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.05), Color(white: 0.015), Color(white: 0.06)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.black.opacity(0.92))
                    .frame(width: 4, height: max(4, height - 6))
            }
            .allowsHitTesting(false)
    }

    private func ticks(height: CGFloat) -> some View {
        let marks: [Double] = [12, 0, -12, -24]
        return ZStack {
            ForEach(marks, id: \.self) { mark in
                let y = tickY(mark, slot: height)
                Capsule()
                    .fill(Color.white.opacity(mark == 0 ? 0.40 : 0.16))
                    .frame(width: 3, height: 1)
                    .position(x: 3, y: y)
                Capsule()
                    .fill(Color.white.opacity(mark == 0 ? 0.40 : 0.16))
                    .frame(width: 3, height: 1)
                    .position(x: 31, y: y)
            }
        }
        .allowsHitTesting(false)
    }

    private func tickY(_ decibels: Double, slot: CGFloat) -> CGFloat {
        let span = TrimmerFaderDrag.maximumDB - TrimmerFaderDrag.minimumDB
        let fraction = (decibels - TrimmerFaderDrag.minimumDB) / span
        let cap = capHeight(slot)
        let travel = max(1, slot - cap)
        return (1 - fraction) * travel + cap / 2
    }

    private var cap: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.84),
                            Color(white: 0.64),
                            Color(white: 0.42),
                            Color(white: 0.56),
                            Color(white: 0.34),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.75), Color.black.opacity(0.45)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.7
                        )
                )
            Rectangle()
                .fill(CutStripChrome.cyan.opacity(0.95))
                .frame(height: 1.3)
                .padding(.horizontal, 3)
        }
        .shadow(color: .black.opacity(0.55), radius: 1.5, y: 1)
    }
}

private struct CutFaderHit: NSViewRepresentable {
    var enabled: Bool
    var origin: Double
    var onLive: (Double) -> Void
    var onCommit: (Double) -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> CutFaderNSView {
        let view = CutFaderNSView()
        view.enabled = enabled
        view.origin = origin
        view.onLive = onLive
        view.onCommit = onCommit
        view.onReset = onReset
        return view
    }

    func updateNSView(_ view: CutFaderNSView, context: Context) {
        view.enabled = enabled
        view.onLive = onLive
        view.onCommit = onCommit
        view.onReset = onReset
        if view.tracking == false {
            view.origin = origin
        }
    }
}

private final class CutFaderNSView: NSView {
    var enabled = true
    var origin = 0.0
    var onLive: (Double) -> Void = { _ in }
    var onCommit: (Double) -> Void = { _ in }
    var onReset: () -> Void = {}
    var tracking = false

    private var down = NSPoint.zero
    private var drag = TrimmerFineDrag()
    private var moved = false

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        if event.clickCount >= 2 {
            tracking = false
            onReset()
            return
        }
        down = convert(event.locationInWindow, from: nil)
        drag = TrimmerFineDrag()
        moved = false
        tracking = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard enabled, tracking else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rawUp = point.y - down.y
        drag.advance(rawX: 0, rawY: Double(rawUp), fine: event.modifierFlags.contains(.option))
        guard abs(rawUp) >= 1 || moved else { return }
        moved = true
        onLive(level)
    }

    override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        tracking = false
        guard enabled, moved else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rawUp = point.y - down.y
        drag.advance(rawX: 0, rawY: Double(rawUp), fine: event.modifierFlags.contains(.option))
        onCommit(level)
    }

    private var level: Double {
        TrimmerFaderDrag.decibels(from: origin, upwardPoints: drag.y, travel: Double(max(bounds.height, 1)))
    }
}
