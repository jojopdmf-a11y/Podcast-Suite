import AppKit
import SwiftUI
import UniformTypeIdentifiers

public extension Notification.Name {
    static let cougarCalcShowAbout = Notification.Name("cougarCalcShowAbout")
    static let cougarCalcShowThirdPartyNotices = Notification.Name("cougarCalcShowThirdPartyNotices")
}

/// Standalone PodLeveler window. The Limiter workspace hosts `LevelerRootView`.
public struct LevelerAppRoot: View {
    @StateObject private var session = LevelerSession()
    @State private var output = LevelerOutputSettings.standaloneDefaults
    @State private var windowFitReport = ""

    public init() {}

    public var body: some View {
        LevelerRootView(session: session, mode: .application, output: $output)
            .overlay(alignment: .topLeading) {
                UITestFitProbe(report: windowFitReport)
            }
            .onReceive(NotificationCenter.default.publisher(for: .uiTestFitMinimumWindow)) { _ in
                windowFitReport = UITestWindowFit.shrinkKeyWindow()
                Task { @MainActor in
                    windowFitReport = UITestWindowFit.measureKeyWindow()
                }
            }
    }
}

public enum LevelerHostMode {
    case application
    case lounge
}

public struct LevelerRootView: View {
    @ObservedObject var session: LevelerSession
    var mode: LevelerHostMode
    @Binding var output: LevelerOutputSettings
    var resultName: Binding<String>
    var resultNameFollowsSource: Binding<Bool>
    var onSaveToDepot: ((URL, String) async throws -> Void)?
    var onControlsChanged: (() -> Void)?
    /// Lounge calls this before PLAY so depot preview stops first.
    var onPlaybackWillStart: (() -> Void)?

    @State private var isDropTargeted = false
    @State private var showAbout = false
    @State private var showNotices = false
    @State private var standaloneResultName = ""
    @State private var standaloneResultFollowsSource = true
    @AppStorage(LevelerPaneMetrics.presetKey) private var presetWidthStorage = Double(LevelerPaneMetrics.presetDefault)
    @AppStorage(LevelerPaneMetrics.outputKey) private var outputWidthStorage = Double(LevelerPaneMetrics.outputDefault)
    @AppStorage(LevelerPaneMetrics.loudnessExtraKey) private var loudnessExtraStorage = 0.0
    @AppStorage(LevelerPaneMetrics.applicationPresetKey) private var appPresetWidthStorage = Double(LevelerLayout.appPresetDefault)
    @AppStorage(LevelerPaneMetrics.applicationOutputKey) private var appOutputWidthStorage = Double(LevelerLayout.appOutputDefault)
    @AppStorage(LevelerPaneMetrics.applicationLoudnessExtraKey) private var appLoudnessExtraStorage = 0.0
    @State private var presetDragOrigin: CGFloat?
    @State private var outputDragOrigin: CGFloat?
    @State private var loudnessDragOrigin: CGFloat?

    public init(
        session: LevelerSession,
        mode: LevelerHostMode,
        output: Binding<LevelerOutputSettings>,
        resultName: Binding<String> = .constant(""),
        resultNameFollowsSource: Binding<Bool> = .constant(true),
        onSaveToDepot: ((URL, String) async throws -> Void)? = nil,
        onControlsChanged: (() -> Void)? = nil,
        onPlaybackWillStart: (() -> Void)? = nil
    ) {
        self.session = session
        self.mode = mode
        self._output = output
        self.resultName = resultName
        self.resultNameFollowsSource = resultNameFollowsSource
        self.onSaveToDepot = onSaveToDepot
        self.onControlsChanged = onControlsChanged
        self.onPlaybackWillStart = onPlaybackWillStart
    }

