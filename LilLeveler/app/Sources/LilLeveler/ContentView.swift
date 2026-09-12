import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var session = LevelerSession()
    @State private var isDropTargeted = false
    @State private var showAbout = false

    var body: some View {
        ZStack {
            LevelerTheme.windowBackground.ignoresSafeArea()
            RadialGradient(
                colors: [LevelerTheme.cyan.opacity(0.06), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 480
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                header
                if session.sourceURL == nil {
                    dropZone
                } else {
                    mainWorkspace
                }
                statusBar
            }
            .padding(LevelerLayout.windowPadding)
        }
        .frame(width: LevelerLayout.windowWidth, height: LevelerLayout.windowHeight)
        .preferredColorScheme(.dark)
        .onDisappear { session.stopPlayback() }
        .onReceive(NotificationCenter.default.publisher(for: .cougarCalcShowAbout)) { _ in
            showAbout = true
        }
        .sheet(isPresented: $showAbout) {
            AboutSupportPanel(
                appName: "Lil Leveler",
                tagline: "Final mix → platform loudness",
                accent: LevelerTheme.cyan
            )
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("LIL LEVELER")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(LevelerTheme.cyan)
                    .shadow(color: LevelerTheme.cyan.opacity(0.4), radius: 10)
                Text("Final mix → platform loudness")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(LevelerTheme.textSecondary)
                Text("\(CougarCalcBrand.company) · \(CougarCalcBrand.versionLabel)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(LevelerTheme.textSecondary.opacity(0.85))
            }
            Spacer()
            Button("ABOUT") { showAbout = true }
                .buttonStyle(LevelerGhostButtonStyle())
            if session.sourceURL != nil {
                Button("LOAD OTHER…") { pickFile() }
                    .buttonStyle(LevelerGhostButtonStyle())
            }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LevelerTheme.panel)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isDropTargeted ? LevelerTheme.lime : LevelerTheme.cyan.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1.4, dash: [7, 6])
                )
                .shadow(color: LevelerTheme.cyan.opacity(0.35), radius: 8)
            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(LevelerTheme.cyan)
                Text("DROP FINAL MIX")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(LevelerTheme.textPrimary)
                Text("WAV, AIFF, MP3, M4A, CAF, FLAC… · export stays WAV")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(LevelerTheme.textSecondary)
                Button("CHOOSE FILE…") { pickFile() }
                    .buttonStyle(LevelerPrimaryButtonStyle())
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var mainWorkspace: some View {
        HStack(alignment: .top, spacing: LevelerLayout.columnGap) {
            presetColumn
                .frame(width: LevelerLayout.presetColumnWidth)

            VStack(alignment: .leading, spacing: 12) {
                fileRow
                DorroughMeterDeck(session: session)
                LoudnessStrip(
                    before: session.before,
                    after: session.after,
                    gainDb: session.appliedGainDb,
                    hasResult: session.hasResult
                )
                transportRow
            }
            .frame(width: LevelerLayout.meterDeckWidth, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var presetColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PLATFORM")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(LevelerTheme.cyanDim)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.listedPresets) { p in
                        HStack(spacing: 6) {
                            Button {
                                session.selectPreset(p)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(session.preset.id == p.id ? LevelerTheme.bgBottom : LevelerTheme.cyan)
                                    Text(p.subtitle)
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundStyle(session.preset.id == p.id ? LevelerTheme.bgBottom.opacity(0.75) : LevelerTheme.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(session.preset.id == p.id ? LevelerTheme.lime : LevelerTheme.panelRaised)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(LevelerTheme.cyan.opacity(0.4), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)

                            if UserLoudnessPreset.isUserID(p.id) {
                                Button("✕") {
                                    session.deleteUserPreset(p.id)
                                }
                                .buttonStyle(LevelerGhostButtonStyle())
                                .help("Remove this personal preset")
                            }
                        }
                    }

                    if session.preset.isCustom {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TARGET LUFS  \(String(format: "%.1f", session.customLUFS))")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(LevelerTheme.cyan)
                            Slider(value: Binding(
                                get: { Double(session.customLUFS) },
                                set: { session.customLUFS = Float($0) }
                            ), in: -24...(-10))
                            .tint(LevelerTheme.cyan)
                            .onChange(of: session.customLUFS) { _, _ in session.process() }

                            Text("TRUE PEAK  \(String(format: "%.1f", session.customTP)) dBTP")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(LevelerTheme.cyan)
                            Slider(value: Binding(
                                get: { Double(session.customTP) },
                                set: { session.customTP = Float($0) }
                            ), in: -3...(-0.1))
                            .tint(LevelerTheme.lime)
                            .onChange(of: session.customTP) { _, _ in session.process() }

                            Button("SAVE PRESET") { promptSavePreset() }
                                .buttonStyle(LevelerGhostButtonStyle())
                                .help("Keep these LUFS / true-peak numbers in the PLATFORM list")
                        }
                        .padding(.top, 4)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .levelerPanel(glow: true)
    }

    private var fileRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SOURCE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(LevelerTheme.cyanDim)
                Text(session.sourceName)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(LevelerTheme.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            if session.hasResult {
                Text(String(format: "GAIN %+.1f dB", session.appliedGainDb))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(LevelerTheme.lime)
            }
        }
        .padding(12)
        .levelerPanel()
    }

    private var transportRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(session.isPlaying ? "PAUSE" : "PLAY") {
                    session.togglePlayback()
                }
                .buttonStyle(LevelerPrimaryButtonStyle())
                .keyboardShortcut(.space, modifiers: [])
                .disabled(session.sourceURL == nil)
                .help("Spacebar toggles play/pause")

                Text(LevelerSession.formatTime(seconds: session.playheadSeconds))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(LevelerTheme.cyan)
                    .frame(minWidth: 44, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { session.playheadSeconds },
                        set: { session.scrub(to: $0) }
                    ),
                    in: 0...max(0.001, session.durationSeconds)
                ) { editing in
                    if editing {
                        session.isScrubbing = true
                    } else {
                        session.endScrub()
                    }
                }
                .tint(LevelerTheme.cyan)
                .disabled(session.sourceURL == nil || session.durationSeconds <= 0)

                Text(LevelerSession.formatTime(seconds: session.durationSeconds))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(LevelerTheme.textSecondary)
                    .frame(minWidth: 44, alignment: .leading)
            }

            HStack(spacing: 10) {
                Text("A/B")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(LevelerTheme.cyanDim)

                Picker("A/B", selection: Binding(
                    get: { session.playAfter },
                    set: { session.setListenPost($0) }
                )) {
                    Text("PRE").tag(false)
                    Text("POST").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(!session.hasResult)
                .help("PRE is the file you dropped. POST is after leveling. Time stays put when you flip.")

                Button("RE-LEVEL") { session.process() }
                    .buttonStyle(LevelerGhostButtonStyle())
                    .disabled(session.sourceURL == nil || session.isBusy)

                Spacer()

                Button(session.isBusy ? "WORKING…" : "EXPORT LEVELED") {
                    session.exportLeveled()
                }
                .buttonStyle(LevelerPrimaryButtonStyle())
                .disabled(!session.hasResult || session.isBusy)
            }
        }
        .padding(12)
        .levelerPanel()
    }

    private var statusBar: some View {
        Text(session.status)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(LevelerTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func promptSavePreset() {
        let alert = NSAlert()
        alert.messageText = "Name this loudness preset"
        alert.informativeText = String(
            format: "Keeps %.1f LUFS and %.1f dBTP in the PLATFORM list on this Mac.",
            session.customLUFS,
            session.customTP
        )
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "My show target"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            session.saveCustomAsPreset(name: field.stringValue)
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = AudioFileIO.importTypes // public.audio — includes MP3
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a podcast master (WAV, AIFF, MP3, M4A, CAF, FLAC…)"
        if panel.runModal() == .OK, let url = panel.url {
            session.load(url: url)
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
            Task { @MainActor in
                guard AudioFileIO.isSupportedAudioURL(url) else {
                    session.status = "Unsupported file type: .\(url.pathExtension)"
                    return
                }
                session.load(url: url)
            }
        }
        return true
    }
}
