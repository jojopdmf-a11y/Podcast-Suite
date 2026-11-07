import SwiftUI

/// Shared suite look with PodStripper / PodProducer (dark panel + cyan neon).
enum LevelerTheme {
    static let bgTop = Color(red: 0.06, green: 0.09, blue: 0.12)
    static let bgBottom = Color(red: 0.03, green: 0.04, blue: 0.06)
    static let panel = Color(red: 0.08, green: 0.11, blue: 0.15)
    static let panelRaised = Color(red: 0.10, green: 0.14, blue: 0.18)
    static let cyan = Color(red: 0.20, green: 0.92, blue: 0.95)
    static let cyanDim = Color(red: 0.20, green: 0.92, blue: 0.95).opacity(0.55)
    static let cyanFaint = Color(red: 0.20, green: 0.92, blue: 0.95).opacity(0.18)
    static let lime = Color(red: 0.78, green: 0.95, blue: 0.20)
    static let textPrimary = Color(red: 0.88, green: 0.94, blue: 0.96)
    static let textSecondary = Color(red: 0.55, green: 0.68, blue: 0.72)
    static let danger = Color(red: 1.0, green: 0.35, blue: 0.38)
    static let meterGreen = Color(red: 0.25, green: 0.90, blue: 0.55)
    static let meterYellow = Color(red: 0.95, green: 0.85, blue: 0.20)
    static let meterRed = Color(red: 1.0, green: 0.30, blue: 0.35)

    static var windowBackground: some View {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Standalone PodLeveler metrics. A larger window gives the extra space to the meters.
enum LevelerLayout {
    static let windowPadding: CGFloat = 12
    static let presetColumnWidth: CGFloat = 220
    static let columnGap: CGFloat = 14
    static let faceplateWidth: CGFloat = 148
    static let ledColumnWidth: CGFloat = 38
    static let scaleWidth: CGFloat = 22
    static let meterStackHeight: CGFloat = 248
    static let meterControlsWidth: CGFloat = 100
    static let meterDeckPadding: CGFloat = 12
    static let meterDeckSpacing: CGFloat = 14

    /// Pane floors for the standalone window. Lounge keeps `LevelerPaneMetrics`.
    static let appPresetMin: CGFloat = 200
    static let appPresetDefault: CGFloat = 220
    static let appPresetMax: CGFloat = 320
    static let appCenterMin: CGFloat = 480
    static let appOutputMin: CGFloat = 276
    static let appOutputDefault: CGFloat = 292
    static let appOutputMax: CGFloat = 420
    /// Shortest meter band before the horizontal divider stops. Controls tighten inside it.
    static let applicationMeterMin: CGFloat = 248

    static var meterDeckWidth: CGFloat {
        meterDeckPadding * 2
            + faceplateWidth * 2
            + meterControlsWidth
            + meterDeckSpacing * 2
    }

    static var windowWidth: CGFloat { LevelerWindowFit.minimumContentWidth }
    static var windowHeight: CGFloat { LevelerWindowFit.minimumContentHeight }
}

/// Standalone window size. Content height stays at or under 840 so the window,
/// including its title bar, fits a 1512×982 point MacBook with the menu bar.
public enum LevelerWindowFit {
    public static let minimumContentWidth: CGFloat = 1180
    public static let minimumContentHeight: CGFloat = 840
    public static let idealContentWidth: CGFloat = 1280
    public static let idealContentHeight: CGFloat = 840
    /// Used when the real title bar has not been measured yet.
    public static let assumedTitleBarHeight: CGFloat = 28

    public struct ContentSize: Equatable, Sendable {
        public var minWidth: CGFloat
        public var minHeight: CGFloat
        public var idealWidth: CGFloat
        public var idealHeight: CGFloat

        public init(minWidth: CGFloat, minHeight: CGFloat, idealWidth: CGFloat, idealHeight: CGFloat) {
            self.minWidth = minWidth
            self.minHeight = minHeight
            self.idealWidth = idealWidth
            self.idealHeight = idealHeight
        }
    }

    /// `visible` is the screen area below the menu bar and clear of the Dock.
    /// The returned sizes are content sizes: the title bar sits on top of them.
    public static func contentSize(
        minimumWidth: CGFloat,
        minimumHeight: CGFloat,
        idealWidth: CGFloat,
        idealHeight: CGFloat,
        visible: CGRect,
        titleBar: CGFloat
    ) -> ContentSize {
        let maxWidth = max(1, visible.width)
        let maxHeight = max(1, visible.height - max(0, titleBar))
        let minWidth = min(minimumWidth, maxWidth)
        let minHeight = min(minimumHeight, maxHeight)
        let fittedIdealWidth = min(max(idealWidth, minWidth), maxWidth)
        let fittedIdealHeight = min(max(idealHeight, minHeight), maxHeight)
        return ContentSize(
            minWidth: minWidth,
            minHeight: minHeight,
            idealWidth: fittedIdealWidth,
            idealHeight: fittedIdealHeight
        )
    }
}

extension View {
    func levelerPanel(cornerRadius: CGFloat = 12, glow: Bool = false) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LevelerTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(LevelerTheme.cyan.opacity(glow ? 0.9 : 0.35), lineWidth: 1.1)
                    .shadow(color: glow ? LevelerTheme.cyan.opacity(0.4) : .clear, radius: glow ? 8 : 0)
            )
    }
}

struct LevelerPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(LevelerTheme.bgBottom)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? LevelerTheme.lime : LevelerTheme.cyan)
                    .shadow(color: LevelerTheme.cyan.opacity(0.45), radius: configuration.isPressed ? 3 : 8)
            )
    }
}

struct LevelerGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(configuration.isPressed ? LevelerTheme.lime : LevelerTheme.cyan)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LevelerTheme.panelRaised))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LevelerTheme.cyan.opacity(0.45), lineWidth: 1)
            )
    }
}
