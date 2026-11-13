import CryptoKit
import Foundation

/// Decides whether a packaged app can keep the shared Application Support venv.
///
/// `uv.lock` does not change when only the Python sources change, and the
/// package version can stay at 0.1.0. The source stamp hashes those file
/// bytes. Matching bytes stay ready. Edited sources do not, even when the
/// file dates are unchanged.
enum EngineSourceStamp {
    static let stampFileName = "engine-source.stamp"
    /// Distribution name in `pyproject.toml`. Reinstalled in place; dependencies stay.
    static let packageName = "podcast-stripper"

    static func syncArguments(project: String) -> [String] {
        [
            "sync",
            "--project", project,
            "--frozen",
            "--no-dev",
            "--no-editable",
            "--reinstall-package", packageName,
        ]
    }

    /// `v1:` plus a SHA-256 of `pyproject.toml` and the `podcast_stripper` sources.
    /// Nil when those files cannot be read.
    static func fingerprint(engineDir: URL) -> String? {
        let fileManager = FileManager.default
        let packageDir = engineDir.appendingPathComponent("podcast_stripper", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: packageDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        var entries: [(name: String, url: URL)] = []
        guard let enumerator = fileManager.enumerator(
            at: packageDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let url as URL in enumerator {
            let relative = relativePath(base: packageDir, file: url)
            if relative.split(separator: "/").contains("__pycache__") || relative.hasSuffix(".pyc") {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            entries.append(("podcast_stripper/" + relative, url))
        }

        let pyproject = engineDir.appendingPathComponent("pyproject.toml")
        if fileManager.fileExists(atPath: pyproject.path) {
            entries.append(("pyproject.toml", pyproject))
        }
        guard !entries.isEmpty else { return nil }
        entries.sort { $0.name < $1.name }

        var hasher = SHA256()
        for entry in entries {
            guard let bytes = try? Data(contentsOf: entry.url) else { return nil }
            hasher.update(data: Data(entry.name.utf8))
            hasher.update(data: Data([0]))
            var count = UInt64(bytes.count).bigEndian
            let countData = withUnsafeBytes(of: &count) { Data($0) }
            hasher.update(data: countData)
            hasher.update(data: bytes)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "v1:" + hex
    }

    static func isReady(venvPython: URL, engineDir: URL, support: URL) -> Bool {
        let fileManager = FileManager.default
        let lockBundled = engineDir.appendingPathComponent("uv.lock")
        let lockStamp = support.appendingPathComponent("uv.lock")
        guard fileManager.isExecutableFile(atPath: venvPython.path),
              fileManager.fileExists(atPath: lockStamp.path),
              fileManager.fileExists(atPath: lockBundled.path),
              let stampedLock = try? Data(contentsOf: lockStamp),
              let bundledLock = try? Data(contentsOf: lockBundled),
              stampedLock == bundledLock
        else { return false }
        guard let expected = fingerprint(engineDir: engineDir) else { return false }
        let sourceStamp = support.appendingPathComponent(stampFileName)
        guard let stored = try? String(contentsOf: sourceStamp, encoding: .utf8) else { return false }
        return stored == expected
    }

    /// Copies the bundled lockfile and writes the source hash next to the shared venv.
    static func write(engineDir: URL, support: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        let lockBundled = engineDir.appendingPathComponent("uv.lock")
        let lockStamp = support.appendingPathComponent("uv.lock")
        if fileManager.fileExists(atPath: lockBundled.path) {
            if fileManager.fileExists(atPath: lockStamp.path) {
                try fileManager.removeItem(at: lockStamp)
            }
            try fileManager.copyItem(at: lockBundled, to: lockStamp)
        }
        guard let fingerprint = fingerprint(engineDir: engineDir) else {
            throw EngineError.failed("Could not read the bundled engine.")
        }
        try Data(fingerprint.utf8).write(to: support.appendingPathComponent(stampFileName), options: .atomic)
    }

    private static func relativePath(base: URL, file: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return file.lastPathComponent
    }
}
