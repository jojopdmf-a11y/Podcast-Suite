import Foundation

public struct StripperEditableTrack: Identifiable, Equatable, Sendable {
    public var id: String
    public var sourceURL: URL
    public var roleLabel: String
    public var displayName: String

    public init(id: String, sourceURL: URL, roleLabel: String, displayName: String) {
        self.id = id
        self.sourceURL = sourceURL
        self.roleLabel = roleLabel
        self.displayName = displayName
    }
}

public enum StripperChrome: Sendable {
    case standalone
    case lounge
}

public struct StripperFinishedJob: Equatable, Sendable {
    public var outputDirectory: URL
    public var tracks: [URL]
    public var speakersJSON: URL
    public var musicFallback: String?

    public init(outputDirectory: URL, tracks: [URL], speakersJSON: URL, musicFallback: String?) {
        self.outputDirectory = outputDirectory
        self.tracks = tracks
        self.speakersJSON = speakersJSON
        self.musicFallback = musicFallback
    }
}

/// What the Lounge (or the standalone window) asks the shared Stripper screen to do.
@MainActor
public final class StripperLoungeModel: ObservableObject {
    public let chrome: StripperChrome
    @Published public var inputURL: URL?
    @Published public var inputTitle = ""
    @Published public var inputDetail = ""
    @Published public var outsideFolder: URL?
    @Published public var sourceLocked = false
    @Published public var namingRows: [StripperEditableTrack] = []
    @Published public var namingVisible = false
    @Published public var namingMessage: String?
    @Published public var askDiscardNaming = false
    @Published public var activeStagingURL: URL?
    @Published public var pendingSplitIndex = 1
    @Published public var pendingSourceAssetID = ""
    @Published public var pendingSpeakersJSON: URL?
    @Published public var revealURLs: [URL] = []

    public var makeStagingDirectory: (() throws -> URL)?
    public var onImportExternal: ((URL) -> Void)?
    public var onChooseOutsideFolder: (() -> Void)?
    public var onUseDepot: (() -> Void)?
    public var onShowInFinder: (() -> Void)?
    public var onSplitFinished: ((StripperFinishedJob) -> Void)?
    public var onAddToDepot: (() -> Void)?
    public var onDiscardNaming: (() -> Void)?
    public var onRunningChange: ((Bool) -> Void)?

    public init(chrome: StripperChrome) {
        self.chrome = chrome
    }

    public var saveToLabel: String {
        if let outsideFolder {
            return outsideFolder.path
        }
        if chrome == .lounge {
            return "Project depot"
        }
        return ""
    }
}
