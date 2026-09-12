import AppKit
import SwiftUI

/// Shared publisher identity for the CougarCalc podcast tools suite.
enum CougarCalcBrand {
    static let company = "CougarCalc"
    static let suiteName = "CougarCalc Podcast Suite"
    /// Update when the real domain is live.
    static let websiteURL = URL(string: "https://cougarcalc.com")!
    static let supportEmail = "hello@cougarcalc.com"
    static let copyrightYear = 2026

    static var copyrightLine: String {
        "© \(copyrightYear) \(company)"
    }

    static var supportMailto: URL {
        URL(string: "mailto:\(supportEmail)?subject=\(company)%20Support")!
    }

    /// Marketing version from Info.plist (CFBundleShortVersionString).
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// Build number from Info.plist (CFBundleVersion).
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var versionLabel: String {
        "Version \(shortVersion) (\(buildNumber))"
    }
}

struct AboutSupportPanel: View {
    var appName: String
    var tagline: String
    var accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.2))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Text(String(appName.prefix(1)))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(appName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.88, green: 0.94, blue: 0.96))
                    Text(tagline)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.55, green: 0.68, blue: 0.72))
                    Text(CougarCalcBrand.versionLabel)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                }
                Spacer(minLength: 0)
            }

            Divider().overlay(accent.opacity(0.25))

            VStack(alignment: .leading, spacing: 6) {
                Text(CougarCalcBrand.suiteName)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.88, green: 0.94, blue: 0.96))
                Text(CougarCalcBrand.copyrightLine)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.68, blue: 0.72))
                Text("macOS 14+ · Offline processing · No account required")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.68, blue: 0.72))
            }

            HStack(spacing: 10) {
                Button("EMAIL SUPPORT") {
                    NSWorkspace.shared.open(CougarCalcBrand.supportMailto)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)

                Button("WEBSITE") {
                    NSWorkspace.shared.open(CougarCalcBrand.websiteURL)
                }
                .buttonStyle(.bordered)
            }

            Text(CougarCalcBrand.supportEmail)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(accent.opacity(0.85))
                .textSelection(.enabled)
        }
        .padding(20)
        .frame(maxWidth: 400)
    }
}
