import SwiftUI

/// Shared suite look with Podcast Stripper / Fixer Mixer (dark panel + cyan neon).
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
