import SwiftUI

@main
struct PodcastStripperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About PodStripper") {
                    NotificationCenter.default.post(name: .showStripperAbout, object: nil)
                }
            }
            CommandGroup(replacing: .newItem) {}
        }
    }
}
