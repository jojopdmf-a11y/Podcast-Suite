import Foundation

struct UserLoudnessPreset: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var targetLUFS: Float
    var truePeakDbTP: Float

    var asPlatformPreset: PlatformPreset {
        PlatformPreset(
            id: id,
            title: title,
            subtitle: String(format: "%.1f LUFS · %.1f dBTP", targetLUFS, truePeakDbTP),
            targetLUFS: targetLUFS,
            truePeakDbTP: truePeakDbTP
        )
    }

    static func isUserID(_ id: String) -> Bool {
        id.hasPrefix("user-")
    }
}

enum UserLoudnessPresetStore {
    private struct File: Codable {
        var formatVersion: Int
        var presets: [UserLoudnessPreset]
    }

    static func load() -> [UserLoudnessPreset] {
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.presets
    }

    static func save(_ presets: [UserLoudnessPreset]) throws {
        let url = try fileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(formatVersion: 1, presets: presets))
        try data.write(to: url, options: [.atomic])
    }

    static func fileURL() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("CougarCalc/LilLeveler", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("user-presets.json")
    }
}
