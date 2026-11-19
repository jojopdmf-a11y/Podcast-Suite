import Foundation
import Testing
@testable import PodLoungeCore

@Test func gestureZoomStaysProportionalAndAnchorsOnThePlayhead() {
    let pinch = TrimmerGestureZoom.factor(magnification: 0.2)
    #expect(abs(pinch - 1.2) < 0.000_1)
    #expect(TrimmerGestureZoom.factor(magnification: 0) == 1)
    #expect(TrimmerGestureZoom.factor(magnification: .nan) == 1)

    let step = TrimmerGestureZoom.factor(verticalDelta: TrimmerGestureZoom.pointsPerStep, precise: true)
    #expect(abs(step - TrimmerViewport.zoomFactor) < 0.000_1)
    let back = TrimmerGestureZoom.factor(verticalDelta: -TrimmerGestureZoom.pointsPerStep, precise: true)
    #expect(abs(back * step - 1) < 0.000_1)

    let small = TrimmerGestureZoom.factor(verticalDelta: 8, precise: true)
    #expect(small > 1)
    #expect(small < TrimmerViewport.zoomFactor)
    let notch = TrimmerGestureZoom.factor(verticalDelta: 1, precise: false)
    let notchPoints = TrimmerGestureZoom.factor(verticalDelta: TrimmerGestureZoom.linePoints, precise: true)
    #expect(abs(notch - notchPoints) < 0.000_1)
    #expect(notch < TrimmerViewport.zoomFactor)

    let fit = 4.0
    let current = 40.0
    let playhead = 10.0
    let scrollX = 100.0
    let view = 400.0
    let next = TrimmerViewport.zoom(pixelsPerSecond: current, by: small, fitPixelsPerSecond: fit)
    let scrolled = TrimmerViewport.zoomedScroll(
        scrollX: scrollX,
        viewportWidth: view,
        pixelsPerSecond: current,
        nextPixelsPerSecond: next,
        playhead: playhead,
        contentSpan: 120
    )
    let oldScreen = playhead * current - scrollX
    #expect(abs((playhead * next - scrolled) - oldScreen) < 0.05)

    let floored = TrimmerViewport.zoom(pixelsPerSecond: fit, by: 0.4, fitPixelsPerSecond: fit)
    #expect(abs(floored - fit) < 0.000_1)
    let capped = TrimmerViewport.zoom(
        pixelsPerSecond: TrimmerViewport.maximumPixelsPerSecond,
        by: small,
        fitPixelsPerSecond: fit
    )
    #expect(capped == TrimmerViewport.maximumPixelsPerSecond)

    let offScreen = TrimmerViewport.zoomedScroll(
        scrollX: 0,
        viewportWidth: view,
        pixelsPerSecond: current,
        nextPixelsPerSecond: next,
        playhead: 80,
        contentSpan: 200
    )
    let middle = (0 + view / 2) / current
    #expect(abs((middle * next - view / 2) - offScreen) < 0.05)
}

@Test func optionFineTuneScalesWithoutJumping() {
    var drag = TrimmerFineDrag()
    drag.advance(rawX: 100, rawY: -40, fine: false)
    #expect(abs(drag.x - 100) < 0.000_1)
    #expect(abs(drag.y - (-40)) < 0.000_1)

    drag.advance(rawX: 100, rawY: -40, fine: true)
    #expect(abs(drag.x - 100) < 0.000_1)
    #expect(abs(drag.y - (-40)) < 0.000_1)

    drag.advance(rawX: 110, rawY: -50, fine: true)
    #expect(abs(drag.x - 101) < 0.000_1)
    #expect(abs(drag.y - (-41)) < 0.000_1)

    drag.advance(rawX: 110, rawY: -50, fine: false)
    #expect(abs(drag.x - 101) < 0.000_1)
    drag.advance(rawX: 130, rawY: -50, fine: false)
    #expect(abs(drag.x - 121) < 0.000_1)

    let full = TrimmerFaderDrag.decibels(from: 0, upwardPoints: 50, travel: 50)
    #expect(abs(full - TrimmerFaderDrag.maximumDB) < 0.000_1)
    let slowed = TrimmerFaderDrag.decibels(from: 0, upwardPoints: 8, travel: 80)
    let normal = TrimmerFaderDrag.decibels(from: 0, upwardPoints: 80, travel: 80)
    #expect(slowed > 0)
    #expect(slowed < normal)
    #expect(TrimmerFaderDrag.clamped(-80) == TrimmerFaderDrag.minimumDB)
    #expect(TrimmerFaderDrag.clamped(40) == TrimmerFaderDrag.maximumDB)
    #expect(TrimmerFaderDrag.decibels(from: -40, upwardPoints: 0, travel: 40) == TrimmerFaderDrag.minimumDB)
}

