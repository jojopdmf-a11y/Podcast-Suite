import Testing
@testable import LilLevelerKit

@Test func leveledResultNameStripsExistingSuffix() {
    #expect(
        LevelerResultName.suggested(sourceName: "X", presetTitle: "APPLE PODCASTS")
            == "X – Leveled (APPLE PODCASTS)"
    )
    #expect(
        LevelerResultName.suggested(
            sourceName: "X – Leveled (APPLE PODCASTS)",
            presetTitle: "APPLE PODCASTS"
        ) == "X – Leveled (APPLE PODCASTS)"
    )
    #expect(
        LevelerResultName.suggested(
            sourceName: "X – Leveled (APPLE PODCASTS)",
            presetTitle: "SPOTIFY"
        ) == "X – Leveled (SPOTIFY)"
    )
    #expect(
        LevelerResultName.suggested(
            sourceName: "X – Leveled (APPLE PODCASTS) – Leveled (APPLE PODCASTS)",
            presetTitle: "YOUTUBE"
        ) == "X – Leveled (YOUTUBE)"
    )
    #expect(
        LevelerResultName.suggested(sourceName: "Episode.wav", presetTitle: "UNIVERSAL")
            == "Episode – Leveled (UNIVERSAL)"
    )
    #expect(
        LevelerResultName.suggested(
            sourceName: "Episode – Leveled (SPOTIFY).m4a",
            presetTitle: "APPLE PODCASTS"
        ) == "Episode – Leveled (APPLE PODCASTS)"
    )
    #expect(
        LevelerResultName.suggested(
            sourceName: "Song – Leveled (My (alt) mix).aiff",
            presetTitle: "AMAZON MUSIC"
        ) == "Song – Leveled (AMAZON MUSIC)"
    )
    #expect(
        LevelerResultName.suggested(sourceName: "   ", presetTitle: "CUSTOM")
            == "Audio – Leveled (CUSTOM)"
    )
    #expect(
        LevelerResultName.suggested(
            sourceName: "My – Leveled (draft) notes.wav",
            presetTitle: "MONO PODCAST"
        ) == "My – Leveled (draft) notes – Leveled (MONO PODCAST)"
    )
}

@Test func theRoofAboutNamesClubPod() {
    #expect(CougarCalcBrand.suiteName == "ClubPod")
}
