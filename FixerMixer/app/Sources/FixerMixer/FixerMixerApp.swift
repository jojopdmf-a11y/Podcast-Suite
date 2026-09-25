import SwiftUI

extension Notification.Name {
    static let cougarCalcShowAbout = Notification.Name("cougarCalcShowAbout")
    static let fixerMixerSaveMix = Notification.Name("fixerMixerSaveMix")
    static let fixerMixerUpdateMix = Notification.Name("fixerMixerUpdateMix")
    static let fixerMixerLoadMix = Notification.Name("fixerMixerLoadMix")
    static let fixerMixerAddStrip = Notification.Name("fixerMixerAddStrip")
    static let fixerMixerRemoveStrip = Notification.Name("fixerMixerRemoveStrip")
    static let fixerMixerToggleReorder = Notification.Name("fixerMixerToggleReorder")
    static let fixerMixerImportFolder = Notification.Name("fixerMixerImportFolder")
    static let fixerMixerImportFiles = Notification.Name("fixerMixerImportFiles")
    static let fixerMixerExport = Notification.Name("fixerMixerExport")
    static let fixerMixerPickInput = Notification.Name("fixerMixerPickInput")
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
                Divider()
                Button("Add Strip") {
                    NotificationCenter.default.post(name: .fixerMixerAddStrip, object: nil)
                }
                Button("Remove Strip") {
                    NotificationCenter.default.post(name: .fixerMixerRemoveStrip, object: nil)
                }
                Button("Reorder Strips") {
                    NotificationCenter.default.post(name: .fixerMixerToggleReorder, object: nil)
                }
                Divider()
                Button("Import Folder…") {
                    NotificationCenter.default.post(name: .fixerMixerImportFolder, object: nil)
                }
                Button("Import Files…") {
                    NotificationCenter.default.post(name: .fixerMixerImportFiles, object: nil)
                }
                Button("Export…") {
                    NotificationCenter.default.post(name: .fixerMixerExport, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Input Device…") {
                    NotificationCenter.default.post(name: .fixerMixerPickInput, object: nil)
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About PodProducer") {
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
