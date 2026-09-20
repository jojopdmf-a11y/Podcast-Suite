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
        /// `"off"` | `"mix"` | `"duck"`. Older mixes omit → derived from autoBalanceEnabled.
        var autoMixMode: String?
        /// Auto Duck max pull-back (dB). Older mixes omit → 9.
        var autoDuckMaxAttenuationDb: Float?
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
        /// Participate in Auto Mix / Auto Duck. Older mixes omit → true.
        var includeInAutoMix: Bool?
        var pan: Float
        var eqGains: [Float]
        var eqBypass: Bool
        /// 24 dB/oct HPF cutoff Hz. Omitted in older mixes → off.
        var eqHpfHz: Float?
        var paraFreqHz: Float
        var paraGainDb: Float
        var paraWidth: String
        var paraBypass: Bool
        /// `"pre"` | `"post"`. Omitted in older mixes → post (legacy order).
        var paraPlacement: String?
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
        /// Linked partner by speaker number (mono only). Older mixes omit this.
        var linkedPeerSpeakerNumber: Int?
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
        let voiceSnaps: [Strip] = session.voices.map { ch in
            let peerSpeaker: Int? = {
                guard let peerID = ch.linkedPeerID,
                      let peer = session.voices.first(where: { $0.id == peerID }) else { return nil }
                return peer.speakerNumber
            }()
            return snapshot(ch, peerSpeakerNumber: peerSpeaker)
        }
        return Document(
            formatVersion: formatVersion,
            folderName: session.sourceFolder?.lastPathComponent ?? "",
            voices: voiceSnaps,
            music: session.stereos.first.map { snapshot($0) },
            stereos: session.stereos.isEmpty ? nil : session.stereos.map { snapshot($0) },
            masterDb: session.masterDb,
            autoBalanceEnabled: session.autoMixMode.isActive,
            autoBalanceTargetDb: session.autoBalanceTargetDb,
            autoMixMode: session.autoMixMode.rawValue,
            autoDuckMaxAttenuationDb: session.autoDuckMaxAttenuationDb,
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

    static func snapshot(_ ch: ChannelStripState, peerSpeakerNumber: Int? = nil) -> Strip {
        Strip(
            speakerNumber: ch.speakerNumber,
            name: ch.name,
            mute: ch.mute,
            solo: ch.solo,
            dspBypass: ch.dspBypass,
            faderDb: ch.faderDb,
            autoBiasDb: 0,
            includeInAutoMix: ch.isStereo ? nil : ch.includeInAutoMix,
            pan: ch.pan,
            eqGains: ch.eq.gains,
            eqBypass: ch.eq.bypass,
            eqHpfHz: ch.eq.hpfHz,
            paraFreqHz: ch.para.freqHz,
            paraGainDb: ch.para.gainDb,
            paraWidth: ch.para.width.rawValue,
            paraBypass: ch.para.bypass,
            paraPlacement: ch.para.placement.rawValue,
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
            inputChannel: ch.inputChannel,
            linkedPeerSpeakerNumber: peerSpeakerNumber
        )
    }

    static func apply(_ snap: Strip, to ch: inout ChannelStripState) {
        ch.name = snap.name
        ch.mute = snap.mute
        ch.solo = snap.solo ?? false
        ch.dspBypass = snap.dspBypass
        // Baseline = faderDb. Older mixes that saved while auto was on stored the
        // manual weighting in autoBiasDb — prefer that when it differs from faderDb.
        if abs(snap.autoBiasDb) > 0.01, abs(snap.autoBiasDb - snap.faderDb) > 0.01 {
            ch.faderDb = snap.autoBiasDb
        } else {
            ch.faderDb = snap.faderDb
        }
        ch.autoBiasDb = 0
        if !ch.isStereo {
            ch.includeInAutoMix = snap.includeInAutoMix ?? true
        }
        ch.pan = snap.pan
        var gains = snap.eqGains
        let n = GraphicEQBand.allCases.count
        if gains.count < n {
            gains.append(contentsOf: Array(repeating: Float(0), count: n - gains.count))
        }
        ch.eq.gains = Array(gains.prefix(n))
        ch.eq.bypass = snap.eqBypass
        ch.eq.hpfHz = snap.eqHpfHz ?? 0
        ch.eq.clampHPF()
        ch.para.freqHz = snap.paraFreqHz
        ch.para.gainDb = snap.paraGainDb
        ch.para.width = ParaEQWidth(rawValue: snap.paraWidth) ?? .narrow
        ch.para.bypass = snap.paraBypass
        ch.para.placement = ParaEQPlacement(rawValue: snap.paraPlacement ?? "") ?? .post
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
        if let raw = doc.autoMixMode, let mode = AutoMixMode(rawValue: raw) {
            session.autoMixMode = mode
        } else {
            session.autoMixMode = doc.autoBalanceEnabled ? .mix : .off
        }
        session.autoBalanceTargetDb = doc.autoBalanceTargetDb
        session.autoDuckMaxAttenuationDb = doc.autoDuckMaxAttenuationDb ?? 9
        if session.autoMixMode.isActive {
            session.autoGainDb = Array(repeating: 0, count: session.voices.count)
        } else {
            session.autoGainDb = []
        }
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

        // Restore mono links by speaker number (bidirectional, adjacent only).
        for i in session.voices.indices {
            session.voices[i].linkedPeerID = nil
        }
        for i in session.voices.indices {
            let number = session.voices[i].speakerNumber
            guard let snap = doc.voices.first(where: { $0.speakerNumber == number }),
                  let peerNumber = snap.linkedPeerSpeakerNumber,
                  let peerIdx = session.voices.firstIndex(where: { $0.speakerNumber == peerNumber }) else { continue }
            let a = session.voices[i].id
            let b = session.voices[peerIdx].id
            if session.areAdjacentMonos(a, b) {
                session.voices[i].linkedPeerID = b
                session.voices[peerIdx].linkedPeerID = a
            }
        }
        session.pruneBrokenMonoLinks()
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
