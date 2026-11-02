import Foundation

public enum RecordEventType: UInt8, Sendable {
    case inputSkip = 1
    case inputOverlap = 2
    case ringOverflow = 3
    case writerLate = 4
    case formatChange = 5
    case configChange = 6
    case deviceOverload = 7
    case clockReset = 8
    case writeFailed = 9

    public var jsonName: String {
        switch self {
        case .inputSkip: return "inputSkip"
        case .inputOverlap: return "inputOverlap"
        case .ringOverflow: return "ringOverflow"
        case .writerLate: return "writerLate"
        case .formatChange: return "formatChange"
        case .configChange: return "configChange"
        case .deviceOverload: return "deviceOverload"
        case .clockReset: return "clockReset"
        case .writeFailed: return "writeFailed"
        }
    }
}

public struct RecordArmedChannel: Sendable {
    public var voiceIndex: Int
    public var speakerNumber: Int
    public var hwChannel: Int
    public var file: String
    public var renameWhenDone: Bool

    public init(voiceIndex: Int, speakerNumber: Int, hwChannel: Int, file: String, renameWhenDone: Bool) {
        self.voiceIndex = voiceIndex
        self.speakerNumber = speakerNumber
        self.hwChannel = hwChannel
        self.file = file
        self.renameWhenDone = renameWhenDone
    }
}

public struct RecordLogHeader: Sendable {
    public var startedAt: Date
    public var sampleRate: Double
    public var inputDeviceUID: String
    public var inputDeviceName: String
    public var outputDeviceName: String
    public var inputNominalRate: Double
    public var outputNominalRate: Double
    public var clockDomainsDiffer: Bool
    public var punchStartFrame: Int
    public var armed: [RecordArmedChannel]

    public init(
        startedAt: Date,
        sampleRate: Double,
        inputDeviceUID: String,
        inputDeviceName: String,
        outputDeviceName: String,
        inputNominalRate: Double,
        outputNominalRate: Double,
        clockDomainsDiffer: Bool,
        punchStartFrame: Int,
        armed: [RecordArmedChannel]
    ) {
        self.startedAt = startedAt
        self.sampleRate = sampleRate
        self.inputDeviceUID = inputDeviceUID
        self.inputDeviceName = inputDeviceName
        self.outputDeviceName = outputDeviceName
        self.inputNominalRate = inputNominalRate
        self.outputNominalRate = outputNominalRate
        self.clockDomainsDiffer = clockDomainsDiffer
        self.punchStartFrame = punchStartFrame
        self.armed = armed
    }
}

public struct RecordTotals: Sendable {
    public var skips: Int = 0
    public var skipFrames: Int = 0
    public var overflowFrames: Int = 0
    public var overflowEvents: Int = 0
    /// Render callback could not take the engine lock. Affects playback only, never the take on disk.
    public var renderLockMisses: Int = 0
    public var clockResets: Int = 0
    public var writeFailures: Int = 0
    /// Discontinuities in the take itself (shown red in the UI).
    public var dropouts: Int { skips + overflowEvents }
    public init() {}
}

struct RecordEventPOD {
    var type: UInt8
    var detail: UInt8
    var frame: UInt64
    var length: UInt64
}

struct RecordedEvent {
    var type: RecordEventType
    var detail: UInt8
    var frame: UInt64
    var length: UInt64
}

/// In-memory take log. The producer pushes POD events; the writer thread drains and owns the list.
final class RecordLog: @unchecked Sendable {
    let header: RecordLogHeader
    private let capacity = 4096
    private let mask: UInt64 = 4095
    private let slots: UnsafeMutablePointer<RecordEventPOD>
    private let writeIndex: PPAtomicU64
    private let readIndex: PPAtomicU64
    private(set) var dropped: Int = 0
    private var events: [RecordedEvent] = []
    var framesWritten: UInt64 = 0
    var totals = RecordTotals()

