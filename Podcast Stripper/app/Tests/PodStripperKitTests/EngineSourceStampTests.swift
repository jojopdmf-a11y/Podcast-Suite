import Foundation
import Testing
@testable import PodStripperKit

@Test func sourceStampMatchesPackageBytesNotFileDates() throws {
    let fixture = try EngineStampFixture()
    defer { fixture.remove() }

    let first = EngineSourceStamp.fingerprint(engineDir: fixture.engine)
    #expect(first == EngineStampFixture.knownDigest)

    let export = fixture.engine.appendingPathComponent("podcast_stripper/export.py")
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
        ofItemAtPath: export.path
    )
    #expect(EngineSourceStamp.fingerprint(engineDir: fixture.engine) == first)

    try Data("not-the-package".utf8).write(to: fixture.engine.appendingPathComponent("podcast_stripper/__pycache__/export.pyc"))
    try Data("lock-changed".utf8).write(to: fixture.engine.appendingPathComponent("uv.lock"))
    #expect(EngineSourceStamp.fingerprint(engineDir: fixture.engine) == first)

    try Data("def downmix_to_mono():\n    return 2\n".utf8).write(to: export)
    #expect(EngineSourceStamp.fingerprint(engineDir: fixture.engine) != first)
}

@Test func syncReinstallsOnlyTheLocalPackage() {
    #expect(EngineSourceStamp.syncArguments(project: "/Engine") == [
        "sync",
        "--project", "/Engine",
        "--frozen",
        "--no-dev",
        "--no-editable",
        "--reinstall-package", "podcast-stripper",
    ])
}

@Test func bundledRuntimeNeedsLockAndSourceStamp() throws {
    let fixture = try EngineStampFixture()
    defer { fixture.remove() }
    let support = fixture.root.appendingPathComponent("support", isDirectory: true)
    let paths = fixture.bundledPaths()

    #expect(EngineRunner.runtimeIsReady(paths: paths, support: support) == false)

    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try Data(EngineStampFixture.knownDigest.utf8).write(to: support.appendingPathComponent(EngineSourceStamp.stampFileName))
    try Data("different-lock".utf8).write(to: support.appendingPathComponent("uv.lock"))
    #expect(EngineRunner.runtimeIsReady(paths: paths, support: support) == false)

    try EngineSourceStamp.write(engineDir: fixture.engine, support: support)
    #expect(EngineRunner.runtimeIsReady(paths: paths, support: support))

    let names = try FileManager.default.contentsOfDirectory(atPath: support.path).sorted()
    #expect(names == ["engine-source.stamp", "uv.lock"])
    let stamped = try String(contentsOf: support.appendingPathComponent("engine-source.stamp"), encoding: .utf8)
    #expect(stamped == EngineStampFixture.knownDigest)

    let export = fixture.engine.appendingPathComponent("podcast_stripper/export.py")
    try Data("def downmix_to_mono():\n    return 2\n".utf8).write(to: export)
    #expect(EngineRunner.runtimeIsReady(paths: paths, support: support) == false)

    try Data("def downmix_to_mono():\n    return 1\n".utf8).write(to: export)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
        ofItemAtPath: export.path
    )
    #expect(EngineRunner.runtimeIsReady(paths: paths, support: support))

    try Data("other-lock".utf8).write(to: fixture.engine.appendingPathComponent("uv.lock"))
    #expect(EngineRunner.runtimeIsReady(paths: paths, support: support) == false)
}

@Test func checkoutModeDoesNotReadTheSharedStamp() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("stripper-stamp-dev-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = EnginePaths(
        repoRoot: root,
        engineDir: root.appendingPathComponent("engine"),
        uvBinary: root.appendingPathComponent("uv"),
        runnerScript: root.appendingPathComponent("run.sh"),
        venvDir: nil,
        resourcesDir: nil,
        isBundled: false
    )
    let support = root.appendingPathComponent("support")
    #expect(EngineRunner.runtimeIsReady(paths: paths, support: support))
    #expect(FileManager.default.fileExists(atPath: support.path) == false)
}

private struct EngineStampFixture {
    static let knownDigest = "v1:473f0b9b9a30aecd8ab9bd38b600bdc573ab3b0548a6682bd94a2022cae1fc1e"

    let root: URL
    var engine: URL { root.appendingPathComponent("engine", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stripper-stamp-\(UUID().uuidString)", isDirectory: true)
        let package = engine.appendingPathComponent("podcast_stripper", isDirectory: true)
        let cache = package.appendingPathComponent("__pycache__", isDirectory: true)
        let venvBin = root.appendingPathComponent("venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: venvBin, withIntermediateDirectories: true)
        try Data("def downmix_to_mono():\n    return 1\n".utf8)
            .write(to: package.appendingPathComponent("export.py"))
        try Data().write(to: package.appendingPathComponent("__init__.py"))
        try Data("version = \"0.1.0\"\n".utf8).write(to: engine.appendingPathComponent("pyproject.toml"))
        try Data("lock-body".utf8).write(to: engine.appendingPathComponent("uv.lock"))
        try Data("ignored".utf8).write(to: cache.appendingPathComponent("export.pyc"))
        let python = venvBin.appendingPathComponent("python3")
        try Data("#!/bin/sh\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    }

    func bundledPaths() -> EnginePaths {
        EnginePaths(
            repoRoot: root,
            engineDir: engine,
            uvBinary: root.appendingPathComponent("uv"),
            runnerScript: root.appendingPathComponent("run.sh"),
            venvDir: root.appendingPathComponent("venv", isDirectory: true),
            resourcesDir: nil,
            isBundled: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
