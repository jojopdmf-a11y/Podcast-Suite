import LilLevelerKit
import PodLoungeCore
import SwiftUI

/// The real PodLeveler UI, aimed at the depot file selected in the Lounge.
struct LimiterWorkspaceView: View {
    @EnvironmentObject private var session: ProjectSession
    @StateObject private var leveler = LevelerSession()
    @State private var acceptControlEdits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Button("← Lounge") { session.leaveWorkspace() }
                    .buttonStyle(LoungeButtonStyle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Limiter")
                        .font(.system(size: 22, weight: .semibold))
                    Text("The selected depot file is the source. Pick another in the list without leaving. Back to Lounge stops playback.")
                        .font(.system(size: 12))
                        .foregroundStyle(LoungeTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ScrollView([.vertical, .horizontal]) {
                LevelerRootView(
                    session: leveler,
                    mode: .lounge,
                    output: outputBinding,
                    resultName: resultNameBinding,
                    resultNameFollowsSource: followsBinding,
                    onSaveToDepot: { url, name in
                        try session.importLimiterResult(from: url, displayName: name)
                    },
                    onControlsChanged: syncControls
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            session.endLimiterPlayback = { leveler.teardown() }
            leveler.applyControls(controlSnapshot)
            loadSelected()
            acceptControlEdits = true
        }
        .onDisappear {
            leveler.teardown()
            session.endLimiterPlayback = nil
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
        let base = (raw as NSString).deletingPathExtension
        let stem = base.isEmpty ? "Audio" : base
        return "\(stem) – Leveled (\(leveler.activePresetTitle))"
    }

    private var outputBinding: Binding<LevelerOutputSettings> {
        Binding(
            get: { outputSettings(from: session.limiterSettings) },
            set: { newValue in
                var next = session.limiterSettings
                next.container = newValue.container.rawValue
                next.bitDepth = bitDepthToken(newValue.bitDepth)
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

    private func loadSelected() {
        guard let package = session.package else {
            if leveler.sourceURL != nil { leveler.teardown() }
            leveler.status = "Open a project, then pick a depot file."
            return
        }
        guard let id = session.selectedAssetID,
              let asset = session.assets.first(where: { $0.id == id })
        else {
            if leveler.sourceURL != nil { leveler.teardown() }
            leveler.status = "Select a depot file to level."
            return
        }
        guard session.health(of: asset) == .present, let url = try? package.resolvedURL(for: asset) else {
            leveler.teardown()
            leveler.status = "That depot file is missing. Save will not recreate it."
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
            container: container == .mp3 ? .wav : container,
            bitDepth: depth,
            rateMode: rateMode
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
