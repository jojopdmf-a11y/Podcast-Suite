import Foundation

/// What an export from TheCut writes. Full Mix is the timeline as it plays.
/// One track writes only that track.
public enum TrimmerExportScope: String, CaseIterable, Equatable, Sendable {
    case fullMix
    case episodeMix
    case introsOutrosAds
    case musicBeds

    public var track: TrimmerTrackID? {
        switch self {
        case .fullMix: nil
        case .episodeMix: .episodeMix
        case .introsOutrosAds: .introsOutrosAds
        case .musicBeds: .musicBeds
        }
    }

    public var menuTitle: String {
        switch self {
        case .fullMix: "Full Mix"
        case .episodeMix: "Episode Mix only"
        case .introsOutrosAds: "Intros · Outros · Ads only"
        case .musicBeds: "Music Beds only"
        }
    }
}

public enum TrimmerExportPlan {
    /// Full mix is always stereo. One track is mono only when every clip on it
    /// comes from a one-channel file. A missing count is treated as stereo.
    public static func channelCount(
        scope: TrimmerExportScope,
        document: TrimmerDocument,
        channelCounts: [String: Int]
    ) -> Int {
        guard let track = scope.track else { return 2 }
        let clips = document.clips.filter { $0.track == track }
        guard clips.isEmpty == false else { return 2 }
        for clip in clips where channelCounts[clip.assetID] != 1 {
            return 2
        }
        return 1
    }

    public static func displayName(episode: String, scope: TrimmerExportScope) -> String {
        let trimmed = episode.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Episode" : trimmed
        switch scope {
        case .fullMix:
            return "\(title) \u{2013} Cut"
        default:
            let track = scope.track?.title ?? "Track"
            return "\(title) \u{2013} \(track) Cut"
        }
    }

    /// The chapters text file is written for the full mix only.
    public static func includesChapters(_ scope: TrimmerExportScope) -> Bool {
        scope == .fullMix
    }

    /// WAV and AIFF keep the timeline rate. MP3 and M4A use 44.1 or 48, otherwise 48.
    public static func deliveryRate(renderRate: Double, container: TrimmerExportContainer) -> Double {
        let rate = renderRate > 0 && renderRate.isFinite ? renderRate : 48_000
        switch container {
        case .wav, .aiff:
            return rate
        case .m4a, .mp3:
            if abs(rate - 44_100) < 1 { return 44_100 }
            if abs(rate - 48_000) < 1 { return 48_000 }
            return 48_000
        }
    }

    /// Integer WAV and AIFF cannot hold a peak above 0 dBFS, so those files are written as 32-bit float.
    public static func writtenDepth(
        chosen: TrimmerExportDepth,
        container: TrimmerExportContainer,
        peak: Float
    ) -> (depth: TrimmerExportDepth, steeredToFloat: Bool) {
        switch container {
        case .wav, .aiff:
            if peak > 1, chosen != .float32 {
                return (.float32, true)
            }
            return (chosen, false)
        case .m4a, .mp3:
            return (chosen, false)
        }
    }

    /// Left channel of an interleaved stereo block. Mono sources were copied to both sides.
    public static func leftChannel(_ stereo: [Float]) -> [Float] {
        var mono: [Float] = []
        mono.reserveCapacity(stereo.count / 2)
        var index = 0
        while index < stereo.count {
            mono.append(stereo[index])
            index += 2
        }
        return mono
    }
}

public enum TrimmerExportContainer: String, CaseIterable, Equatable, Sendable {
    case wav
    case aiff
    case m4a
    case mp3

    public var title: String {
        switch self {
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .m4a: "M4A"
        case .mp3: "MP3"
        }
    }

    public var fileExtension: String { rawValue }

    public var usesBitDepth: Bool { self == .wav || self == .aiff }

    public var usesBitrate: Bool { self == .mp3 }

    public var isLossy: Bool { self == .mp3 || self == .m4a }
}

public enum TrimmerExportDepth: String, CaseIterable, Equatable, Sendable {
    case int16
    case int24
    case float32

    public var title: String {
        switch self {
        case .int16: "16-bit"
        case .int24: "24-bit"
        case .float32: "32-bit float"
        }
    }
}

/// Format, bit depth, and MP3 bitrate remembered for this Lounge session.
public struct TrimmerExportChoices: Equatable, Sendable {
    public var container: TrimmerExportContainer
    public var bitDepth: TrimmerExportDepth
    public var mp3BitrateKbps: Int
    /// Until the user picks a bitrate, mono uses 128 kbps and stereo uses 192.
    public var bitrateFollowsWidth: Bool

    public static let mp3Bitrates = [96, 128, 160, 192]

    public static let standard = TrimmerExportChoices(
        container: .wav,
        bitDepth: .int24,
        mp3BitrateKbps: 192,
        bitrateFollowsWidth: true
    )

    public init(
        container: TrimmerExportContainer,
        bitDepth: TrimmerExportDepth,
        mp3BitrateKbps: Int,
        bitrateFollowsWidth: Bool = true
    ) {
        self.container = container
        self.bitDepth = bitDepth
        self.mp3BitrateKbps = Self.normalizedBitrate(mp3BitrateKbps)
        self.bitrateFollowsWidth = bitrateFollowsWidth
    }

