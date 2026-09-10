import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var runner = EngineRunner()
    @State private var inputFile: URL?
    @State private var outputFolder: URL?
    @State private var speakerCount: SpeakerCountChoice = .two
    @State private var showSettings = false
    @State private var isDropTargeted = false

    var body: some View {
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

            VStack(alignment: .leading, spacing: 18) {
                header
                dropZone
                controlsPanel
                statusPanel
                if let result = runner.result {
                    resultRow(result)
                }
                if let error = runner.errorMessage {
                    errorPanel(error)
                }
                Spacer(minLength: 0)
                footerBrand
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            runner.refreshSetup()
            restoreOutputFolder()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView {
                runner.refreshSetup()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PODCAST STRIPPER")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(StripperTheme.cyan)
                    .shadow(color: StripperTheme.cyan.opacity(0.45), radius: 10)
                Text("Stereo Mix → Separate Speaker Tracks + Music / SFX")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(StripperTheme.textSecondary)
            }
            Spacer()
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
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: inputFile == nil ? [7, 6] : [])
                )
                .shadow(color: (isDropTargeted ? StripperTheme.lime : StripperTheme.cyan).opacity(0.4), radius: isDropTargeted ? 12 : 6)

            VStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(isDropTargeted ? StripperTheme.lime : StripperTheme.cyan)
                    .shadow(color: StripperTheme.cyan.opacity(0.5), radius: 8)
                if let inputFile {
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
        .frame(maxWidth: .infinity, minHeight: 168)
        .onTapGesture { pickInput() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .animation(.easeOut(duration: 0.18), value: isDropTargeted)
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Text("SPEAKERS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(StripperTheme.cyanDim)
                    .frame(width: 88, alignment: .leading)
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
                Text("SAVE TO")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(StripperTheme.cyanDim)
                    .frame(width: 88, alignment: .leading)
                Text(outputFolder?.path ?? "Same folder as the podcast · new _speakers folder")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(StripperTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("CHOOSE…") { pickOutput() }
                    .buttonStyle(StripperGhostButtonStyle())
            }

            HStack(spacing: 12) {
                Button {
                    startSplit()
                } label: {
                    Text(runner.isRunning ? "WORKING…" : "SPLIT INTO TRACKS")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .frame(minWidth: 180)
                }
                .buttonStyle(StripperPrimaryButtonStyle())
                .disabled(inputFile == nil || runner.isRunning)
                .keyboardShortcut(.defaultAction)

                if runner.isRunning {
                    Button("CANCEL") { runner.cancel() }
                        .buttonStyle(StripperGhostButtonStyle())
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
                }
            }
            .frame(height: 8)

            Text(runner.message.uppercased())
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(StripperTheme.textPrimary)
            Text(runner.setup.message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(StripperTheme.textSecondary)
        }
        .padding(16)
        .stripperPanel()
    }

    private var progressValue: Double {
        if runner.isRunning {
            return min(1, max(0.02, runner.percent / 100))
        }
        return runner.result == nil ? 0 : 1
    }

    private func resultRow(_ result: EngineResult) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(StripperTheme.success)
            Text("\(result.tracks.count) TRACKS READY")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(StripperTheme.textPrimary)
            Spacer()
            Button("SHOW IN FINDER") {
                NSWorkspace.shared.activateFileViewerSelecting([result.outputDir])
            }
            .buttonStyle(StripperPrimaryButtonStyle(compact: true))
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
            }
            ScrollView {
                Text(error)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(StripperTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
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
            Text("THE STRIPPER")
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
                inputFile = url
                if outputFolder == nil {
                    outputFolder = defaultOutput(for: url)
                }
            }
        }
        return true
    }

    private func pickInput() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType.mp3, UTType.wav, UTType.aiff, UTType.mpeg4Audio, UTType(filenameExtension: "m4a"),
            UTType(filenameExtension: "flac"), UTType(filenameExtension: "caf"),
        ].compactMap { $0 }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            inputFile = url
            if outputFolder == nil {
                outputFolder = defaultOutput(for: url)
            }
        }
    }

    private func pickOutput() {
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
        guard let inputFile else { return }
        let dest = outputFolder ?? defaultOutput(for: inputFile)
        outputFolder = dest
        UserDefaults.standard.set(dest.path, forKey: "lastOutputFolder")
        runner.split(input: inputFile, outputDir: dest, speakerCount: speakerCount)
    }

    private func defaultOutput(for input: URL) -> URL {
        input.deletingLastPathComponent().appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)_speakers")
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
            }
            .padding(24)
        }
        .frame(width: 540, height: 400)
        .preferredColorScheme(.dark)
        .onAppear {
            // Attributes-only check; usually avoids the password prompt that load() triggers.
            tokenAlreadySaved = HuggingFaceKeychain.hasSavedToken()
        }
    }
}
