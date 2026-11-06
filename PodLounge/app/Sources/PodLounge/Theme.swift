import SwiftUI

enum LoungeTheme {
    static let background = Color(red: 0.027, green: 0.055, blue: 0.090)
    static let backgroundRaised = Color(red: 0.045, green: 0.078, blue: 0.110)
    static let panel = Color(red: 0.055, green: 0.095, blue: 0.125)
    static let field = Color(red: 0.035, green: 0.060, blue: 0.080)
    static let cyan = Color(red: 0.18, green: 0.90, blue: 0.93)
    static let text = Color(red: 0.90, green: 0.96, blue: 0.97)
    static let textDim = Color(red: 0.55, green: 0.68, blue: 0.73)
    static let amber = Color(red: 0.93, green: 0.72, blue: 0.28)
    static let original = Color(red: 0.45, green: 0.72, blue: 0.98)
    static let result = Color(red: 0.40, green: 0.86, blue: 0.58)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.45)
}

struct LoungeButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? Color(red: 0.03, green: 0.08, blue: 0.10) : LoungeTheme.cyan)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? LoungeTheme.cyan : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LoungeTheme.cyan.opacity(prominent ? 0 : 0.75), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct LoungePanel: ViewModifier {
    var stroke: Color = LoungeTheme.cyan.opacity(0.55)
    var radius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LoungeTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
    }
}

extension View {
    func loungePanel(stroke: Color = LoungeTheme.cyan.opacity(0.55), radius: CGFloat = 14) -> some View {
        modifier(LoungePanel(stroke: stroke, radius: radius))
    }
}
