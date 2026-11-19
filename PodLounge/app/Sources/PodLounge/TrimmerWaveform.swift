import AppKit
import AVFoundation
import Foundation
import PodLoungeCore
import SwiftUI

/// Min/max peaks for one depot file, kept at several levels of detail.
/// The finest level is decoded once. Coarser levels are built from it, so zooming does not read the file again.
/// Drawing uses the level closest to the zoom and never more than one pair per screen pixel.
struct WaveformPyramid: Sendable {
    struct Level: Sendable {
        var framesPerBucket: Int
        var minima: [Float]
        var maxima: [Float]

        func range(from startFrame: Int, to endFrame: Int) -> (Float, Float) {
            guard framesPerBucket > 0, !minima.isEmpty else { return (0, 0) }
            let lastFrame = max(startFrame, endFrame - 1)
            var first = startFrame / framesPerBucket
            var last = lastFrame / framesPerBucket
            if first >= minima.count { return (0, 0) }
            first = max(0, first)
            last = min(minima.count - 1, max(first, last))
            var low = minima[first]
            var high = maxima[first]
            if last > first {
                for index in (first + 1)...last {
                    low = min(low, minima[index])
                    high = max(high, maxima[index])
                }
            }
            return (low, high)
        }
    }

    var sampleRate: Double
    var totalFrames: Int
    var levels: [Level]

    static let empty = WaveformPyramid(sampleRate: 0, totalFrames: 0, levels: [])

    /// Min/max pairs for one visible slice. Never more than `count` pairs (one per pixel).
    func columns(startFrame: Int, frameCount: Int, count: Int) -> [(Float, Float)] {
        let levels = self.levels.map {
            TrimmerPeakLevel(framesPerBucket: $0.framesPerBucket, minima: $0.minima, maxima: $0.maxima)
        }
        return TrimmerPeakLOD.pairs(
            levels: levels,
            startFrame: startFrame,
            frameCount: frameCount,
            pixels: count
        )
    }

    static func compute(url: URL) -> WaveformPyramid {
        guard let file = try? AVAudioFile(forReading: url) else { return .empty }
        let total = Int(file.length)
        let rate = file.processingFormat.sampleRate
        guard total > 0, rate > 0 else { return .empty }
        let bucket = bucketSize(totalFrames: total)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(min(16_384, max(bucket, 1)))
        ) else { return .empty }
        let channels = Int(file.processingFormat.channelCount)
        var minima: [Float] = []
        var maxima: [Float] = []
        minima.reserveCapacity(total / bucket + 1)
        maxima.reserveCapacity(total / bucket + 1)
        var pending = 0
        var low: Float = 0
        var high: Float = 0
        while file.framePosition < file.length {
            let want = AVAudioFrameCount(min(Int(buffer.frameCapacity), Int(file.length - file.framePosition)))
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: want)
            } catch {
                break
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                var sampleLow = data[0][frame]
                var sampleHigh = sampleLow
                if channels > 1 {
                    for channel in 1..<channels {
                        let sample = data[channel][frame]
                        sampleLow = min(sampleLow, sample)
                        sampleHigh = max(sampleHigh, sample)
                    }
                }
                if pending == 0 {
                    low = sampleLow
                    high = sampleHigh
                } else {
                    low = min(low, sampleLow)
                    high = max(high, sampleHigh)
                }
                pending += 1
                if pending >= bucket {
                    minima.append(low)
                    maxima.append(high)
                    pending = 0
                }
            }
        }
        if pending > 0 {
            minima.append(low)
            maxima.append(high)
        }
        guard !minima.isEmpty else { return .empty }
        var levels = [Level(framesPerBucket: bucket, minima: minima, maxima: maxima)]
        while let last = levels.last, last.minima.count > 256, levels.count < 16 {
            levels.append(downsample(last))
        }
        return WaveformPyramid(sampleRate: rate, totalFrames: total, levels: levels)
    }

    /// About 128 source frames per bucket, coarser only when a file would otherwise hold millions of buckets.
    private static func bucketSize(totalFrames: Int) -> Int {
        let base = 128
        let cap = 1_500_000
        if totalFrames <= base * cap { return base }
        return max(base, (totalFrames + cap - 1) / cap)
    }

    private static func downsample(_ level: Level) -> Level {
        let count = (level.minima.count + 1) / 2
        var minima: [Float] = []
        var maxima: [Float] = []
        minima.reserveCapacity(count)
        maxima.reserveCapacity(count)
        var index = 0
        while index < level.minima.count {
            let next = min(index + 1, level.minima.count - 1)
            minima.append(min(level.minima[index], level.minima[next]))
            maxima.append(max(level.maxima[index], level.maxima[next]))
            index += 2
        }
        return Level(framesPerBucket: level.framesPerBucket * 2, minima: minima, maxima: maxima)
    }
}

