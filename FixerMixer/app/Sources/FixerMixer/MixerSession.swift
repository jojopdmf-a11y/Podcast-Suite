import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    var solo: Bool = false
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
    /// Hardware input channel (0-based) this strip records. Nil = not armed.
    var inputChannel: Int? = nil
    /// Painted silence ranges. The show does not get shorter.
    var muteSpans: [MuteSpan] = []

    static let musicID = 1000
    static let masterID = 2000

    static func == (lhs: ChannelStripState, rhs: ChannelStripState) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isStereo == rhs.isStereo
            && lhs.speakerNumber == rhs.speakerNumber
            && lhs.fileURL == rhs.fileURL
            && lhs.mute == rhs.mute
            && lhs.solo == rhs.solo
            && lhs.dspBypass == rhs.dspBypass
            && lhs.faderDb == rhs.faderDb
            && lhs.autoBiasDb == rhs.autoBiasDb
            && lhs.pan == rhs.pan
            && lhs.eq == rhs.eq
            && lhs.para == rhs.para
            && lhs.voice == rhs.voice
            && lhs.dspOrder == rhs.dspOrder
            && lhs.inputChannel == rhs.inputChannel
            && lhs.muteSpans == rhs.muteSpans
    }

    static func voice(slot: Int, speakerNumber: Int, name: String? = nil) -> ChannelStripState {
        ChannelStripState(
            id: slot,
            name: name ?? "SPK \(speakerNumber)",
            isStereo: false,
            speakerNumber: speakerNumber,
            dspOrder: ChannelDSPSlot.voiceDefault
        )
    }

    static func music() -> ChannelStripState {
        stereo(slot: 0)
    }

    static func stereo(slot: Int, name: String? = nil) -> ChannelStripState {
        ChannelStripState(
            id: musicID + slot,
            name: name ?? (slot == 0 ? "MUSIC" : "SFX"),
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
    @Published var stereos: [ChannelStripState] = []
    var hasMusic: Bool { !stereos.isEmpty }
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
    @Published var status: String = "Drop audio, a Stripper folder, or NEW SESSION to record from your interface."
    @Published var isPlaying = false
    @Published var isRecording = false
    @Published var isBouncing = false
    @Published var inputDevices: [MixerInputDevice] = []
    @Published var selectedInputUID: String?
    @Published var sourceFolder: URL?
    /// Last mix JSON the user saved or opened, used as the Save panel default.
    @Published private(set) var lastMixURL: URL?
    @Published var sampleRate: Double = 44100
    @Published var frameCount: Int = 0
    /// Voice slot id, stereo bed id (`musicID + slot`), or master.
    @Published var selectedChannelID: Int = 0
    @Published var playheadFrame: Int = 0
    @Published var waveformPeaks: [Float] = []
    /// Left-to-right strip order (channel ids). Audio routing stays put.
    @Published var channelOrder: [Int] = []

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
                for i in self.stereos.indices {
                    let slot = n + i
                    if slot < pre.count {
                        self.stereos[i].prePeak = pre[slot]
                        self.stereos[i].postPeak = post[slot]
                    }
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
                self?.isRecording = false
                self?.status = "Reached end."
            }
        }
        engine.onSessionLength = { [weak self] frames in
            Task { @MainActor in
                guard let self else { return }
                self.frameCount = frames
                self.refreshWaveform()
            }
        }
    }

    var selectedInputChannelCount: Int {
        MixerInputDevices.device(uid: selectedInputUID ?? "", in: inputDevices)?.inputChannels
            ?? inputDevices.first?.inputChannels
            ?? 0
    }

    /// True after NEW SESSION, even with no strips. Launch still shows the drop splash.
    @Published private(set) var mixerOpen = false
    var hasSession: Bool { mixerOpen || !voices.isEmpty || !stereos.isEmpty }

    func refreshInputDevices() {
        inputDevices = MixerInputDevices.list()
        if selectedInputUID == nil || MixerInputDevices.device(uid: selectedInputUID ?? "", in: inputDevices) == nil {
            selectedInputUID = MixerInputDevices.defaultInputUID()
                ?? inputDevices.first?.uid
        }
    }

    func newRecordSession() {
        if isPlaying || isRecording {
            engine.stop()
            isPlaying = false
            isRecording = false
        }
        refreshInputDevices()
        engine.prepareBlankSession(voiceCount: 0, sampleRate: 48_000)
        voices = []
        stereos = []
        mixerOpen = true
        sourceFolder = nil
        lastMixURL = nil
        sampleRate = engine.sampleRate
        frameCount = 0
        playheadFrame = 0
        selectedChannelID = ChannelStripState.masterID
        autoBalanceEnabled = false
        autoGainDb = []
        channelOrder = []
        refreshWaveform()
        syncRTASource()
        syncParamsToEngine()
        status = "Empty mixer. Drop audio or ADD STRIP. Pick IN on a speaker, then Record. Monitor through your interface."
    }

    private func ensureSessionFolder() {
        guard sourceFolder == nil else { return }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ", ", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let folder = desktop.appendingPathComponent("FixerMixer-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sourceFolder = folder
    }

    func addBlankStrip() {
        guard voices.count < StripperFolderLoader.maxSpeakers else {
            status = "Mixer already has \(StripperFolderLoader.maxSpeakers) speaker strips."
            return
        }
        mixerOpen = true
        if isPlaying || isRecording {
            engine.stop()
            isPlaying = false
            isRecording = false
        }
        let n = voices.count + 1
        var ch = ChannelStripState.voice(slot: voices.count, speakerNumber: n, name: "SPK \(n)")
        if selectedInputChannelCount >= n {
            ch.inputChannel = n - 1
        }
        engine.appendSilentVoice(speakerNumber: n)
        voices.append(ch)
        syncChannelOrder()
        sampleRate = engine.sampleRate
        frameCount = engine.frameCount
        selectedChannelID = ch.id
        refreshWaveform()
        syncParamsToEngine()
        status = "Added \(ch.name). Pick IN on the strip to record it."
    }

    func toggleRecord() {
        if isRecording {
            stopRecord()
            return
        }
        refreshInputDevices()
        guard voices.contains(where: { $0.inputChannel != nil }) else {
            status = voices.isEmpty
                ? "ADD STRIP, pick IN 1 / IN 2, then Record. Monitor through your interface."
                : "Pick IN 1 / IN 2 on a speaker strip, then Record. Monitor through your interface."
            return
        }
        ensureSessionFolder()
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            continueRecordIfMicAllowed(true)
        case .denied:
            continueRecordIfMicAllowed(false)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor [weak self] in
                    self?.continueRecordIfMicAllowed(granted)
                }
            }
        @unknown default:
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor [weak self] in
                    self?.continueRecordIfMicAllowed(granted)
                }
            }
        }
    }

    private func continueRecordIfMicAllowed(_ granted: Bool) {
        guard granted else {
            status = "Microphone access is off. System Settings → Privacy & Security → Microphone → Fixer Mixer."
            return
        }
        syncParamsToEngine()
        do {
            try engine.start(
                fromBeginning: false,
                recording: true,
                inputDeviceUID: selectedInputUID
            )
            isPlaying = true
            isRecording = true
            status = "Recording — overwrites from the playhead on armed strips. Monitor mics on your interface, not through Mixer."
        } catch {
            status = error.localizedDescription
        }
    }

    func stopRecord() {
        engine.stop()
        isPlaying = false
        isRecording = false
        frameCount = engine.frameCount
        playheadFrame = engine.currentFrame()
        engine.rebuildPeaks()
        refreshWaveform()
        if let folder = sourceFolder {
            do {
                let written = try engine.writeWorkingTakes(to: folder)
                for (index, url) in written {
                    if voices.indices.contains(index) {
                        voices[index].fileURL = url
                    }
                }
                let mixURL = MixerMixFile.sidecarURL(in: folder)
                try MixerMixFile.write(MixerMixFile.make(from: self), to: mixURL)
                lastMixURL = mixURL
                status = "Recorded to \(folder.lastPathComponent). Shift-drag the waveform to mute a cough (silence — the show stays this long). Monitor mics on your interface, not through Mixer."
            } catch {
                status = "Recorded in this window. Export to keep it. Could not write takes: \(error.localizedDescription)"
            }
        } else {
            status = "Recorded in this window. Export to keep it. Shift-drag the waveform to mute a cough."
        }
    }

    func paintMute(normalizedFrom: Double, to normalizedTo: Double) {
        guard selectedChannelID != ChannelStripState.masterID else {
            status = "Select a strip, then Shift-drag the waveform to silence that span (the show stays this long)."
            return
        }
        guard frameCount > 1 else { return }
        let a = Int((min(normalizedFrom, normalizedTo) * Double(frameCount - 1)).rounded())
        let b = Int((max(normalizedFrom, normalizedTo) * Double(frameCount - 1)).rounded())
        guard b > a else { return }
        let span = MuteSpan(startFrame: a, endFrame: b)
        if let idx = stereos.firstIndex(where: { $0.id == selectedChannelID }) {
            stereos[idx].muteSpans = MuteSpanStore.adding(span, to: stereos[idx].muteSpans)
        } else if let idx = voices.firstIndex(where: { $0.id == selectedChannelID }) {
            voices[idx].muteSpans = MuteSpanStore.adding(span, to: voices[idx].muteSpans)
        }
        syncParamsToEngine()
        persistMixIfPossible()
        status = "Muted that span on \(selectedChannelName) (silence, same length). Option-drag to clear."
    }

    func clearMute(normalizedFrom: Double, to normalizedTo: Double) {
        guard selectedChannelID != ChannelStripState.masterID else {
            status = "Select a speaker strip, then Option-drag to clear a mute."
            return
        }
        guard frameCount > 1 else { return }
        let a = Int((min(normalizedFrom, normalizedTo) * Double(frameCount - 1)).rounded())
        let b = Int((max(normalizedFrom, normalizedTo) * Double(frameCount - 1)).rounded())
        guard b > a else { return }
        let span = MuteSpan(startFrame: a, endFrame: b)
        if let idx = stereos.firstIndex(where: { $0.id == selectedChannelID }) {
            stereos[idx].muteSpans = MuteSpanStore.removing(span, from: stereos[idx].muteSpans)
        } else if let idx = voices.firstIndex(where: { $0.id == selectedChannelID }) {
            voices[idx].muteSpans = MuteSpanStore.removing(span, from: voices[idx].muteSpans)
        }
        syncParamsToEngine()
        persistMixIfPossible()
        status = "Unmuted that span on \(selectedChannelName)."
    }

    private func persistMixIfPossible() {
        guard let folder = sourceFolder else { return }
        let dest = lastMixURL ?? MixerMixFile.sidecarURL(in: folder)
        do {
            try MixerMixFile.write(MixerMixFile.make(from: self), to: dest)
            lastMixURL = dest
        } catch {
            // Keep the paint / record status line; UPDATE MIX still works.
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

    /// Keep existing strip order, drop missing ids, append new strips at the end.
    func syncChannelOrder() {
        let ids = voices.map(\.id) + stereos.map(\.id)
        var next = channelOrder.filter { ids.contains($0) }
        for id in ids where !next.contains(id) {
            next.append(id)
        }
        channelOrder = next
    }

    func replaceChannelOrderFromCurrentStrips() {
        channelOrder = voices.map(\.id) + stereos.map(\.id)
    }

    func moveChannel(fromID: Int, toID: Int) {
        var order = displayChannelOrder
        guard fromID != toID,
              let from = order.firstIndex(of: fromID),
              let to = order.firstIndex(of: toID) else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        channelOrder = order
        persistMixIfPossible()
        let name = voices.first(where: { $0.id == fromID })?.name
            ?? stereos.first(where: { $0.id == fromID })?.name
            ?? "strip"
        status = "Moved \(name). Click REORDER again when the order looks right."
    }

    func selectChannel(_ id: Int) {
        selectedChannelID = id
        refreshWaveform()
        syncRTASource()
    }

    func syncRTASource() {
        if selectedChannelID == ChannelStripState.masterID {
            engine.setRTASource(isMusic: false, voiceIndex: 0, isMaster: true)
        } else if let idx = stereos.firstIndex(where: { $0.id == selectedChannelID }) {
            engine.setRTASource(isMusic: true, voiceIndex: idx, isMaster: false)
        } else if let idx = voices.firstIndex(where: { $0.id == selectedChannelID }) {
            engine.setRTASource(isMusic: false, voiceIndex: idx, isMaster: false)
        }
    }

    func refreshWaveform() {
        if selectedChannelID == ChannelStripState.masterID {
            waveformPeaks = engine.waveformPeaks(channelIndex: nil, music: false, masterMix: true, binCount: 900)
        } else if let idx = stereos.firstIndex(where: { $0.id == selectedChannelID }) {
            waveformPeaks = engine.waveformPeaks(channelIndex: nil, music: true, masterMix: false, stereoIndex: idx, binCount: 900)
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
        if let s = stereos.first(where: { $0.id == selectedChannelID }) { return s.name }
        if let v = voices.first(where: { $0.id == selectedChannelID }) { return v.name }
        return "—"
    }

    var selectedMuteSpansNormalized: [(Double, Double)] {
        if let s = stereos.first(where: { $0.id == selectedChannelID }) {
            return muteSpansNormalized(s.muteSpans)
        }
        if let v = voices.first(where: { $0.id == selectedChannelID }) {
            return muteSpansNormalized(v.muteSpans)
        }
        return []
    }

    /// Left-to-right strip ids. Does not publish; safe to read in views.
    var displayChannelOrder: [Int] {
        let ids = voices.map(\.id) + stereos.map(\.id)
        var next = channelOrder.filter { ids.contains($0) }
        for id in ids where !next.contains(id) {
            next.append(id)
        }
        return next
    }

    /// Speaker strips then stereo beds, or the user's REORDER layout. Visual overview — not an editor.
    var waveformLanes: [MixerWaveformLane] {
        var lanes: [MixerWaveformLane] = []
        for id in displayChannelOrder {
            if let index = voices.firstIndex(where: { $0.id == id }) {
                let voice = voices[index]
                lanes.append(
                    MixerWaveformLane(
                        id: voice.id,
                        name: voice.name,
                        peaks: engine.waveformPeaks(channelIndex: index, music: false, masterMix: false, binCount: 900),
                        muteSpans: muteSpansNormalized(voice.muteSpans)
                    )
                )
            } else if let index = stereos.firstIndex(where: { $0.id == id }) {
                let bed = stereos[index]
                lanes.append(
                    MixerWaveformLane(
                        id: bed.id,
                        name: bed.name,
                        peaks: engine.waveformPeaks(channelIndex: nil, music: true, masterMix: false, stereoIndex: index, binCount: 900),
                        muteSpans: muteSpansNormalized(bed.muteSpans)
                    )
                )
            }
        }
        return lanes
    }

    private func muteSpansNormalized(_ spans: [MuteSpan]) -> [(Double, Double)] {
        guard frameCount > 1 else { return [] }
        let denom = Double(frameCount - 1)
        return spans.map { (Double($0.startFrame) / denom, Double($0.endFrame) / denom) }
    }

    func loadStripperFolder(_ folder: URL) {
        do {
            if isPlaying || isRecording {
                engine.stop()
                isPlaying = false
                isRecording = false
            }
            let mapped = try StripperFolderLoader.load(folder: folder)
            voices = mapped.speakers.enumerated().map { slot, item in
                var ch = ChannelStripState.voice(slot: slot, speakerNumber: item.number)
                ch.fileURL = item.url
                return ch
            }
            stereos = mapped.music.enumerated().map { slot, url in
                var bed = ChannelStripState.stereo(slot: slot, name: MixerAudioIO.displayName(url: url))
                bed.fileURL = url
                return bed
            }
            replaceChannelOrderFromCurrentStrips()
            sourceFolder = folder
            try engine.load(
                voiceURLs: voices.map(\.fileURL),
                speakerNumbers: voices.map { $0.speakerNumber ?? ($0.id + 1) },
                stereoURLs: stereos.compactMap(\.fileURL),
                sampleRateHint: nil
            )
            sampleRate = engine.sampleRate
            frameCount = engine.frameCount
            playheadFrame = 0
            if let first = voices.first {
                selectedChannelID = first.id
            } else if let firstBed = stereos.first {
                selectedChannelID = firstBed.id
            }
            refreshWaveform()
            syncRTASource()
            syncParamsToEngine()
            let loaded = voices.count + stereos.count
            let spkLabel = voices.isEmpty ? "no speakers" : "\(voices.count) speaker\(voices.count == 1 ? "" : "s")"
            let bedLabel = stereos.isEmpty ? "" : " + \(stereos.count) stereo"
            var line = "Loaded \(loaded) track(s) · \(spkLabel)\(bedLabel) · \(Int(sampleRate)) Hz · \(formatDuration(frames: frameCount, rate: sampleRate))"
            if mapped.skippedSpeakers > 0 {
                line += " · stopped at \(StripperFolderLoader.maxSpeakers) speaker strips"
            }
            if mapped.skippedStereo > 0 {
                line += " · stopped at \(StripperFolderLoader.maxStereo) stereo strips"
            }
            if FileManager.default.fileExists(atPath: MixerMixFile.sidecarURL(in: folder).path) {
                if restoreMixIfPresent(in: folder) {
                    line += " · mix restored"
                } else {
                    line += " · mix file found but could not be read"
                }
            } else if lastMixURL?.deletingLastPathComponent() != folder {
                lastMixURL = nil
            }
            status = line
        } catch MixerError.noTracks {
            let audio = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            ))?.filter {
                MixerAudioIO.isSupportedAudioURL($0) && !$0.lastPathComponent.hasPrefix(".")
            } ?? []
            if audio.isEmpty {
                status = MixerError.noTracks.localizedDescription
                return
            }
            importAudioFiles(audio.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }, append: false)
        } catch {
            status = error.localizedDescription
        }
    }

    /// Dropped Finder items: mix JSON, Stripper folder, or any audio files.
    func importDroppedURLs(_ urls: [URL]) {
        let unique = Self.dedupeURLs(urls)
        guard !unique.isEmpty else { return }

        if let mix = unique.first(where: { MixerMixFile.isMixFile($0) }) {
            openMixFile(mix)
            return
        }

        let folders = unique.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        if let folder = folders.first {
            loadStripperFolder(folder)
            return
        }

        let audio = unique.filter { MixerAudioIO.isSupportedAudioURL($0) }
        if audio.isEmpty {
            status = "Drop audio (WAV, AIFF, MP3, M4A…) or a Stripper _speakers folder."
            return
        }
        importAudioFiles(audio, append: frameCount > 0)
    }

    func importAudioFiles(_ urls: [URL], append: Bool) {
        let incoming = Self.dedupeURLs(urls).filter {
            MixerAudioIO.isSupportedAudioURL($0) && !$0.lastPathComponent.hasPrefix(".")
        }
        guard !incoming.isEmpty else {
            status = "Those files aren’t audio Mixer can open."
            return
        }

        if isPlaying || isRecording {
            engine.stop()
            isPlaying = false
            isRecording = false
        }

        var nextVoices = append ? voices : []
        var nextStereos = append ? stereos : []
        var hitCap = false
        var hitStereoCap = false

        for url in incoming {
            if nextVoices.contains(where: { $0.fileURL == url }) { continue }
            if nextStereos.contains(where: { $0.fileURL == url }) { continue }
            if nextVoices.count >= StripperFolderLoader.maxSpeakers,
               nextStereos.count >= StripperFolderLoader.maxStereo {
                hitCap = true
                hitStereoCap = true
                break
            }

            let wantsMusic = MixerAudioIO.looksLikeMusic(url: url)
            if wantsMusic {
                if nextStereos.count < StripperFolderLoader.maxStereo {
                    var bed = ChannelStripState.stereo(
                        slot: nextStereos.count,
                        name: MixerAudioIO.displayName(url: url)
                    )
                    bed.fileURL = url
                    nextStereos.append(bed)
                } else {
                    hitStereoCap = true
                }
                continue
            }

            if nextVoices.count >= StripperFolderLoader.maxSpeakers {
                hitCap = true
                continue
            }

            let slot = nextVoices.count
            var ch = ChannelStripState.voice(
                slot: slot,
                speakerNumber: slot + 1,
                name: MixerAudioIO.displayName(url: url)
            )
            ch.fileURL = url
            nextVoices.append(ch)
        }

        guard !nextVoices.isEmpty || !nextStereos.isEmpty else {
            status = "No tracks to load."
            return
        }

        let startedVoices = append ? voices.count : 0
        let startedStereos = append ? stereos.count : 0
        if nextVoices.count == startedVoices, nextStereos.count == startedStereos {
            if hitStereoCap {
                status = "Mixer already has \(StripperFolderLoader.maxStereo) stereo strips (music / SFX)."
            } else {
                status = hitCap
                    ? "Mixer already has \(StripperFolderLoader.maxSpeakers) speaker strips."
                    : "Those tracks are already on the mixer."
            }
            return
        }

        // Re-index ids so strips stay 0..<n after append.
        for i in nextVoices.indices {
            let url = nextVoices[i].fileURL
            let name = nextVoices[i].name
            let kept = nextVoices[i]
            var ch = ChannelStripState.voice(slot: i, speakerNumber: kept.speakerNumber ?? (i + 1), name: name)
            ch.fileURL = url
            ch.mute = kept.mute
            ch.solo = kept.solo
            ch.dspBypass = kept.dspBypass
            ch.faderDb = kept.faderDb
            ch.autoBiasDb = kept.autoBiasDb
            ch.pan = kept.pan
            ch.eq = kept.eq
            ch.para = kept.para
            ch.voice = kept.voice
            ch.dspOrder = kept.dspOrder
            ch.inputChannel = kept.inputChannel
            ch.muteSpans = kept.muteSpans
            nextVoices[i] = ch
        }
        for i in nextStereos.indices {
            let kept = nextStereos[i]
            var bed = ChannelStripState.stereo(slot: i, name: kept.name)
            bed.fileURL = kept.fileURL
            bed.mute = kept.mute
            bed.solo = kept.solo
            bed.dspBypass = kept.dspBypass
            bed.faderDb = kept.faderDb
            bed.pan = kept.pan
            bed.eq = kept.eq
            bed.para = kept.para
            bed.dspOrder = kept.dspOrder
            bed.muteSpans = kept.muteSpans
            nextStereos[i] = bed
        }

        do {
            voices = nextVoices
            stereos = nextStereos
            if append {
                syncChannelOrder()
            } else {
                replaceChannelOrderFromCurrentStrips()
            }
            if !append || sourceFolder == nil {
                sourceFolder = incoming.first?.deletingLastPathComponent() ?? sourceFolder
            }
            try engine.load(
                voiceURLs: voices.map(\.fileURL),
                speakerNumbers: voices.map { $0.speakerNumber ?? ($0.id + 1) },
                stereoURLs: stereos.compactMap(\.fileURL),
                sampleRateHint: nil
            )
            sampleRate = engine.sampleRate
            frameCount = engine.frameCount
            playheadFrame = 0
            if !append {
                lastMixURL = nil
                autoBalanceEnabled = false
                autoGainDb = []
            }
            if let first = voices.first {
                selectedChannelID = first.id
            } else if let firstBed = stereos.first {
                selectedChannelID = firstBed.id
            }
            refreshWaveform()
            syncRTASource()
            syncParamsToEngine()
            var line = "Loaded \(voices.count + stereos.count) track(s) · \(Int(sampleRate)) Hz · \(formatDuration(frames: frameCount, rate: sampleRate))"
            if hitStereoCap {
                line += " · stopped at \(StripperFolderLoader.maxStereo) stereo strips"
            }
            if hitCap {
                line += " · stopped at \(StripperFolderLoader.maxSpeakers) speaker strips"
            }
            status = line
        } catch {
            status = error.localizedDescription
        }
    }

    private static func dedupeURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                out.append(url.standardizedFileURL)
            }
        }
        return out
    }

    func syncParamsToEngine() {
        engine.updateParams(
            voices: voices,
            stereos: stereos,
            masterDb: masterDb,
            autoBalanceEnabled: autoBalanceEnabled,
            autoBalanceTargetDb: autoBalanceTargetDb,
            masterComp: masterComp
        )
    }

    func togglePlay() {
        if isRecording {
            stopRecord()
            return
        }
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
        if isRecording {
            stopRecord()
            return
        }
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

    /// Overwrite the current mix file with no naming window.
    /// First time writes `FixerMixer.mix.json` in the `_speakers` folder.
    func updateMix() {
        guard (frameCount > 0 || hasSession), let folder = sourceFolder else {
            status = "Load tracks or start a session before saving a mix."
            return
        }
        let dest = lastMixURL ?? MixerMixFile.sidecarURL(in: folder)
        writeMix(to: dest, verb: "Updated")
    }

    /// Opens a Save panel so you pick the folder and file name for the mix JSON.
    func saveMix() {
        guard (frameCount > 0 || hasSession), let folder = sourceFolder else {
            status = "Load tracks or start a session before saving a mix."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Mix"
        panel.message = "Mix settings only (faders, EQ, FX). Audio stays in the WAV files."
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = lastMixURL?.lastPathComponent ?? MixerMixFile.fileName
        panel.directoryURL = lastMixURL?.deletingLastPathComponent() ?? folder
        guard panel.runModal() == .OK, var dest = panel.url else {
            status = "Save cancelled"
            return
        }
        if dest.pathExtension.lowercased() != "json" {
            dest = dest.appendingPathExtension("json")
        }
        writeMix(to: dest, verb: "Saved")
    }

    private func writeMix(to dest: URL, verb: String) {
        do {
            try MixerMixFile.write(MixerMixFile.make(from: self), to: dest)
            lastMixURL = dest
            status = "\(verb) mix → \(dest.lastPathComponent)"
        } catch {
            status = "Could not save mix: \(error.localizedDescription)"
        }
    }

    /// Open a mix JSON. If it sits in a speakers folder, that folder loads first.
    func openMixFile(_ url: URL) {
        do {
            let doc = try MixerMixFile.read(from: url)
            lastMixURL = url
            let folder = url.deletingLastPathComponent()
            if isStripperSpeakersFolder(folder), sourceFolder != folder || frameCount == 0 {
                loadStripperFolder(folder)
                MixerMixFile.apply(doc, to: self)
                syncParamsToEngine()
                lastMixURL = url
                status = "Loaded folder and mix from \(url.lastPathComponent)"
                return
            }
            guard frameCount > 0 else {
                status = "Drop the _speakers folder first, then load this mix."
                return
            }
            MixerMixFile.apply(doc, to: self)
            syncParamsToEngine()
            status = "Mix loaded from \(url.lastPathComponent)"
        } catch {
            status = "Could not load mix: \(error.localizedDescription)"
        }
    }

    private func isStripperSpeakersFolder(_ folder: URL) -> Bool {
        (try? StripperFolderLoader.load(folder: folder)) != nil
    }

    @discardableResult
    private func restoreMixIfPresent(in folder: URL) -> Bool {
        let url = MixerMixFile.sidecarURL(in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let doc = try MixerMixFile.read(from: url)
            MixerMixFile.apply(doc, to: self)
            syncParamsToEngine()
            lastMixURL = url
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
        for (index, bed) in stereos.enumerated() {
            items.append(
                MixerExportItem(
                    id: "stereo-\(bed.id)",
                    kind: .stereo(index),
                    enabled: true,
                    name: "\(bed.bounceStemBaseName)_fixed",
                    label: bed.name,
                    role: index == 0 ? "Music" : "Stereo bed"
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
        var stereoFiles: [Int: String] = [:]
        var mixFile: String?
        for item in items where item.enabled {
            switch item.kind {
            case .voice(let index):
                voiceFiles[index] = item.name
            case .stereo(let index):
                stereoFiles[index] = item.name
            case .mix:
                mixFile = item.name
            }
        }
        let plan = MixerEngine.BounceWritePlan(
            voiceFiles: voiceFiles,
            stereoFiles: stereoFiles,
            mixFile: mixFile
        )
        guard !plan.isEmpty else {
            status = "Check at least one output to export."
            return
        }
        isBouncing = true
        if isPlaying || isRecording {
            engine.stop()
            isPlaying = false
            isRecording = false
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

/// One strip in the stacked ALL TRACKS waveform view.
struct MixerWaveformLane: Identifiable, Equatable {
    var id: Int
    var name: String
    var peaks: [Float]
    var muteSpans: [(Double, Double)]

    static func == (lhs: MixerWaveformLane, rhs: MixerWaveformLane) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.peaks == rhs.peaks
            && lhs.muteSpans.count == rhs.muteSpans.count
            && zip(lhs.muteSpans, rhs.muteSpans).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

struct StripperSpeakerFile: Equatable {
    var number: Int
    var url: URL
}

enum StripperFolderLoader {
    static let maxSpeakers = 8
    static let maxStereo = 2

    static func load(folder: URL) throws -> (speakers: [StripperSpeakerFile], music: [URL], skippedSpeakers: Int, skippedStereo: Int) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw MixerError.notAFolder
        }
        let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }

        var byNumber: [Int: URL] = [:]
        var beds: [URL] = []
        var skippedSpeakers = 0
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            if name.contains("music") || name.contains("sfx") {
                beds.append(file)
                continue
            }
            guard name.contains("speaker") else { continue }
            let digits = name.replacingOccurrences(of: #"\D+"#, with: " ", options: .regularExpression)
            let parts = digits.split(separator: " ").compactMap { Int($0) }
            if let n = parts.last, (1...maxSpeakers).contains(n) {
                byNumber[n] = file
            } else if let n = parts.last, n > maxSpeakers {
                skippedSpeakers += 1
            }
        }
        beds.sort { a, b in
            let an = a.deletingPathExtension().lastPathComponent.lowercased()
            let bn = b.deletingPathExtension().lastPathComponent.lowercased()
            let am = an.contains("music")
            let bm = bn.contains("music")
            if am != bm { return am && !bm }
            return an.localizedStandardCompare(bn) == .orderedAscending
        }
        let skippedStereo = max(0, beds.count - maxStereo)
        beds = Array(beds.prefix(maxStereo))
        let speakers = byNumber.keys.sorted().map { StripperSpeakerFile(number: $0, url: byNumber[$0]!) }
        if speakers.isEmpty && beds.isEmpty {
            throw MixerError.noTracks
        }
        return (speakers, beds, skippedSpeakers, skippedStereo)
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
        case .notAFolder: return "Drop audio files, or a Stripper _speakers folder."
        case .noTracks: return "No audio tracks found in that folder."
        case .loadFailed(let m): return "Could not load audio: \(m)"
        case .engine(let m): return m
        case .mixFailed(let m): return m
        }
    }
}
