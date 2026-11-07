import AppKit
import SwiftUI

/// Column floors for the Limiter workspace. Built from the real label widths
/// (platform subtitles, loudness rows, and the four output choices) so text
/// stays on one line. Spare width goes to the center, which holds the meters.
public enum LevelerPaneMetrics {
    public static let presetMin: CGFloat = 184
    public static let presetDefault: CGFloat = 196
    public static let presetMax: CGFloat = 320
    public static let centerMin: CGFloat = 400
    public static let outputMin: CGFloat = 276
    public static let outputDefault: CGFloat = 292
    public static let outputMax: CGFloat = 420
    public static let divider: CGFloat = 10
    /// Shortest useful meter stack. Ballistics are unchanged; this is only a floor.
    public static let meterMin: CGFloat = 168
    public static let rootPadding: CGFloat = 16
    public static let workspacePadding: CGFloat = 16

    public static var columnsMinimum: CGFloat {
        presetMin + centerMin + outputMin + divider * 2
    }

    /// Width the Limiter needs before the depot is allowed to grow.
    public static var limiterWorkspaceMinimum: CGFloat {
        columnsMinimum + rootPadding + workspacePadding
    }

    public static let presetKey = "podlounge.limiter.presetWidth"
    public static let outputKey = "podlounge.limiter.outputWidth"
    public static let loudnessExtraKey = "podlounge.limiter.loudnessExtra"
}

public struct LevelerColumnSplit: Equatable, Sendable {
    public var preset: CGFloat
    public var center: CGFloat
    public var output: CGFloat

    public init(preset: CGFloat, center: CGFloat, output: CGFloat) {
        self.preset = preset
        self.center = center
        self.output = output
    }
}

public enum LevelerPaneMath {
    public enum ColumnLock: Sendable {
        /// Fit both stored widths. Shrink Output first, then Presets.
        case none
        /// Preset drag: keep Output where it is until the center hits its floor.
        case output
        /// Output drag: keep Presets where they are until the center hits its floor.
        case preset
    }

    public static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        let hi = max(lower, upper)
        return min(hi, max(lower, value))
    }

    /// `available` includes the columns and the dividers between them.
    public static func columns(
        available: CGFloat,
        preset: CGFloat,
        output: CGFloat,
        showsPreset: Bool,
        presetMin: CGFloat,
        presetMax: CGFloat,
        outputMin: CGFloat,
        outputMax: CGFloat,
        centerMin: CGFloat,
        divider: CGFloat,
        lock: ColumnLock = .none
    ) -> LevelerColumnSplit {
        let chrome = divider * (showsPreset ? 2 : 1)
        let room = available - chrome
        let pMin: CGFloat = showsPreset ? presetMin : 0
        let pMax: CGFloat = showsPreset ? presetMax : 0
        let requestedPreset: CGFloat = showsPreset ? preset : 0

        if room <= pMin + outputMin + centerMin {
            let output = min(outputMin, max(0, room - pMin))
            let center = max(0, room - pMin - output)
            return LevelerColumnSplit(preset: pMin, center: center, output: output)
        }

        func fittedPreset(_ value: CGFloat, ceiling: CGFloat) -> CGFloat {
            guard showsPreset else { return 0 }
            return clamp(value, min: pMin, max: min(pMax, ceiling))
        }

        switch lock {
        case .output:
            var side = clamp(output, min: outputMin, max: outputMax)
            let sideCeiling = room - pMin - centerMin
            side = min(side, max(outputMin, sideCeiling))
            if side + pMin + centerMin > room {
                side = max(0, room - pMin - centerMin)
            }
            let leading = fittedPreset(requestedPreset, ceiling: max(pMin, room - side - centerMin))
            return LevelerColumnSplit(preset: leading, center: room - leading - side, output: side)
        case .preset:
            var leading = fittedPreset(requestedPreset, ceiling: max(pMin, room - outputMin - centerMin))
            if leading + outputMin + centerMin > room {
                leading = max(0, room - outputMin - centerMin)
            }
            let sideCeiling = max(outputMin, room - leading - centerMin)
            let side = clamp(output, min: outputMin, max: min(outputMax, sideCeiling))
            return LevelerColumnSplit(preset: leading, center: room - leading - side, output: side)
        case .none:
            var leading = fittedPreset(requestedPreset, ceiling: pMax)
            var side = clamp(output, min: outputMin, max: outputMax)
            if leading + side + centerMin > room {
                let overflow = leading + side + centerMin - room
                let sideSlack = max(0, side - outputMin)
                let takeSide = min(sideSlack, overflow)
                side -= takeSide
                leading = max(pMin, leading - (overflow - takeSide))
            }
            return LevelerColumnSplit(preset: leading, center: room - leading - side, output: side)
        }
    }

    /// Split a vertical band. `storedBottom` is content height plus any extra
    /// the user dragged. Spare height stays in `top` (the meters).
    public static func band(
        available: CGFloat,
        storedBottom: CGFloat,
        topMin: CGFloat,
        bottomMin: CGFloat
    ) -> (top: CGFloat, bottom: CGFloat) {
        if available <= 0 { return (0, 0) }
        let floorBottom = max(0, bottomMin)
        let floorTop = max(0, topMin)
        if available <= floorBottom + floorTop {
            let bottom = min(floorBottom, available)
            return (available - bottom, bottom)
        }
        let bottom = min(max(storedBottom, floorBottom), available - floorTop)
        return (available - bottom, bottom)
    }

    /// Largest depot width that still leaves `reserved` points for the limiter.
    public static func depotMaximum(
        container: CGFloat,
        reserved: CGFloat,
        minimum: CGFloat,
        cap: CGFloat
    ) -> CGFloat {
        clamp(container - reserved, min: minimum, max: cap)
    }
}

