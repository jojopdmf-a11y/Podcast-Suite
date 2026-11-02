import Darwin
import Foundation
import RecordCore

private let sampleRate = 48_000.0
private let channelCount = 8

private func patternFloat(channel: Int, frame: Int) -> Float {
    let mixed = (frame &* 7 &+ channel &* 1009) & 0x7FFF
    let centered = Int16(truncatingIfNeeded: mixed) - 16384
    return Float(centered) / 32768
}

private func expectedInt16(channel: Int, frame: Int) -> Int16 {
    let x = patternFloat(channel: channel, frame: frame)
    let clipped = max(-1 as Float, min(1, x))
    return Int16((clipped * 32767).rounded())
}

private func readU16(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func readU32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

private struct WavInfo {
    var sampleRate: UInt32
    var channels: UInt16
    var bits: UInt16
    var dataSize: UInt32
    var fileSize: Int
}

private func readWavInfo(_ url: URL) throws -> (WavInfo, FileHandle) {
    let handle = try FileHandle(forReadingFrom: url)
    let header = try handle.read(upToCount: 44) ?? Data()
    guard header.count >= 44 else {
        try handle.close()
        throw TestError("short header \(url.lastPathComponent)")
    }
    let info = try header.withUnsafeBytes { raw -> WavInfo in
        guard String(bytes: raw[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: raw[8..<12], encoding: .ascii) == "WAVE",
              String(bytes: raw[36..<40], encoding: .ascii) == "data"
        else { throw TestError("bad wav header \(url.lastPathComponent)") }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return WavInfo(
            sampleRate: readU32(raw, 24),
            channels: readU16(raw, 22),
            bits: readU16(raw, 34),
            dataSize: readU32(raw, 40),
            fileSize: fileSize
        )
    }
    return (info, handle)
}

private struct TestError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private final class StallPlan: @unchecked Sendable {
    private var next = 0
    private let marks: [(UInt64, Double)]
    init(marks: [(UInt64, Double)]) { self.marks = marks }
    func check(_ frames: UInt64) {
        while next < marks.count, frames >= marks[next].0 {
            let seconds = marks[next].1
            next += 1
            if seconds > 0 {
                Thread.sleep(forTimeInterval: seconds)
            }
        }
    }
}

private func makeSession(folder: URL, stalls: StallPlan?) throws -> RecordSession {
    var armed: [RecordArmedChannel] = []
    for ch in 0..<channelCount {
        armed.append(RecordArmedChannel(
            voiceIndex: ch,
            speakerNumber: ch + 1,
            hwChannel: ch,
            file: "Speaker_\(ch + 1).recording.wav",
            renameWhenDone: false
        ))
    }
    let header = RecordLogHeader(
        startedAt: Date(),
        sampleRate: sampleRate,
        inputDeviceUID: "stress",
        inputDeviceName: "stress",
        outputDeviceName: "stress",
        inputNominalRate: sampleRate,
        outputNominalRate: sampleRate,
        clockDomainsDiffer: false,
        punchStartFrame: 0,
        armed: armed
    )
    let onStall: (@Sendable (UInt64) -> Void)?
    if let plan = stalls {
        onStall = { @Sendable frames in
            plan.check(frames)
        }
    } else {
        onStall = nil
    }
    return try RecordSession(
        folder: folder,
        sampleRate: sampleRate,
        inputSampleRate: sampleRate,
        punchStartFrame: 0,
        baseFrameCount: 0,
        armed: armed,
        hwChannels: channelCount,
        header: header,
        onDropouts: nil,
        onStall: onStall
    )
}

private func produce(session: RecordSession, totalFrames: Int, skipAt: Int?) {
    let cap = 4096
    var buffer = [Float](repeating: 0, count: cap * channelCount)
    var rng: UInt64 = 0xC0FFEE
    var source = 0
    var skipInserted = 0
    while source < totalFrames {
        rng = rng &* 6364136223846793005 &+ 1
        var block = 512 + Int(rng % 3585)
        block = min(block, totalFrames - source)
        if let skipAt, source < skipAt, source + block > skipAt {
            block = skipAt - source
        }
        for f in 0..<block {
            let frame = source + f
            for ch in 0..<channelCount {
                buffer[f * channelCount + ch] = patternFloat(channel: ch, frame: frame)
            }
        }
        let injecting = skipAt != nil && source == skipAt && skipInserted == 0
        let extra = injecting ? 480 : 0
        while session.writableFrames < block + extra {
            Thread.sleep(forTimeInterval: 0.0002)
        }
        var sampleTime = Int64(source + skipInserted)
        if injecting {
            sampleTime += 480
            skipInserted = 480
        }
        buffer.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            session.ingest(interleaved: base, frames: block, sampleTime: sampleTime, sampleTimeValid: true)
        }
        source += block
    }
}

private func verifyTake(folder: URL, totalSourceFrames: Int, skipAt: Int?) throws {
    let skip = skipAt ?? -1
    let skipLen = skipAt == nil ? 0 : 480
    let expectedFrames = totalSourceFrames + skipLen
    for ch in 0..<channelCount {
        let url = folder.appendingPathComponent("Speaker_\(ch + 1).recording.wav")
        let (info, handle) = try readWavInfo(url)
        if info.channels != 1 || info.bits != 16 || info.sampleRate != 48_000 {
            throw TestError("header format ch=\(ch) rate=\(info.sampleRate) bits=\(info.bits) channels=\(info.channels)")
        }
        let dataSize = Int(info.dataSize)
        if dataSize > info.fileSize - 44 {
            throw TestError("data size \(dataSize) past end of \(url.lastPathComponent) (\(info.fileSize))")
        }
        if info.fileSize != 44 + dataSize {
            throw TestError("\(url.lastPathComponent) size \(info.fileSize) != 44+\(dataSize)")
        }
        let frames = dataSize / 2
        if frames != expectedFrames {
            throw TestError("\(url.lastPathComponent) frames \(frames) != \(expectedFrames)")
        }
        var frame = 0
        var mismatches = 0
        let chunkFrames = 16_384
        var chunk = [UInt8](repeating: 0, count: chunkFrames * 2)
        while frame < frames {
            let n = min(chunkFrames, frames - frame)
            let got = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(handle.fileDescriptor, base, n * 2)
            }
            if got != n * 2 {
                throw TestError("short read \(url.lastPathComponent) at \(frame)")
            }
            for i in 0..<n {
                let lo = UInt16(chunk[i * 2])
                let hi = UInt16(chunk[i * 2 + 1])
                let sample = Int16(bitPattern: lo | (hi << 8))
                let out = frame + i
                let expect: Int16
                if skipAt != nil, out >= skip, out < skip + skipLen {
                    expect = 0
                } else if skipAt != nil, out >= skip + skipLen {
                    expect = expectedInt16(channel: ch, frame: out - skipLen)
                } else {
                    expect = expectedInt16(channel: ch, frame: out)
                }
                if sample != expect {
                    mismatches += 1
                    if mismatches <= 3 {
                        print("FAIL \(url.lastPathComponent) frame \(out) got \(sample) expect \(expect)")
                    }
                }
            }
            frame += n
        }
        try handle.close()
        if mismatches != 0 {
            throw TestError("\(url.lastPathComponent) \(mismatches) mismatched samples")
        }
    }
    let logURL = folder.appendingPathComponent("record-log.json")
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: logURL)) as? [String: Any]
    let takes = obj?["takes"] as? [[String: Any]] ?? []
    guard let take = takes.last else { throw TestError("record-log has no takes") }
    let totals = take["totals"] as? [String: Any] ?? [:]
    let skips = (totals["skips"] as? NSNumber)?.intValue ?? (totals["skips"] as? Int)
    let overflow = (totals["overflowFrames"] as? NSNumber)?.intValue ?? (totals["overflowFrames"] as? Int)
    let written = (take["framesWritten"] as? NSNumber)?.intValue ?? (take["framesWritten"] as? Int)
    if skips != (skipAt == nil ? 0 : 1) || overflow != 0 || written != expectedFrames {
        throw TestError("log skips=\(skips ?? -1) overflow=\(overflow ?? -1) written=\(written ?? -1) expectedFrames=\(expectedFrames)")
    }
    if let skipAt {
        let events = take["events"] as? [[String: Any]] ?? []
        let hit = events.contains { ev in
            (ev["type"] as? String) == "inputSkip"
                && ((ev["frame"] as? NSNumber)?.intValue ?? (ev["frame"] as? Int)) == skipAt
                && ((ev["lengthFrames"] as? NSNumber)?.intValue ?? (ev["lengthFrames"] as? Int)) == 480
        }
        if !hit {
            throw TestError("inputSkip not logged at frame \(skipAt)")
        }
    }
    // RIFF chunk size matches the data size.
    for ch in 0..<channelCount {
        let url = folder.appendingPathComponent("Speaker_\(ch + 1).recording.wav")
        let handle = try FileHandle(forReadingFrom: url)
        let head = try handle.read(upToCount: 44) ?? Data()
        try handle.close()
        guard head.count == 44 else { throw TestError("short header") }
        let raw = [UInt8](head)
        let chunk = UInt32(raw[4]) | (UInt32(raw[5]) << 8) | (UInt32(raw[6]) << 16) | (UInt32(raw[7]) << 24)
        let dataSize = UInt32(raw[40]) | (UInt32(raw[41]) << 8) | (UInt32(raw[42]) << 16) | (UInt32(raw[43]) << 24)
        if chunk != dataSize &+ 36 {
            throw TestError("RIFF size \(chunk) != 36+\(dataSize)")
        }
    }
}

