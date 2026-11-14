import LilLevelerKit
import PodLoungeCore
import PodStripperKit
import SwiftUI

/// PodStripper aimed at the selected depot file.
struct StripperWorkspaceView: View {
    @EnvironmentObject private var session: ProjectSession
    @StateObject private var model = StripperLoungeModel(chrome: .lounge)
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button("← Lounge") { session.leaveWorkspace() }
                    .buttonStyle(LoungeButtonStyle())
                    .disabled(session.navigationLocked)
                    .accessibilityIdentifier("lounge.back")
                VStack(alignment: .leading, spacing: 1) {
                    RoomTitleText(workspace: .stripper, size: 18)
                    Text("The selected depot file is the source. Dropping a new file imports it. Only Split Into Tracks starts a split.")
                        .font(.system(size: 11))
                        .foregroundStyle(LoungeTheme.textDim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 8)
                Button("Project Notes") { showNotes = true }
                    .buttonStyle(LoungeButtonStyle())
                    .accessibilityIdentifier("stripper.notes")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            StripperRootView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            wire()
            session.sweepAbandonedStripperStaging(keeping: nil)
            refreshInput()
            revealSampleNamingIfAsked()
        }
        .onChange(of: session.selectedAssetID) { _, _ in
            refreshInput()
        }
        .onChange(of: session.package?.rootURL) { _, _ in
            refreshInput()
        }
        .sheet(isPresented: $showNotes) {
            StripperNotesSheet()
        }
    }

    private func wire() {
        model.makeStagingDirectory = {
            session.sweepAbandonedStripperStaging(keeping: nil)
            guard let package = session.package else {
                throw PackageError.operationFailed("Create or open a project before splitting.")
            }
            return try package.makeStripperStagingDirectory()
        }
        model.onImportExternal = { url in
            session.importStripperSource(url)
        }
        model.onChooseOutsideFolder = {
            session.chooseStripperOutsideFolder(model)
        }
        model.onUseDepot = {
            model.outsideFolder = nil
        }
        model.onShowInFinder = {
            session.revealStripperFinder(model)
        }
        model.onSplitFinished = { job in
            session.presentStripperNaming(job, model: model)
        }
        model.onAddToDepot = {
            session.addStripperTracks(model)
        }
        model.onDiscardNaming = {
            session.discardStripperNaming(model)
        }
        model.onRunningChange = { running in
            session.stripperRunning = running
        }
    }

    private func refreshInput() {
        guard session.stripperRunning == false else { return }
        guard let package = session.package else {
            model.inputURL = nil
            model.inputTitle = ""
            model.inputDetail = "Open a project, then pick a depot file."
            return
        }
        guard let id = session.selectedAssetID,
              let asset = session.assets.first(where: { $0.id == id })
        else {
            model.inputURL = nil
            model.inputTitle = ""
            model.inputDetail = "Select a depot file to split."
            return
        }
        guard session.health(of: asset) == .present, let url = try? package.resolvedURL(for: asset) else {
            model.inputURL = nil
            model.inputTitle = asset.displayName
            model.inputDetail = "That depot file is missing."
            return
        }
        model.inputURL = url
        model.inputTitle = asset.displayName
        model.inputDetail = asset.relativePath
    }

    private func revealSampleNamingIfAsked() {
        guard UITestMode.argument("-UITestRevealNaming") == "1" else { return }
        let tracks = [
            URL(fileURLWithPath: "/tmp/Speaker_1.wav"),
            URL(fileURLWithPath: "/tmp/Speaker_2.wav"),
            URL(fileURLWithPath: "/tmp/Music_and_SFX.wav"),
        ]
        let drafts = StripperNaming.drafts(sourceDisplayName: "Episode.wav", splitIndex: 1, tracks: tracks)
        model.namingRows = drafts.map {
            StripperEditableTrack(id: $0.id, sourceURL: $0.sourceURL, roleLabel: $0.roleLabel, displayName: $0.displayName)
        }
        model.namingVisible = true
    }
}

private struct StripperNotesSheet: View {
    @EnvironmentObject private var session: ProjectSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project notes")
                .font(.system(size: 18, weight: .semibold))
            Text("Notes stay with this project. They are not a mix and they are not a split.")
                .font(.system(size: 12))
                .foregroundStyle(LoungeTheme.textDim)
            TextEditor(text: noteBinding)
                .font(.system(size: 13))
                .foregroundStyle(LoungeTheme.text)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minWidth: 420, minHeight: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(LoungeTheme.field))
                .disabled(session.package == nil)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(LoungeButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 360)
        .preferredColorScheme(.dark)
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { session.notes[.stripper] ?? "" },
            set: { newValue in
                var copy = session.notes
                copy[.stripper] = newValue
                session.notes = copy
            }
        )
    }
}
