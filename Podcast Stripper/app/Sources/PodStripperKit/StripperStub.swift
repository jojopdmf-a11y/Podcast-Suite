import AVFoundation
import Darwin
import Foundation

enum StripperUITest {
    static var enabled: Bool {
        CommandLine.arguments.contains("-UITestMode")
    }

    static var stubbed: Bool {
        enabled && CommandLine.arguments.contains("-UITestStripperStub")
    }

    static var pauseFirstJob: Bool {
        enabled && CommandLine.arguments.contains("-UITestStripperPause")
    }

    static func argument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        guard value.isEmpty == false, value.hasPrefix("-") == false else { return nil }
        return value
    }
}

/// Writes speaker files without Python, torch, or a model download.
enum StripperStubJob {
    static func write(
        input: URL,
        outputDir: URL,
        audioFormat: ExportAudioFormatChoice
    ) throws -> (tracks: [URL], speakersJSON: URL) {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let ext = audioFormat == .aiff24 ? "aiff" : "wav"
        let names = ["Speaker_1.\(ext)", "Speaker_2.\(ext)", "Music_and_SFX.\(ext)"]
        let probed = try? AVAudioFile(forReading: input)
        let duration = probed.map { file in
            file.fileFormat.sampleRate > 0 ? Double(file.length) / file.fileFormat.sampleRate : 0
        } ?? 0
        let sampleRate = probed?.fileFormat.sampleRate ?? 48_000
        var tracks: [URL] = []
        for name in names {
            let url = outputDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            try fm.copyItem(at: input, to: url)
            tracks.append(url)
        }
        let speakers: [[String: Any]] = [
            [
                "id": "SPEAKER_00",
                "label": "Speaker 1",
                "path": tracks[0].path,
                "turns": [["start": 0.0, "end": min(1.0, duration)]],
            ],
            [
                "id": "SPEAKER_01",
                "label": "Speaker 2",
                "path": tracks[1].path,
                "turns": [["start": 0.0, "end": min(1.0, duration)]],
            ],
        ]
        let payload: [String: Any] = [
            "source": input.path,
            "duration": duration,
            "sample_rate": sampleRate,
            "native_sample_rate": sampleRate,
            "audio_format": audioFormat.cliValue,
            "speakers": speakers,
            "music": [
                "id": "music_and_sfx",
                "label": "Music and SFX",
                "path": tracks[2].path,
            ],
        ]
        let jsonURL = outputDir.appendingPathComponent("speakers.json")
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: jsonURL, options: .atomic)
        return (tracks, jsonURL)
    }

}

/// Blocks a second app from installing or updating the shared engine folder.
final class StripperSetupLock: @unchecked Sendable {
    private var fd: Int32 = -1

    static func acquire() async throws -> StripperSetupLock {
        let directory = EnginePaths.applicationSupportDir()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(".setup.lock")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
                guard fd >= 0 else {
                    continuation.resume(throwing: EngineError.failed("Could not lock the shared engine setup."))
                    return
                }
                if flock(fd, LOCK_EX) != 0 {
                    close(fd)
                    continuation.resume(throwing: EngineError.failed("Could not lock the shared engine setup."))
                    return
                }
                let lock = StripperSetupLock()
                lock.fd = fd
                continuation.resume(returning: lock)
            }
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
