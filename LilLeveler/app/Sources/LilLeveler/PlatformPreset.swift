import Foundation

enum LevelerError: LocalizedError {
    case loadFailed(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let m), .processFailed(let m): return m
        }
    }
}

/// Destination loudness / true-peak targets for common podcast platforms.
struct PlatformPreset: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    var targetLUFS: Float
    var truePeakDbTP: Float
    var isCustom: Bool = false

    static let universal = PlatformPreset(
        id: "universal",
        title: "UNIVERSAL",
        subtitle: "−16 LUFS · safe single master",
        targetLUFS: -16,
        truePeakDbTP: -1
    )
    static let apple = PlatformPreset(
        id: "apple",
        title: "APPLE PODCASTS",
        subtitle: "−16 LUFS · −1 dBTP",
        targetLUFS: -16,
        truePeakDbTP: -1
    )
    static let spotify = PlatformPreset(
        id: "spotify",
        title: "SPOTIFY",
        subtitle: "−14 LUFS · −1 dBTP",
        targetLUFS: -14,
        truePeakDbTP: -1
    )
    static let youtube = PlatformPreset(
        id: "youtube",
        title: "YOUTUBE",
        subtitle: "−14 LUFS · −1 dBTP",
        targetLUFS: -14,
        truePeakDbTP: -1
    )
    static let amazon = PlatformPreset(
        id: "amazon",
        title: "AMAZON MUSIC",
        subtitle: "−14 LUFS · −2 dBTP",
        targetLUFS: -14,
        truePeakDbTP: -2
    )
    static let mono = PlatformPreset(
        id: "mono",
        title: "MONO PODCAST",
        subtitle: "−19 LUFS · matches stereo −16",
        targetLUFS: -19,
        truePeakDbTP: -1
    )
    static let custom = PlatformPreset(
        id: "custom",
        title: "CUSTOM",
        subtitle: "Dial your own target",
        targetLUFS: -16,
        truePeakDbTP: -1,
        isCustom: true
    )

    static let all: [PlatformPreset] = [
        .universal, .apple, .spotify, .youtube, .amazon, .mono, .custom
    ]
}

struct LoudnessReport: Equatable {
    var integratedLUFS: Float
    var shortTermLUFS: Float
    /// Approximate momentary (400 ms) loudness.
    var momentaryLUFS: Float
    var truePeakDbTP: Float
    var samplePeakDbFS: Float
    var durationSec: Double
    var channelCount: Int
    var sampleRate: Double

    static let empty = LoudnessReport(
        integratedLUFS: -70,
        shortTermLUFS: -70,
        momentaryLUFS: -70,
        truePeakDbTP: -120,
        samplePeakDbFS: -120,
        durationSec: 0,
        channelCount: 0,
        sampleRate: 0
    )
}
