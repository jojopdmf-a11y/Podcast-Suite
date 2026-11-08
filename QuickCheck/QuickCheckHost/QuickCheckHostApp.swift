import SwiftUI

/// Tiny window the UI test runner launches. The real apps are started by the test.
@main
struct QuickCheckHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Quick Check")
                .frame(width: 200, height: 60)
        }
        .windowResizability(.contentSize)
    }
}
