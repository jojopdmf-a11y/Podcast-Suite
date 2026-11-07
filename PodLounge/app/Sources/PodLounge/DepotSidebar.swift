import PodLoungeCore
import SwiftUI

struct DepotSidebar: View {
    @EnvironmentObject private var session: ProjectSession

    var body: some View {
        GeometryReader { geo in
            // A long list scrolls. A short one stays as tall as its rows.
            // Room below the list for the selected-file actions, including Export Copy and Show in Finder.
            let listCap = max(72, geo.size.height - 440)
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
                    Spacer(minLength: 8)
                    Button("Import Audio") { session.importAudio() }
                        .buttonStyle(LoungeButtonStyle(prominent: true))
                        .disabled(session.package == nil || session.limiterExporting)
                }
                if session.limiterExporting {
                    Text("Exporting…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LoungeTheme.amber)
                    Text("The depot stays locked until the file is written.")
                        .font(.system(size: 11))
                        .foregroundStyle(LoungeTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Files live inside this project. Import copies once. Save Project does not copy them again.")
                    .font(.system(size: 11))
                    .foregroundStyle(LoungeTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                if session.package == nil {
                    Text("Create or open a project to keep audio in the package.")
                        .font(.system(size: 13))
                        .foregroundStyle(LoungeTheme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        columnHeader
                        if session.assets.count > 8 {
                            ScrollView { assetRows }
                                .frame(height: listCap)
                        } else {
                            assetRows
                        }
                    }
                    .fixedSize(horizontal: false, vertical: session.assets.count <= 8)
                    selectedSection
                }
                savingNotes
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(LoungeTheme.backgroundRaised)
    }

    private var columnHeader: some View {
        HStack {
            Color.clear.frame(width: 22)
            Text("NAME")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("KIND")
                .frame(width: 72, alignment: .leading)
            Text("LENGTH")
                .frame(width: 52, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(LoungeTheme.textDim)
    }

    private var assetRows: some View {
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
        .opacity(session.limiterExporting ? 0.35 : 1)
        .allowsHitTesting(!session.limiterExporting)
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
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Export Copy…") { session.exportCopy(of: asset) }
                            .buttonStyle(LoungeButtonStyle())
                            .disabled(exportActionsDisabled(asset))
                        Button("Show in Finder") { session.showInFinder(asset) }
                            .buttonStyle(LoungeButtonStyle())
                            .disabled(exportActionsDisabled(asset))
                        Button("Delete from Project") { session.deleteAsset(asset) }
                            .buttonStyle(LoungeButtonStyle())
                            .disabled(session.limiterExporting)
                    }
                    .padding(.top, 4)
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
            Text("In Limiter, Export File to Depot adds a new file under depot/results. The original is not changed.")
                .font(.system(size: 11))
                .foregroundStyle(LoungeTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text("Package v\(PackageLayout.formatVersion)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LoungeTheme.textDim)
        }
    }

    private func exportActionsDisabled(_ asset: DepotAsset) -> Bool {
        session.limiterExporting || session.health(of: asset) == .missing
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
    @EnvironmentObject private var player: DepotPreviewPlayer
    let asset: DepotAsset
    @State private var length = "—"

    private var playing: Bool { player.playingAssetID == asset.id }

    var body: some View {
        let selected = session.selectedAssetID == asset.id
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    session.toggleDepotPlayback(asset)
                } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(canPlay ? LoungeTheme.cyan : LoungeTheme.textDim)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(LoungeTheme.cyan.opacity(playing ? 0.22 : 0.08))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canPlay || session.limiterExporting)
                .help(playing ? "Stop" : "Play this file as it is, with no processing")
                .accessibilityLabel(playing ? "Stop \(asset.displayName)" : "Play \(asset.displayName)")

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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.limiterExporting)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? LoungeTheme.cyan.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? LoungeTheme.cyan.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            if playing {
                Capsule()
                    .fill(LoungeTheme.cyan)
                    .frame(height: 2)
                    .scaleEffect(x: max(0.02, CGFloat(player.progress)), y: 1, anchor: .leading)
                    .padding(.horizontal, 6)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            Button("Export Copy…") { session.exportCopy(of: asset) }
                .disabled(session.limiterExporting || session.health(of: asset) == .missing)
            Button("Show in Finder") { session.showInFinder(asset) }
                .disabled(session.limiterExporting || session.health(of: asset) == .missing)
            Button("Delete from Project…") { session.deleteAsset(asset) }
                .disabled(session.limiterExporting)
        }
        .task(id: asset.id) {
            length = await loadLength()
        }
    }

    private var canPlay: Bool {
        session.package != nil && session.health(of: asset) == .present
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
