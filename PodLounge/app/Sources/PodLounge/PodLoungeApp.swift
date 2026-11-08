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
                    .disabled(session.limiterExporting)
                Button("Open Project…") { session.openProject() }
                    .keyboardShortcut("o")
                    .disabled(session.limiterExporting)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { session.saveShowingError() }
                    .keyboardShortcut("s")
                    .disabled(session.package == nil || !session.isDirty)
                Button("Save Project As…") { session.saveAs() }
                    .keyboardShortcut("S")
                    .disabled(session.package == nil || session.limiterExporting)
                Button("Save Result") {}
                    .disabled(true)
            }
            CommandGroup(after: .sidebar) {
                Button("Back to Lounge") { session.leaveWorkspace() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .disabled(session.activeWorkspace == nil || session.limiterExporting)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Pod Lounge") { session.showAbout = true }
                Button("Third-Party Notices") { session.showThirdPartyNotices = true }
            }
        }
    }
}