private func runLabeled(name: String, frames: Int, skipAt: Int?, stalls: Bool) throws -> RecordTotals {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordStress-\(name)-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let marks: [(UInt64, Double)]
    if stalls {
        let five = UInt64(5 * 60 * 48_000)
        marks = (1...9).map { i in
            (five * UInt64(i), i == 5 ? 2.5 : 0.6)
        }
    } else {
        marks = []
    }
    let plan = StallPlan(marks: marks)
    let session = try makeSession(folder: folder, stalls: stalls ? plan : nil)
    produce(session: session, totalFrames: frames, skipAt: skipAt)
    let totals = try session.finish()
    try verifyTake(folder: folder, totalSourceFrames: frames, skipAt: skipAt)
    print("\(name): frames=\(frames + (skipAt == nil ? 0 : 480)) skips=\(totals.skips) overflow=\(totals.overflowFrames) lockMisses=\(totals.renderLockMisses)")
    return totals
}

// MARK: - Real-time paced producer (never waits, like the real input tap)

private func produceRealtime(session: RecordSession, totalFrames: Int) {
    let block = 1024
    var buffer = [Float](repeating: 0, count: block * channelCount)
    let start = DispatchTime.now().uptimeNanoseconds
    var source = 0
    while source < totalFrames {
        let n = min(block, totalFrames - source)
        // Pace to wall clock: block k is due at k * block / 48 kHz.
        let due = start + UInt64(Double(source) / sampleRate * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        if due > now { usleep(useconds_t((due - now) / 1000)) }
        for f in 0..<n {
            for ch in 0..<channelCount {
                buffer[f * channelCount + ch] = patternFloat(channel: ch, frame: source + f)
            }
        }
        buffer.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            session.ingest(interleaved: base, frames: n, sampleTime: Int64(source), sampleTimeValid: true)
        }
        source += n
    }
}