actor TrimmerWaveformCache {
    static let shared = TrimmerWaveformCache()
    private var jobs: [String: Task<WaveformPyramid, Never>] = [:]

    func pyramid(assetID: String, url: URL) async -> WaveformPyramid {
        if let existing = jobs[assetID] {
            return await existing.value
        }
        let task = Task.detached(priority: .utility) {
            WaveformPyramid.compute(url: url)
        }
        jobs[assetID] = task
        return await task.value
    }
}

enum CutTimelineScale {
    static let tileWidth: CGFloat = 512

    static func step(pixelsPerSecond: CGFloat) -> Double {
        let raw = Double(80 / max(pixelsPerSecond, 1))
        let steps = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        return steps.first { $0 >= raw } ?? 1800
    }

    static func clock(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = clamped - Double(hours * 3600 + minutes * 60)
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, Int(secs))
        }
        return String(format: "%d:%02d", minutes, Int(secs.rounded(.down)))
    }
}

/// Reads and sets the timeline's horizontal scroll so zoom can keep the playhead still.
@MainActor
final class CutScrollBridge: NSObject {
    weak var scrollView: NSScrollView?
    private var observing = false
    private var desired: CGFloat?
    private var pinUntil: TimeInterval = 0
    var x: CGFloat = 0

    func attach(_ scrollView: NSScrollView) {
        if self.scrollView !== scrollView, let old = self.scrollView, observing {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old.contentView)
            observing = false
        }
        self.scrollView = scrollView
        guard !observing else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        observing = true
        x = scrollView.contentView.bounds.origin.x
    }

    func pin(to desired: CGFloat) {
        self.desired = desired
        pinUntil = ProcessInfo.processInfo.systemUptime + 0.45
        apply()
        Task { @MainActor [weak self] in
            self?.apply()
            Task { @MainActor [weak self] in
                self?.apply()
            }
        }
    }

    @objc private func boundsChanged(_ note: Notification) {
        guard let clip = note.object as? NSClipView else { return }
        if let desired, ProcessInfo.processInfo.systemUptime < pinUntil {
            let applied = clamped(desired, clip: clip)
            if abs(clip.bounds.origin.x - applied) > 0.5 {
                setOrigin(applied, clip: clip)
                return
            }
        }
        let next = clip.bounds.origin.x
        if abs(next - x) > 0.25 {
            x = next
        }
    }

    private func apply() {
        guard let desired, let clip = scrollView?.contentView else { return }
        guard ProcessInfo.processInfo.systemUptime < pinUntil else { return }
        setOrigin(clamped(desired, clip: clip), clip: clip)
    }

    /// Shift plus the wheel. Positive delta moves the timeline the same way a rightward swipe does.
    func nudge(by deltaX: CGFloat) {
        guard deltaX.isFinite, deltaX != 0, let clip = scrollView?.contentView else { return }
        desired = nil
        pinUntil = 0
        let next = clamped(clip.bounds.origin.x - deltaX, clip: clip)
        x = next
        clip.scroll(to: NSPoint(x: next, y: clip.bounds.origin.y))
        scrollView?.reflectScrolledClipView(clip)
    }

    private func setOrigin(_ originX: CGFloat, clip: NSClipView) {
        x = originX
        guard abs(clip.bounds.origin.x - originX) > 0.25 else { return }
        clip.scroll(to: NSPoint(x: originX, y: clip.bounds.origin.y))
        scrollView?.reflectScrolledClipView(clip)
    }

    private func clamped(_ originX: CGFloat, clip: NSClipView) -> CGFloat {
        let width = clip.documentView?.frame.width ?? 0
        let maxX = max(0, width - clip.bounds.width)
        return min(max(0, originX), maxX)
    }
}