    init(header: RecordLogHeader) {
        self.header = header
        slots = .allocate(capacity: capacity)
        slots.initialize(repeating: RecordEventPOD(type: 0, detail: 0, frame: 0, length: 0), count: capacity)
        writeIndex = PPAtomicU64(0)
        readIndex = PPAtomicU64(0)
        events.reserveCapacity(256)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    func push(type: RecordEventType, frame: UInt64, length: UInt64, detail: UInt8 = 0) {
        let w = writeIndex.load()
        let r = readIndex.load()
        if w &- r >= UInt64(capacity) {
            dropped += 1
            return
        }
        slots[Int(w & mask)] = RecordEventPOD(type: type.rawValue, detail: detail, frame: frame, length: length)
        writeIndex.store(w &+ 1)
    }

    /// Writer thread. Moves queued POD events onto the owned list and folds totals.
    func drain() {
        while true {
            let r = readIndex.load()
            let w = writeIndex.load()
            if r == w { break }
            let pod = slots[Int(r & mask)]
            readIndex.store(r &+ 1)
            guard let type = RecordEventType(rawValue: pod.type) else { continue }
            let event = RecordedEvent(type: type, detail: pod.detail, frame: pod.frame, length: pod.length)
            events.append(event)
            switch type {
            case .inputSkip:
                totals.skips += 1
                totals.skipFrames += Int(event.length)
            case .ringOverflow:
                totals.overflowEvents += 1
                totals.overflowFrames += Int(event.length)
            case .clockReset:
                totals.clockResets += 1
            default:
                break
            }
        }
    }

    func appendDirect(type: RecordEventType, frame: UInt64, length: UInt64, detail: UInt8 = 0) {
        if type == .writeFailed { totals.writeFailures += 1 }
        events.append(RecordedEvent(type: type, detail: detail, frame: frame, length: length))
    }

    func writeFile(in folder: URL, renderLockMisses: Int) throws {
        totals.renderLockMisses = renderLockMisses
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var eventJSON: [[String: Any]] = []
        eventJSON.reserveCapacity(events.count)
        let rate = header.sampleRate
        for event in events {
            let detail: String
            switch event.detail {
            case 1: detail = "resample"
            case 2: detail = "invalid sample time"
            case 3: detail = "input clock jumped backward; re-anchored"
            case 4: detail = "input clock jumped forward more than 10 s; re-anchored without filling"
            case 5: detail = "input channel count changed; buffer not recorded"
            case 6: detail = "disk write failed (disk full?)"
            case 7: detail = "input clock moved after a configuration change; re-anchored"
            default: detail = ""
            }
            eventJSON.append([
                "type": event.type.jsonName,
                "frame": Int(event.frame),
                "seconds": rate > 0 ? Double(event.frame) / rate : 0,
                "lengthFrames": Int(event.length),
                "detail": detail,
            ])
        }
        let armedJSON: [[String: Any]] = header.armed.map {
            [
                "voiceIndex": $0.voiceIndex,
                "speakerNumber": $0.speakerNumber,
                "hwChannel": $0.hwChannel,
                "file": $0.file,
            ]
        }
        let take: [String: Any] = [
            "startedAt": iso.string(from: header.startedAt),
            "sampleRate": header.sampleRate,
            "inputDeviceUID": header.inputDeviceUID,
            "inputDeviceName": header.inputDeviceName,
            "outputDeviceName": header.outputDeviceName,
            "inputNominalRate": header.inputNominalRate,
            "outputNominalRate": header.outputNominalRate,
            "clockDomainsDiffer": header.clockDomainsDiffer,
            "punchStartFrame": header.punchStartFrame,
            "framesWritten": Int(framesWritten),
            "armed": armedJSON,
            "events": eventJSON,
            "totals": [
                "skips": totals.skips,
                "skipFrames": totals.skipFrames,
                "overflowFrames": totals.overflowFrames,
                "overflowEvents": totals.overflowEvents,
                "clockResets": totals.clockResets,
                "writeFailures": totals.writeFailures,
                "renderLockMisses": totals.renderLockMisses,
            ],
        ]
        let url = folder.appendingPathComponent("record-log.json")
        var takes: [Any] = []
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = obj["takes"] as? [Any] {
            takes = existing
        }
        takes.append(take)
        let root: [String: Any] = ["takes": takes]
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }
}
