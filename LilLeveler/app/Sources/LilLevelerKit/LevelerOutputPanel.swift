import SwiftUI

/// Output choices shared by PodLeveler Export and the Limiter workspace.
/// Existing meters, presets, and transport are not drawn here.
struct LevelerOutputPanel: View {
    @ObservedObject var session: LevelerSession
    @Binding var settings: LevelerOutputSettings
    var resultName: Binding<String>?
    var followsSource: Binding<Bool>?
    var primaryTitle: String
    var primaryHelp: String
    var primaryDisabled: Bool
    var primaryAction: () -> Void
    /// Stretch the card and pin the save button to the bottom of the column.
    var fillsColumn: Bool = false
    /// Draws the save button under the result name (Lounge: Export File to Depot).
    var includesPrimaryButton: Bool = true

    private var sourceRate: Double {
        session.sourceSampleRate > 0 ? session.sourceSampleRate : 48_000
    }

    private var selectedRate: Double {
        settings.resolvedSampleRate(sourceRate: sourceRate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: fillsColumn ? 8 : 10) {
            Text("OUTPUT")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(LevelerTheme.cyanDim)

            VStack(alignment: .leading, spacing: 6) {
                Text("FILE TYPE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(LevelerTheme.cyanDim)
                HStack(spacing: 8) {
                    ForEach(LevelerContainer.allCases) { container in
                        containerButton(container)
                    }
                }
            }

            if settings.container == .m4a {
                Text("AAC · 256 kbps stereo · 44.1 or 48 kHz")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(LevelerTheme.textSecondary)
            } else if settings.container == .mp3 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BITRATE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(LevelerTheme.cyanDim)
                    HStack(spacing: 8) {
                        ForEach(LevelerOutputSettings.mp3Bitrates, id: \.self) { bitrate in
                            choiceButton(
                                title: "\(bitrate)",
                                detail: "kbps",
                                selected: settings.mp3BitrateKbps == bitrate,
                                enabled: true,
                                identifier: "leveler.bitrate.\(bitrate)"
                            ) {
                                settings.mp3BitrateKbps = bitrate
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BIT DEPTH")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(LevelerTheme.cyanDim)
                    HStack(spacing: 8) {
                        ForEach(LevelerBitDepth.allCases) { depth in
                            choiceButton(
                                title: depth.title,
                                detail: depth.detail,
                                selected: settings.bitDepth == depth,
                                enabled: true,
                                identifier: "leveler.bit.\(depth.rawValue)"
                            ) {
                                settings.bitDepth = depth
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SAMPLE RATE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(LevelerTheme.cyanDim)
                HStack(spacing: 8) {
                    ForEach(LevelerOutputSettings.standardRates, id: \.self) { rate in
                        let enabled = settings.rateIsEnabled(rate)
                        choiceButton(
                            title: Self.rateLabel(rate),
                            detail: nil,
                            selected: abs(selectedRate - rate) < 1,
                            enabled: enabled,
                            identifier: "leveler.rate.\(Int(rate))"
                        ) {
                            settings.rateMode = .explicit(rate)
                        }
                    }
                }
            }

            if let resultName {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RESULT NAME")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(LevelerTheme.cyanDim)
                    TextField("Result name", text: resultNameBinding(resultName))
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("leveler.resultName")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .foregroundStyle(LevelerTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(LevelerTheme.panelRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(LevelerTheme.cyan.opacity(0.35), lineWidth: 1)
                        )
                }
            }

            if fillsColumn, includesPrimaryButton {
                Spacer(minLength: 8)
            }

            if session.isBusy, session.renderFraction > 0 {
                ProgressView(value: session.renderFraction)
                    .tint(LevelerTheme.cyan)
                Text(session.status)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(LevelerTheme.textSecondary)
                    .lineLimit(2)
            }

            if includesPrimaryButton {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(LevelerPrimaryButtonStyle())
                    .disabled(primaryDisabled || settings.container.isWritable == false)
                    .help(primaryHelp)
                    .accessibilityIdentifier("leveler.export")
            }
        }
        .padding(fillsColumn ? 10 : 12)
        .frame(maxWidth: .infinity, maxHeight: fillsColumn ? .infinity : nil, alignment: .top)
        .levelerPanel(glow: true)
        .onChange(of: settings.container) { _, container in
            guard container == .m4a || container == .mp3 else { return }
            if case let .explicit(rate) = settings.rateMode,
               settings.rateIsEnabled(rate) == false {
                settings.rateMode = .explicit(48_000)
            }
        }
    }

    private func containerButton(_ container: LevelerContainer) -> some View {
        let enabled = container.isWritable
        return Button {
            guard enabled else { return }
            settings.container = container
        } label: {
            VStack(spacing: 2) {
                Text(container.title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if container == .mp3, enabled == false {
                    Text("encoder missing")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(enabled ? (settings.container == container ? LevelerTheme.bgBottom : LevelerTheme.cyan) : LevelerTheme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(settings.container == container && enabled ? LevelerTheme.lime : LevelerTheme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LevelerTheme.cyan.opacity(enabled ? 0.4 : 0.15), lineWidth: 1)
            )
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("leveler.container.\(container.rawValue)")
    }

    private func choiceButton(
        title: String,
        detail: String?,
        selected: Bool,
        enabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                if let detail {
                    Text(detail)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(enabled ? (selected ? LevelerTheme.bgBottom : LevelerTheme.cyan) : LevelerTheme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected && enabled ? LevelerTheme.lime : LevelerTheme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LevelerTheme.cyan.opacity(enabled ? 0.4 : 0.15), lineWidth: 1)
            )
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

    private func resultNameBinding(_ source: Binding<String>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue },
            set: { newValue in
                source.wrappedValue = newValue
                followsSource?.wrappedValue = false
            }
        )
    }

    private static func rateLabel(_ rate: Double) -> String {
        if abs(rate - 44_100) < 1 { return "44.1 kHz" }
        if abs(rate - 48_000) < 1 { return "48 kHz" }
        if abs(rate - 88_200) < 1 { return "88.2 kHz" }
        if abs(rate - 96_000) < 1 { return "96 kHz" }
        return String(format: "%.1f kHz", rate / 1000)
    }
}
