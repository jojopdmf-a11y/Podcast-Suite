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

/// The name field on TheCut's export sheet.
/// A name the user typed stays when the choice changes.
/// An empty field is not a custom name, so the next choice fills the default again.
public struct TrimmerExportDraft: Equatable, Sendable {
    public var scope: TrimmerExportScope
    public var field: String
    public var customized: Bool

    public init(scope: TrimmerExportScope, field: String, customized: Bool) {
        self.scope = scope
        self.field = field
        self.customized = customized
    }
}

public enum TrimmerExportNaming {
    /// The sheet opens on Full Mix, with that choice's default name filled in.
    public static func opened(episode: String) -> TrimmerExportDraft {
        TrimmerExportDraft(
            scope: .fullMix,
            field: TrimmerExportPlan.displayName(episode: episode, scope: .fullMix),
            customized: false
        )
    }

    /// Changing the choice refreshes the field unless the user has typed their own name.
    public static func choosing(
        _ scope: TrimmerExportScope,
        in draft: TrimmerExportDraft,
        episode: String
    ) -> TrimmerExportDraft {
        var next = draft
        next.scope = scope
        if draft.customized == false {
            next.field = TrimmerExportPlan.displayName(episode: episode, scope: scope)
        }
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
        let standard = TrimmerExportPlan.displayName(episode: episode, scope: draft.scope)
        next.customized = trimmed.isEmpty == false && trimmed != standard
        return next
    }

    /// The list name handed to TheValet. Whitespace falls back to the default for the choice.
    /// TheValet keeps this as the display name, aside from `/`, `\`, and control characters,
    /// and it turns characters a file name cannot hold into spaces in the stored file.
    public static func resolvedDisplayName(
        field: String,
        episode: String,
        scope: TrimmerExportScope
    ) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return TrimmerExportPlan.displayName(episode: episode, scope: scope)
        }
        return trimmed
    }
}