struct CutZoomKeyHost: NSViewRepresentable {
    var editingMarker: Bool
    var onZoomIn: () -> Void
    var onZoomOut: () -> Void

    func makeNSView(context: Context) -> CutZoomKeyView {
        let view = CutZoomKeyView()
        view.editingMarker = editingMarker
        view.onZoomIn = onZoomIn
        view.onZoomOut = onZoomOut
        view.install()
        return view
    }

    func updateNSView(_ view: CutZoomKeyView, context: Context) {
        view.editingMarker = editingMarker
        view.onZoomIn = onZoomIn
        view.onZoomOut = onZoomOut
    }
}

final class CutZoomKeyView: NSView {
    var editingMarker = false
    var onZoomIn: () -> Void = {}
    var onZoomOut: () -> Void = {}
    nonisolated(unsafe) private var monitor: Any?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let typed = event.characters ?? ""
            let plain = event.charactersIgnoringModifiers ?? ""
            let zoomIn = typed == "+" || typed == "=" || plain == "+" || plain == "="
            let zoomOut = typed == "-" || plain == "-"
            guard zoomIn || zoomOut else { return event }
            if self.editingMarker { return event }
            if Self.textIsFirstResponder() { return event }
            if zoomIn { self.onZoomIn() } else { self.onZoomOut() }
            return nil
        }
    }

    private static func textIsFirstResponder() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if responder is NSTextField { return true }
        return false
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

struct CutTimelineGestureHost: NSViewRepresentable {
    var onZoom: (Double) -> Void
    var onNudge: (CGFloat) -> Void

    func makeNSView(context: Context) -> CutTimelineGestureView {
        let view = CutTimelineGestureView()
        view.onZoom = onZoom
        view.onNudge = onNudge
        view.install()
        return view
    }

    func updateNSView(_ view: CutTimelineGestureView, context: Context) {
        view.onZoom = onZoom
        view.onNudge = onNudge
    }
}

final class CutTimelineGestureView: NSView {
    var onZoom: (Double) -> Void = { _ in }
    var onNudge: (CGFloat) -> Void = { _ in }
    nonisolated(unsafe) private var monitor: Any?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = self.window, event.window === window else { return event }
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return event }
        if event.type == .magnify {
            let factor = TrimmerGestureZoom.factor(magnification: Double(event.magnification))
            if abs(factor - 1) > 0.000_000_1 { onZoom(factor) }
            return nil
        }
        let shift = event.modifierFlags.contains(.shift)
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if shift {
            let delta = abs(dx) >= abs(dy) ? dx : dy
            if delta != 0 { onNudge(delta) }
            return nil
        }
        if event.hasPreciseScrollingDeltas, abs(dx) > abs(dy) {
            return event
        }
        let factor = TrimmerGestureZoom.factor(
            verticalDelta: Double(dy),
            precise: event.hasPreciseScrollingDeltas
        )
        if abs(factor - 1) > 0.000_000_1 { onZoom(factor) }
        return nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

struct CutScrollSpy: NSViewRepresentable {
    var bridge: CutScrollBridge

    func makeNSView(context: Context) -> CutScrollSpyView {
        let view = CutScrollSpyView()
        view.bridge = bridge
        return view
    }

    func updateNSView(_ view: CutScrollSpyView, context: Context) {
        view.bridge = bridge
        view.attachIfNeeded()
    }
}

