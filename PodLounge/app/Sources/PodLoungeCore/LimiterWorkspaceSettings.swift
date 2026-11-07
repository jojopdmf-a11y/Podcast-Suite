import Foundation

/// Limiter controls stored in `workspaces/limiter.json`.
/// Missing keys keep their defaults so an old project still opens.
public struct LimiterWorkspaceSettings: Codable, Equatable, Sendable {
    public var presetID: String
    public var customLUFS: Float
    public var customTruePeak: Float
    public var musicThresholdDb: Float
    public var meterMode: String
    public var peakHold: Bool
    public var listenPost: Bool
    public var container: String
    public var bitDepth: String
    public var sampleRate: Double?
    public var resultName: String
    public var resultNameFollowsSource: Bool

    public static let defaults = LimiterWorkspaceSettings(
        presetID: "universal",
        customLUFS: -16,
        customTruePeak: -1,
        musicThresholdDb: -0.1,
        meterMode: "TRUE PEAK",
        peakHold: true,
        listenPost: false,
        container: "wav",
        bitDepth: "24",
        sampleRate: nil,
        resultName: "",
        resultNameFollowsSource: true
    )

    public init(
        presetID: String,
        customLUFS: Float,
        customTruePeak: Float,
        musicThresholdDb: Float,
        meterMode: String,
        peakHold: Bool,
        listenPost: Bool,
        container: String,
        bitDepth: String,
        sampleRate: Double?,
        resultName: String,
        resultNameFollowsSource: Bool
    ) {
        self.presetID = presetID
        self.customLUFS = customLUFS
        self.customTruePeak = customTruePeak
        self.musicThresholdDb = musicThresholdDb
        self.meterMode = meterMode
        self.peakHold = peakHold
        self.listenPost = listenPost
        self.container = container
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.resultName = resultName
        self.resultNameFollowsSource = resultNameFollowsSource
    }

    private enum CodingKeys: String, CodingKey {
        case presetID
        case customLUFS
        case customTruePeak
        case musicThresholdDb
        case meterMode
        case peakHold
        case listenPost
        case container
        case bitDepth
        case sampleRate
        case resultName
        case resultNameFollowsSource
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(presetID, forKey: .presetID)
        try container.encode(customLUFS, forKey: .customLUFS)
        try container.encode(customTruePeak, forKey: .customTruePeak)
        try container.encode(musicThresholdDb, forKey: .musicThresholdDb)
        try container.encode(meterMode, forKey: .meterMode)
        try container.encode(peakHold, forKey: .peakHold)
        try container.encode(listenPost, forKey: .listenPost)
        try container.encode(self.container, forKey: .container)
        try container.encode(bitDepth, forKey: .bitDepth)
        try container.encodeIfPresent(sampleRate, forKey: .sampleRate)
        try container.encode(resultName, forKey: .resultName)
        try container.encode(resultNameFollowsSource, forKey: .resultNameFollowsSource)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaults
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID) ?? fallback.presetID
        customLUFS = try container.decodeIfPresent(Float.self, forKey: .customLUFS) ?? fallback.customLUFS
        customTruePeak = try container.decodeIfPresent(Float.self, forKey: .customTruePeak) ?? fallback.customTruePeak
        musicThresholdDb = try container.decodeIfPresent(Float.self, forKey: .musicThresholdDb) ?? fallback.musicThresholdDb
        meterMode = try container.decodeIfPresent(String.self, forKey: .meterMode) ?? fallback.meterMode
        peakHold = try container.decodeIfPresent(Bool.self, forKey: .peakHold) ?? fallback.peakHold
        listenPost = try container.decodeIfPresent(Bool.self, forKey: .listenPost) ?? fallback.listenPost
        self.container = try container.decodeIfPresent(String.self, forKey: .container) ?? fallback.container
        bitDepth = try container.decodeIfPresent(String.self, forKey: .bitDepth) ?? fallback.bitDepth
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate)
        resultName = try container.decodeIfPresent(String.self, forKey: .resultName) ?? fallback.resultName
        resultNameFollowsSource = try container.decodeIfPresent(Bool.self, forKey: .resultNameFollowsSource) ?? fallback.resultNameFollowsSource
    }
}
