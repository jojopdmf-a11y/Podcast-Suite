import SwiftUI

/// Shared suite look with PodStripper (dark panel + cyan neon).
enum MixerTheme {
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
    func mixerPanel(cornerRadius: CGFloat = 12, glow: Bool = false) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(MixerTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(MixerTheme.cyan.opacity(glow ? 0.9 : 0.35), lineWidth: 1.1)
                    .shadow(color: glow ? MixerTheme.cyan.opacity(0.4) : .clear, radius: glow ? 8 : 0)
            )
    }
}

struct MixerPrimaryButtonStyle: ButtonStyle {
    var compact: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 7 : 10)
            .foregroundStyle(MixerTheme.bgBottom)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? MixerTheme.lime : MixerTheme.cyan)
                    .shadow(color: MixerTheme.cyan.opacity(0.45), radius: configuration.isPressed ? 3 : 8)
            )
    }
}

struct MixerGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(configuration.isPressed ? MixerTheme.lime : MixerTheme.cyan)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MixerTheme.panelRaised))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MixerTheme.cyan.opacity(0.45), lineWidth: 1)
            )
    }
}

struct MixerRecordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(MixerTheme.bgBottom)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? MixerTheme.meterRed : MixerTheme.danger)
            )
    }
}

struct MixerStandbyButtonStyle: ButtonStyle {
    var engaged: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(engaged ? MixerTheme.bgBottom : MixerTheme.lime)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(engaged ? MixerTheme.lime : MixerTheme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MixerTheme.lime.opacity(engaged ? 0.95 : 0.55), lineWidth: engaged ? 1.4 : 1)
            )
    }
}

/// Shared SEL control — selected = solid lime fill, black “SEL” + black dot (Julie’s style).
struct SelectChannelButton: View {
    var isSelected: Bool
    /// Master strip uses a full-width SEL; channel strips stay compact.
    var expandsHorizontally: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("SEL")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.4)
                Circle()
                    .fill(isSelected ? MixerTheme.bgBottom : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .foregroundStyle(isSelected ? MixerTheme.bgBottom : MixerTheme.cyan)
            .frame(maxWidth: expandsHorizontally ? .infinity : nil)
            .frame(minWidth: expandsHorizontally ? nil : 54, minHeight: 28)
            .padding(.horizontal, expandsHorizontally ? 0 : 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? MixerTheme.lime : MixerTheme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        isSelected ? MixerTheme.lime : MixerTheme.cyan.opacity(0.45),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