final class CutScrollSpyView: NSView {
    var bridge: CutScrollBridge?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    override func layout() {
        super.layout()
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard let bridge, let scroll = enclosingScrollView else { return }
        bridge.attach(scroll)
    }
}

struct CutRulerMarks: NSViewRepresentable {
    var pixelsPerSecond: CGFloat

    func makeNSView(context: Context) -> CutRulerMarksView {
        let view = CutRulerMarksView()
        view.pixelsPerSecond = pixelsPerSecond
        return view
    }

    func updateNSView(_ view: CutRulerMarksView, context: Context) {
        guard view.pixelsPerSecond != pixelsPerSecond else { return }
        view.pixelsPerSecond = pixelsPerSecond
        view.needsDisplay = true
    }
}

final class CutRulerMarksView: NSView {
    var pixelsPerSecond: CGFloat = 10
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let region = drawingRegion(dirtyRect)
        guard region.width > 0, pixelsPerSecond > 0 else { return }
        let step = CutTimelineScale.step(pixelsPerSecond: pixelsPerSecond)
        let minor = step / 2
        guard minor > 0 else { return }
        let first = max(0, Int((Double(region.minX - 48) / Double(pixelsPerSecond) / minor).rounded(.down)))
        let last = Int((Double(region.maxX + 8) / Double(pixelsPerSecond) / minor).rounded(.up))
        guard last >= first else { return }
        let hop = max(1, (last - first) / 600)
        let majorColor = NSColor(srgbRed: 0.55, green: 0.68, blue: 0.73, alpha: 0.55)
        let minorColor = NSColor(srgbRed: 0.55, green: 0.68, blue: 0.73, alpha: 0.25)
        let labelColor = NSColor(srgbRed: 0.55, green: 0.68, blue: 0.73, alpha: 1)
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor,
        ]
        var index = first
        while index <= last {
            let time = Double(index) * minor
            let x = CGFloat(time) * pixelsPerSecond
            let major = index % 2 == 0
            let tick = NSBezierPath()
            if major {
                tick.move(to: NSPoint(x: x, y: 0))
                tick.line(to: NSPoint(x: x, y: bounds.height))
                majorColor.setStroke()
            } else {
                tick.move(to: NSPoint(x: x, y: bounds.height - 8))
                tick.line(to: NSPoint(x: x, y: bounds.height))
                minorColor.setStroke()
            }
            tick.lineWidth = 1
            tick.stroke()
            if major {
                let label = CutTimelineScale.clock(time) as NSString
                label.draw(at: NSPoint(x: x + 4, y: 3), withAttributes: labelAttributes)
            }
            index += hop
        }
    }

    private func drawingRegion(_ dirtyRect: NSRect) -> NSRect {
        if visibleRect.isEmpty || visibleRect.isNull { return dirtyRect }
        return dirtyRect.intersection(visibleRect)
    }
}

struct CutLaneGrid: NSViewRepresentable {
    var pixelsPerSecond: CGFloat

    func makeNSView(context: Context) -> CutLaneGridView {
        let view = CutLaneGridView()
        view.pixelsPerSecond = pixelsPerSecond
        return view
    }

    func updateNSView(_ view: CutLaneGridView, context: Context) {
        guard view.pixelsPerSecond != pixelsPerSecond else { return }
        view.pixelsPerSecond = pixelsPerSecond
        view.needsDisplay = true
    }
}

final class CutLaneGridView: NSView {
    var pixelsPerSecond: CGFloat = 10
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let region = visibleRect.isEmpty ? dirtyRect : dirtyRect.intersection(visibleRect)
        guard region.width > 0, pixelsPerSecond > 0 else { return }
        let step = CutTimelineScale.step(pixelsPerSecond: pixelsPerSecond)
        let minor = step / 2
        guard minor > 0 else { return }
        let first = max(0, Int((Double(region.minX) / Double(pixelsPerSecond) / minor).rounded(.down)))
        let last = Int((Double(region.maxX) / Double(pixelsPerSecond) / minor).rounded(.up))
        guard last >= first else { return }
        let hop = max(1, (last - first) / 600)
        NSColor(calibratedWhite: 1, alpha: 0.04).setStroke()
        var index = first
        while index <= last {
            let x = CGFloat(Double(index) * minor) * pixelsPerSecond
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: 0))
            line.line(to: NSPoint(x: x, y: bounds.height))
            line.lineWidth = 1
            line.stroke()
            index += hop
        }
    }
}

