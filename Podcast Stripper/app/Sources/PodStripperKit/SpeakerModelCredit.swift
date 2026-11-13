import SwiftUI

public extension Notification.Name {
    static let showStripperAbout = Notification.Name("cougarCalcShowStripperAbout")
}

enum SpeakerModelCredit {
    static let full = """
    Speaker detection uses pyannote/speaker-diarization-community-1. \
    The model is included with this app. Its license is Creative Commons \
    Attribution 4.0 (CC-BY-4.0). CougarCalc does not claim to own it.

    The model card credits:
    • Segmentation — Alexis Plaquet and Hervé Bredin, “Powerset multi-class cross entropy loss for neural speaker diarization,” INTERSPEECH 2023.
    • Embedding — WeSpeaker: Hongji Wang, Chengdong Liang, Shuai Wang, Zhengyang Chen, Binbin Zhang, Xu Xiang, Yanlei Deng, and Yanmin Qian, ICASSP 2023. The VoxCeleb embedding follows CC-BY-4.0.
    • Clustering — VBx: Federico Landini, Ján Profant, Mireia Diez, and Lukáš Burget, Computer Speech & Language, 2022.
    • PLDA — trained by the BUT Speech@FIT group. Jiangyu Han and Petr Pálka integrated VBx in pyannote.audio.

    Model page: https://huggingface.co/pyannote/speaker-diarization-community-1
    License: https://creativecommons.org/licenses/by/4.0/
    """
}

struct AboutStripperView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build, !build.isEmpty {
            return "\(version) (\(build))"
        }
        return version
    }

    var body: some View {
        ZStack {
            StripperTheme.windowBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("PODSTRIPPER")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(StripperTheme.cyan)
                Text("Version \(appVersion)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(StripperTheme.lime)
                Text("Audio is processed on this Mac.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(StripperTheme.textSecondary)
                ScrollView {
                    Text(SpeakerModelCredit.full)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(StripperTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
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
        .frame(width: 560, height: 480)
        .preferredColorScheme(.dark)
    }
}
