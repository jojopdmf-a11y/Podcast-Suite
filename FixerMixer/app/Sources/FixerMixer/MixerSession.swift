import AppKit
import Foundation
import SwiftUI

enum GraphicEQBand: Int, CaseIterable, Identifiable {
    case b31, b63, b125, b250, b500, b1k, b2k, b4k, b8k, b16k
    var id: Int { rawValue }
    var hz: Double {
        switch self {
        case .b31: return 31.5
        case .b63: return 63
        case .b125: return 125
        case .b250: return 250
        case .b500: return 500
        case .b1k: return 1000
        case .b2k: return 2000
        case .b4k: return 4000
        case .b8k: return 8000
        case .b16k: return 16000
        }
    }
    var shortLabel: String {
        switch self {
        case .b31: return "31"
        case .b63: return "63"
        case .b125: return "125"
        case .b250: return "250"
        case .b500: return "500"
        case .b1k: return "1k"
        case .b2k: return "2k"
        case .b4k: return "4k"
        case .b8k: return "8k"
        case .b16k: return "16k"
        }
    }
}

struct ChannelEQ: Equatable {
    var gains: [Float] = Array(repeating: 0, count: GraphicEQBand.allCases.count)
    var bypass: Bool = false

    subscript(band: GraphicEQBand) -> Float {
        get { gains[band.rawValue] }
        set { gains[band.rawValue] = max(-12, min(12, newValue)) }
    }
}

/// How fast bandwidth collapses as |gain| grows. Notch is the most surgical.
enum ParaEQWidth: String, CaseIterable, Identifiable, Hashable {
    case notch
    case narrow
    case wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: return "NOTCH"
        case .narrow: return "NARROW"
        case .wide: return "WIDE"
        }
    }

    /// Octave bandwidth at this gain. Shrinks as you boost or cut.
    func bandwidthOctaves(gainDb: Float) -> Float {
        let g = abs(gainDb)
        let bw0: Float
        let k: Float
        switch self {
        case .notch:
            bw0 = 0.38
            k = 0.30
        case .narrow:
            bw0 = 0.90
            k = 0.14
        case .wide:
            bw0 = 1.70
            k = 0.055
        }
        return bw0 / (1 + k * g)
    }

    func q(gainDb: Float) -> Float {
        let bw = Double(max(0.02, bandwidthOctaves(gainDb: gainDb)))
        let q = 1.0 / (2.0 * sinh(log(2.0) / 2.0 * bw))
        return Float(min(40, max(0.3, q)))
    }
}

/// Single speaker-only parametric band. Music / master never get one.
struct ChannelParaEQ: Equatable {
    static let minHz: Float = 40
    static let maxHz: Float = 12_000
    static let minGainDb: Float = -18
    static let maxGainDb: Float = 18

    var freqHz: Float = 1_000
    var gainDb: Float = 0
    var width: ParaEQWidth = .narrow
    var bypass: Bool = false

    var isActive: Bool { abs(gainDb) > 0.05 }

    mutating func clamp() {
        freqHz = min(Self.maxHz, max(Self.minHz, freqHz))
        gainDb = min(Self.maxGainDb, max(Self.minGainDb, gainDb))
    }
}

enum WetterRoom: String, CaseIterable, Identifiable, Hashable {
    case drumRoom
    case studio
    case stage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drumRoom: return "DRUM"
        case .studio: return "STUDIO"
        case .stage: return "STAGE"
        }
    }

    var help: String {
        switch self {
        case .drumRoom: return "Drum room — bright, short punch"
        case .studio: return "Studio — tight treated-booth air"
        case .stage: return "Stage — small live floor, not a hall"
        }
    }
}

struct VoiceFX: Equatable {
    var deVerb: Float = 0
    var deVerbBypass: Bool = false
    var wetter: Float = 0
    var wetterBypass: Bool = false
    var wetterRoom: WetterRoom = .drumRoom
    /// 0…1 — correction strength / how hard to push into soft limit at Target
    var levelerDrive: Float = 0
    var levelerBypass: Bool = false
    var levelerTargetDb: Float = -6
}

