import Foundation

struct EnginePaths {
    let repoRoot: URL
    let engineDir: URL
    let uvBinary: URL
    let runnerScript: URL

    static func resolve() throws -> EnginePaths {
        let fileManager = FileManager.default
        var searchRoots: [URL] = []

        if let env = ProcessInfo.processInfo.environment["PODCAST_STRIPPER_ROOT"] {
            searchRoots.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        searchRoots.append(contentsOf: walkParents(from: Bundle.main.bundleURL))
        searchRoots.append(contentsOf: walkParents(from: URL(fileURLWithPath: CommandLine.arguments[0])))
        searchRoots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))

        for root in searchRoots {
            let engine = root.appendingPathComponent("engine", isDirectory: true)
            let pyproject = engine.appendingPathComponent("pyproject.toml")
            if fileManager.fileExists(atPath: pyproject.path) {
                let uv = try findUv(repoRoot: root)
                let runner = root.appendingPathComponent("scripts/run_engine.sh")
                return EnginePaths(repoRoot: root, engineDir: engine, uvBinary: uv, runnerScript: runner)
            }
        }
        throw EngineError.engineNotFound
    }

    static func findUv(repoRoot: URL) throws -> URL {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            repoRoot.appendingPathComponent("tools/uv"),
            repoRoot.appendingPathComponent("tools/uv-venv/bin/uv"),
            home.appendingPathComponent(".local/bin/uv"),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            URL(fileURLWithPath: "/usr/local/bin/uv"),
        ]
        for url in candidates where fileManager.isExecutableFile(atPath: url.path) {
            return url
        }
        if let which = which("uv") {
            return which
        }
        throw EngineError.uvMissing
    }

    private static func which(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func walkParents(from url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        for _ in 0 ..< 10 {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return result
    }
}

enum SpeakerCountChoice: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case two = "2"
    case three = "3"
    case four = "4"
    case five = "5"

    var id: String { rawValue }

    var argumentValue: Int? {
        switch self {
        case .auto: return nil
        case .two: return 2
        case .three: return 3
        case .four: return 4
        case .five: return 5
        }
    }
}

struct EngineSetup: Equatable {
    var ffmpegOK = false
    var tokenOK = false
    var ffmpegPath: String?
    var message: String = "Checking setup…"
}

struct EngineResult {
    var outputDir: URL
    var tracks: [URL]
}

enum EngineError: LocalizedError {
    case engineNotFound
    case uvMissing
    case startFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .engineNotFound:
            return "Could not find the engine folder. Keep Podcast Stripper.app inside the Podcast Stripper project folder."
        case .uvMissing:
            return "Python tooling (uv) is not installed yet. Run scripts/setup.sh from the project folder, then try again."
        case .startFailed(let message), .failed(let message):
            return message
        }
    }
}

@MainActor
final class EngineRunner: ObservableObject {
    @Published var setup = EngineSetup()
    @Published var isRunning = false
    @Published var percent: Double = 0
    @Published var message = "Drop a podcast file to start."
    @Published var errorMessage: String?
    @Published var result: EngineResult?

    private var process: Process?
    private var lineBuffer = ""

    func refreshSetup() {
        Task {
            do {
                let paths = try EnginePaths.resolve()
                let output = try await runTool(
                    paths: paths,
                    arguments: ["--check-setup", "--json-progress"]
                )
                if let line = output.split(separator: "\n").last,
                   let data = String(line).data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    let ffmpegOK = json["ffmpeg_ok"] as? Bool ?? false
                    let tokenOK = json["token_ok"] as? Bool ?? false
                    setup = EngineSetup(
                        ffmpegOK: ffmpegOK,
                        tokenOK: tokenOK,
                        ffmpegPath: json["ffmpeg"] as? String,
                        message: summary(ffmpegOK: ffmpegOK, tokenOK: tokenOK)
                    )
                }
            } catch {
                setup = EngineSetup(message: error.localizedDescription)
            }
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        isRunning = false
        message = "Cancelled."
    }

