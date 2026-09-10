import SwiftUI

extension Notification.Name {
    static let cougarCalcShowAbout = Notification.Name("cougarCalcShowAbout")
}

@main
struct LilLevelerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Lil Leveler") {
                    NotificationCenter.default.post(name: .cougarCalcShowAbout, object: nil)
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
