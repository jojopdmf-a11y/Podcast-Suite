import AppKit
import LilLevelerKit
import PodLoungeCore
import SwiftUI

enum DepotChrome {
    static let minWidth: CGFloat = 260
    static let maxWidth: CGFloat = 560
    static let defaultWidth: Double = 332
    static let widthKey = "podlounge.depotWidth"
    static let hiddenKey = "podlounge.depotHidden"
}

struct ContentView: View {
    @EnvironmentObject private var session: ProjectSession
    @AppStorage(DepotChrome.widthKey) private var depotWidthStorage = DepotChrome.defaultWidth
    @AppStorage(DepotChrome.hiddenKey) private var depotHidden = false
    @State private var depotDragStart: CGFloat?
    @State private var windowFitReport = ""

    private func depotMax(in containerWidth: CGFloat) -> CGFloat {
        let reserved: CGFloat? = switch session.activeWorkspace {
        case .limiter: LevelerPaneMetrics.limiterWorkspaceMinimum
        case .stripper: 780
        case .fixer: 960
        case .trimmer: 860
        default: nil
        }
        guard let reserved else { return DepotChrome.maxWidth }
        return LevelerPaneMath.depotMaximum(
            container: containerWidth,
            reserved: reserved,
            minimum: DepotChrome.minWidth,
            cap: DepotChrome.maxWidth
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(LoungeTheme.cyan.opacity(0.18))
                .frame(height: 1)
            GeometryReader { geo in
                let maxDepot = depotMax(in: geo.size.width)
                let width = min(maxDepot, max(DepotChrome.minWidth, CGFloat(depotWidthStorage)))
                let depotOnLeft = session.activeWorkspace?.depotSide == .leading
                HStack(spacing: 0) {
                    if !depotHidden, depotOnLeft {
                        depotSidebar(width: width, maximum: maxDepot, onLeft: true)
                    }
                    Group {
                        if let workspace = session.activeWorkspace {
                            if workspace == .limiter {
                                LimiterWorkspaceView()
                            } else if workspace == .stripper {
                                StripperWorkspaceView()
                            } else if workspace == .fixer {
                                FixerWorkspaceView()
                            } else if workspace == .trimmer {
                                TrimmerWorkspaceView()
                            } else {
                                WorkspaceScaffoldView(workspace: workspace)
                            }
                        } else {
                            LoungeHomeView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !depotHidden, depotOnLeft == false {
                        depotSidebar(width: width, maximum: maxDepot, onLeft: false)
                    }
                }
            }
        }
        .background(LoungeTheme.background)
        .foregroundStyle(LoungeTheme.text)
        .frame(
            minWidth: LevelerPaneMetrics.limiterWorkspaceMinimum + DepotChrome.minWidth,
            minHeight: 800
        )
        .overlay(alignment: .topLeading) {
            UITestFitProbe(report: windowFitReport)
        }
        .onReceive(NotificationCenter.default.publisher(for: .uiTestFitMinimumWindow)) { _ in
            windowFitReport = UITestWindowFit.shrinkKeyWindow()
            Task { @MainActor in
                windowFitReport = UITestWindowFit.measureKeyWindow()
            }
        }
        .onChange(of: session.activeWorkspace) { _, _ in
            session.stopDepotPlayback()
        }
        .onAppear {
            if UITestMode.argument("-UITestAutoOpen") == "stripper" {
                session.newProject()
                session.importAudio()
                session.openWorkspace(.stripper)
            }
        }
        .alert(ClubPodNaming.hubScreenTitle, isPresented: alertIsPresented) {
            Button("OK", role: .cancel) { session.alertMessage = nil }
        } message: {
            Text(session.alertMessage ?? "")
        }
        .alert("About \(ClubPodNaming.product)", isPresented: aboutIsPresented) {
            Button("Third-Party Notices") { session.showThirdPartyNotices = true }
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(ClubPodNaming.product). Lounge is the hub for TheStrip, TheDecks, TheCut, and TheRoof. TheStrip splits the selected depot file into speaker tracks and music. TheDecks records and mixes. TheCut edits the finished episode and can save a new mix for TheRoof. TheRoof levels the selected depot file and can save a new result. The first time TheDecks records, macOS asks Lounge for the microphone.")
        }
        .alert("Third-Party Notices", isPresented: noticesIsPresented) {
            Button("Show LGPL Text") { LAMENotice.openCopying() }
            Button("LAME Website") { LAMENotice.openWebsite() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(LAMENotice.summary)
        }
        .confirmationDialog(
            "This project has unsaved changes.",
            isPresented: discardIsPresented,
            titleVisibility: .visible
        ) {
            Button("Save Project") { session.saveAndContinue() }
            Button("Discard Changes", role: .destructive) { session.discardAndContinue() }
            Button("Cancel", role: .cancel) { session.cancelPending() }
        } message: {
            Text("Save Project writes the manifest, TheCut edits, TheRoof settings, and the TheDecks session. It does not rewrite depot audio.")
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { session.alertMessage != nil },
            set: { if !$0 { session.alertMessage = nil } }
        )
    }

    private var aboutIsPresented: Binding<Bool> {
        Binding(
            get: { session.showAbout },
            set: { session.showAbout = $0 }
        )
    }

    private var noticesIsPresented: Binding<Bool> {
        Binding(
            get: { session.showThirdPartyNotices },
            set: { session.showThirdPartyNotices = $0 }
        )
    }

    private var discardIsPresented: Binding<Bool> {
        Binding(
            get: { session.confirmDiscard },
            set: { session.confirmDiscard = $0 }
        )
    }

    private var projectNameBinding: Binding<String> {
        Binding(
            get: { session.projectName },
            set: { session.projectName = $0 }
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 10) {
                Text("C")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(red: 0.03, green: 0.08, blue: 0.10))
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LoungeTheme.cyan))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ClubPodNaming.product)
                        .font(.system(size: 18, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(ClubPodNaming.hubScreenTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(LoungeTheme.textDim)
                }
            }
            TextField(
                "Project name",
                text: projectNameBinding,
                prompt: Text("No project open").foregroundStyle(LoungeTheme.textDim)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(LoungeTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LoungeTheme.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LoungeTheme.cyan.opacity(0.4), lineWidth: 1)
            )
            .disabled(session.package == nil)
            .frame(maxWidth: 420)
            .accessibilityIdentifier("lounge.projectName")
            if session.isDirty {
                Text("Unsaved")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LoungeTheme.amber)
            }
            Spacer()
            Button("New") { session.newProject() }
                .buttonStyle(LoungeButtonStyle())
                .disabled(session.navigationLocked)
                .accessibilityIdentifier("lounge.new")
            Button("Open") { session.openProject() }
                .buttonStyle(LoungeButtonStyle())
                .disabled(session.navigationLocked)
            Button("Save") { session.saveShowingError() }
                .buttonStyle(LoungeButtonStyle(prominent: true))
                .disabled(session.package == nil || !session.isDirty)
            Button("Save As") { session.saveAs() }
                .buttonStyle(LoungeButtonStyle())
                .disabled(session.package == nil || session.navigationLocked)
            Button(depotHidden ? "Show Depot" : "Hide Depot") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    depotHidden.toggle()
                }
            }
            .buttonStyle(LoungeButtonStyle())
            .help(depotHidden ? "Show the project depot" : "Hide the project depot")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(LoungeTheme.backgroundRaised)
    }

    private func depotSidebar(width: CGFloat, maximum: CGFloat, onLeft: Bool) -> some View {
        DepotSidebar()
            .frame(width: width)
            .overlay(alignment: onLeft ? .trailing : .leading) {
                depotResizeHandle(current: width, maximum: maximum, onLeft: onLeft)
            }
    }

    private func depotResizeHandle(current: CGFloat, maximum: CGFloat, onLeft: Bool) -> some View {
        LevelerPaneDivider(
            axis: .vertical,
            help: "Drag to resize the depot. Double-click to reset."
        ) { delta in
            if depotDragStart == nil { depotDragStart = current }
            let signed = onLeft ? delta : -delta
            let next = (depotDragStart ?? current) + signed
            let clamped = min(maximum, max(DepotChrome.minWidth, next))
            depotWidthStorage = Double(clamped)
        } onDragEnded: {
            depotDragStart = nil
        } onReset: {
            depotWidthStorage = DepotChrome.defaultWidth
            depotDragStart = nil
        }
    }
}

