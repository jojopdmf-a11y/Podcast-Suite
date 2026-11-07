import LilLevelerKit
import SwiftUI

@main
struct LilLevelerApp: App {
    var body: some Scene {
        WindowGroup {
            LevelerAppRoot()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About PodLeveler") {
                    NotificationCenter.default.post(name: .cougarCalcShowAbout, object: nil)
                }
                Button("Third-Party Notices") {
                    NotificationCenter.default.post(name: .cougarCalcShowThirdPartyNotices, object: nil)
                }
            }
            CommandGroup(after: .help) {
                Button("CougarCalc Support…") {
                    NotificationCenter.default.post(name: .cougarCalcShowAbout, object: nil)
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
            }
        }
    }
}