/// Per-channel DSP chain order (independent per strip).
enum ChannelDSPSlot: String, CaseIterable, Codable, Identifiable, Hashable {
    case eq
    case deVerb
    case wetter
    case leveler

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eq: return "EQ"
        case .deVerb: return "DE-VERB"
        case .wetter: return "WETTER"
        case .leveler: return "LEVELER"
        }
    }

    var panelTitle: String {
        switch self {
        case .eq: return "EQ 2520"
        case .deVerb: return "DE-VERB"
        case .wetter: return "WETTER"
        case .leveler: return "LEVELER"
        }
    }

    var panelSubtitle: String {
        switch self {
        case .eq: return "10-band graphic · 560 curves · finer ±4 dB"
        case .deVerb: return "Dry room / ambience"
        case .wetter: return "Small spaces for dry voices"
        case .leveler: return "Drive into target · soft compress + limit"
        }
    }

    static let voiceDefault: [ChannelDSPSlot] = [.eq, .deVerb, .wetter, .leveler]
    static let musicDefault: [ChannelDSPSlot] = [.eq]
}

struct ChannelStripState: Identifiable, Equatable {
    let id: Int
    var name: String
    var isStereo: Bool
    /// Original Stripper speaker index (1-based), for bounce filenames.
    var speakerNumber: Int? = nil
    var fileURL: URL?
    var mute: Bool = false
    /// Bypass all DSP (EQ + voice FX); fader/pan/mute still apply.
    var dspBypass: Bool = false
    var faderDb: Float = 0
    /// Relative preference while Auto Balance is on (favor/cut this speaker).
    var autoBiasDb: Float = 0
    var pan: Float = 0
    var eq = ChannelEQ()
    var para = ChannelParaEQ()
    var voice = VoiceFX()
    /// Signal flow order for this channel’s processors.
    var dspOrder: [ChannelDSPSlot] = ChannelDSPSlot.voiceDefault
    var prePeak: Float = 0
    var postPeak: Float = 0

    static let musicID = 1000
    static let masterID = 2000

    static func == (lhs: ChannelStripState, rhs: ChannelStripState) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isStereo == rhs.isStereo
            && lhs.speakerNumber == rhs.speakerNumber
            && lhs.fileURL == rhs.fileURL
            && lhs.mute == rhs.mute
            && lhs.dspBypass == rhs.dspBypass
            && lhs.faderDb == rhs.faderDb
            && lhs.autoBiasDb == rhs.autoBiasDb
            && lhs.pan == rhs.pan
            && lhs.eq == rhs.eq
            && lhs.para == rhs.para
            && lhs.voice == rhs.voice
            && lhs.dspOrder == rhs.dspOrder
    }

    static func voice(slot: Int, speakerNumber: Int) -> ChannelStripState {
        ChannelStripState(
            id: slot,
            name: "SPK \(speakerNumber)",
            isStereo: false,
            speakerNumber: speakerNumber,
            dspOrder: ChannelDSPSlot.voiceDefault
        )
    }

    static func music() -> ChannelStripState {
        ChannelStripState(
            id: musicID,
            name: "MUSIC",
            isStereo: true,
            dspOrder: ChannelDSPSlot.musicDefault
        )
    }

    mutating func moveDSP(from fromID: ChannelDSPSlot, to toID: ChannelDSPSlot) {
        guard let from = dspOrder.firstIndex(of: fromID),
              let to = dspOrder.firstIndex(of: toID),
              from != to else { return }
        dspOrder.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// Filesystem-safe base for bounce stems (`{base}_fixed.wav`).
    var bounceStemBaseName: String {
        let cleaned = Self.sanitizeFilenameComponent(name)
        if cleaned.isEmpty {
            if let speakerNumber { return "Speaker_\(speakerNumber)" }
            return isStereo ? "Music_and_SFX" : "Speaker"
        }
        return cleaned
    }

    static func sanitizeFilenameComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.'()[]"))
        let mapped = String(trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
        var s = mapped
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "._ "))
        if s.count > 48 { s = String(s.prefix(48)) }
        return s
    }
}

@MainActor
final class MixerSession: ObservableObject {
    @Published var voices: [ChannelStripState] = []
    @Published var music: ChannelStripState = .music()
    @Published var hasMusic = false
    @Published var masterDb: Float = 0
    @Published var masterPeakL: Float = 0
    @Published var masterPeakR: Float = 0
    @Published var masterComp = MasterCompressorState()
    @Published var masterCompInL: Float = 0
    @Published var masterCompInR: Float = 0
    @Published var masterCompOutL: Float = 0
    @Published var masterCompOutR: Float = 0
    @Published var masterCompGRDb: Float = 0
    @Published var autoBalanceEnabled = false
    @Published var autoBalanceTargetDb: Float = -18
    /// Live auto-mix gains in dB (one per voice). Fader display = this + autoBiasDb.
    @Published var autoGainDb: [Float] = []
    @Published var rtaBins: [Float] = Array(repeating: 0, count: RTAAnalyzer.displayBins)
    @Published var status: String = "Drop a Podcast Stripper _speakers folder to load tracks."
    @Published var isPlaying = false
    @Published var isBouncing = false
    @Published var sourceFolder: URL?
    @Published var sampleRate: Double = 44100
    @Published var frameCount: Int = 0
    /// Voice slot id, or `ChannelStripState.musicID`
    @Published var selectedChannelID: Int = 0
    @Published var playheadFrame: Int = 0
    @Published var waveformPeaks: [Float] = []

