import AudioToolbox
import Foundation

/// Header duration from AudioToolbox. Returns nil when the file is missing or not audio.
enum AudioDuration {
    static func label(for url: URL?) -> String {
        guard let url, let seconds = seconds(for: url), seconds.isFinite, seconds > 0 else {
            return "—"
        }
        let total = Int(seconds.rounded(.down))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func seconds(for url: URL) -> Double? {
        var file: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &file)
        guard status == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var duration: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let property = AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)
        guard property == noErr, duration.isFinite, duration > 0 else { return nil }
        return duration
    }
}