private func intValue(_ any: Any?) -> Int? {
    (any as? NSNumber)?.intValue ?? (any as? Int)
}

/// 30 s, 8 ch, paced in real time. Writer stalls 2.5 s (must be absorbed: no overflow) and later
/// longer than the whole ring (must give exactly one ringOverflow with zeros at exactly that spot).
private func runRealtime() throws -> (overflowFrames: Int, overflowAt: Int, ringSeconds: Double) {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordStress-realtime-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let total = 30 * 48_000
    let ringFrames = SPSCFloatRing(sampleRate: sampleRate, channels: 1).capacityFrames
    let ringSeconds = Double(ringFrames) / sampleRate
    // The ring is the next power of two >= 4 s (262,144 frames = 5.46 s at 48 kHz), so the
    // overflow stall must be longer than that.
    let longStall = ringSeconds + 1.5
    let plan = StallPlan(marks: [(UInt64(4 * 48_000), 2.5), (UInt64(12 * 48_000), longStall)])
    let session = try makeSession(folder: folder, stalls: plan)
    // Stall 1 alone: by 9 s of input the writer must have caught up with no overflow.
    produceRealtime(session: session, totalFrames: total)
    let totals = try session.finish()

    let logURL = folder.appendingPathComponent("record-log.json")
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: logURL)) as? [String: Any]
    guard let take = (obj?["takes"] as? [[String: Any]])?.last else { throw TestError("realtime: no take in log") }
    let events = take["events"] as? [[String: Any]] ?? []
    let overflows = events.filter { ($0["type"] as? String) == "ringOverflow" }
    if overflows.count != 1 {
        throw TestError("realtime: expected exactly 1 ringOverflow, got \(overflows.count)")
    }
    let at = intValue(overflows[0]["frame"]) ?? -1
    let len = intValue(overflows[0]["lengthFrames"]) ?? -1
    // Must come from the long stall (writer stalls at 12 s of disk), never from the 2.5 s one.
    if at < 12 * 48_000 || at > total || len <= 0 {
        throw TestError("realtime: overflow at \(at) len \(len) is not where the long stall is")
    }
    if totals.overflowFrames != len || totals.overflowEvents != 1 || totals.skips != 0 || totals.dropouts != 1 {
        throw TestError("realtime: totals overflowFrames=\(totals.overflowFrames) events=\(totals.overflowEvents) skips=\(totals.skips) dropouts=\(totals.dropouts) (event len \(len))")
    }
    if intValue(take["framesWritten"]) != total {
        throw TestError("realtime: framesWritten \(intValue(take["framesWritten"]) ?? -1) != \(total)")
    }
    for ch in 0..<channelCount {
        let url = folder.appendingPathComponent("Speaker_\(ch + 1).recording.wav")
        let (info, handle) = try readWavInfo(url)
        defer { try? handle.close() }
        let frames = Int(info.dataSize) / 2
        if frames != total || info.fileSize != 44 + Int(info.dataSize) {
            throw TestError("realtime: \(url.lastPathComponent) frames \(frames) != \(total)")
        }
        guard let data = try handle.readToEnd(), data.count == frames * 2 else {
            throw TestError("realtime: short read \(url.lastPathComponent)")
        }
        var bad = 0
        data.withUnsafeBytes { raw in
            for f in 0..<frames {
                let sample = Int16(bitPattern: UInt16(raw[f * 2]) | (UInt16(raw[f * 2 + 1]) << 8))
                let expect: Int16 = (f >= at && f < at + len) ? 0 : expectedInt16(channel: ch, frame: f)
                if sample != expect {
                    bad += 1
                    if bad <= 3 { print("FAIL realtime \(url.lastPathComponent) frame \(f) got \(sample) expect \(expect)") }
                }
            }
        }
        if bad != 0 { throw TestError("realtime: \(url.lastPathComponent) \(bad) mismatched samples") }
    }
    print("realtime: frames=\(total) stall2.5s overflow=0 stall\(String(format: "%.2f", longStall))s ringOverflow=1 at \(at) len=\(len) (ring \(String(format: "%.2f", ringSeconds))s) zerosPlaced=ok")
    return (len, at, ringSeconds)
}