    public static func normalizedBitrate(_ value: Int) -> Int {
        mp3Bitrates.contains(value) ? value : 192
    }
}

/// The name field on TheCut's export sheet.
/// A name the user typed stays when the mix choice changes.
/// Changing the file type changes only the extension.
/// An empty field is not a custom name, so the next choice fills the default again.
public struct TrimmerExportDraft: Equatable, Sendable {
    public var scope: TrimmerExportScope
    public var field: String
    public var customized: Bool
    public var choices: TrimmerExportChoices

    public init(
        scope: TrimmerExportScope,
        field: String,
        customized: Bool,
        choices: TrimmerExportChoices = .standard
    ) {
        self.scope = scope
        self.field = field
        self.customized = customized
        self.choices = choices
    }
}

public enum TrimmerExportNaming {
    /// The sheet opens on Full Mix, with that choice's default name and extension filled in.
    public static func opened(
        episode: String,
        choices: TrimmerExportChoices = .standard,
        mono: Bool = false,
        mp3Available: Bool = true
    ) -> TrimmerExportDraft {
        var choices = choices
        if choices.container == .mp3, mp3Available == false {
            choices.container = .wav
        }
        if choices.bitrateFollowsWidth {
            choices.mp3BitrateKbps = mono ? 128 : 192
        }
        return TrimmerExportDraft(
            scope: .fullMix,
            field: fileName(episode: episode, scope: .fullMix, container: choices.container),
            customized: false,
            choices: choices
        )
    }

    /// Changing the mix refreshes the field unless the user has typed their own name.
    public static func choosing(
        _ scope: TrimmerExportScope,
        in draft: TrimmerExportDraft,
        episode: String,
        mono: Bool = false
    ) -> TrimmerExportDraft {
        var next = draft
        next.scope = scope
        if next.choices.bitrateFollowsWidth {
            next.choices.mp3BitrateKbps = mono ? 128 : 192
        }
        if draft.customized == false {
            next.field = fileName(episode: episode, scope: scope, container: next.choices.container)
        }
        return next
    }

    /// Changing the file type keeps a typed name and swaps only the extension.
    public static func choosingContainer(
        _ container: TrimmerExportContainer,
        in draft: TrimmerExportDraft,
        episode: String
    ) -> TrimmerExportDraft {
        var next = draft
        next.choices.container = container
        if draft.customized == false {
            next.field = fileName(episode: episode, scope: draft.scope, container: container)
        } else {
            next.field = replacingExtension(in: draft.field, with: container.fileExtension)
        }
        return next
    }

    public static func choosingDepth(
        _ depth: TrimmerExportDepth,
        in draft: TrimmerExportDraft
    ) -> TrimmerExportDraft {
        var next = draft
        next.choices.bitDepth = depth
        return next
    }

    public static func choosingBitrate(
        _ kbps: Int,
        in draft: TrimmerExportDraft
    ) -> TrimmerExportDraft {
        var next = draft
        next.choices.mp3BitrateKbps = TrimmerExportChoices.normalizedBitrate(kbps)
        next.choices.bitrateFollowsWidth = false
        return next
    }

    /// Typing in the field. The current default, or only whitespace, is not a custom name.
    public static func editing(
        _ text: String,
        in draft: TrimmerExportDraft,
        episode: String
    ) -> TrimmerExportDraft {
        var next = draft
        next.field = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let standard = fileName(episode: episode, scope: draft.scope, container: draft.choices.container)
        next.customized = trimmed.isEmpty == false && trimmed != standard
        return next
    }

    /// The list name handed to TheValet. Whitespace falls back to the default for the choice.
    /// TheValet keeps this as the display name, aside from `/`, `\`, and control characters,
    /// and it turns characters a file name cannot hold into spaces in the stored file.
    public static func resolvedDisplayName(
        field: String,
        episode: String,
        scope: TrimmerExportScope,
        container: TrimmerExportContainer = .wav
    ) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fileName(episode: episode, scope: scope, container: container)
        }
        return trimmed
    }

    public static func fileName(
        episode: String,
        scope: TrimmerExportScope,
        container: TrimmerExportContainer
    ) -> String {
        "\(TrimmerExportPlan.displayName(episode: episode, scope: scope)).\(container.fileExtension)"
    }

    /// Swaps a trailing audio extension, or adds one. The rest of the name stays.
    public static func replacingExtension(in field: String, with ext: String) -> String {
        let known = ["wav", "aiff", "aif", "m4a", "mp3"]
        var trailing = ""
        var head = field
        while let last = head.last, last.isWhitespace {
            trailing.insert(last, at: trailing.startIndex)
            head.removeLast()
        }
        let lower = head.lowercased()
        for token in known {
            let suffix = ".\(token)"
            if lower.hasSuffix(suffix) {
                let stem = String(head.dropLast(suffix.count))
                return stem + ".\(ext)" + trailing
            }
        }
        if head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return field
        }
        return head + ".\(ext)" + trailing
    }
}
