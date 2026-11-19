import AppKit
import PodLoungeCore
import SwiftUI

/// Which part of a clip received the mouse-down. The zone is chosen once, so a drag cannot jump to the neighbor.
enum CutHitKind: Equatable {
    case body
    case trimStart
    case trimEnd
    case fadeIn
    case fadeOut
}

/// One clip's mouse handling.
///
/// An AppKit view owns the drag from mouse-down to mouse-up. Touching clips therefore cannot both
/// trim: the view under the pointer is the only one that moves, and a shared boundary trims one side.
struct CutClipHitView: NSViewRepresentable {
    var fadeInBoundary: CGFloat
    var fadeOutBoundary: CGFloat
    var onDown: () -> Void
    var onClick: (CGFloat) -> Void
    var onChanged: (CutHitKind, CGFloat, CGFloat) -> Void
    var onEnded: (CutHitKind, CGFloat, CGFloat) -> Void
    var onResetCurve: (CutHitKind) -> Void

    func makeNSView(context: Context) -> CutClipHitNSView {
        let view = CutClipHitNSView()
        view.onDown = onDown
        view.onClick = onClick
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onResetCurve = onResetCurve
        view.fadeInBoundary = fadeInBoundary
        view.fadeOutBoundary = fadeOutBoundary
        return view
    }

    func updateNSView(_ nsView: CutClipHitNSView, context: Context) {
        nsView.onDown = onDown
        nsView.onClick = onClick
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
        nsView.onResetCurve = onResetCurve
        if !nsView.tracking {
            nsView.fadeInBoundary = fadeInBoundary
            nsView.fadeOutBoundary = fadeOutBoundary
            nsView.needsLayout = true
            nsView.resetCursorRects()
        }
    }
}

final class CutClipHitNSView: NSView {
    var fadeInBoundary: CGFloat = 0
    var fadeOutBoundary: CGFloat = 0
    var onDown: () -> Void = {}
    var onClick: (CGFloat) -> Void = { _ in }
    var onChanged: (CutHitKind, CGFloat, CGFloat) -> Void = { _, _, _ in }
    var onEnded: (CutHitKind, CGFloat, CGFloat) -> Void = { _, _, _ in }
    var onResetCurve: (CutHitKind) -> Void = { _ in }
    var tracking = false

    private var down = NSPoint.zero
    private var zone: CutHitKind = .body
    private var pushedCursor = false
    private var resetClick = false
    private var fine = TrimmerFineDrag()

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        let handle = handleWidth
        let box = boxSize
        addCursorRect(rect(x: 0, yFromTop: 0, width: handle, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(
            rect(x: bounds.width - handle, yFromTop: 0, width: handle, height: bounds.height),
            cursor: .resizeLeftRight
        )
        addCursorRect(appKit(fadeInBox(box)), cursor: .resizeLeftRight)
        addCursorRect(appKit(fadeOutBox(box)), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        down = convert(event.locationInWindow, from: nil)
        zone = zone(at: down)
        if event.clickCount >= 2, zone == .fadeIn || zone == .fadeOut {
            resetClick = true
            tracking = false
            onResetCurve(zone)
            return
        }
        resetClick = false
        tracking = true
        fine = TrimmerFineDrag()
        onDown()
        if zone != .body {
            NSCursor.resizeLeftRight.push()
            pushedCursor = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if resetClick { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - down.x
        let dy = down.y - point.y
        let scaled = scaledTravel(dx: dx, dy: dy, event: event)
        guard hypot(dx, dy) >= 4 else { return }
        onChanged(zone, scaled.width, scaled.height)
    }

    override func mouseUp(with event: NSEvent) {
        if resetClick {
            resetClick = false
            tracking = false
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - down.x
        let dy = down.y - point.y
        let scaled = scaledTravel(dx: dx, dy: dy, event: event)
        tracking = false
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
        resetCursorRects()
        if hypot(dx, dy) < 4 {
            onClick(down.x)
        } else {
            onEnded(zone, scaled.width, scaled.height)
        }
    }

    /// Trim and fade follow a slowed pointer while Option is held. Moving the clip does not.
    private func scaledTravel(dx: CGFloat, dy: CGFloat, event: NSEvent) -> CGSize {
        guard zone != .body else { return CGSize(width: dx, height: dy) }
        fine.advance(
            rawX: Double(dx),
            rawY: Double(dy),
            fine: event.modifierFlags.contains(.option)
        )
        return CGSize(width: fine.x, height: fine.y)
    }

    /// Just inside the clip. Narrow clips split the width so the two ends never cover the same point.
    private var handleWidth: CGFloat {
        min(7, max(0, bounds.width / 2 - 0.5))
    }

    private var boxSize: CGFloat {
        min(8, max(4, bounds.width / 2))
    }

    private func zone(at point: NSPoint) -> CutHitKind {
        let box = boxSize
        let fromTop = bounds.height - point.y
        let location = CGPoint(x: point.x, y: fromTop)
        let fadeIn = fadeInBox(box)
        let fadeOut = fadeOutBox(box)
        let inFadeIn = fadeIn.contains(location)
        let inFadeOut = fadeOut.contains(location)
        if inFadeIn && inFadeOut {
            // A full-length fade parks its box on the other corner. The fade that has moved in wins.
            if fadeInBoundary > 1, fadeOutBoundary <= 1 { return .fadeIn }
            if fadeOutBoundary > 1, fadeInBoundary <= 1 { return .fadeOut }
            return point.x < bounds.midX ? .fadeIn : .fadeOut
        }
        if inFadeIn { return .fadeIn }
        if inFadeOut { return .fadeOut }
        let handle = handleWidth
        if point.x <= handle { return .trimStart }
        if point.x >= bounds.width - handle { return .trimEnd }
        return .body
    }

    /// AppKit rects grow upward. `yFromTop` matches the fade boxes drawn along the top of the clip.
    private func rect(x: CGFloat, yFromTop: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: bounds.height - yFromTop - height, width: width, height: height)
    }

    /// Top-left origin, matching the white boxes drawn on the clip.
    private func fadeInBox(_ box: CGFloat) -> CGRect {
        let x = min(max(0, bounds.width - box), max(0, fadeInBoundary - box / 2))
        return CGRect(x: x, y: 1, width: box, height: box)
    }

    private func fadeOutBox(_ box: CGFloat) -> CGRect {
        let boundary = bounds.width - fadeOutBoundary
        let x = min(max(0, bounds.width - box), max(0, boundary - box / 2))
        return CGRect(x: x, y: 1, width: box, height: box)
    }

    private func appKit(_ topLeft: CGRect) -> CGRect {
        rect(x: topLeft.minX, yFromTop: topLeft.minY, width: topLeft.width, height: topLeft.height)
    }
}
