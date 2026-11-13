import Foundation

/// The four Lounge cards. Order is layout only — there is no signal chain.
public enum WorkspaceID: String, CaseIterable, Identifiable, Codable, Sendable {
    case stripper
    case fixer
    case trimmer
    case limiter

    public var id: String { rawValue }

    /// Visible room title. No space after The: TheStrip, TheDecks, TheCut, TheRoof.
    public var title: String { ClubPodNaming.roomLabel(for: self).joined }

    public var subtitle: String {
        switch self {
        case .stripper: "Separate speakers & music"
        case .fixer: "Record & mix the show"
        case .trimmer: "Cuts, intros & commercials"
        case .limiter: "Final loudness & peak"
        }
    }

    /// Trimmer has no product screenshot. The card must say it is a concept.
    public var conceptOnly: Bool { self == .trimmer }

    public var screenshotResourceName: String? {
        switch self {
        case .stripper: "stripper-card"
        case .fixer: "fixer-card"
        case .trimmer: nil
        case .limiter: "limiter-card"
        }
    }

    public var scaffoldMessage: String {
        switch self {
        case .stripper:
            "TheStrip splits the selected depot file into speaker tracks and a music track."
        case .fixer:
            "TheDecks records and mixes. While a take is recording, stay here until Stop."
        case .trimmer:
            "TheCut is a new tool for cuts, intros, and commercials. There is no TheCut app and no engine in this build."
        case .limiter:
            "TheRoof sets final loudness and peak on the selected depot file."
        }
    }
}

/// ClubPod is the suite. Lounge is the hub screen, not another name for ClubPod.
public enum ClubPodNaming {
    public static let product = "ClubPod"
    /// Title of the hub screen. This is not the product name.
    public static let hubScreenTitle = "Lounge"

    public struct RoomLabel: Equatable, Sendable {
        public var quiet: String
        public var name: String
        public var joined: String { quiet + name }

        public init(quiet: String, name: String) {
            self.quiet = quiet
            self.name = name
        }
    }

    public static func roomLabel(for workspace: WorkspaceID) -> RoomLabel {
        let name: String
        switch workspace {
        case .stripper: name = "Strip"
        case .fixer: name = "Decks"
        case .trimmer: name = "Cut"
        case .limiter: name = "Roof"
        }
        return RoomLabel(quiet: "The", name: name)
    }
}

/// Which edge of a room the project depot uses.
public enum DepotSide: String, Equatable, Sendable {
    case leading
    case trailing
}

extension WorkspaceID {
    /// The depot sits on the right in every room, including TheStrip.
    public var depotSide: DepotSide { .trailing }
}

public enum AssetKind: String, Codable, Sendable {
    case original
    case result

    public var depotDirectory: String {
        switch self {
        case .original: "depot/originals"
        case .result: "depot/results"
        }
    }

    public var label: String {
        switch self {
        case .original: "Original"
        case .result: "Result"
        }
    }
}