final class WaveformTileBox: NSObject {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

final class WaveformTileCache: @unchecked Sendable {
    static let shared = WaveformTileCache()
    private let cache = NSCache<NSString, WaveformTileBox>()

    init() {
        cache.countLimit = 96
    }

    func image(for key: String, make: () -> CGImage?) -> CGImage? {
        let name = key as NSString
        if let hit = cache.object(forKey: name) { return hit.image }
        guard let image = make() else { return nil }
        cache.setObject(WaveformTileBox(image), forKey: name, cost: image.width * image.height)
        return image
    }
}

struct CutClipCanvas: NSViewRepresentable {
    var assetID: String
    var url: URL?
    var track: TrimmerTrackID
    var inOffset: Double
    var length: Double
    var sourceDuration: Double?
    var pixelsPerSecond: CGFloat
    var fadeIn: Double
    var fadeOut: Double
    var fadeInCurve: Double
    var fadeOutCurve: Double

    func makeNSView(context: Context) -> CutClipCanvasView {
        let view = CutClipCanvasView()
        view.wantsLayer = false
        return view
    }

    func updateNSView(_ view: CutClipCanvasView, context: Context) {
        view.wantsLayer = false
        var changed = false
        if view.track != track { view.track = track; changed = true }
        if view.inOffset != inOffset { view.inOffset = inOffset; changed = true }
        if view.length != length { view.length = length; changed = true }
        if view.sourceDuration != sourceDuration { view.sourceDuration = sourceDuration; changed = true }
        if view.pixelsPerSecond != pixelsPerSecond { view.pixelsPerSecond = pixelsPerSecond; changed = true }
        if view.fadeIn != fadeIn { view.fadeIn = fadeIn; changed = true }
        if view.fadeOut != fadeOut { view.fadeOut = fadeOut; changed = true }
        if view.fadeInCurve != fadeInCurve { view.fadeInCurve = fadeInCurve; changed = true }
        if view.fadeOutCurve != fadeOutCurve { view.fadeOutCurve = fadeOutCurve; changed = true }
        let needsLoad = view.assetID != assetID || (view.sourceURL != url && view.pyramid.totalFrames == 0)
        if needsLoad {
            view.assetID = assetID
            view.sourceURL = url
            view.pyramid = .empty
            changed = true
            view.loadTask?.cancel()
            view.loadToken &+= 1
            let token = view.loadToken
            if let fileURL = url {
                view.loadTask = Task { @MainActor in
                    let pyramid = await TrimmerWaveformCache.shared.pyramid(assetID: assetID, url: fileURL)
                    guard view.assetID == assetID, view.loadToken == token else { return }
                    view.pyramid = pyramid
                    view.needsDisplay = true
                }
            }
        }
        if changed { view.needsDisplay = true }
    }
}

final class CutClipCanvasView: NSView {
    var assetID = ""
    var track: TrimmerTrackID = .episodeMix
    var inOffset = 0.0
    var length = 0.0
    var sourceDuration: Double?
    var pixelsPerSecond: CGFloat = 10
    var fadeIn = 0.0
    var fadeOut = 0.0
    var fadeInCurve = 0.0
    var fadeOutCurve = 0.0
    var sourceURL: URL?
    var pyramid = WaveformPyramid.empty
    var loadToken = 0
    var loadTask: Task<Void, Never>?

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let region = visibleRect.isEmpty ? dirtyRect : dirtyRect.intersection(visibleRect)
        guard region.width > 0, region.height > 0, bounds.width > 1, bounds.height > 1 else { return }
        drawWaveform(in: region)
        drawFades(in: region)
    }

