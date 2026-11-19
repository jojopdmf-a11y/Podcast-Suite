import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PodLoungeCore

@Test @MainActor func depotAssetDragRoundTripsThroughItsTransferPayload() async throws {
    let drag = DepotAssetDrag(assetID: "asset-42")
    let data = try drag.encodedPayload()
    #expect(DepotAssetDrag.assetID(from: data) == "asset-42")
    #expect(DepotAssetDrag.assetID(from: Data("asset-42".utf8)) == "asset-42")
    #expect(DepotAssetDrag.assetID(from: Data("{\"assetID\":\"\"}".utf8)) == nil)
    #expect(DepotAssetDrag.assetID(from: Data()) == nil)

    let provider = drag.itemProvider()
    let type = UTType.podLoungeDepotAsset.identifier
    #expect(provider.registeredTypeIdentifiers.contains(type))
    #expect(provider.registeredTypeIdentifiers.contains(UTType.json.identifier) == false)

    let board = NSPasteboard(name: NSPasteboard.Name("com.cougarcalc.podlounge.drag-test"))
    board.clearContents()
    defer { board.clearContents() }
    let pasteType = NSPasteboard.PasteboardType(type)
    #expect(board.setData(data, forType: pasteType))
    let pasted = try #require(board.data(forType: pasteType))
    #expect(DepotAssetDrag.assetID(from: pasted) == "asset-42")

    let loaded = await withCheckedContinuation { continuation in
        provider.loadDataRepresentation(forTypeIdentifier: type) { payload, _ in
            continuation.resume(returning: payload.flatMap { DepotAssetDrag.assetID(from: $0) })
        }
    }
    #expect(loaded == "asset-42")
}

@Test func dropXBecomesATimelineTime() {
    #expect(DepotAssetDrag.timelineSeconds(dropX: 80, pixelsPerSecond: 8) == 10)
    #expect(DepotAssetDrag.timelineSeconds(dropX: 0, pixelsPerSecond: 10) == 0)
    #expect(DepotAssetDrag.timelineSeconds(dropX: -12, pixelsPerSecond: 10) == 0)
    #expect(DepotAssetDrag.timelineSeconds(dropX: 40, pixelsPerSecond: 0) == 0)
}

@Test @MainActor func placingADroppedClipLandsOnThatTrackAndUndoes() {
    let editor = TrimmerEditor()
    let time = DepotAssetDrag.timelineSeconds(dropX: 80, pixelsPerSecond: 8)
    let placed = TrimmerClip(
        assetID: "episode",
        track: .introsOutrosAds,
        start: time,
        inOffset: 0,
        length: 6,
        sourceDuration: 6
    )
    editor.apply(label: "Place Clip", editor.document.placing(placed))
    #expect(editor.document.clips.count == 1)
    #expect(editor.document.clips[0].assetID == "episode")
    #expect(editor.document.clips[0].track == .introsOutrosAds)
    #expect(abs(editor.document.clips[0].start - 10) < 0.000_1)
    #expect(abs(editor.document.clips[0].length - 6) < 0.000_1)
    editor.undoManager.undo()
    #expect(editor.document.clips.isEmpty)
    #expect(editor.undoManager.canRedo)
    editor.undoManager.redo()
    #expect(editor.document.clips.count == 1)
    #expect(editor.document.clips[0].track == .introsOutrosAds)
}
