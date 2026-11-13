import Foundation

/// Silence this span on a strip. The show does not get shorter.
struct MuteSpan: Equatable, Codable, Hashable {
    var startFrame: Int
    var endFrame: Int

    var length: Int { max(0, endFrame - startFrame) }

    func clamped(toFrames total: Int) -> MuteSpan? {
        let a = max(0, min(startFrame, endFrame))
        let b = max(startFrame, endFrame)
        let start = min(a, max(0, total))
        let end = min(b, max(0, total))
        guard end > start else { return nil }
        return MuteSpan(startFrame: start, endFrame: end)
    }
}

enum MuteSpanStore {
    /// ~8 ms fade so punches do not click.
    static func fadeFrames(sampleRate: Double) -> Int {
        max(32, Int((sampleRate * 0.008).rounded()))
    }

    static func merge(_ spans: [MuteSpan]) -> [MuteSpan] {
        let ordered = spans.filter { $0.endFrame > $0.startFrame }
            .sorted { $0.startFrame < $1.startFrame }
        guard var current = ordered.first else { return [] }
        var out: [MuteSpan] = []
        for span in ordered.dropFirst() {
            if span.startFrame <= current.endFrame {
                current.endFrame = max(current.endFrame, span.endFrame)
            } else {
                out.append(current)
                current = span
            }
        }
        out.append(current)
        return out
    }

    static func adding(_ span: MuteSpan, to spans: [MuteSpan]) -> [MuteSpan] {
        guard span.endFrame > span.startFrame else { return merge(spans) }
        return merge(spans + [span])
    }

    static func removing(_ span: MuteSpan, from spans: [MuteSpan]) -> [MuteSpan] {
        guard span.endFrame > span.startFrame else { return merge(spans) }
        var out: [MuteSpan] = []
        for existing in merge(spans) {
            if existing.endFrame <= span.startFrame || existing.startFrame >= span.endFrame {
                out.append(existing)
                continue
            }
            if existing.startFrame < span.startFrame {
                out.append(MuteSpan(startFrame: existing.startFrame, endFrame: span.startFrame))
            }
            if existing.endFrame > span.endFrame {
                out.append(MuteSpan(startFrame: span.endFrame, endFrame: existing.endFrame))
            }
        }
        return merge(out)
    }

    /// 1 = audible, 0 = silent. Linear fades at each punch edge.
    static func gain(at frame: Int, spans: [MuteSpan], fadeFrames: Int) -> Float {
        let fade = max(1, fadeFrames)
        var g: Float = 1
        for span in spans {
            if frame < span.startFrame || frame >= span.endFrame { continue }
            let into = frame - span.startFrame
            let outOf = span.endFrame - 1 - frame
            var local: Float = 0
            if into < fade {
                local = 1 - Float(into + 1) / Float(fade)
            } else if outOf < fade {
                local = 1 - Float(outOf + 1) / Float(fade)
            }
            g = min(g, local)
        }
        return g
    }
}
