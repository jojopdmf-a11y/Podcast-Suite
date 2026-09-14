import Foundation

/// Mix settings sidecar that lives in a Stripper `_speakers` folder.
/// Audio stays in the WAVs; this file is faders, EQ, FX, and master.
enum MixerMixFile {
    static let fileName = "FixerMixer.mix.json"
    static let formatVersion = 1

    static func sidecarURL(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    static func isMixFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "json" else { return false }
        if url.lastPathComponent.lowercased() == fileName.lowercased() { return true }
        if url.lastPathComponent.lowercased().contains("fixer") { return true }
        if url.lastPathComponent.lowercased().contains("podproducer") { return true }
        if url.lastPathComponent.lowercased().contains("mix") { return true }
        return (try? read(from: url)) != nil
    }

    struct Document: Codable {
        var formatVersion: Int
        var folderName: String
        var voices: [Strip]
        /// First stereo bed. Kept so older mix files still open.
        var music: Strip?
        /// MUSIC then SFX (up to 2). Newer mixes write this; older files omit it.
        var stereos: [Strip]?
        var masterDb: Float
        var autoBalanceEnabled: Bool
        var autoBalanceTargetDb: Float
        var masterComp: Comp
        var inputDeviceUID: String?
        /// Left-to-right strip ids. Older mix files omit this.
        var channelOrder: [Int]?
    }

    struct Strip: Codable {
        var speakerNumber: Int?
        var name: String
        var mute: Bool
        var solo: Bool?
        var dspBypass: Bool
        var faderDb: Float
        var autoBiasDb: Float
        var pan: Float
        var eqGains: [Float]
        var eqBypass: Bool
        var paraFreqHz: Float
        var paraGainDb: Float
        var paraWidth: String
        var paraBypass: Bool
        var deVerb: Float
        var deVerbBypass: Bool
        var wetter: Float
        var wetterBypass: Bool
        var wetterRoom: String
        var levelerDrive: Float
        var levelerBypass: Bool
        var levelerTargetDb: Float
        var dspOrder: [String]
        var muteSpans: [MuteSpan]?
        var inputChannel: Int?
    }

    struct Comp: Codable {
        var bypass: Bool
        var thresholdDb: Float
        var attackMs: Float
        var ratio: Float
        var releaseSec: Float
        var knee: Int
        var outputDb: Float
        var autoMakeup: Bool
    }

    @MainActor
    static func make(from session: MixerSession) -> Document {
        Document(
            formatVersion: formatVersion,
            folderName: session.sourceFolder?.lastPathComponent ?? "",
            voices: session.voices.map { snapshot($0) },
            music: session.stereos.first.map { snapshot($0) },
            stereos: session.stereos.isEmpty ? nil : session.stereos.map { snapshot($0) },
            masterDb: session.masterDb,
            autoBalanceEnabled: session.autoBalanceEnabled,
            autoBalanceTargetDb: session.autoBalanceTargetDb,
            masterComp: Comp(
                bypass: session.masterComp.bypass,
                thresholdDb: session.masterComp.thresholdDb,
                attackMs: session.masterComp.attackMs,
                ratio: session.masterComp.ratio,
                releaseSec: session.masterComp.releaseSec,
                knee: session.masterComp.knee,
                outputDb: session.masterComp.outputDb,
                autoMakeup: session.masterComp.autoMakeup
            ),
            inputDeviceUID: session.selectedInputUID,
            channelOrder: session.displayChannelOrder.isEmpty ? nil : session.displayChannelOrder
        )
    }

    static func snapshot(_ ch: ChannelStripState) -> Strip {
        Strip(
            speakerNumber: ch.speakerNumber,
            name: ch.name,
            mute: ch.mute,
            solo: ch.solo,
            dspBypass: ch.dspBypass,
            faderDb: ch.faderDb,
            autoBiasDb: ch.autoBiasDb,
            pan: ch.pan,
            eqGains: ch.eq.gains,
            eqBypass: ch.eq.bypass,
            paraFreqHz: ch.para.freqHz,
            paraGainDb: ch.para.gainDb,
            paraWidth: ch.para.width.rawValue,
            paraBypass: ch.para.bypass,
            deVerb: ch.voice.deVerb,
            deVerbBypass: ch.voice.deVerbBypass,
            wetter: ch.voice.wetter,
            wetterBypass: ch.voice.wetterBypass,
            wetterRoom: ch.voice.wetterRoom.rawValue,
            levelerDrive: ch.voice.levelerDrive,
            levelerBypass: ch.voice.levelerBypass,
            levelerTargetDb: ch.voice.levelerTargetDb,
            dspOrder: ch.dspOrder.map(\.rawValue),
            muteSpans: ch.muteSpans,
            inputChannel: ch.inputChannel
        )
    }