struct LoungeHomeView: View {
    @EnvironmentObject private var session: ProjectSession

    var body: some View {
        GeometryReader { geo in
            let layout = LoungeHomeLayout.fitting(geo.size)
            let canvas = layout.needsScroll
                ? CGSize(width: max(geo.size.width, layout.contentWidth), height: layout.contentHeight)
                : geo.size
            let board = homeBoard(layout, canvas: canvas)
            if layout.needsScroll {
                ScrollView([.horizontal, .vertical]) {
                    board
                }
            } else {
                board
            }
        }
    }

    private func homeBoard(_ layout: LoungeHomeLayout, canvas: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: canvas.width, height: canvas.height)
            VStack(alignment: .leading, spacing: 2) {
                Text("WORKSPACES")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(LoungeTheme.textDim)
                Text("Click a card to fill this window. Return to the Lounge to switch. Any order.")
                    .font(.system(size: 13))
                    .foregroundStyle(LoungeTheme.textDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, LoungeHomeLayout.contentPadding)
            .padding(.top, LoungeHomeLayout.contentPadding)
            .accessibilityIdentifier("lounge.workspacesHeading")

            homeCard(layout, index: 0)
            homeCard(layout, index: 1)
            homeCard(layout, index: 2)
            homeCard(layout, index: 3)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func homeCard(_ layout: LoungeHomeLayout, index: Int) -> some View {
        let rooms = Array(WorkspaceID.allCases)
        if rooms.indices.contains(index), layout.cells.indices.contains(index) {
            let cell = layout.cells[index]
            WorkspaceCard(workspace: rooms[index]) {
                session.openWorkspace(rooms[index])
            }
            .disabled(session.navigationLocked)
            .frame(width: cell.width, height: cell.height)
            .position(x: cell.x + cell.width / 2, y: cell.y + cell.height / 2)
        }
    }
}

struct WorkspaceCard: View {
    let workspace: WorkspaceID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        RoomTitleText(workspace: workspace, size: 22)
                        Text(workspace.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(LoungeTheme.textDim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                }
                cardBody
                    .layoutPriority(-1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Open workspace  →")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LoungeTheme.cyan)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .loungePanel(stroke: LoungeTheme.cyan.opacity(0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(workspace.title). \(workspace.subtitle)")
        .accessibilityIdentifier("lounge.card.\(workspace.rawValue)")
    }

