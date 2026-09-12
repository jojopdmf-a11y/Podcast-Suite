import SwiftUI

extension Notification.Name {
    static let cougarCalcShowAbout = Notification.Name("cougarCalcShowAbout")
    static let fixerMixerSaveMix = Notification.Name("fixerMixerSaveMix")
    static let fixerMixerUpdateMix = Notification.Name("fixerMixerUpdateMix")
    static let fixerMixerLoadMix = Notification.Name("fixerMixerLoadMix")
}

@main
struct FixerMixerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 980, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Update Mix") {
                    NotificationCenter.default.post(name: .fixerMixerUpdateMix, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                Button("Save Mix…") {
                    NotificationCenter.default.post(name: .fixerMixerSaveMix, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Load Mix…") {
                    NotificationCenter.default.post(name: .fixerMixerLoadMix, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Fixer Mixer") {
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
