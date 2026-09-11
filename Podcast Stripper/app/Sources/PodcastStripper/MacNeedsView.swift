import SwiftUI

/// Short in-app version of the suite Mac notes. Full copy for cougarcalc.com lives in
/// `docs/cougarcalc-system-requirements.md`.
struct MacNeedsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            StripperTheme.windowBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("YOUR MAC")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(StripperTheme.cyan)
                    .shadow(color: StripperTheme.cyan.opacity(0.35), radius: 8)
                Text("Brief notes so you know if this Mac is a fit, and about how long a split will take.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(StripperTheme.textSecondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        needBlock(title: "IT ONLY RUNS ON", body: "macOS 14 Sonoma or newer. Ventura and older will not launch the apps.")
                        needBlock(
                            title: "WE HIGHLY RECOMMEND",
                            body: "Apple Silicon (M1 or newer) with 16 GB of RAM. A Mac mini M4 is a comfortable weekly machine. Intel Macs are not recommended — same buttons, much slower."
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HOW LONG STRIPPER TAKES")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .tracking(1.0)
                                .foregroundStyle(StripperTheme.cyanDim)
                            Text("Timed on a Mac mini M4, 2 speakers, 31-minute episode: 9 minutes 23 seconds. About 18 seconds of wait per minute of show. The status line tells you the current step; the lime clock is the total when it finishes.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(StripperTheme.textPrimary)
                            timingRow("15 min episode", "~4–5 min")
                            timingRow("30 min episode", "~9 min")
                            timingRow("60 min episode", "~18 min")
                            timingRow("90 min episode", "~27 min")
                            timingRow("2 hour episode", "~35–40 min")
                            Text("First split on a new Mac can add a one-time model download. M1/M2 is often 1.5–2× these times. Mixer and Leveler stay light.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(StripperTheme.textSecondary)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("DONE") { dismiss() }
                        .buttonStyle(StripperPrimaryButtonStyle(compact: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 540, height: 520)
        .preferredColorScheme(.dark)
    }

    private func needBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(StripperTheme.cyanDim)
            Text(body)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(StripperTheme.textPrimary)
        }
    }

    private func timingRow(_ episode: String, _ wait: String) -> some View {
        HStack {
            Text(episode)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(StripperTheme.textSecondary)
            Spacer()
            Text(wait)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(StripperTheme.lime)
        }
        .padding(.vertical, 2)
    }
}
