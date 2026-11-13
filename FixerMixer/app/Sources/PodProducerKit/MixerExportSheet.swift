import AppKit
import SwiftUI

enum MixerBounceFormat: String, CaseIterable, Identifiable, Sendable {
    case wav16
    case wav24
    case aiff24

    var id: String { rawValue }

    var pathExtension: String {
        switch self {
        case .wav16, .wav24: return "wav"
        case .aiff24: return "aiff"
        }
    }

    var menuTitle: String {
        switch self {
        case .wav16: return "WAV 16-bit"
        case .wav24: return "WAV 24-bit"
        case .aiff24: return "AIFF 24-bit"
        }
    }
}

enum MixerBounceRate: Hashable, Identifiable, Sendable {
    case native
    case hz(Int)

    var id: String {
        switch self {
        case .native: return "native"
        case .hz(let value): return "\(value)"
        }
    }

    static let choices: [MixerBounceRate] = [.native, .hz(44_100), .hz(48_000), .hz(96_000)]

    func resolved(native: Double) -> Double {
        switch self {
        case .native: return native
        case .hz(let value): return Double(value)
        }
    }

    func menuTitle(native: Double) -> String {
        switch self {
        case .native:
            let hz = max(1, Int(native.rounded()))
            return "Native (\(hz) Hz)"
        case .hz(44_100):
            return "44.1 kHz"
        case .hz(48_000):
            return "48 kHz"
        case .hz(96_000):
            return "96 kHz"
        case .hz(let value):
            return "\(value) Hz"
        }
    }
}

struct MixerExportItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case voice(Int)
        case stereo(Int)
        case mix
    }

    let id: String
    var kind: Kind
    var enabled: Bool
    var name: String
    var label: String
    var role: String
}

struct MixerExportSheet: View {
    @Binding var items: [MixerExportItem]
    @Binding var folder: URL?
    var nativeSampleRate: Double
    @Binding var sampleRate: MixerBounceRate
    @Binding var format: MixerBounceFormat
    var onCancel: () -> Void
    var onExport: () -> Void

    private var canExport: Bool {
        items.contains(where: \.enabled) && folder != nil
    }

    private var fileExtension: String { ".\(format.pathExtension)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("EXPORT")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.cyan)
                Text("Check what to write, then name each file. Playback stays at this session’s rate. Convert here if you need another rate or format.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MixerTheme.textSecondary)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($items) { $item in
                        HStack(alignment: .center, spacing: 10) {
                            Toggle("", isOn: $item.enabled)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .tint(MixerTheme.cyan)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(MixerTheme.textPrimary)
                                    .lineLimit(1)
                                Text(item.role)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(MixerTheme.textSecondary)
                            }
                            .frame(width: 150, alignment: .leading)

                            HStack(spacing: 4) {
                                TextField("File name", text: $item.name)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(MixerTheme.textPrimary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(MixerTheme.panelRaised)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(MixerTheme.cyan.opacity(0.35), lineWidth: 1)
                                    )
                                    .disabled(!item.enabled)
                                    .opacity(item.enabled ? 1 : 0.45)
                                Text(fileExtension)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(MixerTheme.textSecondary)
                                    .frame(width: 52, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MixerTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MixerTheme.cyan.opacity(0.3), lineWidth: 1)
            )

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SAMPLE RATE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(MixerTheme.cyanDim)
                    Picker("Sample rate", selection: $sampleRate) {
                        ForEach(MixerBounceRate.choices) { choice in
                            Text(choice.menuTitle(native: nativeSampleRate)).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 160)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("FORMAT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(MixerTheme.cyanDim)
                    Picker("Format", selection: $format) {
                        ForEach(MixerBounceFormat.allCases) { choice in
                            Text(choice.menuTitle).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 140)
                }
                Spacer(minLength: 8)
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SAVE TO")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(MixerTheme.cyanDim)
                    Text(folder?.path ?? "Choose a folder")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(MixerTheme.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("CHOOSE FOLDER…") { pickFolder() }
                    .buttonStyle(MixerGhostButtonStyle())
            }

            HStack {
                Button("CANCEL") { onCancel() }
                    .buttonStyle(MixerGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("EXPORT") { onExport() }
                    .buttonStyle(MixerPrimaryButtonStyle())
                    .disabled(!canExport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(MixerTheme.windowBackground)
        .preferredColorScheme(.dark)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Folder for the files you checked"
        panel.directoryURL = folder
        if panel.runModal() == .OK {
            folder = panel.url
        }
    }
}
