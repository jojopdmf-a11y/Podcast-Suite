import Foundation

/// The four Lounge cards. Order is layout only — there is no signal chain.
public enum WorkspaceID: String, CaseIterable, Identifiable, Codable, Sendable {
    case stripper
    case fixer
    case trimmer
    case limiter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stripper: "Stripper"
        case .fixer: "Fixer"
        case .trimmer: "Trimmer"
        case .limiter: "Limiter"
        }
    }

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
            "Stripper splits the selected depot file into speaker tracks and a music track."
        case .fixer:
            "Fixer records and mixes with PodProducer. While a take is recording, stay here until Stop."
        case .trimmer:
            "Trimmer is a new tool for cuts, intros, and commercials. There is no Trimmer app and no engine in this build."
        case .limiter:
            "Limiter will set final loudness and peak. This workspace is not connected to PodLeveler, and it does not measure or limit audio."
        }
    }
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