/// Clock jumps: backward > 1 s must re-anchor (keep recording), forward > 10 s must re-anchor without silence.
private func runClockJumps() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordStress-clock-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = try makeSession(folder: folder, stalls: nil)
    let block = 4800
    var buffer = [Float](repeating: 0.25, count: block * channelCount)
    var written = 0
    func feed(_ times: [Int64]) {
        for t in times {
            buffer.withUnsafeBufferPointer { ptr in
                session.ingest(interleaved: ptr.baseAddress!, frames: block, sampleTime: t, sampleTimeValid: true)
            }
            written += block
        }
    }
    feed((0..<20).map { Int64($0 * block) })            // 2 s
    feed((0..<10).map { Int64($0 * block) })            // clock reset to 0 (backward 2 s)
    feed((0..<10).map { Int64(48_000 * 60 + $0 * block) }) // forward ~59 s
    let totals = try session.finish()
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("record-log.json"))) as? [String: Any]
    let take = (obj?["takes"] as? [[String: Any]])?.last ?? [:]
    let resets = (take["events"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String) == "clockReset" }
    let fw = intValue(take["framesWritten"]) ?? -1
    if resets.count != 2 || fw != written || totals.clockResets != 2 || totals.skips != 0 || totals.dropouts != 0 {
        throw TestError("clock: resets=\(resets.count) framesWritten=\(fw) expected=\(written) skips=\(totals.skips)")
    }
    print("clock: backward+forward jumps re-anchored (2 clockReset), framesWritten=\(fw), no silence inserted")
}