/// Thin resize bar with a small grip. Positive drag is rightward or downward.
public struct LevelerPaneDivider: View {
    public enum Axis: Sendable {
        case vertical
        case horizontal
    }

    private var axis: Axis
    private var help: String
    private var onDrag: (CGFloat) -> Void
    private var onDragEnded: () -> Void
    private var onReset: () -> Void

    public init(
        axis: Axis,
        help: String,
        onDrag: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) {
        self.axis = axis
        self.help = help
        self.onDrag = onDrag
        self.onDragEnded = onDragEnded
        self.onReset = onReset
    }

    public var body: some View {
        let vertical = axis == .vertical
        LevelerPaneDividerRepresentable(
            axisIsVertical: vertical,
            onDrag: onDrag,
            onDragEnded: onDragEnded,
            onReset: onReset
        )
        .frame(
            width: vertical ? LevelerPaneMetrics.divider : nil,
            height: vertical ? nil : LevelerPaneMetrics.divider
        )
        .frame(
            maxWidth: vertical ? nil : .infinity,
            maxHeight: vertical ? .infinity : nil
        )
        .help(help)
        .accessibilityLabel(help)
        .accessibilityHint("Double-click to reset the size")
        .accessibilityAddTraits(.isButton)
    }
}

private struct LevelerPaneDividerRepresentable: NSViewRepresentable {
    var axisIsVertical: Bool
    var onDrag: (CGFloat) -> Void
    var onDragEnded: () -> Void
    var onReset: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PaneDividerNSView {
        let view = PaneDividerNSView()
        view.bridge = context.coordinator
        view.axisIsVertical = axisIsVertical
        return view
    }

    func updateNSView(_ nsView: PaneDividerNSView, context: Context) {
        context.coordinator.onDrag = onDrag
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onReset = onReset
        nsView.axisIsVertical = axisIsVertical
        nsView.bridge = context.coordinator
        nsView.needsDisplay = true
    }

    final class Coordinator {
        var onDrag: ((CGFloat) -> Void)?
        var onDragEnded: (() -> Void)?
        var onReset: (() -> Void)?
    }
}

private final class PaneDividerNSView: NSView {
    var axisIsVertical = true {
        didSet { resetCursorRects() }
    }

    weak var bridge: LevelerPaneDividerRepresentable.Coordinator?
    private var origin: CGFloat = 0
    private var moved = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let cursor: NSCursor = axisIsVertical ? .resizeLeftRight : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.20, green: 0.92, blue: 0.95, alpha: 0.28).setFill()
        if axisIsVertical {
            NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
        } else {
            NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
        }
        NSColor(calibratedRed: 0.20, green: 0.92, blue: 0.95, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: gripRect, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private var gripRect: NSRect {
        if axisIsVertical {
            return NSRect(x: bounds.midX - 1.5, y: bounds.midY - 16, width: 3, height: 32)
        }
        return NSRect(x: bounds.midX - 16, y: bounds.midY - 1.5, width: 32, height: 3)
    }

    override func mouseDown(with event: NSEvent) {
        moved = false
        if event.clickCount >= 2 {
            bridge?.onReset?()
            return
        }
        let point = event.locationInWindow
        origin = axisIsVertical ? point.x : point.y
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        let delta: CGFloat
        if axisIsVertical {
            delta = point.x - origin
        } else {
            // Window y grows upward. A downward drag is the positive resize.
            delta = origin - point.y
        }
        guard abs(delta) >= 1 else { return }
        moved = true
        bridge?.onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 2 { return }
        if moved {
            bridge?.onDragEnded?()
        }
        moved = false
    }
}

/// Meters take the leftover height. The loudness band keeps its content height
/// plus `extra` points from the horizontal divider, and never steals the meter floor.
struct LevelerCenterLayout: Layout {
    var extra: CGFloat
    var meterMin: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 else { return }
        let width = bounds.width
        let ideal = ProposedViewSize(width: width, height: nil)
        let fileH = subviews[0].sizeThatFits(ideal).height
        let divH = LevelerPaneMetrics.divider
        let loudIdeal = subviews[3].sizeThatFits(ideal).height
        let footerH = subviews[4].sizeThatFits(ideal).height
        let gaps = spacing * 4
        let remaining = max(0, bounds.height - fileH - divH - footerH - gaps)
        let split = LevelerPaneMath.band(
            available: remaining,
            storedBottom: loudIdeal + max(0, extra),
            topMin: meterMin,
            bottomMin: loudIdeal
        )

        var y = bounds.minY
        func place(_ index: Int, _ height: CGFloat) {
            let proposal = ProposedViewSize(width: width, height: max(0, height))
            _ = subviews[index].sizeThatFits(proposal)
            subviews[index].place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: proposal
            )
            y += height + spacing
        }
        place(0, fileH)
        place(1, split.top)
        place(2, divH)
        place(3, split.bottom)
        place(4, footerH)
    }
}
