import AppKit
import Foundation
import LilLevelerKit
import PodLoungeCore
import PodStripperKit

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
    @Published var showThirdPartyNotices = false
    @Published var limiterSettings = LimiterWorkspaceSettings.defaults
    /// True while the Limiter is rendering or copying a result. Depot clicks wait.
    @Published var limiterExporting = false
    /// True while Stripper is splitting. Leaving, New, Open, and depot edits wait.
    @Published var stripperRunning = false

    var navigationLocked: Bool { limiterExporting || stripperRunning }

    /// Set by the Limiter workspace so leaving the card stops playback.
    var endLimiterPlayback: (() -> Void)?
    /// Stops Limiter transport without unloading the file. Depot preview calls this.
    var stopLimiterPlayback: (() -> Void)?
    let depotPlayer = DepotPreviewPlayer()

    private var pending: PendingNavigation?
    private var savedName = ""
    private var savedNotes: [WorkspaceID: String] = [:]
    private var savedSelection: String?
    private var savedLimiterSettings = LimiterWorkspaceSettings.defaults

    var isDirty: Bool {
        projectName != savedName
            || notes != savedNotes
            || selectedAssetID != savedSelection
            || limiterSettings != savedLimiterSettings
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
        guard !navigationLocked else { return }
        selectedAssetID = asset.id
    }

    /// Plays the depot file as stored. A second file, or the same file again, stops the first.
    func toggleDepotPlayback(_ asset: DepotAsset) {
        guard !navigationLocked else { return }
        if depotPlayer.playingAssetID == asset.id {
            stopDepotPlayback()
            return
        }
        guard health(of: asset) == .present,
              let package,
              let url = try? package.resolvedURL(for: asset)
        else {
            stopDepotPlayback()
            alertMessage = "That depot file can't be played."
            return
        }
        stopLimiterPlayback?()
        do {
            try depotPlayer.play(assetID: asset.id, url: url)
        } catch {
            stopDepotPlayback()
            alertMessage = error.localizedDescription
        }
    }

    func stopDepotPlayback() {
        depotPlayer.stop()
    }

    /// Opens a card. Ignored while a Limiter export is still writing.
    func openWorkspace(_ workspace: WorkspaceID) {
        guard !navigationLocked else { return }
        activeWorkspace = workspace
    }

    func newProject() {
        guard !navigationLocked else { return }
        guard !isDirty else {
            pending = .newProject
            confirmDiscard = true
            return
        }
        presentNewPanel()
    }

    func openProject() {
        guard !navigationLocked else { return }
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
            report(error)
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
            report(error)
        }
    }

    func save() throws {
        guard let package else {
            throw PackageError.operationFailed("Create or open a project before saving.")
        }
        applyMetadata(to: package)
        try package.writeLimiterSettings(limiterSettings)
        try package.save()
        markClean()
        missingAssetIDs = package.missingAssetIDs
        mismatchedAssetIDs = package.mismatchedAssetIDs
    }

    func saveAs() {
        if UITestMode.enabled {
            alertMessage = "UI test does not use Save As."
            return
        }
        guard !navigationLocked else { return }
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
            do {
                try copy.writeLimiterSettings(limiterSettings)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            // The copy takes the name typed in the Save As box, so the
            // project name at the top of the Lounge matches the new file.
            copy.manifest.projectName = folder.deletingPathExtension().lastPathComponent
            do {
                try copy.save()
            } catch {
                report(error)
            }
            adopt(copy)
        } catch {
            report(error)
        }
    }

    func importAudio() {
        guard !navigationLocked else { return }
        guard package != nil else {
            alertMessage = "Create or open a project before importing audio."
            return
        }
        if UITestMode.enabled {
            guard let raw = UITestMode.argument("-UITestImport") else {
                alertMessage = "UI test import path is missing."
                return
            }
            let urls = raw.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            importFiles(urls)
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
        if UITestMode.enabled { return }
        guard !navigationLocked else { return }
        guard let package else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(asset.displayName)\u{201D} from this project?"
        alert.informativeText = "The copy inside the project is deleted and the project is saved. Your original file outside the project is not touched. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if depotPlayer.playingAssetID == asset.id {
            stopDepotPlayback()
        }
        do {
            applyMetadata(to: package)
            try package.writeLimiterSettings(limiterSettings)
            try package.removeAsset(id: asset.id)
            adopt(package, keepWorkspace: true)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Navigation only. Stops Limiter playback. Does not delete depot audio.
    /// Does not stop a Fixer take — there is no recorder in this build.
    func leaveWorkspace() {
        guard !navigationLocked else { return }
        stopDepotPlayback()
        if activeWorkspace == .limiter {
            endLimiterPlayback?()
        }
        activeWorkspace = nil
    }

    /// Renders nothing itself. The Limiter workspace passes a finished file.
    /// The original depot bytes are not rewritten, and the selection stays on
    /// the file that was leveled.
    func importLimiterResult(from url: URL, displayName: String) throws {
        guard let package else {
            throw PackageError.operationFailed("Create or open a project before saving a result.")
        }
        applyMetadata(to: package)
        try package.writeLimiterSettings(limiterSettings)
        _ = try package.importResult(
            from: url,
            producedBy: "limiter",
            displayName: displayName,
            select: false
        )
        adopt(package, keepWorkspace: true)
    }

    /// Drop or choose on the Stripper screen. An outside file is copied in as an
    /// original and selected. A file already in the depot is only selected.
    /// Neither path starts a split.
    func importStripperSource(_ url: URL) {
        guard !navigationLocked else { return }
        guard package != nil else {
            alertMessage = "Create or open a project before importing audio."
            return
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if let asset = assets.first(where: { asset in
            guard let stored = try? package?.resolvedURL(for: asset) else { return false }
            return stored.standardizedFileURL.resolvingSymlinksInPath() == resolved
        }) {
            selectedAssetID = asset.id
            return
        }
        importFiles([url])
    }

    func chooseStripperOutsideFolder(_ model: StripperLoungeModel) {
        guard !navigationLocked else { return }
        if UITestMode.enabled {
            if let raw = UITestMode.argument("-UITestStripperOutside") {
                model.outsideFolder = URL(fileURLWithPath: raw, isDirectory: true)
            }
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Extra Copy Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Tracks are always added to the project depot. This folder also gets a copy."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.outsideFolder = url
    }

    func presentStripperNaming(_ job: StripperFinishedJob, model: StripperLoungeModel) {
        guard let sourceID = selectedAssetID,
              let source = assets.first(where: { $0.id == sourceID })
        else { return }
        let index = StripperNaming.nextSplitIndex(
            sourceAssetID: sourceID,
            groups: package?.readStripperGroups() ?? []
        )
        let drafts = StripperNaming.drafts(
            sourceDisplayName: source.displayName,
            splitIndex: index,
            tracks: job.tracks
        )
        model.pendingSplitIndex = index
        model.pendingSourceAssetID = sourceID
        model.pendingSpeakersJSON = job.speakersJSON
        model.namingRows = drafts.map {
            StripperEditableTrack(
                id: $0.id,
                sourceURL: $0.sourceURL,
                roleLabel: $0.roleLabel,
                displayName: $0.displayName
            )
        }
        model.namingMessage = nil
        model.namingVisible = true
        model.revealURLs = job.tracks
    }

    func addStripperTracks(_ model: StripperLoungeModel) {
        guard let package else {
            model.namingMessage = "Create or open a project before adding tracks."
            return
        }
        let sourceID = model.pendingSourceAssetID
        guard sourceID.isEmpty == false, let speakersJSON = model.pendingSpeakersJSON else {
            model.namingMessage = "This split is missing its tracks."
            return
        }
        do {
            applyMetadata(to: package)
            try package.writeLimiterSettings(limiterSettings)
            let tracks = model.namingRows.map {
                StripperTrackImport(sourceURL: $0.sourceURL, displayName: $0.displayName)
            }
            let outcome = try package.importStripperGroup(
                tracks: tracks,
                speakersJSON: speakersJSON,
                sourceAssetID: sourceID,
                splitIndex: model.pendingSplitIndex,
                outsideDirectory: model.outsideFolder
            )
            if let staging = model.activeStagingURL {
                package.removeOwnedStripperStaging(staging)
            }
            model.activeStagingURL = nil
            model.namingVisible = false
            model.namingRows = []
            model.namingMessage = nil
            model.revealURLs = outcome.assets.compactMap { try? package.resolvedURL(for: $0) }
            adopt(package, keepWorkspace: true)
            if let warning = outcome.outsideCopyWarning {
                alertMessage = warning
            }
        } catch {
            model.namingMessage = error.localizedDescription
        }
    }

    func discardStripperNaming(_ model: StripperLoungeModel) {
        if let package, let staging = model.activeStagingURL {
            package.removeOwnedStripperStaging(staging)
        }
        model.activeStagingURL = nil
        model.namingVisible = false
        model.namingRows = []
        model.namingMessage = nil
        model.revealURLs = []
        model.askDiscardNaming = false
    }

    func revealStripperFinder(_ model: StripperLoungeModel) {
        if UITestMode.enabled { return }
        let urls = model.revealURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard urls.isEmpty == false else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func sweepAbandonedStripperStaging(keeping: URL?) {
        guard let package else { return }
        let root = package.rootURL.appendingPathComponent("recovery/stripper-jobs", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        let keep = keeping?.standardizedFileURL.resolvingSymlinksInPath().path
        for item in items {
            if item.standardizedFileURL.resolvingSymlinksInPath().path == keep { continue }
            package.removeOwnedStripperStaging(item)
        }
    }

    /// Copies the stored depot file out. The project and its audio are not changed.
    func exportCopy(of asset: DepotAsset) {
        if UITestMode.enabled {
            alertMessage = "UI test does not use Export Copy."
            return
        }
        guard !navigationLocked else { return }
        guard health(of: asset) != .missing, let package else { return }
        let panel = NSSavePanel()
        panel.title = "Export Copy"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = ProjectPackage.exportCopySuggestedName(
            displayName: asset.displayName,
            relativePath: asset.relativePath
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try package.exportCopy(of: asset, to: url)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Reveals the stored depot file. This is a user action, so Finder may open.
    func showInFinder(_ asset: DepotAsset) {
        if UITestMode.enabled { return }
        guard !navigationLocked else { return }
        guard health(of: asset) != .missing, let package else { return }
        guard let url = try? package.resolvedURL(for: asset) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Private

    private func presentNewPanel() {
        if UITestMode.enabled {
            guard let path = UITestMode.argument("-UITestProject") else {
                alertMessage = "UI test project path is missing."
                return
            }
            let folder = ProjectPackage.directoryURL(forPickedURL: URL(fileURLWithPath: path))
            let name = folder.deletingPathExtension().lastPathComponent
            do {
                let created = try ProjectPackage.create(at: folder, name: name)
                adopt(created)
            } catch {
                report(error)
            }
            return
        }
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
            report(error)
        }
    }

    private func presentOpenPanel() {
        if UITestMode.enabled {
            alertMessage = "UI test does not use Open."
            return
        }
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
        try? package.writeLimiterSettings(limiterSettings)
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

    private func report(_ error: Error) {
        if error.localizedDescription == ProjectPackage.nestedProjectMessage {
            let alert = NSAlert()
            alert.messageText = ProjectPackage.nestedProjectMessage
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alertMessage = error.localizedDescription
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
        let rootChanged = self.package?.rootURL != package.rootURL
        let workspace = keepWorkspace ? activeWorkspace : nil
        if activeWorkspace == .limiter, workspace != .limiter {
            endLimiterPlayback?()
        }
        self.package = package
        projectName = package.manifest.projectName
        var nextNotes: [WorkspaceID: String] = [:]
        for id in WorkspaceID.allCases {
            nextNotes[id] = package.manifest.workspaceSettings[id.rawValue]?.notes ?? ""
        }
        notes = nextNotes
        selectedAssetID = package.manifest.selectedAssetID
        limiterSettings = package.readLimiterSettings()
        missingAssetIDs = package.missingAssetIDs
        mismatchedAssetIDs = package.mismatchedAssetIDs
        activeWorkspace = workspace
        markClean()
        if rootChanged {
            stopDepotPlayback()
        } else if let playing = depotPlayer.playingAssetID, assets.contains(where: { $0.id == playing }) == false {
            stopDepotPlayback()
        }
    }

    private func markClean() {
        savedName = projectName
        savedNotes = notes
        savedSelection = selectedAssetID
        savedLimiterSettings = limiterSettings
    }

    private func discardUnsavedEdits() {
        projectName = savedName
        notes = savedNotes
        selectedAssetID = savedSelection
        limiterSettings = savedLimiterSettings
        guard let package else { return }
        package.manifest.projectName = savedName
        package.manifest.selectedAssetID = savedSelection
        for id in WorkspaceID.allCases {
            package.manifest.workspaceSettings[id.rawValue] = WorkspaceSettings(notes: savedNotes[id] ?? "")
        }
    }
}
