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
            .padding(18)
        }
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
        .frame(maxWidth: .infinity, minHeight: 320)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var mainWorkspace: some View {
        HStack(alignment: .top, spacing: 14) {
            presetColumn
                .frame(width: 220)

            VStack(alignment: .leading, spacing: 12) {
                fileRow
                HStack(alignment: .top, spacing: 12) {
                    MeterPanel(title: "BEFORE", report: session.before, glow: false)
                    MeterPanel(title: "AFTER", report: session.after, glow: session.hasResult)
                }
                transportRow
            }
        }
    }

    private var presetColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PLATFORM")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(LevelerTheme.cyanDim)

            ForEach(PlatformPreset.all) { p in
                Button {
                    session.preset = p
                    session.process()
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
                }
                .padding(.top, 4)
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
        HStack(spacing: 10) {
            Button(session.isPlaying && !session.playAfter ? "STOP SOURCE" : "PLAY SOURCE") {
                session.togglePlay(after: false)
            }
            .buttonStyle(LevelerGhostButtonStyle())
            .disabled(session.sourceURL == nil || session.isBusy)

            Button(session.isPlaying && session.playAfter ? "STOP LEVELED" : "PLAY LEVELED") {
                session.togglePlay(after: true)
            }
            .buttonStyle(LevelerGhostButtonStyle())
            .disabled(!session.hasResult || session.isBusy)

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

// MARK: - Metering

struct MeterPanel: View {
    var title: String
    var report: LoudnessReport
    var glow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(glow ? LevelerTheme.lime : LevelerTheme.cyan)

            HStack(alignment: .bottom, spacing: 14) {
                LoudnessBar(
                    label: "INT",
                    value: report.integratedLUFS,
                    range: -40...(-5),
                    unit: "LUFS"
                )
                LoudnessBar(
                    label: "SHORT",
                    value: report.shortTermLUFS,
                    range: -40...(-5),
                    unit: "LUFS"
                )
                LoudnessBar(
                    label: "MOM",
                    value: report.momentaryLUFS,
                    range: -40...(-5),
                    unit: "LUFS"
                )
                LoudnessBar(
                    label: "TP",
                    value: report.truePeakDbTP,
                    range: -20...0,
                    unit: "dBTP",
                    hotAbove: -1
                )
            }
            .frame(height: 160)

            VStack(alignment: .leading, spacing: 4) {
                metricRow("Integrated", String(format: "%.1f LUFS", report.integratedLUFS))
                metricRow("Short-term", String(format: "%.1f LUFS", report.shortTermLUFS))
                metricRow("True peak", String(format: "%.1f dBTP", report.truePeakDbTP))
                metricRow("Sample peak", String(format: "%.1f dBFS", report.samplePeakDbFS))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .levelerPanel(glow: glow)
    }

    private func metricRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(LevelerTheme.textSecondary)
            Spacer()
            Text(v)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(LevelerTheme.cyan)
        }
    }
}

struct LoudnessBar: View {
    var label: String
    var value: Float
    var range: ClosedRange<Float>
    var unit: String
    var hotAbove: Float? = nil

    private var norm: CGFloat {
        let span = range.upperBound - range.lowerBound
        let n = (value - range.lowerBound) / span
        return CGFloat(max(0, min(1, n)))
    }

    private var color: Color {
        if let hot = hotAbove, value > hot { return LevelerTheme.meterRed }
        if norm > 0.85 { return LevelerTheme.meterYellow }
        return LevelerTheme.meterGreen
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%.1f", value))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(height: 12)
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LevelerTheme.cyanFaint)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(height: max(2, geo.size.height * norm))
                        .shadow(color: color.opacity(0.45), radius: 3)
                }
            }
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(LevelerTheme.cyanDim)
            Text(unit)
                .font(.system(size: 7, weight: .medium, design: .rounded))
                .foregroundStyle(LevelerTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