    let engine = MixerEngine()

    func bindEngine() {
        engine.onMeters = { [weak self] pre, post, masterL, masterR, autoDb, rta, compInL, compInR, compOutL, compOutR, compGR in
            Task { @MainActor in
                guard let self else { return }
                let n = self.voices.count
                for i in 0..<min(n, pre.count) {
                    self.voices[i].prePeak = pre[i]
                    self.voices[i].postPeak = post[i]
                }
                if self.hasMusic, pre.count > n {
                    self.music.prePeak = pre[n]
                    self.music.postPeak = post[n]
                }
                self.masterPeakL = masterL
                self.masterPeakR = masterR
                if self.autoBalanceEnabled {
                    self.autoGainDb = autoDb
                }
                self.rtaBins = rta
                self.masterCompInL = compInL
                self.masterCompInR = compInR
                self.masterCompOutL = compOutL
                self.masterCompOutR = compOutR
                self.masterCompGRDb = compGR
            }
        }
        engine.onPlayhead = { [weak self] frame in
            Task { @MainActor in
                self?.playheadFrame = frame
            }
        }
        engine.onPlaybackEnded = { [weak self] in
            Task { @MainActor in
                self?.isPlaying = false
                self?.status = "Reached end."
            }
        }
    }

    func setAutoBalanceEnabled(_ enabled: Bool) {
        if enabled && !autoBalanceEnabled {
            // Keep current fader positions as relative favor when auto takes over
            for i in voices.indices {
                voices[i].autoBiasDb = voices[i].faderDb
            }
            autoGainDb = Array(repeating: 0, count: voices.count)
        } else if !enabled && autoBalanceEnabled {
            // Bake auto + bias into manual faders so levels don't jump
            for i in voices.indices {
                let auto = autoGainDb.indices.contains(i) ? autoGainDb[i] : 0
                voices[i].faderDb = max(-60, min(12, auto + voices[i].autoBiasDb))
                voices[i].autoBiasDb = 0
            }
            autoGainDb = []
        }
        autoBalanceEnabled = enabled
        syncParamsToEngine()
    }

    /// Fader binding for a voice strip: shows auto rides; drags adjust bias.
    func voiceFaderBinding(at index: Int) -> Binding<Float> {
        Binding(
            get: {
                guard self.voices.indices.contains(index) else { return 0 }
                if self.autoBalanceEnabled {
                    let auto = self.autoGainDb.indices.contains(index) ? self.autoGainDb[index] : 0
                    return max(-60, min(12, auto + self.voices[index].autoBiasDb))
                }
                return self.voices[index].faderDb
            },
            set: { newValue in
                guard self.voices.indices.contains(index) else { return }
                if self.autoBalanceEnabled {
                    let auto = self.autoGainDb.indices.contains(index) ? self.autoGainDb[index] : 0
                    self.voices[index].autoBiasDb = max(-24, min(18, newValue - auto))
                } else {
                    self.voices[index].faderDb = newValue
                }
                self.syncParamsToEngine()
            }
        )
    }

    func selectChannel(_ id: Int) {
        selectedChannelID = id
        refreshWaveform()
        syncRTASource()
    }

    func syncRTASource() {
        if selectedChannelID == ChannelStripState.masterID {
            engine.setRTASource(isMusic: false, voiceIndex: 0, isMaster: true)
        } else if selectedChannelID == ChannelStripState.musicID {
            engine.setRTASource(isMusic: true, voiceIndex: 0, isMaster: false)
        } else if let idx = voices.firstIndex(where: { $0.id == selectedChannelID }) {
            engine.setRTASource(isMusic: false, voiceIndex: idx, isMaster: false)
        }
    }

    func refreshWaveform() {
        if selectedChannelID == ChannelStripState.masterID {
            // Bus overview: max envelope across loaded voices (+ music)
            waveformPeaks = engine.waveformPeaks(channelIndex: nil, music: false, masterMix: true, binCount: 900)
        } else if selectedChannelID == ChannelStripState.musicID {
            waveformPeaks = engine.waveformPeaks(channelIndex: nil, music: true, masterMix: false, binCount: 900)
        } else if let idx = voices.firstIndex(where: { $0.id == selectedChannelID }) {
            waveformPeaks = engine.waveformPeaks(channelIndex: idx, music: false, masterMix: false, binCount: 900)
        } else {
            waveformPeaks = []
        }
    }

