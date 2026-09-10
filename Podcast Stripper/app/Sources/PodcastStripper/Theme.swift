import SwiftUI

/// Shared pro-audio look for the Cougar podcast tool suite.
/// Dark panel + cyan neon accents (Waves-style plugin vibe).
enum StripperTheme {
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
    static let success = Color(red: 0.35, green: 0.92, blue: 0.55)

    static var windowBackground: some View {
        LinearGradient(
            colors: [bgTop, bgBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func labelStyle() -> some ShapeStyle {
        cyanDim
    }
}

struct GlowBorder: ViewModifier {
    var color: Color = StripperTheme.cyan
    var lineWidth: CGFloat = 1.2
    var cornerRadius: CGFloat = 14
    var glow: Bool = true

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(color.opacity(0.85), lineWidth: lineWidth)
                    .shadow(color: glow ? color.opacity(0.45) : .clear, radius: glow ? 8 : 0)
            )
    }
}

extension View {
    func stripperPanel(cornerRadius: CGFloat = 14, glow: Bool = false) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(StripperTheme.panel)
            )
            .modifier(GlowBorder(color: StripperTheme.cyan.opacity(glow ? 1 : 0.35), cornerRadius: cornerRadius, glow: glow))
    }
}
