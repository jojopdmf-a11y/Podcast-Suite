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
                let depotOnLeft = session.activeWorkspace == .stripper
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
        .alert("Pod Lounge", isPresented: alertIsPresented) {
            Button("OK", role: .cancel) { session.alertMessage = nil }
        } message: {
            Text(session.alertMessage ?? "")
        }
        .alert("About Pod Lounge", isPresented: aboutIsPresented) {
            Button("Third-Party Notices") { session.showThirdPartyNotices = true }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Project home for Stripper, Fixer, Trimmer, and Limiter. Stripper splits the selected depot file into speaker tracks and music. Limiter levels the selected depot file and can save a new result. Fixer and Trimmer do not process audio in this build.")
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
            Text("Save Project writes the manifest and Limiter settings. It does not rewrite depot audio.")
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
                Text("P")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(red: 0.03, green: 0.08, blue: 0.10))
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LoungeTheme.cyan))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pod Lounge")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Project home")
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
        .padding(.vertical, 14)
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

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WORKSPACES")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(LoungeTheme.textDim)
                    Text("Click a card to fill this window. Return to the Lounge to switch. Any order.")
                        .font(.system(size: 13))
                        .foregroundStyle(LoungeTheme.textDim)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(WorkspaceID.allCases) { workspace in
                        WorkspaceCard(workspace: workspace) {
                            session.openWorkspace(workspace)
                        }
                        .disabled(session.navigationLocked)
                    }
                }
                .frame(minHeight: 560)
            }
            .padding(18)
        }
    }
}

struct WorkspaceCard: View {
    let workspace: WorkspaceID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(LoungeTheme.text)
                        Text(workspace.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(LoungeTheme.textDim)
                    }
                    Spacer(minLength: 8)
                    if workspace.conceptOnly {
                        Text("Concept — new tool")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LoungeTheme.amber)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(LoungeTheme.amber.opacity(0.85), lineWidth: 1)
                            )
                    }
                }
                cardBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Open workspace  →")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LoungeTheme.cyan)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity, alignment: .topLeading)
            .loungePanel(
                stroke: workspace.conceptOnly ? LoungeTheme.amber.opacity(0.85) : LoungeTheme.cyan.opacity(0.7)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(workspace.title). \(workspace.subtitle)")
        .accessibilityIdentifier("lounge.card.\(workspace.rawValue)")
    }

    @ViewBuilder
    private var cardBody: some View {
        if workspace.conceptOnly {
            ConceptCardBody()
        } else if let name = workspace.screenshotResourceName {
            ScreenshotCardBody(name: name)
        }
    }
}

struct ConceptCardBody: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.07, blue: 0.05),
                    Color(red: 0.04, green: 0.06, blue: 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, size in
                var path = Path()
                let gap: CGFloat = 14
                var x = -size.height
                while x < size.width + size.height {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += gap
                }
                context.stroke(path, with: .color(LoungeTheme.amber.opacity(0.16)), lineWidth: 1)
            }
            VStack(spacing: 6) {
                Text("Concept — new tool")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LoungeTheme.amber)
                Text("No app screenshot yet")
                    .font(.system(size: 12))
                    .foregroundStyle(LoungeTheme.textDim)
                Text("Cuts, intros, and commercials are planned.")
                    .font(.system(size: 11))
                    .foregroundStyle(LoungeTheme.textDim)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.28))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(LoungeTheme.amber.opacity(0.9), lineWidth: 1)
            )
        }
    }
}

struct ScreenshotCardBody: View {
    let name: String

    var body: some View {
        if let image = CardArt.image(named: name) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
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
