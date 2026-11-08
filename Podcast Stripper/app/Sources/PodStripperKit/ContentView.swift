import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct StripperRootView: View {
    @ObservedObject var model: StripperLoungeModel
    @StateObject private var runner = EngineRunner()
    @State private var inputFile: URL?

    public init(model: StripperLoungeModel) {
        self.model = model
    }

    private var lounge: Bool { model.chrome == .lounge }

    private var activeInput: URL? {
        lounge ? model.inputURL : inputFile
    }
    @State private var outputFolder: URL?
    @State private var speakerCount: SpeakerCountChoice = .two
    @State private var exportSampleRate: ExportSampleRateChoice = .native
    @State private var exportAudioFormat: ExportAudioFormatChoice = .wav16
    @State private var showSettings = false
    @State private var showMacNeeds = false
    @State private var isDropTargeted = false

    public var body: some View {
        ZStack {
            StripperTheme.windowBackground.ignoresSafeArea()
            // Soft vignette / panel depth
            RadialGradient(
                colors: [StripperTheme.cyan.opacity(0.07), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 420
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: lounge ? 8 : 18) {
                header
                dropZone
                controlsPanel
                if lounge, model.namingVisible {
                    namingPanel
                }
                statusPanel
                if lounge, let warning = runner.musicFallbackWarning {
                    Text(warning)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(StripperTheme.lime)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("stripper.fallback")
                }
                if let result = runner.result {
                    resultRow(result)
                }
                if let error = runner.errorMessage {
                    errorPanel(error)
                }
                Spacer(minLength: 0)
                footerBrand
            }
            .padding(lounge ? 10 : 24)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            runner.refreshSetup()
            if lounge == false {
                restoreOutputFolder()
            }
        }
        .onChange(of: runner.isRunning) { _, running in
            if lounge {
                model.sourceLocked = running
                model.onRunningChange?(running)
            }
        }
        .onChange(of: runner.finishedToken) { _, _ in
            guard lounge, let result = runner.result else { return }
            model.onSplitFinished?(
                StripperFinishedJob(
                    outputDirectory: result.outputDir,
                    tracks: result.tracks,
                    speakersJSON: result.outputDir.appendingPathComponent("speakers.json"),
                    musicFallback: runner.musicFallbackWarning
                )
            )
        }
        .confirmationDialog("Discard this split?", isPresented: $model.askDiscardNaming, titleVisibility: .visible) {
            Button("Discard Split", role: .destructive) {
                model.onDiscardNaming?()
            }
            .accessibilityIdentifier("stripper.confirmDiscard")
            Button("Keep Naming", role: .cancel) {}
        } message: {
            Text("The new tracks are not in the depot yet. Closing removes this split.")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView {
                runner.refreshSetup()
            }
        }
        .sheet(isPresented: $showMacNeeds) {
            MacNeedsView(inputFile: inputFile)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PODSTRIPPER")
                    .font(.system(size: lounge ? 18 : 28, weight: .bold, design: .rounded))
                    .tracking(lounge ? 1.0 : 1.5)
                    .foregroundStyle(StripperTheme.cyan)
                    .shadow(color: StripperTheme.cyan.opacity(0.45), radius: 10)
                Text("Stereo Mix → Separate Speaker Tracks + Music / SFX")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(StripperTheme.textSecondary)
                Text("Version \(appVersion)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(StripperTheme.lime)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    showMacNeeds = true
                } label: {
                    Label("YOUR MAC", systemImage: "laptopcomputer")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(StripperGhostButtonStyle())
                .help("This Mac’s chip, RAM, and a scaled wait estimate")
                .accessibilityIdentifier("stripper.mac")
                Button {
                    showSettings = true
                } label: {
                    Label("SETTINGS", systemImage: "gearshape.fill")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(StripperGhostButtonStyle())
                .accessibilityIdentifier("stripper.settings")
            }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StripperTheme.panel)
            // Fake “waveform” atmosphere
            WaveformBackdrop()
                .opacity(isDropTargeted ? 0.55 : 0.28)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isDropTargeted ? StripperTheme.lime : StripperTheme.cyan.opacity(0.55),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: activeInput == nil ? [7, 6] : [])
                )
                .shadow(color: (isDropTargeted ? StripperTheme.lime : StripperTheme.cyan).opacity(0.4), radius: isDropTargeted ? 12 : 6)

            VStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: lounge ? 22 : 40, weight: .light))
                    .foregroundStyle(isDropTargeted ? StripperTheme.lime : StripperTheme.cyan)
                    .shadow(color: StripperTheme.cyan.opacity(0.5), radius: 8)
                if lounge {
                    if model.inputTitle.isEmpty {
                        Text("SELECT A DEPOT FILE")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(StripperTheme.textPrimary)
                        Text("Drop or choose a file to import it. Splitting starts only from the button.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(StripperTheme.textSecondary)
                    } else {
                        Text(model.inputTitle.uppercased())
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(StripperTheme.textPrimary)
                            .lineLimit(1)
                            .accessibilityIdentifier("stripper.input")
                        Text(model.inputDetail.isEmpty ? "Selected depot file" : model.inputDetail)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(StripperTheme.textSecondary)
                            .lineLimit(1)
                    }
                } else if let inputFile {
                    Text(inputFile.lastPathComponent.uppercased())
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(StripperTheme.textPrimary)
                        .lineLimit(1)
                    Text(inputFile.deletingLastPathComponent().path)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(StripperTheme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("DROP AUDIO HERE")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(StripperTheme.textPrimary)
                    Text("MP3 · M4A · WAV · AIFF · FLAC  ·  or click to choose")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(StripperTheme.textSecondary)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, minHeight: lounge ? 64 : 168)
        .onTapGesture {
            guard model.sourceLocked == false, runner.isRunning == false else { return }
            pickInput()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .animation(.easeOut(duration: 0.18), value: isDropTargeted)
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: lounge ? 8 : 16) {
            HStack(alignment: .center, spacing: 14) {
                Text("SPEAKERS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(StripperTheme.cyanDim)
                    .frame(width: 102, alignment: .leading)
                Picker("Speakers", selection: $speakerCount) {
                    ForEach(SpeakerCountChoice.allCases) { choice in
                        Text(choice == .auto ? "AUTO" : "\(choice.rawValue)").tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
            }

            HStack(alignment: .center, spacing: 14) {
                Text("SAMPLE RATE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(StripperTheme.cyanDim)
                    .frame(width: 102, alignment: .leading)
                Picker("Sample rate", selection: $exportSampleRate) {
                    ForEach(ExportSampleRateChoice.allCases) { choice in
                        Text(choice.rawValue.uppercased()).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                .help("Tracks are split at the file’s native rate. Convert only when writing the files.")
            }

            HStack(alignment: .center, spacing: 14) {
                Text("FORMAT")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(StripperTheme.cyanDim)
                    .frame(width: 102, alignment: .leading)
                Picker("Format", selection: $exportAudioFormat) {
                    ForEach(ExportAudioFormatChoice.allCases) { choice in
                        Text(choice.rawValue.uppercased()).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                .help("WAV 16-bit is the Mixer-friendly default. WAV 24-bit or AIFF 24-bit if your editor wants that.")
            }

            HStack(alignment: .center, spacing: 14) {
                Text("SAVE TO")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(StripperTheme.cyanDim)
                    .frame(width: 102, alignment: .leading)
                Text(saveToText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(StripperTheme.textSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("stripper.saveTo")
                Spacer(minLength: 8)
                if lounge, model.outsideFolder != nil {
                    Button("USE DEPOT") { model.onUseDepot?() }
                        .buttonStyle(StripperGhostButtonStyle())
                        .accessibilityIdentifier("stripper.useDepot")
                }
                Button("CHOOSE…") { pickOutput() }
                    .buttonStyle(StripperGhostButtonStyle())
                    .disabled(model.sourceLocked || runner.isRunning)
                    .accessibilityIdentifier("stripper.choose")
            }

            HStack(spacing: 12) {
                Button {
                    startSplit()
                } label: {
                    Text(splitButtonTitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .frame(minWidth: 180)
                }
                .buttonStyle(StripperPrimaryButtonStyle())
                .disabled(activeInput == nil || runner.isRunning || runner.isPreparingEngine || model.sourceLocked || (lounge && model.namingVisible))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("stripper.split")

                if runner.isRunning {
                    Button("CANCEL") { runner.cancel() }
                        .buttonStyle(StripperGhostButtonStyle())
                        .accessibilityIdentifier("stripper.cancel")
                }
            }
        }
        .padding(16)
        .stripperPanel()
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(StripperTheme.cyanFaint)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [StripperTheme.cyan, StripperTheme.lime.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * CGFloat(progressValue)))
                        .shadow(color: StripperTheme.cyan.opacity(0.55), radius: 6)
                        .animation(.linear(duration: 1.0), value: progressValue)
                }
            }
            .frame(height: 8)

            HStack(alignment: .firstTextBaseline) {
                Text(runner.message.uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(StripperTheme.textPrimary)
                Spacer(minLength: 8)
                if showElapsedClock {
                    Text(runner.elapsedLabel)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(StripperTheme.lime)
                        .help(runner.isRunning ? "Time so far" : "Time this job took")
                }
            }
            if runner.isRunning {
                Text(processingHint)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(StripperTheme.textSecondary)
            } else if runner.isPreparingEngine {
                Text("First open can take a few minutes and about 2 GB. Stay on Wi-Fi. Homebrew is not required.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(StripperTheme.textSecondary)
            } else if runner.result != nil, runner.elapsedSeconds > 0 {
                Text("Finished in \(runner.elapsedLabel).")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(StripperTheme.textSecondary)
            } else {
                Text(runner.setup.message)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(StripperTheme.textSecondary)
            }
        }
        .padding(16)
        .stripperPanel()
    }

    private var progressValue: Double {
        if runner.isPreparingEngine && !runner.isRunning {
            return 0.12
        }
        if runner.isRunning {
            return min(1, max(0.02, runner.percent / 100))
        }
        return runner.result == nil ? 0 : 1
    }

    private var splitButtonTitle: String {
        if runner.isRunning { return "WORKING…" }
        if runner.isPreparingEngine { return "INSTALLING ENGINE…" }
        return "SPLIT INTO TRACKS"
    }

    private var processingHint: String {
        let clock = runner.elapsedLabel
        if runner.engineProgressStale {
            return "No new progress for a while (\(clock)). You can cancel if this looks stuck."
        }
        return "Still working… \(clock). Long episodes can take several minutes."
    }

    private var showElapsedClock: Bool {
        runner.isRunning || runner.elapsedSeconds > 0
    }

    private func resultRow(_ result: EngineResult) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(StripperTheme.success)
            Text("\(result.tracks.count) TRACKS READY")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(StripperTheme.textPrimary)
            if runner.elapsedSeconds > 0 {
                Text("·")
                    .foregroundStyle(StripperTheme.textSecondary)
                Text(runner.elapsedLabel.uppercased())
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(StripperTheme.lime)
            }
            Spacer()
            Button("SHOW IN FINDER") {
                if lounge, let reveal = model.onShowInFinder {
                    reveal()
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputDir])
                }
            }
            .buttonStyle(StripperPrimaryButtonStyle(compact: true))
            .accessibilityIdentifier("stripper.showInFinder")
        }
        .padding(14)
        .stripperPanel(glow: true)
    }

    private func errorPanel(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SOMETHING WENT WRONG")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(StripperTheme.danger)
                Spacer()
                Button("COPY ERROR") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error, forType: .string)
                }
                .buttonStyle(StripperGhostButtonStyle())
                .accessibilityIdentifier("stripper.copyError")
            }
            ScrollView {
                Text(error)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(StripperTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: lounge ? 72 : 140)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StripperTheme.danger.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(StripperTheme.danger.opacity(0.5), lineWidth: 1)
        )
    }

    private var footerBrand: some View {
        HStack {
            Text("PODSTRIPPER")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(StripperTheme.cyanDim)
            Text("·")
                .foregroundStyle(StripperTheme.textSecondary)
            Text("LOCAL PROCESSING · NOTHING UPLOADED")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(StripperTheme.textSecondary)
            Spacer()
            Text("Version \(appVersion)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(StripperTheme.textSecondary)
        }
        .padding(.top, 4)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data, let loaded = URL(dataRepresentation: data, relativeTo: nil) {
                url = loaded
            } else if let loaded = item as? URL {
                url = loaded
            } else {
                url = nil
            }
            guard let url else { return }
            DispatchQueue.main.async {
                guard model.sourceLocked == false, runner.isRunning == false else { return }
                if lounge {
                    model.onImportExternal?(url)
                } else {
                    inputFile = url
                    if outputFolder == nil {
                        outputFolder = defaultOutput(for: url)
                    }
                }
            }
        }
        return true
    }

    private var saveToText: String {
        if lounge {
            return model.saveToLabel
        }
        return outputFolder?.path ?? "Same folder as the podcast · new _speakers folder"
    }

    private var namingPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAME THE NEW TRACKS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(StripperTheme.cyan)
            ForEach(model.namingRows.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Text(model.namingRows[index].roleLabel.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(StripperTheme.cyanDim)
                        .frame(width: 110, alignment: .leading)
                    TextField("Name", text: namingBinding(index))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(StripperTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(StripperTheme.panelRaised))
                        .accessibilityIdentifier("stripper.name.\(index)")
                        .accessibilityValue(model.namingRows[index].displayName)
                }
            }
            if let namingMessage = model.namingMessage, namingMessage.isEmpty == false {
                Text(namingMessage)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(StripperTheme.lime)
                    .accessibilityIdentifier("stripper.namingMessage")
            }
            HStack(spacing: 8) {
                Button("Add to Depot") { model.onAddToDepot?() }
                    .buttonStyle(StripperPrimaryButtonStyle(compact: true))
                    .accessibilityIdentifier("stripper.addToDepot")
                Button("Close") { model.askDiscardNaming = true }
                    .buttonStyle(StripperGhostButtonStyle())
                    .accessibilityIdentifier("stripper.closeNaming")
            }
        }
        .padding(10)
        .stripperPanel(glow: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stripper.naming")
    }

    private func namingBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard model.namingRows.indices.contains(index) else { return "" }
                return model.namingRows[index].displayName
            },
            set: { newValue in
                guard model.namingRows.indices.contains(index) else { return }
                model.namingRows[index].displayName = newValue
            }
        )
    }

    private func pickInput() {
        guard model.sourceLocked == false, runner.isRunning == false else { return }
        if lounge, StripperUITest.enabled {
            if let raw = StripperUITest.argument("-UITestStripperImport") {
                model.onImportExternal?(URL(fileURLWithPath: raw))
            }
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType.mp3, UTType.wav, UTType.aiff, UTType.mpeg4Audio, UTType(filenameExtension: "m4a"),
            UTType(filenameExtension: "flac"), UTType(filenameExtension: "caf"),
        ].compactMap { $0 }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if lounge {
                model.onImportExternal?(url)
            } else {
                inputFile = url
                if outputFolder == nil {
                    outputFolder = defaultOutput(for: url)
                }
            }
        }
    }

    private func pickOutput() {
        guard model.sourceLocked == false, runner.isRunning == false else { return }
        if lounge {
            if StripperUITest.enabled {
                if let raw = StripperUITest.argument("-UITestStripperOutside") {
                    model.onChooseOutsideFolder?()
                    _ = raw
                }
                return
            }
            model.onChooseOutsideFolder?()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            outputFolder = url
            UserDefaults.standard.set(url.path, forKey: "lastOutputFolder")
        }
    }

    private func startSplit() {
        guard let activeInput, !runner.isRunning, !runner.isPreparingEngine, model.sourceLocked == false else { return }
        if lounge {
            guard let make = model.makeStagingDirectory else { return }
            let dest: URL
            do {
                dest = try make()
            } catch {
                runner.errorMessage = error.localizedDescription
                return
            }
            model.activeStagingURL = dest
            model.namingVisible = false
            model.namingRows = []
            runner.split(
                input: activeInput,
                outputDir: dest,
                speakerCount: speakerCount,
                sampleRate: exportSampleRate,
                audioFormat: exportAudioFormat,
                cleanup: .ownedStaging
            )
            return
        }
        guard let inputFile else { return }
        let dest = outputFolder ?? defaultOutput(for: inputFile)
        outputFolder = dest
        UserDefaults.standard.set(dest.path, forKey: "lastOutputFolder")
        runner.split(
            input: inputFile,
            outputDir: dest,
            speakerCount: speakerCount,
            sampleRate: exportSampleRate,
            audioFormat: exportAudioFormat
        )
    }

    private func defaultOutput(for input: URL) -> URL {
        input.deletingLastPathComponent().appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)_speakers")
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func restoreOutputFolder() {
        if let path = UserDefaults.standard.string(forKey: "lastOutputFolder") {
            outputFolder = URL(fileURLWithPath: path)
        }
    }
}

