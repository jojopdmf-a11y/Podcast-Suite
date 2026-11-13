import Combine
import SwiftUI

public extension Notification.Name {
    static let cougarCalcShowAbout = Notification.Name("cougarCalcShowAbout")
    static let fixerMixerSaveMix = Notification.Name("fixerMixerSaveMix")
    static let fixerMixerUpdateMix = Notification.Name("fixerMixerUpdateMix")
    static let fixerMixerLoadMix = Notification.Name("fixerMixerLoadMix")
    static let fixerMixerAddStrip = Notification.Name("fixerMixerAddStrip")
    static let fixerMixerRemoveStrip = Notification.Name("fixerMixerRemoveStrip")
    static let fixerMixerToggleReorder = Notification.Name("fixerMixerToggleReorder")
    static let fixerMixerImportFolder = Notification.Name("fixerMixerImportFolder")
    static let fixerMixerImportFiles = Notification.Name("fixerMixerImportFiles")
    static let fixerMixerExport = Notification.Name("fixerMixerExport")
    static let fixerMixerPickInput = Notification.Name("fixerMixerPickInput")
}

enum ProducerChrome {
    case application
    case lounge
}

/// On-screen mixer title. The is quieter in the header; the joined string is TheDecks.
enum DeckWordmark {
    static let quiet = "The"
    static let name = "Decks"
    static let joined = quiet + name
    static let suite = "ClubPod"
}

/// New Track, Remove Track, Reorder, and Input Device. The File menu posts the same actions.
enum ProducerTrackControls {
    static let newTrackTitle = "New Track"
    static let removeTrackTitle = "Remove Track"
    static let reorderTitle = "Reorder"
    static let inputDeviceTitle = "Input Device"
    /// Short header label so Play, Standby, and Record stay on screen.
    static let inputDeviceButtonTitle = "INPUT"
    /// Same notification standalone's File → Input Device… posts.
    static let inputDeviceNotification = Notification.Name.fixerMixerPickInput

    /// Recording and a closed mixer leave the toggle where it is.
    static func toggledReorder(_ isOn: Bool, hasSession: Bool, isRecording: Bool) -> Bool {
        guard hasSession, !isRecording else { return isOn }
        return !isOn
    }
}

/// Status, progress, and the mic-denied sentence shown in the title row.
public enum DeckStatusCopy {
    public static func microphoneDenied(appName: String) -> String {
        "ClubPod can't use the microphone. Turn on \(appName) in System Settings › Privacy & Security › Microphone."
    }

    public static func noInput(deviceName: String?) -> String {
        let trimmed = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "No input from that interface. Pick another INPUT."
        }
        return "No input from \(trimmed). Pick another INPUT."
    }

    public static func progressText(label: String?, fraction: Double) -> String {
        let pct = Int((min(1, max(0, fraction)) * 100).rounded())
        if let label, !label.isEmpty {
            return "\(label) · \(pct)%"
        }
        return "\(pct)%"
    }

    public static let openSettingsTitle = "Open Settings"

    public static func hint(lounge: Bool) -> String {
        if lounge {
            return "SEL opens DSP. Shift-drag a waveform to silence. Option-drag clears."
        }
        return "File menu loads, saves, imports, and exports. INPUT picks the interface. SEL opens DSP. Shift-drag a waveform to silence. Option-drag clears."
    }
}

/// Compact status in the title row. The bottom bar is gone so the strips can use that height.
public struct ProducerStatusCluster: View {
    public var status: String
    public var progress: Double?
    public var progressLabel: String?
    public var showMicrophoneSettings: Bool
    public var hint: String
    public var onOpenMicrophoneSettings: () -> Void

