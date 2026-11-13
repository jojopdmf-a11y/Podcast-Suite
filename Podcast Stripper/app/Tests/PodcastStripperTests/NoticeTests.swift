import Foundation
import Testing

struct SpeakerModelNoticeTests {
    @Test func noticeCreditsTheBundledModelAndDoesNotShipAToken() throws {
        let notice = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NOTICE")
        let text = try String(contentsOf: notice, encoding: .utf8)
        #expect(text.contains("pyannote/speaker-diarization-community-1"))
        #expect(text.contains("CC-BY-4.0"))
        #expect(text.contains("Hervé Bredin"))
        #expect(text.contains("Alexis Plaquet"))
        #expect(text.contains("shipped in the app"))
        #expect(!text.contains("hf_"))
    }
}