    @ViewBuilder
    private var cardBody: some View {
        if workspace == .trimmer {
            TheCutCardArt()
        } else if let name = workspace.screenshotResourceName {
            ScreenshotCardBody(name: name)
        }
    }
}

/// Drawn timeline thumbnail. TheCut has no product screenshot.
struct TheCutCardArt: View {
    var body: some View {
        Canvas { context, size in
            let panel = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            context.fill(
                Path(roundedRect: panel, cornerRadius: 8),
                with: .color(Color(red: 0.03, green: 0.06, blue: 0.09))
            )
            let laneHeight = size.height / 3
            for index in 0..<3 {
                let y = CGFloat(index) * laneHeight
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y + laneHeight - 0.5))
                line.addLine(to: CGPoint(x: size.width, y: y + laneHeight - 0.5))
                context.stroke(line, with: .color(LoungeTheme.cyan.opacity(0.12)), lineWidth: 1)
            }
            func clip(_ x: CGFloat, _ width: CGFloat, _ lane: Int, _ color: Color) {
                let height = laneHeight * 0.62
                let y = CGFloat(lane) * laneHeight + (laneHeight - height) / 2
                let rect = CGRect(x: x, y: y, width: max(8, width), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.85)))
            }
            clip(size.width * 0.08, size.width * 0.46, 0, LoungeTheme.cyan)
            clip(size.width * 0.62, size.width * 0.3, 0, LoungeTheme.cyan)
            clip(size.width * 0.02, size.width * 0.16, 1, LoungeTheme.original)
            clip(size.width * 0.58, size.width * 0.14, 1, LoungeTheme.amber)
            clip(0, size.width * 0.22, 2, LoungeTheme.result)
            var playhead = Path()
            let x = size.width * 0.36
            playhead.move(to: CGPoint(x: x, y: 0))
            playhead.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(playhead, with: .color(LoungeTheme.cyan), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}

struct ScreenshotCardBody: View {
    let name: String

    var body: some View {
        if let image = CardArt.image(named: name) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                Color.black.opacity(0.35)
                Text("Screenshot is missing from the app bundle.")
                    .font(.system(size: 12))
                    .foregroundStyle(LoungeTheme.textDim)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }
}
