import AppKit
import PodLoungeCore
import SwiftUI
import UniformTypeIdentifiers

/// Drop target for one TheCut lane.
///
/// A SwiftUI view that accepts the drop also takes the click, so a click on the
/// lane never moves the playhead. This anchor is not hit-tested. It keeps a
/// real AppKit view above the window, clipped to the visible part of the lane.
/// That view returns nil from hit-testing unless a depot row is on the drag
/// pasteboard, so clicks and range drags still reach the lane.
struct LaneDropCatcher: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onPerform: (String, CGFloat) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.onHover = onHover
        context.coordinator.onPerform = onPerform
        nsView.coordinator = context.coordinator
        context.coordinator.sync(anchor: nsView)
    }

    @MainActor
    final class Coordinator {
        let dropView = LaneDropView()
        var onHover: (Bool) -> Void = { _ in }
        var onPerform: (String, CGFloat) -> Bool = { _, _ in false }

        func sync(anchor: NSView) {
            dropView.onHover = onHover
            dropView.onPerform = onPerform
            guard let content = anchor.window?.contentView else { return }
            if dropView.superview !== content {
                content.addSubview(dropView, positioned: .above, relativeTo: nil)
            }
            let full = anchor.convert(anchor.bounds, to: content)
            let visible: NSRect
            if let clip = anchor.enclosingScrollView?.contentView {
                let clipRect = clip.convert(clip.bounds, to: content)
                visible = full.intersection(clipRect)
            } else {
                visible = full
            }
            guard visible.width > 1, visible.height > 1, visible.isNull == false else { return }
            dropView.frame = visible
            dropView.timelineOriginX = full.minX
        }

        func teardown() {
            dropView.removeFromSuperview()
        }
    }
}

final class AnchorView: NSView {
    var coordinator: LaneDropCatcher.Coordinator?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        coordinator?.sync(anchor: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            coordinator?.teardown()
        } else {
            coordinator?.sync(anchor: self)
        }
    }
}

final class LaneDropView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onPerform: (String, CGFloat) -> Bool = { _, _ in false }
    /// Content-view x of the lane's left edge. The view itself may be only the visible slice.
    var timelineOriginX: CGFloat = 0
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.dragType])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), Self.depotDragIsActive else { return nil }
        return self
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.assetID(from: sender.draggingPasteboard) != nil else { return [] }
        setHovering(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.assetID(from: sender.draggingPasteboard) != nil else { return [] }
        setHovering(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHovering(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setHovering(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.assetID(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHovering(false)
        guard let assetID = Self.assetID(from: sender.draggingPasteboard) else { return false }
        let contentX = frame.minX + convert(sender.draggingLocation, from: nil).x
        let laneX = contentX - timelineOriginX
        return onPerform(assetID, laneX)
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != self.hovering else { return }
        self.hovering = hovering
        onHover(hovering)
    }

    private static var dragType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(UTType.podLoungeDepotAsset.identifier)
    }

    static var depotDragIsActive: Bool {
        NSPasteboard(name: .drag).types?.contains(dragType) == true
    }

    static func assetID(from pasteboard: NSPasteboard) -> String? {
        if let data = pasteboard.data(forType: dragType), let id = DepotAssetDrag.assetID(from: data) {
            return id
        }
        if let text = pasteboard.string(forType: dragType), let id = DepotAssetDrag.assetID(from: Data(text.utf8)) {
            return id
        }
        for item in pasteboard.pasteboardItems ?? [] {
            if let data = item.data(forType: dragType), let id = DepotAssetDrag.assetID(from: data) {
                return id
            }
            if let text = item.string(forType: dragType), let id = DepotAssetDrag.assetID(from: Data(text.utf8)) {
                return id
            }
        }
        return nil
    }
}