    func seekNormalized(_ t: Double) {
        guard frameCount > 0 else { return }
        let frame = Int((max(0, min(1, t)) * Double(frameCount - 1)).rounded())
        engine.seek(toFrame: frame)
        playheadFrame = frame
    }

    var playheadNormalized: Double {
        guard frameCount > 1 else { return 0 }
        return Double(playheadFrame) / Double(frameCount - 1)
    }

    var selectedChannelName: String {
        if selectedChannelID == ChannelStripState.masterID { return "MASTER" }
        if selectedChannelID == ChannelStripState.musicID { return music.name }
        if let v = voices.first(where: { $0.id == selectedChannelID }) { return v.name }
        return "—"
    }

    func loadStripperFolder(_ folder: URL) {
        do {
            if isPlaying {
                engine.stop()
                isPlaying = false
            }
            let mapped = try StripperFolderLoader.load(folder: folder)
            voices = mapped.speakers.enumerated().map { slot, item in
                var ch = ChannelStripState.voice(slot: slot, speakerNumber: item.number)
                ch.fileURL = item.url
                return ch
            }
            hasMusic = mapped.music != nil
            music = .music()
            music.fileURL = mapped.music
            sourceFolder = folder
            try engine.load(
                voiceURLs: voices.map(\.fileURL),
                speakerNumbers: voices.map { $0.speakerNumber ?? ($0.id + 1) },
                musicURL: music.fileURL,
                sampleRateHint: nil
            )
            sampleRate = engine.sampleRate
            frameCount = engine.frameCount
            playheadFrame = 0
            if let first = voices.first {
                selectedChannelID = first.id
            } else if hasMusic {
                selectedChannelID = ChannelStripState.musicID
            }
            refreshWaveform()
            syncRTASource()
            syncParamsToEngine()
            let loaded = voices.count + (hasMusic ? 1 : 0)
            let spkLabel = voices.isEmpty ? "no speakers" : "\(voices.count) speaker\(voices.count == 1 ? "" : "s")"
            var line = "Loaded \(loaded) track(s) · \(spkLabel)\(hasMusic ? " + music" : "") · \(Int(sampleRate)) Hz · \(formatDuration(frames: frameCount, rate: sampleRate))"
            if FileManager.default.fileExists(atPath: MixerMixFile.sidecarURL(in: folder).path) {
                if restoreMixIfPresent(in: folder) {
                    line += " · mix restored"
                } else {
                    line += " · mix file found but could not be read"
                }
            }
            status = line
        } catch {
            status = error.localizedDescription
        }
    }

    func syncParamsToEngine() {
        engine.updateParams(
            voices: voices,
            music: music,
            masterDb: masterDb,
            autoBalanceEnabled: autoBalanceEnabled,
            autoBalanceTargetDb: autoBalanceTargetDb,
            masterComp: masterComp
        )
    }

