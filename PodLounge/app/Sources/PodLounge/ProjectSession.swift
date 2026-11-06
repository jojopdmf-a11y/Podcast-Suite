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
            // The copy takes the name typed in the Save As box, so the
            // project name at the top of the Lounge matches the new file.
            copy.manifest.projectName = folder.deletingPathExtension().lastPathComponent
            do {
                try copy.save()
            } catch {
                alertMessage = error.localizedDescription
            }
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
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more files. A copy of each is stored in the project. The originals are left where they are."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importFiles(panel.urls)
    }

    /// Asks first, then removes the file from the depot and saves the project.
    func deleteAsset(_ asset: DepotAsset) {
        guard let package else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(asset.displayName)\u{201D} from this project?"
        alert.informativeText = "The copy inside the project is deleted and the project is saved. Your original file outside the project is not touched. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            applyMetadata(to: package)
            try package.removeAsset(id: asset.id)
            adopt(package, keepWorkspace: true)
        } catch {
            alertMessage = error.localizedDescription
        }
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

    /// Imports each chosen file in turn. One bad file does not stop the rest;
    /// any failures are listed by file name afterwards.
    private func importFiles(_ urls: [URL]) {
        guard let package else { return }
        applyMetadata(to: package)
        var failures: [String] = []
        var importedAny = false
        for url in urls {
            do {
                _ = try package.importMedia(from: url, kind: .original, producedBy: nil, select: true)
                importedAny = true
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if importedAny {
            adopt(package, keepWorkspace: true)
        }
        if !failures.isEmpty {
            let header = failures.count == 1 ? "1 file could not be imported:" : "\(failures.count) files could not be imported:"
            alertMessage = ([header] + failures).joined(separator: "\n")
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
