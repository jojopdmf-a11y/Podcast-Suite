import AppKit
import LilLevelerKit
import PodLoungeCore
import SwiftUI

/// The real PodLeveler UI, aimed at the depot file selected in the Lounge.
struct LimiterWorkspaceView: View {
    @EnvironmentObject private var session: ProjectSession
    @StateObject private var leveler = LevelerSession()
    @State private var acceptControlEdits = false
    @State private var chapterSidecar: [PodcastChapter] = []
    @State private var chapterDuration: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button("← Lounge") { session.leaveWorkspace() }
                    .buttonStyle(LoungeButtonStyle())
                    .disabled(session.navigationLocked)
                    .accessibilityIdentifier("lounge.back")
                VStack(alignment: .leading, spacing: 1) {
                    RoomTitleText(workspace: .limiter, size: 18)
                    Text("The file selected in TheValet is the source. Pick another in the list without leaving. Back to Lounge stops playback.")
                        .font(.system(size: 11))
                        .foregroundStyle(LoungeTheme.textDim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if chapterSidecar.isEmpty == false {
                chapterStrip
            }

            LevelerRootView(
                session: leveler,
                mode: .lounge,
                output: outputBinding,
                resultName: resultNameBinding,
                resultNameFollowsSource: followsBinding,
                    onSaveToDepot: { url, name in
                        try saveLeveledFile(url: url, displayName: name)
                    },
                    onControlsChanged: syncControls,
                    onPlaybackWillStart: { session.stopDepotPlayback() }
                )
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            session.endLimiterPlayback = { leveler.teardown() }
            session.stopLimiterPlayback = {
                leveler.stopTransportIfPlaying()
            }
            session.limiterExporting = leveler.isExporting
            leveler.applyControls(controlSnapshot)
            loadSelected()
            acceptControlEdits = true
        }
        .onDisappear {
            leveler.teardown()
            session.endLimiterPlayback = nil
            session.stopLimiterPlayback = nil
            session.limiterExporting = false
            session.stopDepotPlayback()
        }
        .onChange(of: leveler.isExporting) { _, exporting in
            session.limiterExporting = exporting
        }
        .onChange(of: session.selectedAssetID) { _, _ in
            loadSelected()
        }
        .onChange(of: session.package?.rootURL) { _, _ in
            leveler.teardown()
            leveler.applyControls(controlSnapshot)
            loadSelected()
        }
    }

    private var controlSnapshot: LevelerControlSnapshot {
        let settings = session.limiterSettings
        return LevelerControlSnapshot(
            presetID: settings.presetID,
            customLUFS: settings.customLUFS,
            customTruePeak: settings.customTruePeak,
            musicThresholdDb: settings.musicThresholdDb,
            meterMode: settings.meterMode,
            peakHold: settings.peakHold,
            listenPost: settings.listenPost
        )
    }

    private var suggestedResultName: String {
        let asset = session.assets.first { $0.id == session.selectedAssetID }
        let raw = asset?.displayName ?? "Audio"
        return LevelerResultName.suggested(sourceName: raw, presetTitle: leveler.activePresetTitle)
    }

    private var outputBinding: Binding<LevelerOutputSettings> {
        Binding(
            get: { outputSettings(from: session.limiterSettings) },
            set: { newValue in
                var next = session.limiterSettings
                next.container = newValue.container.rawValue
                next.bitDepth = bitDepthToken(newValue.bitDepth)
                next.mp3BitrateKbps = newValue.mp3BitrateKbps
                switch newValue.rateMode {
                case .automatic, .matchSource:
                    next.sampleRate = nil
                case let .explicit(rate):
                    next.sampleRate = rate
                }
                guard next != session.limiterSettings else { return }
                session.limiterSettings = next
            }
        )
    }

    private var resultNameBinding: Binding<String> {
        Binding(
            get: {
                if session.limiterSettings.resultNameFollowsSource {
                    return suggestedResultName
                }
                return session.limiterSettings.resultName
            },
            set: { newValue in
                var next = session.limiterSettings
                next.resultName = newValue
                next.resultNameFollowsSource = false
                guard next != session.limiterSettings else { return }
                session.limiterSettings = next
            }
        )
    }

    private var followsBinding: Binding<Bool> {
        Binding(
            get: { session.limiterSettings.resultNameFollowsSource },
            set: { newValue in
                var next = session.limiterSettings
                next.resultNameFollowsSource = newValue
                guard next != session.limiterSettings else { return }
                session.limiterSettings = next
            }
        )
    }

    private func syncControls() {
        guard acceptControlEdits else { return }
        var next = session.limiterSettings
        let snap = leveler.controlSnapshot()
        next.presetID = snap.presetID
        next.customLUFS = snap.customLUFS
        next.customTruePeak = snap.customTruePeak
        next.musicThresholdDb = snap.musicThresholdDb
        next.meterMode = snap.meterMode
        next.peakHold = snap.peakHold
        next.listenPost = snap.listenPost
        guard next != session.limiterSettings else { return }
        session.limiterSettings = next
    }