    static func apply(_ snap: Strip, to ch: inout ChannelStripState) {
        ch.name = snap.name
        ch.mute = snap.mute
        ch.solo = snap.solo ?? false
        ch.dspBypass = snap.dspBypass
        ch.faderDb = snap.faderDb
        ch.autoBiasDb = snap.autoBiasDb
        ch.pan = snap.pan
        var gains = snap.eqGains
        let n = GraphicEQBand.allCases.count
        if gains.count < n {
            gains.append(contentsOf: Array(repeating: Float(0), count: n - gains.count))
        }
        ch.eq.gains = Array(gains.prefix(n))
        ch.eq.bypass = snap.eqBypass
        ch.para.freqHz = snap.paraFreqHz
        ch.para.gainDb = snap.paraGainDb
        ch.para.width = ParaEQWidth(rawValue: snap.paraWidth) ?? .narrow
        ch.para.bypass = snap.paraBypass
        ch.para.clamp()
        ch.voice.deVerb = snap.deVerb
        ch.voice.deVerbBypass = snap.deVerbBypass
        ch.voice.wetter = snap.wetter
        ch.voice.wetterBypass = snap.wetterBypass
        ch.voice.wetterRoom = WetterRoom(rawValue: snap.wetterRoom) ?? .drumRoom
        ch.voice.levelerDrive = snap.levelerDrive
        ch.voice.levelerBypass = snap.levelerBypass
        ch.voice.levelerTargetDb = snap.levelerTargetDb
        let order = snap.dspOrder.compactMap(ChannelDSPSlot.init(rawValue:))
        if !order.isEmpty {
            ch.dspOrder = order
        }
        ch.muteSpans = snap.muteSpans ?? []
        ch.inputChannel = snap.inputChannel
    }

    @MainActor
    static func apply(_ doc: Document, to session: MixerSession) {
        for i in session.voices.indices {
            let number = session.voices[i].speakerNumber
            guard let snap = doc.voices.first(where: { $0.speakerNumber == number }) else { continue }
            apply(snap, to: &session.voices[i])
        }
        if let snaps = doc.stereos, !snaps.isEmpty {
            for i in session.stereos.indices where i < snaps.count {
                apply(snaps[i], to: &session.stereos[i])
            }
        } else if let musicSnap = doc.music, !session.stereos.isEmpty {
            apply(musicSnap, to: &session.stereos[0])
        }
        session.masterDb = doc.masterDb
        session.autoBalanceEnabled = doc.autoBalanceEnabled
        session.autoBalanceTargetDb = doc.autoBalanceTargetDb
        session.masterComp.bypass = doc.masterComp.bypass
        session.masterComp.thresholdDb = doc.masterComp.thresholdDb
        session.masterComp.attackMs = doc.masterComp.attackMs
        session.masterComp.ratio = doc.masterComp.ratio
        session.masterComp.releaseSec = doc.masterComp.releaseSec
        session.masterComp.knee = doc.masterComp.knee
        session.masterComp.outputDb = doc.masterComp.outputDb
        session.masterComp.autoMakeup = doc.masterComp.autoMakeup
        if let uid = doc.inputDeviceUID {
            session.selectedInputUID = uid
        }
        if let order = doc.channelOrder, !order.isEmpty {
            session.channelOrder = order
            session.syncChannelOrder()
        } else {
            session.replaceChannelOrderFromCurrentStrips()
        }
    }

    static func write(_ doc: Document, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: url, options: [.atomic])
    }

    static func read(from url: URL) throws -> Document {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Document.self, from: data)
    }
}
