import PodLoungeCore
import SwiftUI

struct DepotSidebar: View {
    @EnvironmentObject private var session: ProjectSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DEPOT")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(LoungeTheme.textDim)
                    Text("Project audio")
                        .font(.system(size: 16, weight: .semibold))
                }
                Spacer()
                Button("Import Audio") { session.importAudio() }
                    .buttonStyle(LoungeButtonStyle(prominent: true))
                    .disabled(session.package == nil)
            }
            Text("Files live inside this project. Import copies once. Save Project does not copy them again.")
                .font(.system(size: 11))
                .foregroundStyle(LoungeTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            if session.package == nil {
                Text("Create or open a project to keep audio in the package.")
                    .font(.system(size: 13))
                    .foregroundStyle(LoungeTheme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 12)
            } else {
                assetList
                selectedSection
            }
            savingNotes
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LoungeTheme.backgroundRaised)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LoungeTheme.cyan.opacity(0.18))
                .frame(width: 1)
        }
    }

    private var assetList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("NAME")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("KIND")
                    .frame(width: 72, alignment: .leading)
                Text("LENGTH")
                    .frame(width: 52, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(LoungeTheme.textDim)
            ScrollView {
                VStack(spacing: 4) {
                    if session.assets.isEmpty {
                        Text("No audio yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(LoungeTheme.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    ForEach(session.assets) { asset in
                        DepotRow(asset: asset)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var selectedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SELECTED")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(LoungeTheme.textDim)
            if let asset = session.assets.first(where: { $0.id == session.selectedAssetID }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text("\(asset.kind.label)  ·  \(ByteCountLabel.string(asset.byteCount))")
                        .font(.system(size: 11))
                        .foregroundStyle(LoungeTheme.textDim)
                    Text(asset.relativePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LoungeTheme.cyan.opacity(0.85))
                        .lineLimit(2)
                    healthLabel(session.health(of: asset))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .loungePanel(radius: 10)
            } else {
                Text("Select a depot file.")
                    .font(.system(size: 12))
                    .foregroundStyle(LoungeTheme.textDim)
            }
        }
    }

    private var savingNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How saving works")
                .font(.system(size: 12, weight: .semibold))
            Text("Save Project updates the manifest and settings atomically. It does not rewrite depot audio or add another copy.")
                .font(.system(size: 11))
                .foregroundStyle(LoungeTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Button("Save Result") {}
                .buttonStyle(LoungeButtonStyle())
                .disabled(true)
            Text("Save Result stays off until a tool can write a finished file into depot/results.")
                .font(.system(size: 11))
                .foregroundStyle(LoungeTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text("Package v\(PackageLayout.formatVersion)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LoungeTheme.textDim)
        }
    }

    @ViewBuilder
    private func healthLabel(_ health: AssetHealth) -> some View {
        switch health {
        case .present:
            EmptyView()
        case .missing:
            Text("Missing file in the package. Save will not recreate it.")
                .font(.system(size: 11))
                .foregroundStyle(LoungeTheme.danger)
        case .sizeMismatch:
            Text("File size differs from the manifest. Save will not rewrite it.")
                .font(.system(size: 11))
                .foregroundStyle(LoungeTheme.amber)
        }
    }
}

private struct DepotRow: View {
    @EnvironmentObject private var session: ProjectSession
    let asset: DepotAsset
    @State private var length = "—"

    var body: some View {
        let selected = session.selectedAssetID == asset.id
        Button {
            session.select(asset)
        } label: {
            HStack(spacing: 6) {
                Text(asset.displayName)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(asset.kind.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(asset.kind == .original ? LoungeTheme.original : LoungeTheme.result)
                    .frame(width: 72, alignment: .leading)
                Text(length)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LoungeTheme.textDim)
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? LoungeTheme.cyan.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(selected ? LoungeTheme.cyan.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .task(id: asset.id) {
            length = await loadLength()
        }
    }

    private func loadLength() async -> String {
        guard session.health(of: asset) == .present, let package = session.package else {
            return "—"
        }
        let url = try? package.resolvedURL(for: asset)
        return AudioDuration.label(for: url)
    }
}

enum ByteCountLabel {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
