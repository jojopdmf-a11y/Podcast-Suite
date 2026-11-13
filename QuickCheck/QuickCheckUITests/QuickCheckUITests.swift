import AppKit
import AVFoundation
import XCTest

final class QuickCheckUITests: XCTestCase {
    private struct Check: Codable {
        var name: String
        var pass: Bool
        var detail: String
    }

    private struct Counts: Equatable {
        var analyses: Int
        var levels: Int
    }

    private struct QuickConfig {
        var levelerApp: URL
        var loungeApp: URL
        var audioA: URL
        var audioB: URL
        var exportDir: URL
        var project: URL
        var presetsLeveler: URL
        var presetsLounge: URL
        var checks: URL
        var screenshots: URL
        var blocked: URL

        static func load() throws -> QuickConfig {
            let env = ProcessInfo.processInfo.environment["QUICKCHECK_CONFIG"] ?? ""
            let candidates = [env, "/tmp/podstudio-quickcheck-active.json"].filter { $0.isEmpty == false }
            for path in candidates where FileManager.default.fileExists(atPath: path) {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let object = try JSONSerialization.jsonObject(with: data)
                guard let map = object as? [String: String] else { continue }
                func url(_ key: String) throws -> URL {
                    guard let value = map[key], value.isEmpty == false else {
                        throw NSError(domain: "QuickCheck", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Missing \(key) in \(path)",
                        ])
                    }
                    return URL(fileURLWithPath: value)
                }
                return QuickConfig(
                    levelerApp: try url("levelerApp"),
                    loungeApp: try url("loungeApp"),
                    audioA: try url("audioA"),
                    audioB: try url("audioB"),
                    exportDir: try url("exportDir"),
                    project: try url("project"),
                    presetsLeveler: try url("presetsLeveler"),
                    presetsLounge: try url("presetsLounge"),
                    checks: try url("checks"),
                    screenshots: try url("screenshots"),
                    blocked: try url("blocked")
                )
            }
            throw NSError(domain: "QuickCheck", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not find the quick check config.",
            ])
        }
    }

    private var config: QuickConfig?
    private var checks: [Check] = []
    private var shots = 0
    private var sourceSeconds: Double = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    override func tearDown() {
        try? writeChecks()
        super.tearDown()
    }

    func testPodStudioQuickCheck() throws {
        // The runner can read the script's work folder, but the sandbox blocks
        // writes there. Files this process creates go in its own temp directory.
        // The apps still read and write that folder; they are not sandboxed.
        let loaded = try prepareRunnerFiles(try QuickConfig.load())
        config = loaded
        try writeSignal(to: loaded.audioA, frequency: 220, burstOffset: 0.05)
        try writeSignal(to: loaded.audioB, frequency: 330, burstOffset: 0.4)
        sourceSeconds = try decodedSeconds(loaded.audioA)
        checkLeveler(loaded)
        checkLounge(loaded)
        try writeChecks()
        let failed = checks.filter { $0.pass == false }.map(\.name)
        XCTAssertTrue(failed.isEmpty, "Failed: \(failed.joined(separator: "; "))")
    }

    // MARK: - PodLeveler

    private func checkLeveler(_ config: QuickConfig) {
        let app = XCUIApplication(url: config.levelerApp)
        app.launchArguments = [
            "-UITestMode",
            "-ApplePersistenceIgnoreState", "YES",
            "-UITestOpen", config.audioA.path,
            "-UITestExportDir", config.exportDir.path,
            "-UITestPresets", config.presetsLeveler.path,
        ]
        app.launch()
        defer { stop(app) }

        guard cameForward(app, name: "PodLeveler opened") else { return }
        guard click("leveler.chooseFile", in: app, timeout: 20) else {
            record("PodLeveler loaded the test file and showed loudness", false, "The Choose File button was not on screen.\n\(snippet(app))")
            shoot("leveler-no-choose", app)
            return
        }
        let loaded = poll(90) { resultsAreShowing(app, file: "QuickCheck-A.wav") }
        let afterLoad = statusRaw(app)
        if loaded {
            record(
                "PodLeveler loaded the test file and showed loudness",
                true,
                "POST integrated loudness read \(postLUFS(app)). \(statusText(afterLoad))"
            )
        } else {
            record(
                "PodLeveler loaded the test file and showed loudness",
                false,
                "Loudness did not finish. Status: \(statusText(afterLoad))"
            )
            shoot("leveler-no-loudness", app)
            return
        }

        exportStandalone(app, config: config, container: "wav", kind: "wav", extraClicks: ["leveler.bit.int24", "leveler.rate.48000"])
        exportStandalone(app, config: config, container: "mp3", kind: "mp3", extraClicks: ["leveler.bitrate.128", "leveler.rate.48000"])
        checkWindow(app, standalone: true, name: "PodLeveler minimum window fits a 1512 by 982 screen")
        record(
            "PodLeveler stayed open through the check",
            app.state == .runningForeground,
            app.state == .runningForeground ? "The app was still running." : "The app quit early."
        )
    }

    private func exportStandalone(
        _ app: XCUIApplication,
        config: QuickConfig,
        container: String,
        kind: String,
        extraClicks: [String]
    ) {
        let title = kind == "wav"
            ? "PodLeveler exported one 24-bit WAV at 48 kHz"
            : "PodLeveler exported one 128 kbps MP3 at 48 kHz"
        guard click("leveler.container.\(container)", in: app) else {
            record(title, false, "Could not choose \(container.uppercased()).")
            shoot("leveler-no-\(kind)", app)
            return
        }
        for identifier in extraClicks {
            guard click(identifier, in: app) else {
                record(title, false, "Could not choose \(identifier).")
                shoot("leveler-no-\(kind)", app)
                return
            }
        }
        let before = Set(files(in: config.exportDir).map(\.path))
        guard waitEnabled("leveler.export", in: app, timeout: 20), click("leveler.export", in: app, timeout: 10) else {
            record(title, false, "Export was not available. \(statusText(statusRaw(app)))")
            shoot("leveler-no-\(kind)", app)
            return
        }
        let finished = poll(120) { statusText(statusRaw(app)).contains("Exported") }
        let written = files(in: config.exportDir).filter { before.contains($0.path) == false }
        guard finished, written.count == 1 else {
            record(
                title,
                false,
                "Expected one file after export. Found \(written.map(\.lastPathComponent).joined(separator: ", ")). Status: \(statusText(statusRaw(app)))"
            )
            shoot("leveler-export-\(kind)", app)
            return
        }
        let file = written[0]
        if let problem = audioProblem(file, kind: kind) {
            record(title, false, problem)
            shoot("leveler-decode-\(kind)", app)
            return
        }
        record(title, true, "Wrote \(file.lastPathComponent) and it decodes as 48 kHz stereo.")
    }

    // MARK: - Pod Lounge

    private func checkLounge(_ config: QuickConfig) {
        let app = XCUIApplication(url: config.loungeApp)
        app.launchArguments = [
            "-UITestMode",
            "-ApplePersistenceIgnoreState", "YES",
            "-UITestProject", config.project.path,
            "-UITestImport", "\(config.audioA.path),\(config.audioB.path)",
            "-UITestPresets", config.presetsLounge.path,
            "-UITestStripperStub",
            "-UITestStripperPause",
        ]
        app.launch()
        defer { stop(app) }

        guard cameForward(app, name: "Pod Lounge opened") else { return }
        guard click("lounge.new", in: app, timeout: 20) else {
            record("Pod Lounge created a project and imported the test files", false, "The New button was not on screen.")
            shoot("lounge-no-new", app)
            return
        }
        let named = poll(20) { stringValue("lounge.projectName", in: app) == "QuickCheck" }
        guard named, click("lounge.import", in: app, timeout: 20) else {
            record(
                "Pod Lounge created a project and imported the test files",
                false,
                "The project did not open or Import Audio was missing. Name: \(stringValue("lounge.projectName", in: app))"
            )
            shoot("lounge-no-import", app)
            return
        }
        let imported = poll(30) {
            element("depot.file.QuickCheck-A.wav", in: app).exists
                && element("depot.file.QuickCheck-B.wav", in: app).exists
        }
        if imported {
            record("Pod Lounge created a project and imported the test files", true, "Both test files are in the depot.")
        } else {
            record("Pod Lounge created a project and imported the test files", false, "The depot did not list both files.\n\(snippet(app))")
            shoot("lounge-no-files", app)
            return
        }

        guard click("lounge.card.limiter", in: app, timeout: 20) else {
            record("Pod Lounge Limiter showed loudness for the selected file", false, "The Limiter card was not on screen.")
            shoot("lounge-no-card", app)
            return
        }
        let scanned = poll(90) { resultsAreShowing(app, file: "QuickCheck-B.wav") }
        let raw = statusRaw(app)
        let baseline = counts(raw)
        guard scanned, baseline.analyses >= 1, baseline.levels >= 1 else {
            record(
                "Pod Lounge Limiter showed loudness for the selected file",
                false,
                "Loudness did not finish. Status: \(statusText(raw))"
            )
            shoot("lounge-no-loudness", app)
            return
        }
        record(
            "Pod Lounge Limiter showed loudness for the selected file",
            true,
            "POST integrated loudness read \(postLUFS(app)). \(statusText(raw))"
        )

        let nameBox = element("leveler.resultName", in: app)
        let exportBox = element("leveler.export", in: app)
        let ordered = nameBox.exists && exportBox.exists && exportBox.frame.minY + 2 >= nameBox.frame.maxY
        record(
            "Export File to Depot sits under Result Name",
            ordered,
            ordered
                ? "The export button is below the result name."
                : "Could not see the result name above the export button."
        )

        let lufsBefore = postLUFS(app)
        _ = exportDepot(app, config: config, container: "wav", kind: "wav", extraClicks: ["leveler.bit.int24", "leveler.rate.48000"], baseline: baseline)
        _ = exportDepot(app, config: config, container: "mp3", kind: "mp3", extraClicks: ["leveler.bitrate.128", "leveler.rate.48000"], baseline: baseline)
        if hasLoudnessNumber(app) == false {
            record("Pod Lounge kept the scanned file selected while exporting", false, "Loudness disappeared during export. It had been \(lufsBefore).")
        }

        guard click("depot.file.QuickCheck-A.wav", in: app, timeout: 20) else {
            record("Pod Lounge showed an already-scanned file again without rescanning", false, "Could not select the other depot file.")
            shoot("lounge-no-reselect", app)
            return
        }
        let otherReady = poll(90) { resultsAreShowing(app, file: "QuickCheck-A.wav") }
        let mid = counts(statusRaw(app))
        guard otherReady, mid.analyses > baseline.analyses || mid.levels > baseline.levels else {
            record(
                "Pod Lounge showed an already-scanned file again without rescanning",
                false,
                "The other file did not finish a first scan. Status: \(statusText(statusRaw(app)))"
            )
            shoot("lounge-no-other", app)
            return
        }
        guard click("depot.file.QuickCheck-B.wav", in: app, timeout: 20) else {
            record("Pod Lounge showed an already-scanned file again without rescanning", false, "Could not select the scanned file again.")
            return
        }
        var rescanned = false
        let restored = poll(20) {
            let text = statusText(statusRaw(app))
            if text.contains("Analyzing") || text.contains("Leveling to") { rescanned = true }
            return resultsAreShowing(app, file: "QuickCheck-B.wav")
        }
        let end = counts(statusRaw(app))
        let sameCounts = end == mid
        if restored && rescanned == false && sameCounts && hasLoudnessNumber(app) {
            record(
                "Pod Lounge showed an already-scanned file again without rescanning",
                true,
                "POST integrated loudness read \(postLUFS(app)) and the file was not measured again."
            )
        } else {
            record(
                "Pod Lounge showed an already-scanned file again without rescanning",
                false,
                "Restored \(restored), rescanned \(rescanned), counts \(end) vs \(mid). Status: \(statusText(statusRaw(app)))"
            )
            shoot("lounge-rescanned", app)
        }

        checkWindow(app, standalone: false, name: "Pod Lounge minimum window fits a 1512 by 982 screen")
        checkStripper(app, config: config)
        checkWindow(app, standalone: false, name: "Pod Lounge Stripper workspace fits a 1512 by 982 screen")
        record(
            "Pod Lounge stayed open through the check",
            app.state == .runningForeground,
            app.state == .runningForeground ? "The app was still running." : "The app quit early."
        )
    }

    @discardableResult
    private func exportDepot(
        _ app: XCUIApplication,
        config: QuickConfig,
        container: String,
        kind: String,
        extraClicks: [String],
        baseline: Counts
    ) -> Bool {
        let title = kind == "wav"
            ? "Pod Lounge exported one 24-bit WAV into the depot without selecting it"
            : "Pod Lounge exported one 128 kbps MP3 into the depot without selecting it"
        guard click("leveler.container.\(container)", in: app) else {
            record(title, false, "Could not choose \(container.uppercased()).")
            shoot("lounge-no-\(kind)", app)
            return false
        }
        for identifier in extraClicks {
            guard click(identifier, in: app) else {
                record(title, false, "Could not choose \(identifier).")
                shoot("lounge-no-\(kind)", app)
                return false
            }
        }
        let stem = stringValue("leveler.resultName", in: app).trimmingCharacters(in: .whitespacesAndNewlines)
        let display = stem.lowercased().hasSuffix(".\(kind)") ? stem : "\(stem).\(kind)"
        let before = Set(files(in: config.project.appendingPathComponent("depot/results")).map(\.path))
        guard waitEnabled("leveler.export", in: app, timeout: 20), click("leveler.export", in: app) else {
            record(title, false, "Export File to Depot was not available. \(statusText(statusRaw(app)))")
            shoot("lounge-no-\(kind)", app)
            return false
        }
        var rescanned = false
        let saved = poll(120) {
            let text = statusText(statusRaw(app))
            if text.contains("Analyzing") || text.contains("Leveling to") { rescanned = true }
            return text.contains("Saved result to the depot")
        }
        let after = files(in: config.project.appendingPathComponent("depot/results"))
        let added = after.filter { before.contains($0.path) == false }
        let selected = stringValue("depot.selectedName", in: app)
        let source = sourceName(app)
        let now = counts(statusRaw(app))
        let listed = poll(10) { element("depot.file.\(display)", in: app).exists }
        let ok = saved && added.count == 1 && rescanned == false && now == baseline
            && selected == "QuickCheck-B.wav" && source == "QuickCheck-B.wav" && listed
        if ok == false {
            record(
                title,
                false,
                "Saved \(saved), new files \(added.map(\.lastPathComponent)), selected \(selected), source \(source), rescanned \(rescanned), counts \(now)."
            )
            shoot("lounge-export-\(kind)", app)
            return false
        }
        if let problem = audioProblem(added[0], kind: kind) {
            record(title, false, problem)
            shoot("lounge-decode-\(kind)", app)
            return false
        }
        record(title, true, "Added \(added[0].lastPathComponent). The depot stayed on QuickCheck-B.wav and did not scan again.")
        return true
    }

    // MARK: - Stripper

    private func checkStripper(_ app: XCUIApplication, config: QuickConfig) {
        guard click("lounge.back", in: app, timeout: 20) else {
            record("Pod Lounge Stripper used the imported depot file", false, "Could not return to the Lounge.")
            shoot("stripper-no-back", app)
            return
        }
        guard click("lounge.card.stripper", in: app, timeout: 20) else {
            record("Pod Lounge Stripper used the imported depot file", false, "The Stripper card was not on screen.")
            shoot("stripper-no-card", app)
            return
        }
        let ready = poll(20) { stringValue("stripper.input", in: app).localizedCaseInsensitiveContains("quickcheck-b") }
        record(
            "Pod Lounge Stripper used the imported depot file",
            ready,
            ready ? "Stripper is aimed at the selected depot file." : "The selected file was not shown. \(stringValue("stripper.input", in: app))"
        )
        guard ready else {
            shoot("stripper-no-input", app)
            return
        }

        let resultsDir = config.project.appendingPathComponent("depot/results")
        let beforeCancel = Set(files(in: resultsDir).map(\.path))
        guard waitEnabled("stripper.split", in: app, timeout: 20), click("stripper.split", in: app) else {
            record("Pod Lounge Stripper cancel leaves nothing behind", false, "Split Into Tracks was not available.")
            shoot("stripper-no-split", app)
            return
        }
        guard click("stripper.cancel", in: app, timeout: 20) else {
            record("Pod Lounge Stripper cancel leaves nothing behind", false, "Cancel did not appear.")
            shoot("stripper-no-cancel", app)
            return
        }
        let cancelled = poll(20) { element("stripper.cancel", in: app).exists == false && element("stripper.naming", in: app).exists == false }
        let afterCancel = Set(files(in: resultsDir).map(\.path))
        let stagingLeft = stagingFiles(config)
        let cancelOK = cancelled && afterCancel == beforeCancel && stagingLeft.isEmpty
        record(
            "Pod Lounge Stripper cancel leaves nothing behind",
            cancelOK,
            cancelOK ? "Cancel added no depot tracks and removed the temporary files." : "Cancelled \(cancelled). New files \(afterCancel.subtracting(beforeCancel)). Staging \(stagingLeft)."
        )
        guard cancelOK else {
            shoot("stripper-cancel", app)
            return
        }

        guard waitEnabled("stripper.split", in: app, timeout: 20), click("stripper.split", in: app) else {
            record("Pod Lounge Stripper naming step uses the prefilled names", false, "The second split did not start.")
            return
        }
        let named = poll(30) { element("stripper.naming", in: app).exists && stringValue("stripper.name.0", in: app).contains("Speaker 1") }
        let first = stringValue("stripper.name.0", in: app)
        let second = stringValue("stripper.name.1", in: app)
        let music = stringValue("stripper.name.2", in: app)
        let prefilled = named && first.contains("Split") == false && second.contains("Speaker 2") && music.contains("Music")
        record(
            "Pod Lounge Stripper naming step uses the prefilled names",
            prefilled,
            prefilled ? "Prefills were \(first), \(second), and \(music)." : "Names were \(first) | \(second) | \(music)."
        )
        guard prefilled else {
            shoot("stripper-no-names", app)
            return
        }

        let field = element("stripper.name.0", in: app)
        field.click()
        field.typeKey("a", modifierFlags: [.command])
        field.typeText("Renamed Speaker")
        let beforeAdd = Set(files(in: resultsDir).map(\.path))
        guard click("stripper.addToDepot", in: app, timeout: 15) else {
            record("Pod Lounge Stripper adds renamed tracks without selecting them", false, "Add to Depot was not available.")
            shoot("stripper-no-add", app)
            return
        }
        let listed = poll(20) { element("depot.file.Renamed Speaker", in: app).exists }
        let selected = stringValue("depot.selectedName", in: app)
        let added = files(in: resultsDir).filter { beforeAdd.contains($0.path) == false }
        let durationsOK = added.allSatisfy { durationProblem($0) == nil }
        let noJSON = added.allSatisfy { $0.lastPathComponent != "speakers.json" }
        let addedOK = listed && selected == "QuickCheck-B.wav" && added.count == 3 && durationsOK && noJSON && stagingFiles(config).isEmpty
        if addedOK == false {
            let problems = added.compactMap { durationProblem($0) }
            record(
                "Pod Lounge Stripper adds renamed tracks without selecting them",
                false,
                "Listed \(listed), selected \(selected), files \(added.map(\.lastPathComponent)), durations \(problems), staging \(stagingFiles(config))."
            )
            shoot("stripper-add", app)
            return
        }
        record(
            "Pod Lounge Stripper adds renamed tracks without selecting them",
            true,
            "Added \(added.map(\.lastPathComponent).joined(separator: ", ")). The depot stayed on QuickCheck-B.wav."
        )

        guard click("depot.play.Renamed Speaker", in: app, timeout: 15) else {
            record("Pod Lounge Stripper tracks can be played", false, "The play button was not available.")
            shoot("stripper-no-play", app)
            return
        }
        let playing = poll(10) { element("depot.play.Renamed Speaker", in: app).label.contains("Stop") }
        record(
            "Pod Lounge Stripper tracks can be played",
            playing,
            playing ? "The renamed track started playing." : "Play did not start."
        )
        if playing {
            _ = click("depot.play.Renamed Speaker", in: app, timeout: 5)
        }

        guard waitEnabled("stripper.split", in: app, timeout: 20), click("stripper.split", in: app) else {
            record("Pod Lounge Stripper repeat split adds a suffix and discard keeps the depot", false, "The repeat split did not start.")
            return
        }
        let repeatReady = poll(30) { stringValue("stripper.name.0", in: app).contains("(Split 2)") }
        guard repeatReady else {
            record(
                "Pod Lounge Stripper repeat split adds a suffix and discard keeps the depot",
                false,
                "The repeat prefill was \(stringValue("stripper.name.0", in: app))."
            )
            shoot("stripper-no-repeat", app)
            return
        }
        let beforeDiscard = Set(files(in: resultsDir).map(\.path))
        guard click("stripper.closeNaming", in: app), click("stripper.confirmDiscard", in: app, timeout: 10) else {
            record("Pod Lounge Stripper repeat split adds a suffix and discard keeps the depot", false, "Could not discard the repeat split.")
            shoot("stripper-no-discard", app)
            return
        }
        let discarded = poll(15) { element("stripper.naming", in: app).exists == false }
        let afterDiscard = Set(files(in: resultsDir).map(\.path))
        let discardOK = discarded && afterDiscard == beforeDiscard && stagingFiles(config).isEmpty
        record(
            "Pod Lounge Stripper repeat split adds a suffix and discard keeps the depot",
            discardOK,
            discardOK ? "The repeat prefill included (Split 2), and discarding added nothing." : "Discarded \(discarded). Files changed \(afterDiscard != beforeDiscard). Staging \(stagingFiles(config))."
        )
    }

    private func stagingFiles(_ config: QuickConfig) -> [String] {
        let root = config.project.appendingPathComponent("recovery/stripper-jobs")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var names: [String] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue == false {
                names.append(url.lastPathComponent)
            }
        }
        return names
    }

    private func durationProblem(_ url: URL) -> String? {
        do {
            let file = try AVAudioFile(forReading: url)
            let rate = file.fileFormat.sampleRate
            let seconds = rate > 0 ? Double(file.length) / rate : 0
            if abs(rate - 48_000) > 1 { return "\(url.lastPathComponent) was \(rate) Hz" }
            if file.fileFormat.channelCount != 2 { return "\(url.lastPathComponent) was not stereo" }
            if abs(seconds - sourceSeconds) > 0.05 {
                return String(format: "%@ was %.3f s", url.lastPathComponent, seconds)
            }
            return nil
        } catch {
            return "Could not decode \(url.lastPathComponent)"
        }
    }

    // MARK: - Window

    private func checkWindow(_ app: XCUIApplication, standalone: Bool, name: String) {
        app.activate()
        let how = fitMinimumWindow(app)
        var last = ""
        var stable = 0
        let settled = poll(8) {
            let raw = fitReport(app)
            if raw == last, raw.contains("frame=") {
                stable += 1
            } else {
                stable = 0
                last = raw
            }
            return stable >= 2
        }
        if settled == false {
            _ = fitMinimumWindow(app)
            stable = 0
            _ = poll(8) {
                let raw = fitReport(app)
                if raw == last, raw.contains("frame=") {
                    stable += 1
                } else {
                    stable = 0
                    last = raw
                }
                return stable >= 2
            }
        }
        guard let frame = pair(last, "frame"), let content = pair(last, "content"), let screen = pair(last, "screen") else {
            record(name, false, "Could not read the window size (\(last)). Trigger: \(how).")
            shoot(standalone ? "leveler-window" : "lounge-window", app)
            return
        }
        if frame.0 > 1512.5 || frame.1 > 982.5 {
            record(name, false, String(format: "The window is %.0f by %.0f points, outside 1512 by 982. %@", frame.0, frame.1, last))
            shoot(standalone ? "leveler-window" : "lounge-window", app)
            return
        }
        if let problem = minimumProblem(content: content, screen: screen, standalone: standalone, raw: last) {
            record(name, false, problem)
            shoot(standalone ? "leveler-window" : "lounge-window", app)
            return
        }
        record(
            name,
            true,
            String(format: "Window %.0f by %.0f points, content %.0f by %.0f.", frame.0, frame.1, content.0, content.1)
        )
    }

    /// Asks the app's test-only Quick Check menu to shrink the window.
    private func fitMinimumWindow(_ app: XCUIApplication) -> String {
        let menus = [
            app.menuBars.menuBarItems["Quick Check"],
            app.menuBarItems["Quick Check"],
        ]
        for menu in menus {
            guard poll(4, { menu.exists }) else { continue }
            menu.click()
            let item = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "Fit Minimum")).firstMatch
            if poll(3, { item.exists }) {
                if item.isHittable {
                    item.click()
                } else {
                    item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                }
                return "menu"
            }
            app.typeKey(.escape, modifierFlags: [])
        }
        app.typeKey("m", modifierFlags: [.command, .option, .shift])
        return "key"
    }

    private func fitReport(_ app: XCUIApplication) -> String {
        let target = element("quickcheck.windowFit", in: app)
        guard target.exists else { return "" }
        let value = (target.value as? String) ?? ""
        if value.contains("frame=") { return value }
        if target.label.contains("frame=") { return target.label }
        return value.isEmpty ? target.label : value
    }

    private func minimumProblem(content: (CGFloat, CGFloat), screen: (CGFloat, CGFloat), standalone: Bool, raw: String) -> String? {
        if standalone {
            let widthFloor: CGFloat = screen.0 >= 1180 ? 1180 : screen.0
            let heightFloor: CGFloat = screen.1 >= 900 ? 840 : min(840, screen.1)
            if content.0 + 20 < widthFloor || content.1 + 36 < heightFloor {
                return String(format: "Content %.0f by %.0f is under the standalone minimum of 1180 by 840. %@", content.0, content.1, raw)
            }
            if screen.0 >= 1220, content.0 > 1220 {
                return String(format: "Content width %.0f is wider than the 1180 minimum. %@", content.0, raw)
            }
            if screen.1 >= 920, content.1 > 880 {
                return String(format: "Content height %.0f is taller than the 840 minimum. %@", content.1, raw)
            }
            return nil
        }
        let minW: CGFloat = 1172
        let minH: CGFloat = 800
        if content.0 + 24 < min(minW, screen.0) || content.1 + 40 < min(minH, screen.1) {
            return String(format: "Content %.0f by %.0f is under the Lounge minimum. %@", content.0, content.1, raw)
        }
        if screen.0 >= 1240, abs(content.0 - minW) > 30 {
            return String(format: "Content width %.0f is not the Lounge minimum of 1172. %@", content.0, raw)
        }
        if screen.1 >= 920, content.1 > 860 {
            return String(format: "Content height %.0f is taller than the 800 minimum. %@", content.1, raw)
        }
        return nil
    }

    // MARK: - Audio

    private func writeSignal(to url: URL, frequency: Double, burstOffset: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rate = 48_000.0
        let frames = AVAudioFrameCount(rate * 30)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData
        else {
            throw NSError(domain: "QuickCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not make the test tone."])
        }
        buffer.frameLength = frames
        var noise: UInt32 = 0x12345678
        for index in 0..<Int(frames) {
            let time = Double(index) / rate
            let cycle = (time + burstOffset).truncatingRemainder(dividingBy: 1.1)
            let burst = cycle < 0.42 ? (0.5 - 0.5 * cos((2 * Double.pi * cycle) / 0.42)) : 0
            noise = noise &* 1_664_525 &+ 1_013_904_223
            let unit = Float(noise % 10_000) / 10_000 - 0.5
            let tone = Float(sin(2 * Double.pi * frequency * time))
            channels[0][index] = tone * 0.18 + unit * 0.22 * Float(burst)
            channels[1][index] = tone * 0.14 + unit * 0.18 * Float(burst)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func decodedSeconds(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let rate = file.fileFormat.sampleRate
        guard rate > 0 else { return 0 }
        return Double(file.length) / rate
    }

    private func audioProblem(_ url: URL, kind: String) -> String? {
        let info: String
        let seconds: Double
        let rate: Double
        let channels: Int
        let bits: Int?
        let bitrate: Int?
        do {
            let file = try AVAudioFile(forReading: url)
            rate = file.fileFormat.sampleRate
            channels = Int(file.fileFormat.channelCount)
            seconds = rate > 0 ? Double(file.length) / rate : 0
            bits = file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int
            bitrate = file.fileFormat.settings[AVEncoderBitRateKey] as? Int
            info = afinfo(url)
        } catch {
            return "Could not decode \(url.lastPathComponent): \(error.localizedDescription)"
        }
        if abs(rate - 48_000) > 1 || info.contains("48000") == false {
            return "Sample rate was \(rate). \(info.prefix(240))"
        }
        if channels != 2 || info.contains("2 ch") == false {
            return "Channel count was \(channels)."
        }
        let padding = paddingSeconds(info, rate: rate)
        let delta = seconds - sourceSeconds
        if abs(delta) > 0.050 && abs(delta - padding) > 0.050 {
            return String(format: "Duration %.3f s, source %.3f s, codec padding %.3f s.", seconds, sourceSeconds, padding)
        }
        if kind == "wav" {
            let text = info.lowercased()
            if bits != 24 && text.contains("24-bit") == false && text.contains("24 bit") == false {
                return "The WAV is not 24-bit. \(info.prefix(240))"
            }
        } else if bitrate != 128_000 && info.contains("128000") == false {
            return "The MP3 is not 128 kbps. \(info.prefix(240))"
        }
        return nil
    }

    private func paddingSeconds(_ info: String, rate: Double) -> Double {
        let pattern = #"(\d+) priming \+ (\d+) remainder"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: info, range: NSRange(info.startIndex..., in: info)),
              match.numberOfRanges == 3,
              let primingRange = Range(match.range(at: 1), in: info),
              let remainderRange = Range(match.range(at: 2), in: info),
              let priming = Int(info[primingRange]),
              let remainder = Int(info[remainderRange]),
              rate > 0
        else { return 0 }
        return Double(priming + remainder) / rate
    }

    private func afinfo(_ url: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
        process.arguments = [url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - UI helpers

    private func cameForward(_ app: XCUIApplication, name: String) -> Bool {
        let ok = poll(30) { app.state == .runningForeground }
        record(name, ok, ok ? "The window came to the front." : "The app did not come to the front.")
        if ok == false { shoot("launch-failed", app) }
        return ok
    }

    @discardableResult
    private func click(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        let target = element(identifier, in: app)
        guard poll(timeout, { target.exists }) else { return false }
        if target.isHittable {
            target.click()
        } else {
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        return true
    }

    private func waitEnabled(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let target = element(identifier, in: app)
        return poll(timeout) { target.exists && target.isEnabled }
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private func stringValue(_ identifier: String, in app: XCUIApplication) -> String {
        let target = element(identifier, in: app)
        guard target.exists else { return "" }
        if let value = target.value as? String, value.isEmpty == false { return value }
        return target.label
    }

    private func statusRaw(_ app: XCUIApplication) -> String {
        stringValue("leveler.status", in: app)
    }

    private func statusText(_ raw: String) -> String {
        guard let start = raw.range(of: "status=") else { return raw }
        let rest = raw[start.upperBound...]
        if let end = rest.range(of: ";analyses=") { return String(rest[..<end.lowerBound]) }
        return String(rest)
    }

    private func counts(_ raw: String) -> Counts {
        Counts(analyses: intField(raw, "analyses") ?? -1, levels: intField(raw, "levels") ?? -1)
    }

    private func intField(_ raw: String, _ key: String) -> Int? {
        for part in raw.split(separator: ";") where part.hasPrefix("\(key)=") {
            return Int(part.dropFirst(key.count + 1))
        }
        return nil
    }

    private func sourceName(_ app: XCUIApplication) -> String {
        let label = element("leveler.sourceName", in: app).label
        if label.isEmpty == false, label != "leveler.sourceName" { return label }
        return stringValue("leveler.sourceName", in: app)
    }

    private func postLUFS(_ app: XCUIApplication) -> String {
        let label = element("leveler.postIntegrated", in: app).label
        if label.isEmpty == false, label != "leveler.postIntegrated" { return label }
        return stringValue("leveler.postIntegrated", in: app)
    }

    private func hasLoudnessNumber(_ app: XCUIApplication) -> Bool {
        let label = postLUFS(app)
        return label.contains(where: \.isNumber) && label.contains("—") == false
    }

    private func resultsAreShowing(_ app: XCUIApplication, file: String) -> Bool {
        sourceName(app) == file && statusText(statusRaw(app)).contains("Ready") && hasLoudnessNumber(app)
    }

    /// Moves runner-created files into the sandbox temp directory. Export, the
    /// project, and presets move with them so the apps and the runner share one
    /// folder both can use. App bundles stay where the script built them.
    private func prepareRunnerFiles(_ config: QuickConfig) throws -> QuickConfig {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("podstudio-quickcheck", isDirectory: true)
        let exportDir = scratch.appendingPathComponent("export", isDirectory: true)
        let projectDir = scratch.appendingPathComponent("project", isDirectory: true)
        let presetsLeveler = scratch.appendingPathComponent("presets-leveler", isDirectory: true)
        let presetsLounge = scratch.appendingPathComponent("presets-lounge", isDirectory: true)
        let screenshots = scratch.appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: presetsLeveler, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: presetsLounge, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        let probe = scratch.appendingPathComponent(".write-probe")
        try Data("ok".utf8).write(to: probe, options: .atomic)
        try FileManager.default.removeItem(at: probe)
        NSLog("QUICKCHECK_SCRATCH %@", scratch.path)
        var updated = config
        updated.audioA = scratch.appendingPathComponent("QuickCheck-A.wav")
        updated.audioB = scratch.appendingPathComponent("QuickCheck-B.wav")
        updated.exportDir = exportDir
        updated.project = projectDir.appendingPathComponent("QuickCheck.podlounge")
        updated.presetsLeveler = presetsLeveler
        updated.presetsLounge = presetsLounge
        updated.checks = scratch.appendingPathComponent("checks.json")
        updated.screenshots = screenshots
        updated.blocked = scratch.appendingPathComponent("BLOCKED.txt")
        return updated
    }

    private func files(in directory: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return items.filter { url in
            if url.lastPathComponent.hasPrefix(".") { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile != false
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pair(_ raw: String, _ key: String) -> (CGFloat, CGFloat)? {
        guard let range = raw.range(of: "\(key)=") else { return nil }
        let token = raw[range.upperBound...].split(separator: ";").first ?? ""
        let parts = token.split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
        return (CGFloat(width), CGFloat(height))
    }

    private func stop(_ app: XCUIApplication) {
        if app.state != .notRunning { app.terminate() }
        _ = poll(15) { app.state == .notRunning }
    }

    @discardableResult
    private func poll(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(value: false), object: nil)], timeout: 0.2)
        }
        return condition()
    }

    private func record(_ name: String, _ pass: Bool, _ detail: String) {
        checks.append(Check(name: name, pass: pass, detail: detail))
        try? writeChecks()
    }

    private func shoot(_ name: String, _ app: XCUIApplication) {
        guard shots < 4, let config else { return }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        guard let rep = NSBitmapImageRep(data: png),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.4])
        else { return }
        try? FileManager.default.createDirectory(at: config.screenshots, withIntermediateDirectories: true)
        let url = config.screenshots.appendingPathComponent(String(format: "%02d-%@.jpg", shots + 1, name))
        try? jpeg.write(to: url)
        shots += 1
        _ = app
    }

    private func snippet(_ app: XCUIApplication) -> String {
        let text = app.debugDescription
        if text.count <= 1200 { return text }
        return String(text.prefix(1200))
    }

    private func writeChecks() throws {
        guard let config else { return }
        let data = try JSONEncoder.pretty.encode(checks)
        try FileManager.default.createDirectory(at: config.checks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: config.checks, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
