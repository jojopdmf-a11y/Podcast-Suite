import AVFoundation
import SwiftUI

/// Short in-app version of the suite Mac notes. Full copy for cougarcalc.com lives in
/// `docs/cougarcalc-system-requirements.md`.
struct MacNeedsView: View {
    var inputFile: URL? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var mac = ThisMac.snapshot()
    @State private var episodeMinutes: Double?

    private let sampleEpisodeMinutes: [Double] = [15, 30, 60, 90, 120]

    var body: some View {
        ZStack {
            StripperTheme.windowBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("YOUR MAC")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(StripperTheme.cyan)
                    .shadow(color: StripperTheme.cyan.opacity(0.35), radius: 8)
                Text("\(mac.chip)  ·  \(mac.ramGB) GB  ·  \(mac.osLabel)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(StripperTheme.lime)
                Text(mac.fitTitle)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(mac.isIntel ? StripperTheme.danger : StripperTheme.cyan)
                Text(mac.fitDetail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(StripperTheme.textSecondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        needBlock(title: "IT ONLY RUNS ON", body: "macOS 14 Sonoma or newer. Ventura and older will not launch the apps.")
                        needBlock(
                            title: "WE HIGHLY RECOMMEND",
                            body: "Apple Silicon (M1 or newer) with 16 GB of RAM. A Mac mini M4 is a comfortable weekly machine."
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Text("ESTIMATE ON THIS MAC")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .tracking(1.0)
                                .foregroundStyle(StripperTheme.cyanDim)
                            if let episodeMinutes, episodeMinutes > 0.4 {
                                Text("Dropped file · \(Self.formatEpisode(episodeMinutes))")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(StripperTheme.textPrimary)
                                Text("About \(ThisMac.formatWait(mac.waitSeconds(forEpisodeMinutes: episodeMinutes)))")
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundStyle(StripperTheme.lime)
                            }
                            Text("Ballpark wait for a 2-speaker split. Scaled from a 31-minute episode that took 9m 23s on a Mac mini M4. The lime clock during a real split is the truth.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(StripperTheme.textPrimary)
                            ForEach(sampleEpisodeMinutes, id: \.self) { minutes in
                                timingRow(
                                    Self.formatEpisode(minutes),
                                    "~\(ThisMac.formatWait(mac.waitSeconds(forEpisodeMinutes: minutes)))"
                                )
                            }
                            Text("First split on a new Mac can add a one-time model download. Mixer and Leveler stay light.")
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
        .frame(width: 540, height: 560)
        .preferredColorScheme(.dark)
        .task(id: inputFile?.path) {
            episodeMinutes = await Self.loadEpisodeMinutes(inputFile)
        }
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

    private static func formatEpisode(_ minutes: Double) -> String {
        if minutes >= 119 {
            return "2 hour episode"
        }
        let whole = Int(minutes.rounded())
        return "\(whole) min episode"
    }

    private static func loadEpisodeMinutes(_ url: URL?) async -> Double? {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 1 else { return nil }
            return seconds / 60.0
        } catch {
            return nil
        }
    }
}
