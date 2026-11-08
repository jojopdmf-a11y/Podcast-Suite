import LilLevelerKit
import SwiftUI

@main
struct PodLoungeApp: App {
    @StateObject private var session = ProjectSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environmentObject(session.depotPlayer)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { session.newProject() }
                    .keyboardShortcut("n")
                    .disabled(session.navigationLocked)
                Button("Open Project…") { session.openProject() }
                    .keyboardShortcut("o")
                    .disabled(session.navigationLocked)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { session.saveShowingError() }
                    .keyboardShortcut("s")
                    .disabled(session.package == nil || !session.isDirty)
                Button("Save Project As…") { session.saveAs() }
                    .keyboardShortcut("S")
                    .disabled(session.package == nil || session.navigationLocked)
                Button("Save Result") {}
                    .disabled(true)
            }
            CommandGroup(after: .sidebar) {
                Button("Back to Lounge") { session.leaveWorkspace() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .disabled(session.activeWorkspace == nil || session.navigationLocked)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Pod Lounge") { session.showAbout = true }
                Button("Third-Party Notices") { session.showThirdPartyNotices = true }
            }
            if UITestMode.enabled {
                CommandMenu("Quick Check") {
                    Button("Fit Minimum Window") {
                        NotificationCenter.default.post(name: .uiTestFitMinimumWindow, object: nil)
                    }
                    .keyboardShortcut("m", modifiers: [.command, .option, .shift])
                }
            }
        }
    }
}