// MARK: - Decorative waveform

private struct WaveformBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let midY = size.height * 0.55
            var path = Path()
            let steps = 64
            for i in 0 ... steps {
                let x = size.width * CGFloat(i) / CGFloat(steps)
                let phase = Double(i) * 0.45
                let amp = (sin(phase) * 0.35 + sin(phase * 2.3) * 0.2 + 0.15) * size.height * 0.35
                let y = midY - amp
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            for i in stride(from: steps, through: 0, by: -1) {
                let x = size.width * CGFloat(i) / CGFloat(steps)
                let phase = Double(i) * 0.45
                let amp = (sin(phase) * 0.35 + sin(phase * 2.3) * 0.2 + 0.15) * size.height * 0.35
                path.addLine(to: CGPoint(x: x, y: midY + amp))
            }
            path.closeSubpath()
            context.fill(path, with: .color(StripperTheme.cyan.opacity(0.22)))
        }
    }
}

// MARK: - Buttons

struct StripperPrimaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 8 : 11)
            .foregroundStyle(StripperTheme.bgBottom)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: configuration.isPressed
                                ? [StripperTheme.lime, StripperTheme.cyan]
                                : [StripperTheme.cyan, StripperTheme.cyan.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: StripperTheme.cyan.opacity(configuration.isPressed ? 0.2 : 0.55), radius: configuration.isPressed ? 4 : 10)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct StripperGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(configuration.isPressed ? StripperTheme.lime : StripperTheme.cyan)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(StripperTheme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(StripperTheme.cyan.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: StripperTheme.cyan.opacity(0.15), radius: 4)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var status = ""
    @State private var tokenAlreadySaved = false

    var body: some View {
        ZStack {
            StripperTheme.windowBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("HUGGING FACE TOKEN")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(StripperTheme.cyan)
                    .shadow(color: StripperTheme.cyan.opacity(0.35), radius: 8)
                Text("The speaker model is free, but Hugging Face asks you to log in and accept their terms once.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(StripperTheme.textSecondary)
                Link("1. Create a read token", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                    .foregroundStyle(StripperTheme.cyan)
                Link(
                    "2. Accept the speaker-diarization-community-1 terms",
                    destination: URL(string: "https://huggingface.co/pyannote/speaker-diarization-community-1")!
                )
                .foregroundStyle(StripperTheme.cyan)
                SecureField("Paste token (starts with hf_)", text: $token)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(StripperTheme.panel)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(StripperTheme.cyan.opacity(0.35), lineWidth: 1)
                    )
                    .foregroundStyle(StripperTheme.textPrimary)
                Text("If macOS asks for a Keychain password, use your Mac login password (the one that unlocks this user account), then click Always Allow. That is not your Hugging Face password.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(StripperTheme.textSecondary)
                if tokenAlreadySaved {
                    Text("A token is already saved in your Keychain.")
                        .font(.caption)
                        .foregroundStyle(StripperTheme.textSecondary)
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(StripperTheme.lime)
                }
                HStack {
                    Button("SAVE TOKEN") {
                        do {
                            try HuggingFaceKeychain.save(token)
                            token = ""
                            tokenAlreadySaved = true
                            status = "Saved to the macOS Keychain."
                            onSave()
                        } catch {
                            status = error.localizedDescription
                        }
                    }
                    .buttonStyle(StripperPrimaryButtonStyle(compact: true))
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("REMOVE") {
                        HuggingFaceKeychain.clear()
                        tokenAlreadySaved = false
                        status = "Removed."
                        onSave()
                    }
                    .buttonStyle(StripperGhostButtonStyle())
                    Spacer()
                    Button("DONE") { dismiss() }
                        .buttonStyle(StripperPrimaryButtonStyle(compact: true))
                        .keyboardShortcut(.defaultAction)
                }
                HStack(spacing: 14) {
                    Link("Privacy", destination: URL(string: "https://cougarcalc.com/privacy")!)
                        .foregroundStyle(StripperTheme.cyan)
                    Link("Terms", destination: URL(string: "https://cougarcalc.com/terms")!)
                        .foregroundStyle(StripperTheme.cyan)
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .padding(24)
        }
        .frame(width: 540, height: 430)
        .preferredColorScheme(.dark)
        .onAppear {
            // Attributes-only check; usually avoids the password prompt that load() triggers.
            tokenAlreadySaved = HuggingFaceKeychain.hasSavedToken()
        }
    }
}
