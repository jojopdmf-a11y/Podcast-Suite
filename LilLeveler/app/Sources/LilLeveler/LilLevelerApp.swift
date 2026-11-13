import LilLevelerKit
import SwiftUI

@main
struct LilLevelerApp: App {
    var body: some Scene {
        WindowGroup {
            LevelerAppRoot()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: LevelerWindowFit.idealContentWidth, height: LevelerWindowFit.idealContentHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About TheRoof") {
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