    private var chapterList: PodcastTimestampList.Result {
        PodcastTimestampList.make(chapters: chapterSidecar, episodeDuration: chapterDuration)
    }

    private var chapterStrip: some View {
        let list = chapterList
        return HStack(alignment: .center, spacing: 8) {
            Text("Chapters (\(chapterSidecar.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LoungeTheme.text)
                .accessibilityIdentifier("roof.chapters")
            Button("Copy timestamp list") { copyChapterList(list) }
                .buttonStyle(LoungeButtonStyle())
                .accessibilityIdentifier("roof.chapters.copy")
            if list.addedOpening {
                Text(list.note)
                    .font(.system(size: 10))
                    .foregroundStyle(LoungeTheme.textDim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func copyChapterList(_ list: PodcastTimestampList.Result) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(list.text, forType: .string)
    }

    private func saveLeveledFile(url: URL, displayName: String) throws {
        let sourceURL = selectedSourceURL()
        let chapters = sourceURL.flatMap { PodcastChapters.load(beside: $0) } ?? []
        if url.pathExtension.lowercased() == "mp3", chapters.isEmpty == false {
            let sourceDuration = sourceURL.flatMap(AudioFileClock.duration(of:)) ?? 0
            let outputDuration = AudioFileClock.duration(of: url) ?? sourceDuration
            let map = RoofChapterClock.map(sourceDuration: sourceDuration, outputDuration: outputDuration)
            let aligned = PodcastChapters.apply(chapters, map: map, outputDuration: outputDuration)
            let end = max(outputDuration, aligned.map(\.start).max() ?? 0)
            do {
                try PodcastID3.apply(chapters: aligned, duration: end, to: url)
            } catch {
                session.alertMessage = "The leveled file was saved. The chapter markers could not be written into the MP3."
            }
        }
        let asset = try session.importLimiterResult(from: url, displayName: displayName)
        guard chapters.isEmpty == false,
              let package = session.package,
              let destination = try? package.resolvedURL(for: asset)
        else { return }
        let sourceDuration = sourceURL.flatMap(AudioFileClock.duration(of:)) ?? 0
        let outputDuration = AudioFileClock.duration(of: destination) ?? sourceDuration
        let map = RoofChapterClock.map(sourceDuration: sourceDuration, outputDuration: outputDuration)
        let original = sourceURL.map(PodcastChapters.sidecarURL(forAudio:))
        try? PodcastChapters.write(
            chapters,
            map: map,
            outputDuration: outputDuration,
            beside: destination,
            originalSidecar: original
        )
    }

    private func selectedSourceURL() -> URL? {
        guard let package = session.package,
              let id = session.selectedAssetID,
              let asset = session.assets.first(where: { $0.id == id }),
              session.health(of: asset) == .present
        else { return nil }
        return try? package.resolvedURL(for: asset)
    }

    private func refreshChapters() {
        guard let url = selectedSourceURL() else {
            chapterSidecar = []
            chapterDuration = 0
            return
        }
        let chapters = PodcastChapters.load(beside: url) ?? []
        chapterSidecar = chapters
        chapterDuration = AudioFileClock.duration(of: url) ?? chapters.map(\.start).max() ?? 0
    }

    private func loadSelected() {
        defer { refreshChapters() }
        guard let package = session.package else {
            if leveler.sourceURL != nil { leveler.teardown() }
            leveler.status = "Open a project, then pick a file in TheValet."
            return
        }
        guard let id = session.selectedAssetID,
              let asset = session.assets.first(where: { $0.id == id })
        else {
            if leveler.sourceURL != nil { leveler.teardown() }
            leveler.status = "Select a file in TheValet to level."
            return
        }
        guard session.health(of: asset) == .present, let url = try? package.resolvedURL(for: asset) else {
            leveler.teardown()
            leveler.status = "That file is missing from TheValet. Save will not recreate it."
            return
        }
        if leveler.sourceURL?.standardizedFileURL == url.standardizedFileURL { return }
        leveler.load(url: url, displayName: asset.displayName)
    }

    private func outputSettings(from settings: LimiterWorkspaceSettings) -> LevelerOutputSettings {
        let container = LevelerContainer(rawValue: settings.container) ?? .wav
        let depth: LevelerBitDepth
        switch settings.bitDepth {
        case "16": depth = .int16
        case "32f": depth = .float32
        default: depth = .int24
        }
        let rateMode: LevelerRateMode = if let rate = settings.sampleRate {
            .explicit(rate)
        } else {
            .automatic
        }
        return LevelerOutputSettings(
            container: container,
            bitDepth: depth,
            rateMode: rateMode,
            mp3BitrateKbps: settings.mp3BitrateKbps
        )
    }

    private func bitDepthToken(_ depth: LevelerBitDepth) -> String {
        switch depth {
        case .int16: "16"
        case .int24: "24"
        case .float32: "32f"
        }
    }
}
