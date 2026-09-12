import AppKit
import SwiftUI

struct MixerExportItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case voice(Int)
        case music
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
    var onCancel: () -> Void
    var onExport: () -> Void

    private var canExport: Bool {
        items.contains(where: \.enabled) && folder != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("EXPORT")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(MixerTheme.cyan)
                Text("Check what to write, then name each file. All exports are WAV.")
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
                                Text(".wav")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(MixerTheme.textSecondary)
                                    .frame(width: 36, alignment: .leading)
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
        .frame(width: 560)
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
        panel.message = "Folder for the WAV files you checked"
        panel.directoryURL = folder
        if panel.runModal() == .OK {
            folder = panel.url
        }
    }
}
