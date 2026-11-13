import Testing
@testable import PodLoungeCore

@Test func clubPodNamesKeepLoungeAsTheHub() {
    #expect(ClubPodNaming.product == "ClubPod")
    #expect(ClubPodNaming.hubScreenTitle == "Lounge")
    #expect(ClubPodNaming.hubScreenTitle != ClubPodNaming.product)

    #expect(WorkspaceID.stripper.title == "TheStrip")
    #expect(WorkspaceID.fixer.title == "TheDecks")
    #expect(WorkspaceID.trimmer.title == "TheCut")
    #expect(WorkspaceID.limiter.title == "TheRoof")

    for workspace in WorkspaceID.allCases {
        let label = ClubPodNaming.roomLabel(for: workspace)
        #expect(label.quiet == "The")
        #expect(label.joined == label.quiet + label.name)
        #expect(label.joined.contains(" ") == false)
        #expect(workspace.title == label.joined)
        #expect(workspace.title != ClubPodNaming.product)
        #expect(workspace.title != ClubPodNaming.hubScreenTitle)
    }
}