    public init(
        status: String,
        progress: Double?,
        progressLabel: String?,
        showMicrophoneSettings: Bool,
        hint: String,
        onOpenMicrophoneSettings: @escaping () -> Void
    ) {
        self.status = status
        self.progress = progress
        self.progressLabel = progressLabel
        self.showMicrophoneSettings = showMicrophoneSettings
        self.hint = hint
        self.onOpenMicrophoneSettings = onOpenMicrophoneSettings
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let progress {
                HStack(spacing: 6) {
                    Capsule()
                        .fill(MixerTheme.cyan.opacity(0.18))
                        .frame(width: 72, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(MixerTheme.cyan)
                                .frame(width: max(3, 72 * CGFloat(min(1, max(0, progress)))))
                        }
                    Text(DeckStatusCopy.progressText(label: progressLabel, fraction: progress))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(MixerTheme.lime)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Text(status)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(showMicrophoneSettings ? MixerTheme.danger : MixerTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .help(hint)
                .accessibilityIdentifier("decks.status")
            if showMicrophoneSettings {
                Button(action: onOpenMicrophoneSettings) {
                    Text(verbatim: DeckStatusCopy.openSettingsTitle)
                }
                .buttonStyle(MixerGhostButtonStyle())
                .accessibilityIdentifier("decks.micSettings")
                .help("Opens System Settings › Privacy & Security › Microphone")
            }
        }
        .frame(maxWidth: 340, alignment: .trailing)
    }
}

/// While a take is recording, leaving is refused. The stop closure is not called.
public enum ProducerLeaveGate {
    @discardableResult
    public static func allowLeave(isRecording: Bool, stopRecord: () -> Void) -> Bool {
        if isRecording {
            return false
        }
        _ = stopRecord
        return true
    }
}

public struct ProducerDepotTrack: Codable, Equatable, Sendable {
    public var assetID: String?
    public var role: String
    public var speakerNumber: Int?
    public var name: String

    public init(assetID: String?, role: String, speakerNumber: Int?, name: String) {
        self.assetID = assetID
        self.role = role
        self.speakerNumber = speakerNumber
        self.name = name
    }
}

/// Fixer session stored in the project. Audio paths are depot asset ids, never absolute paths.
public struct ProducerSessionDocument: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var tracks: [ProducerDepotTrack]
    /// Same settings as `FixerMixer.mix.json`. No file paths.
    public var mixJSON: String

    public init(
        formatVersion: Int = ProducerSessionDocument.currentFormatVersion,
        tracks: [ProducerDepotTrack],
        mixJSON: String
    ) {
        self.formatVersion = formatVersion
        self.tracks = tracks
        self.mixJSON = mixJSON
    }

    public static func decode(_ data: Data) -> ProducerSessionDocument? {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" { return nil }
        return try? JSONDecoder().decode(ProducerSessionDocument.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var text = String(decoding: try encoder.encode(self), as: UTF8.self)
        if !text.hasSuffix("\n") { text += "\n" }
        return Data(text.utf8)
    }
}

public struct ProducerDepotFile: Sendable {
    public var url: URL
    public var assetID: String
    public var displayName: String

    public init(url: URL, assetID: String, displayName: String) {
        self.url = url
        self.assetID = assetID
        self.displayName = displayName
    }
}

public enum ProducerFolderScan {
    public struct Found: Sendable {
        public var audio: [URL]
        public var mix: URL?
    }

    public static func isMixFile(_ url: URL) -> Bool {
        MixerMixFile.isMixFile(url)
    }

    /// Audio in the folder, plus a mix sidecar when one is sitting beside it.
    /// Absolute paths inside the sidecar are not read; the sidecar is settings only.
    public static func audioAndMix(in folder: URL) -> Found {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []
        let mix = files.first { $0.lastPathComponent == MixerMixFile.fileName }
            ?? files.first { MixerMixFile.isMixFile($0) }
        let audio = files.filter {
            MixerAudioIO.isSupportedAudioURL($0)
                && !$0.lastPathComponent.hasPrefix(".")
                && !$0.lastPathComponent.hasSuffix(".recording.wav")
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return Found(audio: audio, mix: mix)
    }
}

/// Lounge-owned mixer. Standalone PodProducer uses `ProducerAppRoot` instead.
@MainActor
public final class ProducerLoungeModel: ObservableObject {
    let session: MixerSession

    @Published public private(set) var isRecording = false
    /// How many times Stop ran. Leaving the workspace does not increment this.
    public private(set) var stopRecordCalls = 0

    public var onRecordingChange: ((Bool) -> Void)?
    public var onTakesReady: (([URL]) -> Void)?
    public var onExportReady: ((URL) -> Void)?
    public var onParametersSynced: (() -> Void)?
    public var onAddSelected: (() -> Void)?
    public var onImportURLs: (([URL]) -> Void)?

    @Published public private(set) var statusLine = ""
    @Published public private(set) var busyProgress: Double?
    @Published public private(set) var busyProgressLabel: String?
    @Published public private(set) var microphoneSettingsVisible = false
    private var statusWatch: AnyCancellable?

    public init() {
        let session = MixerSession()
        self.session = session
        session.permissionAppName = "Lounge"
        session.protectTakeUntilStop = true
        session.suppressExportReveal = true
        session.onRecordingFlagChanged = { [weak self] recording in
            self?.isRecording = recording
            self?.onRecordingChange?(recording)
        }
        session.onStopRecord = { [weak self] in
            self?.stopRecordCalls += 1
        }
        session.onWorkingTakesWritten = { [weak self] urls in
            self?.onTakesReady?(urls)
        }
        session.onBounceFinished = { [weak self] folder in
            self?.onExportReady?(folder)
        }
        session.onParametersSynced = { [weak self] in
            self?.onParametersSynced?()
        }
        watchStatus()
    }

    private func watchStatus() {
        statusLine = session.status
        busyProgress = session.busyProgress
        busyProgressLabel = session.busyProgressLabel
        microphoneSettingsVisible = session.microphoneSettingsVisible
        statusWatch = Publishers.CombineLatest4(
            session.$status,
            session.$busyProgress,
            session.$busyProgressLabel,
            session.$microphoneSettingsVisible
        ).sink { [weak self] status, progress, label, mic in
            self?.statusLine = status
            self?.busyProgress = progress
            self?.busyProgressLabel = label
            self?.microphoneSettingsVisible = mic
        }
    }

    public func openMicrophoneSettings() {
        session.openMicrophoneSettings()
    }

    /// False while a take is recording. Does not call Stop.
    public func requestLeave() -> Bool {
        ProducerLeaveGate.allowLeave(isRecording: session.isRecording) {
            self.session.stopRecord()
        }
    }

    /// Test seam. Sets the flag without opening the microphone or the engine.
    public func setRecordingForTest(_ recording: Bool) {
        session.isRecording = recording
    }

    public func setRecordDirectory(_ url: URL?) {
        session.recordDirectoryOverride = url
    }

    public var hasSession: Bool { session.hasSession }

    public func captureDocument() -> ProducerSessionDocument {
        session.producerDocument()
    }

    public func encodedDocument() -> Data {
        (try? captureDocument().encoded()) ?? Data("{\"formatVersion\":1,\"mixJSON\":\"\",\"tracks\":[]}\n".utf8)
    }

    public func restore(data: Data?, urlForAssetID: (String) -> URL?) {
        guard let data, let document = ProducerSessionDocument.decode(data) else {
            session.closeMixer()
            return
        }
        restore(document: document, urlForAssetID: urlForAssetID)
    }

    public func restore(document: ProducerSessionDocument, urlForAssetID: (String) -> URL?) {
        session.restoreProducerDocument(document, urlForAssetID: urlForAssetID)
    }

    public func importDepotFiles(_ files: [ProducerDepotFile], append: Bool) {
        session.importDepotAudio(
            files.map { (url: $0.url, assetID: $0.assetID) },
            append: append
        )
    }

    public func applyMixFile(_ url: URL) {
        session.applyMixSettings(from: url)
    }

    public func retargetTake(from oldURL: URL, to newURL: URL, assetID: String) {
        session.retargetTake(from: oldURL, to: newURL, assetID: assetID)
    }
}

public struct ProducerDeskView: View {
    @ObservedObject private var model: ProducerLoungeModel

    public init(model: ProducerLoungeModel) {
        self.model = model
    }

    public var body: some View {
        ContentView(
            session: model.session,
            chrome: .lounge,
            onAddSelectedDepot: { model.onAddSelected?() },
            onImportURLs: { urls in model.onImportURLs?(urls) }
        )
    }
}

/// Standalone PodProducer window.
public struct ProducerAppRoot: View {
    @StateObject private var session = MixerSession()

    public init() {}

    public var body: some View {
        ContentView(session: session, chrome: .application)
    }
}
