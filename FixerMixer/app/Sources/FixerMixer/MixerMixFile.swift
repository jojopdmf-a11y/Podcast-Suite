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
        url.lastPathComponent.lowercased() == fileName.lowercased()
            || url.pathExtension.lowercased() == "json" && url.lastPathComponent.lowercased().contains("fixer")
    }

    struct Document: Codable {
        var formatVersion: Int
        var folderName: String
        var voices: [Strip]
        var music: Strip?
        var masterDb: Float
        var autoBalanceEnabled: Bool
        var autoBalanceTargetDb: Float
        var masterComp: Comp
    }

    struct Strip: Codable {
        var speakerNumber: Int?
        var name: String
        var mute: Bool
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
            music: session.hasMusic ? snapshot(session.music) : nil,
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
            )
        )
    }

    static func snapshot(_ ch: ChannelStripState) -> Strip {
        Strip(
            speakerNumber: ch.speakerNumber,
            name: ch.name,
            mute: ch.mute,
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
            dspOrder: ch.dspOrder.map(\.rawValue)
        )
    }

    static func apply(_ snap: Strip, to ch: inout ChannelStripState) {
        ch.name = snap.name
        ch.mute = snap.mute
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
    }

    @MainActor
    static func apply(_ doc: Document, to session: MixerSession) {
        for i in session.voices.indices {
            let number = session.voices[i].speakerNumber
            guard let snap = doc.voices.first(where: { $0.speakerNumber == number }) else { continue }
            apply(snap, to: &session.voices[i])
        }
        if session.hasMusic, let musicSnap = doc.music {
            apply(musicSnap, to: &session.music)
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
