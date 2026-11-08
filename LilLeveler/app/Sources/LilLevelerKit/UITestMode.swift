import AppKit
import SwiftUI

/// Test-only switches. A normal launch never passes `-UITestMode`, and every
/// branch below stays off, so windows, meters, and saved settings are unchanged.
public enum UITestMode: Sendable {
    public static var enabled: Bool {
        CommandLine.arguments.contains("-UITestMode")
    }

    /// The value after a flag such as `-UITestOpen`. Empty when the flag is absent.
    public static func argument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        guard value.isEmpty == false, value.hasPrefix("-") == false else { return nil }
        return value
    }
}

public extension Notification.Name {
    /// Posted by the test-only Quick Check menu. Normal launches never send it.
    static let uiTestFitMinimumWindow = Notification.Name("cougarCalcUITestFitMinimumWindow")
}

/// One invisible point the quick check reads after it asks the window to shrink.
public struct UITestFitProbe: View {
    public var report: String

    public init(report: String) {
        self.report = report
    }

    public var body: some View {
        if UITestMode.enabled {
            Text(report.isEmpty ? "window fit" : report)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("quickcheck.windowFit")
                .accessibilityLabel(report.isEmpty ? "window fit" : report)
                .accessibilityValue(report)
        }
    }
}

@MainActor
public enum UITestWindowFit {
    /// Pulls the main window down to the size the app already treats as its minimum.
    public static func shrinkKeyWindow() -> String {
        guard let window = targetWindow() else { return "missing" }
        let titleBar = max(0, window.frame.height - window.contentLayoutRect.height)
        var content = window.contentMinSize
        if content.width < 50 || content.height < 50 {
            content = NSSize(
                width: max(window.minSize.width, content.width),
                height: max(window.minSize.height - titleBar, content.height)
            )
        }
        guard content.width >= 50, content.height >= 50 else { return describe(window) }
        var frame = window.frame
        frame.size.width = content.width
        frame.size.height = content.height + titleBar
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = visible.minX
            frame.origin.y = visible.minY
        }
        window.setFrame(frame, display: true)
        return describe(window)
    }

    public static func measureKeyWindow() -> String {
        guard let window = targetWindow() else { return "missing" }
        return describe(window)
    }

    private static func targetWindow() -> NSWindow? {
        let visible = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        return visible.max { $0.frame.width < $1.frame.width }
    }

    private static func describe(_ window: NSWindow) -> String {
        let fitted = window.frame
        let content = window.contentLayoutRect.size
        let titleBar = max(0, fitted.height - content.height)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let minimum = window.contentMinSize
        return String(
            format: "frame=%.1fx%.1f;content=%.1fx%.1f;min=%.1fx%.1f;screen=%.1fx%.1f;title=%.1f",
            fitted.width,
            fitted.height,
            content.width,
            content.height,
            minimum.width,
            minimum.height,
            visible.width,
            visible.height,
            titleBar
        )
    }
}