private func runCrashChild(folder: URL) throws {
    let session = try makeSession(folder: folder, stalls: nil)
    print("READY")
    fflush(stdout)
    produce(session: session, totalFrames: 60 * 48_000, skipAt: nil)
    Thread.sleep(forTimeInterval: 30)
    _ = try session.finish()
}

private func runCrashTest() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordStress-crash-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    proc.arguments = ["--crash-child", folder.path]
    let pipe = Pipe()
    proc.standardOutput = pipe
    try proc.run()
    var sawReady = false
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        let data = pipe.fileHandleForReading.availableData
        if let text = String(data: data, encoding: .utf8), text.contains("READY") {
            sawReady = true
            break
        }
        if data.isEmpty { break }
    }
    if !sawReady {
        proc.terminate()
        throw TestError("crash child did not become ready")
    }
    Thread.sleep(forTimeInterval: 1.0)
    kill(proc.processIdentifier, SIGKILL)
    proc.waitUntilExit()
    let url = folder.appendingPathComponent("Speaker_1.recording.wav")
    let (info, handle) = try readWavInfo(url)
    if Int(info.dataSize) > info.fileSize - 44 {
        throw TestError("crash data size \(info.dataSize) > file \(info.fileSize)")
    }
    let pcmBytes = info.fileSize - 44
    let gap = pcmBytes - Int(info.dataSize)
    let oneSecond = 48_000 * 2
    if gap < 0 || gap > oneSecond {
        throw TestError("crash header is \(gap) bytes behind the file (limit \(oneSecond))")
    }
    let frames = Int(info.dataSize) / 2
    if frames <= 0 {
        throw TestError("crash file has no committed frames")
    }
    var frame = 0
    let chunkFrames = 8192
    var chunk = [UInt8](repeating: 0, count: chunkFrames * 2)
    while frame < frames {
        let n = min(chunkFrames, frames - frame)
        let got = chunk.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Darwin.read(handle.fileDescriptor, base, n * 2)
        }
        if got != n * 2 { throw TestError("crash short read at \(frame)") }
        for i in 0..<n {
            let sample = Int16(bitPattern: UInt16(chunk[i * 2]) | (UInt16(chunk[i * 2 + 1]) << 8))
            let expect = expectedInt16(channel: 0, frame: frame + i)
            if sample != expect {
                throw TestError("crash frame \(frame + i) got \(sample) expect \(expect)")
            }
        }
        frame += n
    }
    try handle.close()
    print("crash: frames=\(frames) headerGapBytes=\(gap)")
}

private func fail(_ error: Error) -> Never {
    print("FAIL \(error)")
    exit(1)
}

if CommandLine.arguments.dropFirst().first == "--crash-child" {
    let path = CommandLine.arguments.dropFirst(2).first ?? ""
    do {
        try runCrashChild(folder: URL(fileURLWithPath: path))
    } catch {
        print("CHILD FAIL \(error)")
        exit(1)
    }
    exit(0)
}

let started = Date()
do {
    _ = try runLabeled(name: "preflight", frames: 48_000, skipAt: 12_000, stalls: false)
    _ = try runLabeled(name: "stress", frames: 132_480_000, skipAt: 5_000_000, stalls: true)
    try runCrashTest()
    try runClockJumps()
    _ = try runRealtime()
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "PASS %.1fs", elapsed))
    exit(0)
} catch {
    fail(error)
}