    private var plotRect: CGRect {
        CGRect(
            x: 2,
            y: 14,
            width: max(1, bounds.width - 4),
            height: max(1, bounds.height - 18)
        )
    }

    private var waveColor: NSColor {
        switch track {
        case .episodeMix: NSColor(srgbRed: 0.18, green: 0.90, blue: 0.93, alpha: 0.92)
        case .introsOutrosAds: NSColor(srgbRed: 0.45, green: 0.72, blue: 0.98, alpha: 0.92)
        case .musicBeds: NSColor(srgbRed: 0.40, green: 0.86, blue: 0.58, alpha: 0.92)
        }
    }

    private func drawWaveform(in region: NSRect) {
        let plot = plotRect
        let visible = region.intersection(plot)
        guard visible.width > 0 else { return }
        guard pyramid.sampleRate > 0, pyramid.totalFrames > 0 else {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: visible.minX, y: plot.midY))
            line.line(to: NSPoint(x: visible.maxX, y: plot.midY))
            waveColor.withAlphaComponent(0.35).setStroke()
            line.lineWidth = 1
            line.stroke()
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        let tile = CutTimelineScale.tileWidth
        let origin = max(plot.minX, plot.minX + floor((visible.minX - plot.minX) / tile) * tile)
        var x = origin
        let end = min(visible.maxX, plot.maxX)
        while x < end {
            let width = min(tile, plot.maxX - x)
            guard width > 0.5 else { break }
            let tileRect = CGRect(x: x, y: plot.minY, width: width, height: plot.height)
            if let image = tileImage(originX: x, width: width, plot: plot, scale: scale) {
                NSImage(cgImage: image, size: NSSize(width: width, height: plot.height)).draw(in: tileRect)
            }
            x += tile
        }
    }

    private func tileImage(originX: CGFloat, width: CGFloat, plot: CGRect, scale: CGFloat) -> CGImage? {
        let pixels = max(1, Int(width.rounded(.up)))
        let height = max(1, Int(plot.height.rounded(.up)))
        let frames = sourceFrames
        let local = max(0, originX - plot.minX)
        let start = frames.start + Int((Double(local) / Double(plot.width) * Double(frames.count)).rounded(.down))
        let count = max(1, Int((Double(width) / Double(plot.width) * Double(frames.count)).rounded(.up)))
        let key = "\(assetID)|\(pyramid.totalFrames)|\(start)|\(count)|\(pixels)|\(height)|\(Int(scale * 100))|\(track.rawValue)"
        return WaveformTileCache.shared.image(for: key) {
            self.makeTile(startFrame: start, frameCount: count, pixels: pixels, height: height, scale: scale)
        }
    }

    private var sourceFrames: (start: Int, count: Int) {
        guard pyramid.sampleRate > 0 else { return (0, 1) }
        let start = Int((inOffset * pyramid.sampleRate).rounded(.down))
        var end = Int(((inOffset + length) * pyramid.sampleRate).rounded(.down))
        if let sourceDuration, sourceDuration > 0 {
            end = min(end, Int((sourceDuration * pyramid.sampleRate).rounded(.down)))
        }
        end = min(end, pyramid.totalFrames)
        return (max(0, start), max(1, end - start))
    }

    private func makeTile(startFrame: Int, frameCount: Int, pixels: Int, height: Int, scale: CGFloat) -> CGImage? {
        let pairs = pyramid.columns(startFrame: startFrame, frameCount: frameCount, count: pixels)
        guard !pairs.isEmpty else { return nil }
        let pixelW = max(1, Int((CGFloat(pixels) * scale).rounded()))
        let pixelH = max(1, Int((CGFloat(height) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(waveColor.cgColor)
        let mid = CGFloat(pixelH) / 2
        let step = CGFloat(pixelW) / CGFloat(pairs.count)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: step * 0.5, y: mid + CGFloat(pairs[0].1) * mid))
        for (index, pair) in pairs.enumerated() where index > 0 {
            ctx.addLine(to: CGPoint(x: (CGFloat(index) + 0.5) * step, y: mid + CGFloat(pair.1) * mid))
        }
        for (index, pair) in pairs.enumerated().reversed() {
            ctx.addLine(to: CGPoint(x: (CGFloat(index) + 0.5) * step, y: mid + CGFloat(pair.0) * mid))
        }
        ctx.closePath()
        ctx.fillPath()
        return ctx.makeImage()
    }

    private func drawFades(in region: NSRect) {
        guard length > 0.000_1 else { return }
        let inBoundary = CGFloat(fadeIn / length) * bounds.width
        let outBoundary = bounds.width - CGFloat(fadeOut / length) * bounds.width
        strokeFade(boundary: inBoundary, leading: true, curve: fadeInCurve, region: region)
        strokeFade(boundary: outBoundary, leading: false, curve: fadeOutCurve, region: region)
    }

    private func strokeFade(boundary: CGFloat, leading: Bool, curve: Double, region: NSRect) {
        let span = leading ? boundary : bounds.width - boundary
        guard span > 0.5 else { return }
        let fadeRect = leading
            ? CGRect(x: 0, y: 0, width: boundary, height: bounds.height)
            : CGRect(x: boundary, y: 0, width: bounds.width - boundary, height: bounds.height)
        let visible = fadeRect.intersection(region.insetBy(dx: -1, dy: 0))
        guard visible.width > 0 else { return }
        let startX = max(fadeRect.minX, visible.minX)
        let endX = min(fadeRect.maxX, visible.maxX)
        guard endX > startX else { return }
        let samples = min(2_000, max(2, Int((endX - startX).rounded(.up))))
        let shade = NSBezierPath()
        shade.move(to: NSPoint(x: startX, y: 0))
        shade.line(to: NSPoint(x: endX, y: 0))
        for index in stride(from: samples, through: 0, by: -1) {
            let x = startX + (endX - startX) * CGFloat(index) / CGFloat(samples)
            shade.line(to: NSPoint(x: x, y: gainY(at: x, boundary: boundary, leading: leading, curve: curve)))
        }
        shade.close()
        tint.withAlphaComponent(0.50).setFill()
        shade.fill()
        NSColor.black.withAlphaComponent(0.30).setFill()
        shade.fill()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: startX, y: gainY(at: startX, boundary: boundary, leading: leading, curve: curve)))
        for index in 1...samples {
            let x = startX + (endX - startX) * CGFloat(index) / CGFloat(samples)
            line.line(to: NSPoint(x: x, y: gainY(at: x, boundary: boundary, leading: leading, curve: curve)))
        }
        NSColor.white.withAlphaComponent(0.92).setStroke()
        line.lineWidth = 1.25
        line.stroke()
    }

    private var tint: NSColor {
        switch track {
        case .episodeMix: NSColor(srgbRed: 0.18, green: 0.90, blue: 0.93, alpha: 1)
        case .introsOutrosAds: NSColor(srgbRed: 0.45, green: 0.72, blue: 0.98, alpha: 1)
        case .musicBeds: NSColor(srgbRed: 0.40, green: 0.86, blue: 0.58, alpha: 1)
        }
    }

    /// Flipped view: y 0 is the top of the clip, where the fade is at full level.
    private func gainY(at x: CGFloat, boundary: CGFloat, leading: Bool, curve: Double) -> CGFloat {
        let gain: Float
        if leading {
            let span = max(boundary, 0.000_1)
            let t = Double(min(max(0, x), span) / span)
            gain = TrimmerFadeCurve.fadeInGain(t, curve: curve)
        } else {
            let span = max(bounds.width - boundary, 0.000_1)
            let t = Double(min(max(0, x - boundary), span) / span)
            gain = TrimmerFadeCurve.fadeOutGain(t, curve: curve)
        }
        return bounds.height * (1 - CGFloat(gain))
    }
}
