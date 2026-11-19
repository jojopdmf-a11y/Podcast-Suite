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