    public var body: some View {
        Group {
            if mode == .lounge {
                loungeLayout
                    .onDisappear { session.stopPlayback() }
                    .onReceive(NotificationCenter.default.publisher(for: .cougarCalcShowAbout)) { _ in
                        showAbout = true
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .cougarCalcShowThirdPartyNotices)) { _ in
                        showAbout = false
                        showNotices = true
                    }
                    .onExitCommand {
                        if showNotices {
                            showNotices = false
                        } else if showAbout {
                            showAbout = false
                        }
                    }
            } else {
                chrome
            }
        }
        .onChange(of: session.preset) { _, _ in onControlsChanged?() }
        .onChange(of: session.customLUFS) { _, _ in onControlsChanged?() }
        .onChange(of: session.customTP) { _, _ in onControlsChanged?() }
        .onChange(of: session.musicThresholdDb) { _, _ in onControlsChanged?() }
        .onChange(of: session.meterMode) { _, _ in onControlsChanged?() }
        .onChange(of: session.peakHold) { _, _ in onControlsChanged?() }
        .onChange(of: session.playAfter) { _, _ in onControlsChanged?() }
        .onChange(of: session.sourceURL) { _, _ in
            guard mode == .application else { return }
            standaloneResultFollowsSource = true
            standaloneResultName = ""
        }
    }

    /// One screen inside Pod Lounge: presets, meters and loudness, output column.
    private var loungeLayout: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 6) {
                header
                GeometryReader { geo in
                    loungeColumns(in: geo.size)
                }
            }
            .padding(8)

            if showAbout {
                aboutOverlay
            }
            if showNotices {
                noticesOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { levelerBackdrop }
        .preferredColorScheme(.dark)
    }

    private var columnLock: LevelerPaneMath.ColumnLock {
        if presetDragOrigin != nil { return .output }
        if outputDragOrigin != nil { return .preset }
        return .none
    }

    private func columnSplit(in size: CGSize) -> LevelerColumnSplit {
        let loaded = session.sourceURL != nil
        return LevelerPaneMath.columns(
            available: size.width,
            preset: CGFloat(presetWidthStorage),
            output: CGFloat(outputWidthStorage),
            showsPreset: loaded,
            presetMin: LevelerPaneMetrics.presetMin,
            presetMax: LevelerPaneMetrics.presetMax,
            outputMin: LevelerPaneMetrics.outputMin,
            outputMax: LevelerPaneMetrics.outputMax,
            centerMin: loaded ? LevelerPaneMetrics.centerMin : 160,
            divider: LevelerPaneMetrics.divider,
            lock: columnLock
        )
    }

    private func loungeColumns(in size: CGSize) -> some View {
        let split = columnSplit(in: size)
        let loaded = session.sourceURL != nil
        return HStack(alignment: .top, spacing: 0) {
            if loaded {
                presetColumn
                    .frame(width: split.preset, height: size.height, alignment: .top)
                paneDivider(axis: .vertical, help: "Drag to resize presets. Double-click to reset.") {
                    if presetDragOrigin == nil { presetDragOrigin = split.preset }
                    presetWidthStorage = Double((presetDragOrigin ?? split.preset) + $0)
                } onEnded: {
                    presetWidthStorage = Double(split.preset)
                    presetDragOrigin = nil
                } onReset: {
                    presetWidthStorage = Double(LevelerPaneMetrics.presetDefault)
                    presetDragOrigin = nil
                }
            }
            loungeCenter
                .frame(width: loaded ? split.center : nil, height: size.height, alignment: .top)
                .frame(maxWidth: loaded ? nil : .infinity)
            paneDivider(axis: .vertical, help: "Drag to resize Output. Double-click to reset.") {
                if outputDragOrigin == nil { outputDragOrigin = split.output }
                outputWidthStorage = Double((outputDragOrigin ?? split.output) - $0)
            } onEnded: {
                outputWidthStorage = Double(split.output)
                outputDragOrigin = nil
            } onReset: {
                outputWidthStorage = Double(LevelerPaneMetrics.outputDefault)
                outputDragOrigin = nil
            }
            loungeOutput
                .frame(width: split.output, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private func paneDivider(
        axis: LevelerPaneDivider.Axis,
        help: String,
        onDrag: @escaping (CGFloat) -> Void,
        onEnded: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        LevelerPaneDivider(axis: axis, help: help, onDrag: onDrag, onDragEnded: onEnded, onReset: onReset)
    }

    private var loungeCenter: some View {
        Group {
            if session.sourceURL == nil {
                VStack(alignment: .leading, spacing: 6) {
                    loungeEmpty
                    loungeFooter
                }
            } else {
                LevelerCenterLayout(
                    extra: CGFloat(loudnessExtraStorage),
                    meterMin: LevelerPaneMetrics.meterMin,
                    spacing: 6
                ) {
                    fileRow
                    GeometryReader { proxy in
                        DorroughMeterDeck(session: session, compact: true, expands: true)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    paneDivider(
                        axis: .horizontal,
                        help: "Drag to resize the meters. Double-click to reset."
                    ) {
                        if loudnessDragOrigin == nil { loudnessDragOrigin = CGFloat(loudnessExtraStorage) }
                        let next = (loudnessDragOrigin ?? CGFloat(loudnessExtraStorage)) - $0
                        loudnessExtraStorage = Double(min(400, max(0, next)))
                    } onEnded: {
                        loudnessDragOrigin = nil
                    } onReset: {
                        loudnessExtraStorage = 0
                        loudnessDragOrigin = nil
                    }
                    LoudnessCompareBoard(
                        before: session.before,
                        after: session.after,
                        hasResult: session.hasResult,
                        targetLUFS: session.activeTargetLUFS,
                        targetTP: session.activeTruePeak,
                        isMaximizer: session.preset.isMaximizer,
                        maximizerMakeupDb: session.musicMakeupDb,
                        compact: true
                    )
                    .frame(maxWidth: .infinity, alignment: .top)
                    loungeFooter
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var loungeFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            transportRow
            statusBar
        }
    }

    private var loungeOutput: some View {
        VStack(alignment: .leading, spacing: 0) {
            LevelerOutputPanel(
                session: session,
                settings: $output,
                resultName: resultName,
                followsSource: resultNameFollowsSource,
                primaryTitle: session.isBusy ? "WORKING…" : "Export File to Depot",
                primaryHelp: "Render the leveled file into the project. The original is not changed, and the depot selection stays on this file.",
                primaryDisabled: !session.canExportLeveled || onSaveToDepot == nil,
                primaryAction: saveToDepot,
                fillsColumn: false,
                includesPrimaryButton: true
            )
            Spacer(minLength: 0)
        }
    }

    private var levelerBackdrop: some View {
        ZStack {
            LevelerTheme.windowBackground
            RadialGradient(
                colors: [LevelerTheme.cyan.opacity(0.06), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 480
            )
        }
    }

    private var fittedWindow: LevelerWindowFit.ContentSize {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1512, height: 949)
        return LevelerWindowFit.contentSize(
            minimumWidth: LevelerWindowFit.minimumContentWidth,
            minimumHeight: LevelerWindowFit.minimumContentHeight,
            idealWidth: LevelerWindowFit.idealContentWidth,
            idealHeight: LevelerWindowFit.idealContentHeight,
            visible: visible,
            titleBar: LevelerWindowFit.assumedTitleBarHeight
        )
    }

    private var chrome: some View {
        let fit = fittedWindow
        return ZStack {
            VStack(alignment: .leading, spacing: 8) {
                header
                GeometryReader { geo in
                    if session.sourceURL == nil {
                        dropZone
                    } else {
                        applicationColumns(in: geo.size)
                    }
                }
                statusBar
            }
            .padding(LevelerLayout.windowPadding)

            if showAbout {
                aboutOverlay
            }
            if showNotices {
                noticesOverlay
            }
        }
        // Minimum is the content floor. `ideal` matches it so the window can
        // still shrink to that floor; the clamp opens it at the fitted ideal.
        .frame(
            minWidth: fit.minWidth,
            idealWidth: fit.minWidth,
            maxWidth: .infinity,
            minHeight: fit.minHeight,
            idealHeight: fit.minHeight,
            maxHeight: .infinity
        )
        .background { levelerBackdrop }
        .background {
            LevelerWindowClamp(fit: fit)
        }
        .preferredColorScheme(.dark)
        .onDisappear { session.stopPlayback() }
        .onReceive(NotificationCenter.default.publisher(for: .cougarCalcShowAbout)) { _ in
            showAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cougarCalcShowThirdPartyNotices)) { _ in
            showAbout = false
            showNotices = true
        }
        .onExitCommand {
            if showNotices {
                showNotices = false
            } else if showAbout {
                showAbout = false
            }
        }
    }

    private var header: some View {
        let lounge = mode == .lounge
        return HStack(alignment: .center, spacing: lounge ? 8 : 10) {
            VStack(alignment: .leading, spacing: lounge ? 1 : 3) {
                Text("PODLEVELER")
                    .font(.system(size: lounge ? 16 : 22, weight: .bold, design: .rounded))
                    .tracking(lounge ? 0.8 : 1.1)
                    .foregroundStyle(LevelerTheme.cyan)
                    .shadow(color: LevelerTheme.cyan.opacity(0.35), radius: 6)
                    .lineLimit(1)
                    .padding(.vertical, lounge ? 0 : 2)
                    .fixedSize(horizontal: !lounge, vertical: true)
                Text("Final mix → platform loudness")
                    .font(.system(size: lounge ? 10 : 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(LevelerTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: !lounge, vertical: true)
                Text("\(CougarCalcBrand.company) · \(CougarCalcBrand.versionLabel)")
                    .font(.system(size: lounge ? 9 : 10, weight: .medium, design: .rounded))
                    .foregroundStyle(LevelerTheme.textSecondary.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: !lounge, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button("ABOUT") { showAbout = true }
                    .buttonStyle(LevelerGhostButtonStyle())
                    .accessibilityIdentifier("leveler.about")
                if mode == .application, session.sourceURL != nil {
                    Button("LOAD OTHER…") { pickFile() }
                        .buttonStyle(LevelerGhostButtonStyle())
                        .accessibilityIdentifier("leveler.loadOther")
                }
            }
            .fixedSize()
            .controlSize(.small)
        }
    }

    /// In-window panel. A SwiftUI `.sheet` on a `.contentSize` window freezes macOS.
    private var aboutOverlay: some View {
        ZStack {
            Color.black.opacity(0.58)
                .contentShape(Rectangle())
                .onTapGesture { showAbout = false }

            VStack(spacing: 12) {
                AboutSupportPanel(
                    appName: "PodLeveler",
                    tagline: "Final mix → platform loudness",
                    accent: LevelerTheme.cyan,
                    onShowNotices: {
                        showAbout = false
                        showNotices = true
                    }
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LevelerTheme.panelRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(LevelerTheme.cyan.opacity(0.4), lineWidth: 1.1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button("CLOSE") { showAbout = false }
                    .buttonStyle(LevelerPrimaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
    }

    private var noticesOverlay: some View {
        ZStack {
            Color.black.opacity(0.58)
                .contentShape(Rectangle())
                .onTapGesture { showNotices = false }

            VStack(alignment: .leading, spacing: 12) {
                Text("Third-Party Notices")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(LevelerTheme.textPrimary)
                Text(LAMENotice.summary)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(LevelerTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("SHOW LGPL TEXT") { LAMENotice.openCopying() }
                        .buttonStyle(.bordered)
                        .disabled(LAMENotice.copyingURL() == nil)
                    Button("LAME WEBSITE") { LAMENotice.openWebsite() }
                        .buttonStyle(.bordered)
                }
                Button("CLOSE") { showNotices = false }
                    .buttonStyle(LevelerPrimaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .frame(maxWidth: 460)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LevelerTheme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LevelerTheme.cyan.opacity(0.4), lineWidth: 1.1)
            )
        }
    }

    private var loungeEmpty: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LevelerTheme.panel)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LevelerTheme.cyan.opacity(0.55), style: StrokeStyle(lineWidth: 1.4, dash: [7, 6]))
            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(LevelerTheme.cyan)
                Text("SELECT A DEPOT FILE")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(LevelerTheme.textPrimary)
                Text("Pick one in the depot list. The original stays where it is.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(LevelerTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text("WAV, AIFF, MP3, M4A, CAF, FLAC…")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(LevelerTheme.textSecondary)
                Button("CHOOSE FILE…") { pickFile() }
                    .buttonStyle(LevelerPrimaryButtonStyle())
                    .accessibilityIdentifier("leveler.chooseFile")
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func applicationColumnSplit(in size: CGSize) -> LevelerColumnSplit {
        LevelerPaneMath.columns(
            available: size.width,
            preset: CGFloat(appPresetWidthStorage),
            output: CGFloat(appOutputWidthStorage),
            showsPreset: true,
            presetMin: LevelerLayout.appPresetMin,
            presetMax: LevelerLayout.appPresetMax,
            outputMin: LevelerLayout.appOutputMin,
            outputMax: LevelerLayout.appOutputMax,
            centerMin: LevelerLayout.appCenterMin,
            divider: LevelerPaneMetrics.divider,
            lock: columnLock
        )
    }

    /// Presets, the meter stack, and Output side by side. Extra width and height go to the meters.
    private func applicationColumns(in size: CGSize) -> some View {
        let split = applicationColumnSplit(in: size)
        return HStack(alignment: .top, spacing: 0) {
            presetColumn
                .frame(width: split.preset, height: size.height, alignment: .top)
            paneDivider(axis: .vertical, help: "Drag to resize presets. Double-click to reset.") {
                if presetDragOrigin == nil { presetDragOrigin = split.preset }
                appPresetWidthStorage = Double((presetDragOrigin ?? split.preset) + $0)
            } onEnded: {
                appPresetWidthStorage = Double(split.preset)
                presetDragOrigin = nil
            } onReset: {
                appPresetWidthStorage = Double(LevelerLayout.appPresetDefault)
                presetDragOrigin = nil
            }
            applicationCenter
                .frame(width: split.center, height: size.height, alignment: .top)
            paneDivider(axis: .vertical, help: "Drag to resize Output. Double-click to reset.") {
                if outputDragOrigin == nil { outputDragOrigin = split.output }
                appOutputWidthStorage = Double((outputDragOrigin ?? split.output) - $0)
            } onEnded: {
                appOutputWidthStorage = Double(split.output)
                outputDragOrigin = nil
            } onReset: {
                appOutputWidthStorage = Double(LevelerLayout.appOutputDefault)
                outputDragOrigin = nil
            }
            applicationOutput
                .frame(width: split.output, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private var applicationCenter: some View {
        LevelerCenterLayout(
            extra: CGFloat(appLoudnessExtraStorage),
            meterMin: LevelerLayout.applicationMeterMin,
            spacing: 8
        ) {
            fileRow
            GeometryReader { proxy in
                DorroughMeterDeck(session: session, expands: true)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            paneDivider(
                axis: .horizontal,
                help: "Drag to resize the meters. Double-click to reset."
            ) {
                if loudnessDragOrigin == nil { loudnessDragOrigin = CGFloat(appLoudnessExtraStorage) }
                let next = (loudnessDragOrigin ?? CGFloat(appLoudnessExtraStorage)) - $0
                appLoudnessExtraStorage = Double(min(400, max(0, next)))
            } onEnded: {
                loudnessDragOrigin = nil
            } onReset: {
                appLoudnessExtraStorage = 0
                loudnessDragOrigin = nil
            }
            LoudnessCompareBoard(
                before: session.before,
                after: session.after,
                hasResult: session.hasResult,
                targetLUFS: session.activeTargetLUFS,
                targetTP: session.activeTruePeak,
                isMaximizer: session.preset.isMaximizer,
                maximizerMakeupDb: session.musicMakeupDb
            )
            .frame(maxWidth: .infinity, alignment: .top)
            transportRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var applicationOutput: some View {
        LevelerOutputPanel(
            session: session,
            settings: $output,
            resultName: standaloneResultBinding,
            followsSource: $standaloneResultFollowsSource,
            primaryTitle: session.isBusy ? "WORKING…" : "EXPORT LEVELED…",
            primaryHelp: "Choose a file type, bit depth, and sample rate, then a folder. MUSIC LOUD exports the current THRESHOLD.",
            primaryDisabled: !session.canExportLeveled,
            primaryAction: chooseExportDestination,
            fillsColumn: true
        )
    }

    private var standaloneResultBinding: Binding<String> {
        Binding(
            get: {
                if standaloneResultFollowsSource { return defaultExportStem }
                let typed = standaloneResultName.trimmingCharacters(in: .whitespacesAndNewlines)
                return typed.isEmpty ? defaultExportStem : standaloneResultName
            },
            set: { standaloneResultName = $0 }
        )
    }

    /// Same default the save panel used before Result Name was on the main screen: `{file}_leveled`.
    private var defaultExportStem: String {
        let base = session.sourceURL?.deletingPathExtension().lastPathComponent ?? "Audio"
        return "\(base)_leveled"
    }

    private var exportFileStem: String {
        var typed = standaloneResultBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { typed = defaultExportStem }
        let ext = (typed as NSString).pathExtension.lowercased()
        if ["wav", "aiff", "aif", "m4a", "mp3", "caf", "flac"].contains(ext) {
            typed = (typed as NSString).deletingPathExtension
        }
        let cleaned = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? defaultExportStem : cleaned
    }

    private var presetColumn: some View {
        let lounge = mode == .lounge
        return VStack(alignment: .leading, spacing: lounge ? 6 : 8) {
            Text("PLATFORM TARGET LEVEL")
                .font(.system(size: lounge ? 9 : 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(LevelerTheme.cyanDim)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .vertical) {
                presetList
                ScrollView { presetList }
            }

            Spacer(minLength: 0)
        }
        .padding(lounge ? 8 : 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .levelerPanel(glow: true)
    }

    private var presetList: some View {
        let lounge = mode == .lounge
        return VStack(alignment: .leading, spacing: lounge ? 4 : 8) {
                    ForEach(session.listedPresets) { p in
                        HStack(spacing: 6) {
                            Button {
                                session.selectPreset(p)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(session.preset.id == p.id ? LevelerTheme.bgBottom : LevelerTheme.cyan)
                                        .lineLimit(1)
                                    Text(p.subtitle)
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundStyle(session.preset.id == p.id ? LevelerTheme.bgBottom.opacity(0.75) : LevelerTheme.textSecondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, mode == .lounge ? 8 : 10)
                                .padding(.vertical, mode == .lounge ? 4 : 8)
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
                            .disabled(session.isBusy)
                            .help(p.isMaximizer
                                  ? "L1-style maximizer. Play, then drag THRESHOLD — you hear it live. Not a podcast target."
                                  : "Level the file to this platform’s loudness and true-peak numbers.")

                            if UserLoudnessPreset.isUserID(p.id) {
                                Button("✕") {
                                    session.deleteUserPreset(p.id)
                                }
                                .buttonStyle(LevelerGhostButtonStyle())
                                .help("Remove this personal preset")
                            }
                        }
                    }

                    if session.preset.isMaximizer {
                        musicMaximizerControls
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
                            .disabled(session.isBusy)
                            .onChange(of: session.customLUFS) { _, _ in session.process() }

                            Text("TRUE PEAK  \(String(format: "%.1f", session.customTP)) dBTP")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(LevelerTheme.cyan)
                            Slider(value: Binding(
                                get: { Double(session.customTP) },
                                set: { session.customTP = Float($0) }
                            ), in: -3...(-0.1))
                            .tint(LevelerTheme.lime)
                            .disabled(session.isBusy)
                            .onChange(of: session.customTP) { _, _ in session.process() }

                            Button("SAVE PRESET") { promptSavePreset() }
                                .buttonStyle(LevelerGhostButtonStyle())
                                .help("Keep these LUFS / true-peak numbers in the Platform Target Level list")
                        }
                        .padding(.top, 4)
                    }
        }
    }

    /// L1-style: one threshold slider + a readable GR meter. Ceiling is fixed.
    private var musicMaximizerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("THRESHOLD")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(LevelerTheme.cyanDim)
                Spacer()
                Text(String(format: "%.1f dB", session.musicThresholdDb))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(LevelerTheme.cyan)
            }
            Slider(
                value: Binding(
                    get: { Double(session.musicThresholdDb) },
                    set: { session.setMusicThreshold(Float($0)) }
                ),
                in: Double(LevelerSession.musicThresholdMin)...Double(LevelerSession.musicThresholdMax)
            ) { editing in
                if !editing { session.process() }
            }
            .tint(LevelerTheme.lime)
            .disabled(session.isBusy)
            .help("Live: drag while playing to hear makeup into the −0.1 dB limiter. FILE LOUDNESS cards catch up when you let go.")

            Text("Live while you drag. FILE LOUDNESS updates when you let go.")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(LevelerTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("GR")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(LevelerTheme.cyanDim)
                        Spacer()
                        Text(String(format: "%.1f", session.isPlaying ? session.liveGR : session.peakGR))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(session.liveGR > 0.05 || session.peakGR > 0.05 ? LevelerTheme.meterYellow : LevelerTheme.textSecondary)
                        Text("dB")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(LevelerTheme.textSecondary)
                    }
                    GainReductionMeter(liveDb: session.liveGR, peakDb: session.peakGR)
                        .frame(height: 14)
                        .help("How hard the limiter is working. Jumps up with peaks, then falls slowly so you can see it.")
                }
            }

            Text("CEILING  −0.1 dB")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(LevelerTheme.textSecondary)
        }
        .padding(.top, 6)
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
                    .accessibilityIdentifier("leveler.sourceName")
            }
            Spacer()
            if session.hasResult {
                Text(String(format: "GAIN %+.1f dB", session.appliedGainDb))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(LevelerTheme.lime)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(mode == .lounge ? 8 : 12)
        .levelerPanel()
    }

    private var transportRow: some View {
        VStack(alignment: .leading, spacing: mode == .lounge ? 6 : 10) {
            HStack(spacing: 12) {
                Button(session.isPlaying ? "PAUSE" : "PLAY") {
                    if !session.isPlaying {
                        onPlaybackWillStart?()
                    }
                    session.togglePlayback()
                }
                .buttonStyle(LevelerPrimaryButtonStyle())
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!session.hasFile || session.isBusy)
                .help("Spacebar toggles play/pause")

                Text(LevelerSession.formatTime(seconds: session.playheadSeconds))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(LevelerTheme.cyan)
                    .frame(minWidth: 62, alignment: .trailing)

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
                    .frame(minWidth: 62, alignment: .leading)
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
                .frame(width: mode == .lounge ? 112 : 150)
                .disabled(!session.canListenPost)
                .help("PRE is the file you dropped. POST is the live maximizer (MUSIC LOUD) or the leveled file. Time stays put when you flip.")

                Button("RE-LEVEL") { session.relevel() }
                    .buttonStyle(LevelerGhostButtonStyle())
                    .disabled(session.sourceURL == nil || session.isBusy || session.isMeasuring)
            }
        }
        .padding(mode == .lounge ? 8 : 12)
        .levelerPanel()
    }

    private var statusBar: some View {
        let label = Text(session.status)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(LevelerTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("leveler.status")
        return Group {
            if UITestMode.enabled {
                label.accessibilityValue(
                    "status=\(session.status);analyses=\(session.sourceAnalysisCount);levels=\(session.levelingMeasureCount)"
                )
            } else {
                label
            }
        }
    }

    private var automaticResultName: String {
        LevelerResultName.suggested(sourceName: session.sourceName, presetTitle: session.activePresetTitle)
    }

    private func saveToDepot() {
        guard let onSaveToDepot else { return }
        let settings = output
        let ext = settings.container.fileExtension
        var display = resultName.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if display.isEmpty { display = automaticResultName }
        if display.lowercased().hasSuffix(".\(ext)") == false {
            display += ".\(ext)"
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("podleveler-\(UUID().uuidString).\(ext)")
        Task {
            session.isExporting = true
            defer { session.isExporting = false }
            do {
                try await session.writeLeveled(to: temp, output: settings, releaseBusy: false)
                try await onSaveToDepot(temp, display)
                try? FileManager.default.removeItem(at: temp)
                session.isBusy = false
                session.status = "Saved result to the depot"
            } catch {
                try? FileManager.default.removeItem(at: temp)
                session.isBusy = false
                session.renderFraction = 0
                session.status = error.localizedDescription
            }
        }
    }

    private func chooseExportDestination() {
        guard session.sourceURL != nil else {
            session.status = "Nothing to export yet."
            return
        }
        let settings = output
        let ext = settings.container.fileExtension
        if UITestMode.enabled {
            guard let path = UITestMode.argument("-UITestExportDir") else {
                session.status = "UI test export folder is missing."
                return
            }
            let destination = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("\(exportFileStem).\(ext)")
            Task {
                do {
                    try await session.writeLeveled(to: destination, output: settings)
                    session.status = "Exported → \(destination.lastPathComponent)"
                } catch {
                    session.status = error.localizedDescription
                }
            }
            return
        }
        guard let sourceURL = session.sourceURL else {
            session.status = "Nothing to export yet."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Leveled"
        panel.message = settings.container == .mp3
            ? "Leveling is already done. This writes that audio as MP3 at the bitrate and sample rate you picked."
            : "Leveling is already done. This writes that audio in the file type, bit depth, and sample rate you picked."
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [settings.contentType]
        panel.nameFieldStringValue = "\(exportFileStem).\(ext)"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.level = .modalPanel
        guard panel.runModal() == .OK, var dest = panel.url else {
            session.status = "Export cancelled"
            return
        }
        if dest.pathExtension.lowercased() != ext {
            dest = dest.deletingPathExtension().appendingPathExtension(ext)
        }
        let destination = dest
        Task {
            do {
                try await session.writeLeveled(to: destination, output: settings)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                session.status = "Exported → \(destination.lastPathComponent)"
            } catch {
                session.status = error.localizedDescription
            }
        }
    }

    private func promptSavePreset() {
        if UITestMode.enabled { return }
        let alert = NSAlert()
        alert.messageText = "Name this loudness preset"
        alert.informativeText = String(
            format: "Keeps %.1f LUFS and %.1f dBTP in the Platform Target Level list on this Mac.",
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
        if UITestMode.enabled {
            guard let path = UITestMode.argument("-UITestOpen") else {
                session.status = "UI test file path is missing."
                return
            }
            session.load(url: URL(fileURLWithPath: path))
            return
        }
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

/// Puts the standalone window on the visible screen. The floor stays the content
/// minimum; a frame that is larger still fits, and a frame that spills past the
/// menu bar or Dock is pulled back in.
private struct LevelerWindowClamp: NSViewRepresentable {
    var fit: LevelerWindowFit.ContentSize

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let requested = fit
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            guard let visible else { return }
            let titleBar = max(0, window.frame.height - window.contentLayoutRect.height)
            let fitted = LevelerWindowFit.contentSize(
                minimumWidth: requested.minWidth,
                minimumHeight: requested.minHeight,
                idealWidth: LevelerWindowFit.idealContentWidth,
                idealHeight: LevelerWindowFit.idealContentHeight,
                visible: visible,
                titleBar: titleBar
            )
            window.contentMinSize = NSSize(width: fitted.minWidth, height: fitted.minHeight)
            window.minSize = NSSize(width: fitted.minWidth, height: fitted.minHeight + titleBar)
            // The quick check shrinks the window itself. Skip the one-time
            // expand-to-ideal so that shrink is not undone.
            guard UITestMode.enabled == false else { return }
            guard context.coordinator.fitsApplied < 2 else { return }
            context.coordinator.fitsApplied += 1

            var frame = window.frame
            let minFrameH = fitted.minHeight + titleBar
            let idealFrameH = fitted.idealHeight + titleBar
            // A brand-new window often lands on the floor. Open it at the fitted
            // ideal instead, then leave later resizes alone.
            let parkedOnFloor = abs(frame.width - fitted.minWidth) < 4
                && abs(frame.height - minFrameH) < 4
            if parkedOnFloor {
                frame.size.width = min(fitted.idealWidth, visible.width)
                frame.size.height = min(idealFrameH, visible.height)
            }
            frame.size.width = min(max(frame.width, fitted.minWidth), visible.width)
            frame.size.height = min(max(frame.height, minFrameH), visible.height)
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame != window.frame {
                window.setFrame(frame, display: true)
            }
        }
    }

    final class Coordinator {
        var fitsApplied = 0
    }
}

/// GR meter. Fill follows live reduction with a slow fall; pip is peak hold.
private struct GainReductionMeter: View {
    var liveDb: Float
    var peakDb: Float
    private let ceiling: Float = 12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let live = CGFloat(min(1, max(0, liveDb / ceiling)))
            let peak = CGFloat(min(1, max(0, peakDb / ceiling)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LevelerTheme.bgBottom)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(barColor)
                    .frame(width: max(2, w * live))
                Rectangle()
                    .fill(LevelerTheme.meterYellow)
                    .frame(width: 2, height: h)
                    .offset(x: max(0, w * peak - 1))
                    .opacity(peakDb > 0.05 ? 1 : 0)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(LevelerTheme.cyan.opacity(0.35), lineWidth: 1)
            )
        }
        .accessibilityLabel("Gain reduction")
        .accessibilityValue(Text(String(format: "%.1f dB", liveDb)))
    }

    private var barColor: Color {
        if liveDb >= 8 { return LevelerTheme.meterRed }
        if liveDb >= 3 { return LevelerTheme.meterYellow }
        return LevelerTheme.lime
    }
}