@Test func savedProjectKeepsDepotItemsAndMarkers() throws {
    let scratch = try Scratch()
    defer { scratch.cleanup() }
    let source = try scratch.file("Episode.wav", "EPISODE-BYTES")
    let folder = scratch.root.appendingPathComponent("Show.podlounge")
    let package = try ProjectPackage.create(at: folder, name: "Show")
    let asset = try package.importMedia(from: source, kind: .original, producedBy: nil, select: true)

    var document = TrimmerDocument.empty
    document = document.placing(TrimmerClip(
        assetID: asset.id,
        track: .episodeMix,
        start: 2,
        inOffset: 0,
        length: 6,
        fadeIn: 0.4,
        fadeOut: 0.2,
        gainDB: -3,
        sourceDuration: 6
    ))
    document = document.settingTrack(.episodeMix, muted: false, gainDB: -6)
    document = document.settingTrack(.musicBeds, solo: true, gainDB: 3)
    document = document.addingMarker(at: 4, title: "Interview")
    document = document.addingMarker(at: 65, title: "Chapter")
    try package.writeTrimmerDocument(document)

    let saved = try String(contentsOf: package.trimmerDocumentURL, encoding: .utf8)
    #expect(saved.contains("\"markers\""))
    #expect(saved.contains("\"gainDB\""))
    #expect(saved.contains("Interview"))
    #expect(asset.relativePath.hasPrefix("depot/"))

    let reopened = try ProjectPackage.open(at: folder)
    #expect(reopened.manifest.assets.map(\.relativePath) == [asset.relativePath])
    #expect(reopened.manifest.assets.map(\.displayName) == ["Episode.wav"])
    #expect(try Data(contentsOf: reopened.resolvedURL(for: reopened.manifest.assets[0])) == Data("EPISODE-BYTES".utf8))
    let loaded = reopened.readTrimmerDocument()
    #expect(loaded.markers.map(\.title) == ["Interview", "Chapter"])
    #expect(abs((loaded.markers.first { $0.title == "Interview" }?.time ?? -1) - 4) < 0.000_1)
    #expect(abs(loaded.trackState(.episodeMix).gainDB - (-6)) < 0.000_1)
    #expect(loaded.trackState(.musicBeds).solo)
    #expect(abs(loaded.trackState(.musicBeds).gainDB - 3) < 0.000_1)
    #expect(abs(loaded.clips[0].fadeIn - 0.4) < 0.000_1)
    #expect(abs(loaded.clips[0].length - 6) < 0.000_1)
    #expect(TrimmerChapters.text(markers: loaded.markers).contains("00:00:04 Interview"))
    #expect(TrimmerChapters.text(markers: loaded.markers).contains("00:01:05 Chapter"))
}

@Test func loungeCopyAllowsPathsAndFlagsTheWordDepot() {
    #expect(LoungeCopy.mentionsDepot("Hide Depot"))
    #expect(LoungeCopy.mentionsDepot("the depot stays locked"))
    #expect(LoungeCopy.mentionsDepot("depot/originals") == false || LoungeCopy.isAllowedDepotLiteral("depot/originals"))
    #expect(LoungeCopy.mentionsDepot("depotDirectory") == false)
    #expect(LoungeCopy.mentionsDepot("podlounge.depotWidth") == false)
    #expect(LoungeCopy.isAllowedDepotLiteral("depot/originals"))
    #expect(LoungeCopy.isAllowedDepotLiteral("depot"))
    #expect(LoungeCopy.isAllowedDepotLiteral("com.cougarcalc.podlounge.depot-asset"))
    #expect(LoungeCopy.isAllowedDepotLiteral("depot.selectedName"))
    #expect(LoungeCopy.isAllowedDepotLiteral("Select a depot file.") == false)
    let sample = #"Text("Hide Depot")\nlet path = "depot/originals"\nlet key = "podlounge.depotWidth""#
    let literals = LoungeCopy.stringLiterals(in: sample)
    let hits = literals.filter { LoungeCopy.mentionsDepot($0) && LoungeCopy.isAllowedDepotLiteral($0) == false }
    #expect(hits == ["Hide Depot"])
}

@Test func loungeSourcesDoNotCallItDepot() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources")
    let names = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
        .filter { $0.hasSuffix(".swift") }
        .sorted()
    var hits: [String] = []
    for name in names {
        let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
        for literal in LoungeCopy.stringLiterals(in: text)
        where LoungeCopy.mentionsDepot(literal) && LoungeCopy.isAllowedDepotLiteral(literal) == false {
            hits.append("\(name): \(literal)")
        }
    }
    #expect(hits == [])
}
