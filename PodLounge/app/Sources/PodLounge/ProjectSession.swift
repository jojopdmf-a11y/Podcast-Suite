import AppKit
import Foundation
import PodLoungeCore

enum PendingNavigation: Equatable {
    case newProject
    case openProject
}

/// Owns the open `.podlounge` package and Lounge navigation.
///
/// FUTURE Fixer integration: while a take is recording, the user stays in Fixer
/// until they press Stop. `leaveWorkspace()`, New, Open, and Save must never
/// stop or discard a take. This build has no recorder and no audio engine.
@MainActor
final class ProjectSession: ObservableObject {
    @Published var package: ProjectPackage?
    @Published var projectName = ""
    @Published var notes: [WorkspaceID: String] = [:]
    @Published var selectedAssetID: String?
    @Published var activeWorkspace: WorkspaceID?
    @Published var missingAssetIDs: Set<String> = []
    @Published var mismatchedAssetIDs: Set<String> = []
    @Published var alertMessage: String?
    @Published var confirmDiscard = false
    @Published var showAbout = false

    private var pending: PendingNavigation?
    private var savedName = ""
    private var savedNotes: [WorkspaceID: String] = [:]
    private var savedSelection: String?

    var isDirty: Bool {
        projectName != savedName || notes != savedNotes || selectedAssetID != savedSelection
    }

    var assets: [DepotAsset] {
        package?.manifest.assets ?? []
    }

    func health(of asset: DepotAsset) -> AssetHealth {
        if missingAssetIDs.contains(asset.id) { return .missing }
        if mismatchedAssetIDs.contains(asset.id) { return .sizeMismatch }
        return .present
    }

    func select(_ asset: DepotAsset) {
        selectedAssetID = asset.id
    }

    func newProject() {
        guard !isDirty else {
            pending = .newProject
            confirmDiscard = true
            return
        }
        presentNewPanel()
    }

    func openProject() {
        guard !isDirty else {
            pending = .openProject
            confirmDiscard = true
            return
        }
        presentOpenPanel()
    }

    func discardAndContinue() {
        discardUnsavedEdits()
        let action = pending
        pending = nil
        confirmDiscard = false
        switch action {
        case .newProject: presentNewPanel()
        case .openProject: presentOpenPanel()
        case nil: break
        }
    }

    func saveAndContinue() {
        do {
            try save()
        } catch {
            alertMessage = error.localizedDescription
            pending = nil
            return
        }
        let action = pending
        pending = nil
        confirmDiscard = false
        switch action {
        case .newProject: presentNewPanel()
        case .openProject: presentOpenPanel()
        case nil: break
        }
    }

    func cancelPending() {
        pending = nil
        confirmDiscard = false
    }

    func saveShowingError() {
        do {
            try save()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func save() throws {
        guard let package else {
            throw PackageError.operationFailed("Create or open a project before saving.")
        }
        applyMetadata(to: package)
        try package.save()
        markClean()
        missingAssetIDs = package.missingAssetIDs
        mismatchedAssetIDs = package.mismatchedAssetIDs
    }

    func saveAs() {
        guard package != nil else {
            presentNewPanel()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Pod Lounge Project As"
        panel.prompt = "Save As"
        panel.nameFieldStringValue = package?.rootURL.deletingPathExtension().lastPathComponent ?? "Project"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = ProjectPackage.directoryURL(forPickedURL: url)
        guard let package else { return }
        do {
            applyMetadata(to: package)
            let copy = try package.saveAs(to: folder)
            adopt(copy)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func importAudio() {
        guard package != nil else {
            alertMessage = "Create or open a project before importing audio."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "A copy is stored in the project. The original file is left where it is."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    /// Navigation only. Does not stop a take — there is no recorder in this build.
    func leaveWorkspace() {
        activeWorkspace = nil
    }

    // MARK: - Private

    private func presentNewPanel() {
        let panel = NSSavePanel()
        panel.title = "New Pod Lounge Project"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Untitled Project"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = ProjectPackage.directoryURL(forPickedURL: url)
        let name = folder.deletingPathExtension().lastPathComponent
        do {
            let created = try ProjectPackage.create(at: folder, name: name)
            adopt(created)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Pod Lounge Project"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .podlounge folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let root = ProjectPackage.locateRoot(from: url) else {
            alertMessage = "That folder does not contain a Pod Lounge manifest.json."
            return
        }
        do {
            let opened = try ProjectPackage.open(at: root)
            adopt(opened)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func importFile(_ url: URL) {
        guard let package else { return }
        do {
            applyMetadata(to: package)
            _ = try package.importMedia(from: url, kind: .original, producedBy: nil, select: true)
            adopt(package, keepWorkspace: true)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func applyMetadata(to package: ProjectPackage) {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        package.manifest.projectName = trimmed.isEmpty ? "Untitled Project" : trimmed
        projectName = package.manifest.projectName
        package.manifest.selectedAssetID = selectedAssetID
        for id in WorkspaceID.allCases {
            package.manifest.workspaceSettings[id.rawValue] = WorkspaceSettings(notes: notes[id] ?? "")
        }
    }

    private func adopt(_ package: ProjectPackage, keepWorkspace: Bool = false) {
        let workspace = keepWorkspace ? activeWorkspace : nil
        self.package = package
        projectName = package.manifest.projectName
        var nextNotes: [WorkspaceID: String] = [:]
        for id in WorkspaceID.allCases {
            nextNotes[id] = package.manifest.workspaceSettings[id.rawValue]?.notes ?? ""
        }
        notes = nextNotes
        selectedAssetID = package.manifest.selectedAssetID
        missingAssetIDs = package.missingAssetIDs
        mismatchedAssetIDs = package.mismatchedAssetIDs
        activeWorkspace = workspace
        markClean()
    }

    private func markClean() {
        savedName = projectName
        savedNotes = notes
        savedSelection = selectedAssetID
    }

    private func discardUnsavedEdits() {
        projectName = savedName
        notes = savedNotes
        selectedAssetID = savedSelection
        guard let package else { return }
        package.manifest.projectName = savedName
        package.manifest.selectedAssetID = savedSelection
        for id in WorkspaceID.allCases {
            package.manifest.workspaceSettings[id.rawValue] = WorkspaceSettings(notes: savedNotes[id] ?? "")
        }
    }
}