    func split(input: URL, outputDir: URL, speakerCount: SpeakerCountChoice) {
        errorMessage = nil
        result = nil
        isRunning = true
        percent = 1
        lineBuffer = ""
        message = "Starting…"

        Task {
            do {
                let paths = try EnginePaths.resolve()
                outputDir.createDirectoryIfNeeded()
                var arguments = [
                    input.path,
                    "-o",
                    outputDir.path,
                    "--json-progress",
                ]
                if let count = speakerCount.argumentValue {
                    arguments += ["--num-speakers", String(count)]
                }
                let output = try await runTool(paths: paths, arguments: arguments, streaming: true)
                if let done = lastEvent(from: output, named: "done"),
                   let dir = done["output_dir"] as? String
                {
                    let tracks = (done["tracks"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
                    result = EngineResult(outputDir: URL(fileURLWithPath: dir), tracks: tracks)
                    percent = 100
                    let speakerCount = (done["speakers"] as? [Any])?.count ?? tracks.count
                    if done["music"] != nil {
                        message = "Saved \(speakerCount) speaker track\(speakerCount == 1 ? "" : "s") and a music/SFX track."
                    } else {
                        message = "Saved \(tracks.count) speaker track\(tracks.count == 1 ? "" : "s")."
                    }
                } else if let failed = lastEvent(from: output, named: "error") {
                    throw EngineError.failed(failed["message"] as? String ?? "Something went wrong.")
                }
            } catch {
                errorMessage = error.localizedDescription
                message = "Could not split this file."
            }
            isRunning = false
            process = nil
        }
    }

    private func summary(ffmpegOK: Bool, tokenOK: Bool) -> String {
        switch (ffmpegOK, tokenOK) {
        case (true, true):
            return "Ready. Drop in a podcast file."
        case (true, false):
            return "Add your Hugging Face token in Settings before splitting."
        case (false, true):
            return "ffmpeg is missing. Run scripts/setup.sh, or brew install ffmpeg."
        case (false, false):
            return "Finish setup: install tools, then add your Hugging Face token in Settings."
        }
    }

    private func lastEvent(from output: String, named event: String) -> [String: Any]? {
        let lines = output.split(separator: "\n").reversed()
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["event"] as? String == event
            else { continue }
            return json
        }
        return nil
    }

    private func runTool(paths: EnginePaths, arguments: [String], streaming: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = paths.uvBinary
            process.arguments = ["run", "--project", paths.engineDir.path, "podcast-stripper"] + arguments
            process.currentDirectoryURL = paths.repoRoot
            var environment = ProcessInfo.processInfo.environment
            let extraPath = [
                paths.uvBinary.deletingLastPathComponent().path,
                paths.repoRoot.appendingPathComponent("tools").path,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            ]
            environment["PATH"] = extraPath.joined(separator: ":") + ":" + (environment["PATH"] ?? "")
            environment["PYANNOTE_METRICS_ENABLED"] = "0"
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let gathered = OutputCollector()
            let resume = OnceResume(continuation)

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                gathered.append(chunk)
                if streaming, let text = String(data: chunk, encoding: .utf8) {
                    Task { @MainActor in
                        self.consumeProgress(text)
                    }
                }
            }

            process.terminationHandler = { finished in
                stdout.fileHandleForReading.readabilityHandler = nil
                gathered.append(stdout.fileHandleForReading.readDataToEndOfFile())
                let output = gathered.stringValue()
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    resume.resume(returning: output)
                } else if let failed = EngineRunner.parseErrorMessage(from: output) {
                    resume.resume(throwing: EngineError.failed(failed))
                } else {
                    let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    resume.resume(throwing: EngineError.failed(detail.isEmpty ? "The engine quit unexpectedly." : detail))
                }
            }

            self.process = process
            do {
                try process.run()
            } catch {
                resume.resume(throwing: EngineError.startFailed(error.localizedDescription))
            }
        }
    }

    nonisolated private static func parseErrorMessage(from output: String) -> String? {
        let lines = output.split(separator: "\n").reversed()
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["event"] as? String == "error"
            else { continue }
            return json["message"] as? String
        }
        return nil
    }

    private func consumeProgress(_ text: String) {
        lineBuffer += text
        while let range = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<range.lowerBound])
            lineBuffer = String(lineBuffer[range.upperBound...])
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["event"] as? String == "status"
            else { continue }
            if let value = json["percent"] as? Double {
                percent = value
            } else if let value = json["percent"] as? Int {
                percent = Double(value)
            }
            if let message = json["message"] as? String {
                self.message = message
            }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func stringValue() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}

private extension URL {
    func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    }
}