    func togglePlay() {
        syncParamsToEngine()
        if isPlaying {
            engine.stop()
            isPlaying = false
            playheadFrame = engine.currentFrame()
            status = "Paused · \(formatDuration(frames: playheadFrame, rate: sampleRate))"
        } else {
            do {
                try engine.start(fromBeginning: false)
                isPlaying = true
                status = "Playing…"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func restartPlay() {
        syncParamsToEngine()
        do {
            try engine.start(fromBeginning: true)
            playheadFrame = 0
            isPlaying = true
            status = "Playing from start…"
        } catch {
            status = error.localizedDescription
        }
    }

    /// Writes `FixerMixer.mix.json` into the current `_speakers` folder.
    func saveMix() {
        guard frameCount > 0, let folder = sourceFolder else {
            status = "Load a Stripper folder before saving a mix."
            return
        }
        do {
            let url = MixerMixFile.sidecarURL(in: folder)
            try MixerMixFile.write(MixerMixFile.make(from: self), to: url)
            status = "Saved mix → \(MixerMixFile.fileName)"
        } catch {
            status = "Could not save mix: \(error.localizedDescription)"
        }
    }

    /// Open a mix JSON. If it sits in a speakers folder, load that folder (which restores the mix).
    func openMixFile(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        if frameCount == 0 || sourceFolder != folder {
            loadStripperFolder(folder)
            return
        }
        do {
            let doc = try MixerMixFile.read(from: url)
            MixerMixFile.apply(doc, to: self)
            syncParamsToEngine()
            status = "Mix loaded from \(url.lastPathComponent)"
        } catch {
            status = "Could not load mix: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func restoreMixIfPresent(in folder: URL) -> Bool {
        let url = MixerMixFile.sidecarURL(in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let doc = try MixerMixFile.read(from: url)
            MixerMixFile.apply(doc, to: self)
            syncParamsToEngine()
            return true
        } catch {
            return false
        }
    }

    func makeExportItems() -> [MixerExportItem] {
        var items: [MixerExportItem] = []
        for (index, voice) in voices.enumerated() {
            items.append(
                MixerExportItem(
                    id: "voice-\(voice.id)",
                    kind: .voice(index),
                    enabled: true,
                    name: "\(voice.bounceStemBaseName)_fixed",
                    label: voice.name,
                    role: "Speaker stem"
                )
            )
        }
        if hasMusic {
            items.append(
                MixerExportItem(
                    id: "music",
                    kind: .music,
                    enabled: true,
                    name: "\(music.bounceStemBaseName)_fixed",
                    label: music.name,
                    role: "Music + SFX"
                )
            )
        }
        items.append(
            MixerExportItem(
                id: "mix",
                kind: .mix,
                enabled: true,
                name: "mix",
                label: "Complete 2-mix",
                role: "Master bus"
            )
        )
        return items
    }

    func suggestedExportFolder() -> URL {
        if let sourceFolder {
            return sourceFolder.appendingPathComponent("FixerMixer_bounce")
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    func bounce(items: [MixerExportItem], folder: URL) {
        guard !isBouncing else { return }
        guard frameCount > 0 else {
            status = "Load tracks before exporting."
            return
        }
        var voiceFiles: [Int: String] = [:]
        var musicFile: String?
        var mixFile: String?
        for item in items where item.enabled {
            switch item.kind {
            case .voice(let index):
                voiceFiles[index] = item.name
            case .music:
                musicFile = item.name
            case .mix:
                mixFile = item.name
            }
        }
        let plan = MixerEngine.BounceWritePlan(
            voiceFiles: voiceFiles,
            musicFile: musicFile,
            mixFile: mixFile
        )
        guard !plan.isEmpty else {
            status = "Check at least one output to export."
            return
        }
        isBouncing = true
        if isPlaying {
            engine.stop()
            isPlaying = false
        }
        status = "Exporting…"
        syncParamsToEngine()
        Task.detached(priority: .userInitiated) { [engine] in
            do {
                let result = try engine.bounce(to: folder, plan: plan)
                await MainActor.run {
                    self.isBouncing = false
                    self.status = "Exported \(result.fileCount) file\(result.fileCount == 1 ? "" : "s") → \(result.folder.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([result.folder])
                }
            } catch {
                await MainActor.run {
                    self.isBouncing = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func formatDuration(frames: Int, rate: Double) -> String {
        guard rate > 0 else { return "—" }
        let sec = Double(frames) / rate
        return String(format: "%d:%02d", Int(sec) / 60, Int(sec) % 60)
    }
}

struct StripperSpeakerFile: Equatable {
    var number: Int
    var url: URL
}

enum StripperFolderLoader {
    static let maxSpeakers = 16

    static func load(folder: URL) throws -> (speakers: [StripperSpeakerFile], music: URL?) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw MixerError.notAFolder
        }
        let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }

        var byNumber: [Int: URL] = [:]
        var music: URL?
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            if name.contains("music") {
                music = file
                continue
            }
            guard name.contains("speaker") else { continue }
            let digits = name.replacingOccurrences(of: #"\D+"#, with: " ", options: .regularExpression)
            let parts = digits.split(separator: " ").compactMap { Int($0) }
            if let n = parts.last, (1...maxSpeakers).contains(n) {
                byNumber[n] = file
            }
        }
        let speakers = byNumber.keys.sorted().map { StripperSpeakerFile(number: $0, url: byNumber[$0]!) }
        if speakers.isEmpty && music == nil {
            throw MixerError.noTracks
        }
        return (speakers, music)
    }
}

enum MixerError: LocalizedError {
    case notAFolder
    case noTracks
    case loadFailed(String)
    case engine(String)
    case mixFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAFolder: return "Drop a folder (the Stripper _speakers output), not a single file."
        case .noTracks: return "No Speaker_*.wav or Music_and_SFX.wav found in that folder."
        case .loadFailed(let m): return "Could not load audio: \(m)"
        case .engine(let m): return m
        case .mixFailed(let m): return m
        }
    }
}
