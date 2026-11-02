import Foundation

public struct RecordIngestPlan: Sendable {
    public var dropInputFrames: Int
    public var zeroSessionFrames: Int
    public var ignore: Bool
}

/// One take: lock-free ring, per-strip WAV writers, peak caches, and the writer thread.
public final class RecordSession: @unchecked Sendable {
    public let folder: URL
    public let sampleRate: Double
    public let inputSampleRate: Double
    public let channels: Int
    public let punchStartFrame: Int
    public let baseFrameCount: Int
    public let armed: [RecordArmedChannel]
    public let ring: SPSCFloatRing

    public var framesCommitted: UInt64 { runtime.committed.load() }
    public var writableFrames: Int { ring.availableToWrite }

    private let runtime: RecordRuntime
    private let thread: Thread
    private var didFinish = false
    private var cachedTotals = RecordTotals()
    private var finishError: Error?
    private let finishGate = NSLock()

    public init(
        folder: URL,
        sampleRate: Double,
        inputSampleRate: Double,
        punchStartFrame: Int,
        baseFrameCount: Int,
        armed: [RecordArmedChannel],
        hwChannels: Int,
        header: RecordLogHeader,
        onDropouts: (@Sendable (Int) -> Void)? = nil,
        onStall: (@Sendable (UInt64) -> Void)? = nil
    ) throws {
        let ch = max(1, hwChannels)
        self.folder = folder
        self.sampleRate = sampleRate
        self.inputSampleRate = inputSampleRate > 0 ? inputSampleRate : sampleRate
        self.channels = ch
        self.punchStartFrame = punchStartFrame
        self.baseFrameCount = baseFrameCount
        self.armed = armed
        let ring = SPSCFloatRing(sampleRate: sampleRate, channels: ch)
        self.ring = ring
        var writers: [RecordWAVWriter] = []
        writers.reserveCapacity(armed.count)
        var peaks: [RecordPeakCache] = []
        peaks.reserveCapacity(armed.count)
        for item in armed {
            let url = folder.appendingPathComponent(item.file)
            writers.append(try RecordWAVWriter(url: url, sampleRate: sampleRate))
            peaks.append(RecordPeakCache(sampleRate: sampleRate))
        }
        let runtime = RecordRuntime(
            ring: ring,
            channels: ch,
            sampleRate: sampleRate,
            inputSampleRate: self.inputSampleRate,
            armed: armed,
            writers: writers,
            peaks: peaks,
            log: RecordLog(header: header),
            onDropouts: onDropouts,
            onStall: onStall
        )
        self.runtime = runtime
        let thread = Thread { [runtime] in
            runtime.run()
        }
        thread.qualityOfService = .userInitiated
        thread.name = "PodProducer.RecordWriter"
        self.thread = thread
        thread.start()
    }

    deinit {
        if !didFinish {
            runtime.stopFlag.store(1)
            runtime.wake.signal()
            runtime.done.wait()
            didFinish = true
        }
    }

    public func isArmed(voiceIndex: Int) -> Bool {
        armed.contains { $0.voiceIndex == voiceIndex }
    }

    public func livePeak(voiceIndex: Int, from takeStart: Int, to takeEnd: Int) -> Float {
        runtime.peak(voiceIndex: voiceIndex, from: takeStart, to: takeEnd)
    }

    public func beginInputBuffer(sampleTime: Int64, sampleTimeValid: Bool, inputFrames: Int) -> RecordIngestPlan {
        runtime.beginInputBuffer(sampleTime: sampleTime, sampleTimeValid: sampleTimeValid, inputFrames: inputFrames)
    }

    public func writeTimelineZeros(_ frames: Int) {
        runtime.writeZeros(frames)
    }

    public func writeTimelineAudio(_ src: UnsafePointer<Float>, frames: Int) {
        runtime.writeAudio(src, frames: frames)
    }

    public func noteFormatChangeResample() {
        runtime.noteFormatChangeResample()
    }

    public func noteConfigChange() {
        runtime.noteConfigChange()
    }

    /// Tap thread: the input buffer's channel count no longer matches the take. Logged once per take.
    public func noteChannelCountChange(channels: Int) {
        runtime.noteChannelCountChange(channels: channels)
    }

    public func addRenderLockMiss() {
        runtime.renderMisses.fetchAdd(1)
    }

    public func addRenderLockMisses(_ n: UInt64) {
        if n > 0 { runtime.renderMisses.fetchAdd(n) }
    }

    public func noteDeviceOverload() {
        runtime.noteDeviceOverload()
    }

    /// Matching-rate convenience used by the stress tool and the no-resample tap path.
    public func ingest(interleaved: UnsafePointer<Float>, frames: Int, sampleTime: Int64, sampleTimeValid: Bool) {
        let plan = beginInputBuffer(sampleTime: sampleTime, sampleTimeValid: sampleTimeValid, inputFrames: frames)
        if plan.ignore { return }
        if plan.zeroSessionFrames > 0 {
            writeTimelineZeros(plan.zeroSessionFrames)
        }
        let drop = min(max(0, plan.dropInputFrames), frames)
        let keep = frames - drop
        if keep > 0 {
            writeTimelineAudio(interleaved.advanced(by: drop * channels), frames: keep)
        }
    }

    public func finish() throws -> RecordTotals {
        finishGate.lock()
        defer { finishGate.unlock() }
        if didFinish {
            if let finishError { throw finishError }
            return cachedTotals
        }
        // The tap is removed before finish(), so the producer side is idle here.
        runtime.flushOverflowRun()
        runtime.stopFlag.store(1)
        runtime.wake.signal()
        runtime.done.wait()
        didFinish = true
        cachedTotals = runtime.totals
        finishError = runtime.writeError
        if let finishError { throw finishError }
        return cachedTotals
    }

    /// Totals from the last `finish()`, including when the log write threw.
    public func finishedTotals() -> RecordTotals {
        finishGate.lock()
        defer { finishGate.unlock() }
        return cachedTotals
    }
}

private final class GapQueue: @unchecked Sendable {
    struct Gap {
        var after: UInt64
        var count: UInt64
    }

    private let cap = 4096
    private let mask: UInt64 = 4095
    private let slots: UnsafeMutablePointer<Gap>
    private let writeIndex: PPAtomicU64
    private let readIndex: PPAtomicU64

    init() {
        slots = .allocate(capacity: cap)
        slots.initialize(repeating: Gap(after: 0, count: 0), count: cap)
        writeIndex = PPAtomicU64(0)
        readIndex = PPAtomicU64(0)
    }

    deinit {
        slots.deinitialize(count: cap)
        slots.deallocate()
    }

    func push(after: UInt64, count: UInt64) -> Bool {
        let w = writeIndex.load()
        let r = readIndex.load()
        if w &- r >= UInt64(cap) { return false }
        slots[Int(w & mask)] = Gap(after: after, count: count)
        writeIndex.store(w &+ 1)
        return true
    }

    func peek() -> Gap? {
        let r = readIndex.load()
        let w = writeIndex.load()
        if r == w { return nil }
        return slots[Int(r & mask)]
    }

    func pop() {
        let r = readIndex.load()
        readIndex.store(r &+ 1)
    }

    var isEmpty: Bool { peek() == nil }
}

private final class RecordRuntime: @unchecked Sendable {
    let ring: SPSCFloatRing
    let channels: Int
    let sampleRate: Double
    let inputSampleRate: Double
    let armed: [RecordArmedChannel]
    let writers: [RecordWAVWriter]
    let peaks: [RecordPeakCache]
    let log: RecordLog
    let committed: PPAtomicU64
    let stopFlag: PPAtomicU64
    let renderMisses: PPAtomicU64
    let wake: DispatchSemaphore
    let done: DispatchSemaphore
    let onDropouts: (@Sendable (Int) -> Void)?
    let onStall: (@Sendable (UInt64) -> Void)?

    private let gaps = GapQueue()
    private let pendingZeros = PPAtomicU64(0)
    private let configCount = PPAtomicU64(0)
    private let overloadCount = PPAtomicU64(0)
    private let formatOnce = PPAtomicU64(0)
    private let zeroScratch: UnsafeMutablePointer<Float>
    private let zeroFrames = 8192
    private let audioScratch: UnsafeMutablePointer<Float>
    private let monoScratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 8192
    private var timeline: UInt64 = 0
    private var audioRead: UInt64 = 0
    private var diskFrames: UInt64 = 0
    private var insertedZeros: UInt64 = 0
    private var expected: Int64 = 0
    private var timelineStarted = false
    private var clockValid = true
    private var loggedInvalid = false
    private var wasLate = false
    private var loggedConfig: UInt64 = 0
    private var loggedOverload: UInt64 = 0
    private var lastNotify: UInt64 = 0
    private var peakByVoice: [Int: RecordPeakCache] = [:]
    // Producer (tap) side only.
    private var anchoredConfig: UInt64 = 0
    private var overflowRun: UInt64 = 0
    private var overflowRunAfter: UInt64 = 0
    private var overflowRunFrame: UInt64 = 0
    private let channelOnce = PPAtomicU64(0)
    private let overflowRunsStarted = PPAtomicU64(0)
    // Writer side only.
    private var writeFailReported: [Bool]
    private(set) var totals = RecordTotals()
    private(set) var writeError: Error?

    init(
        ring: SPSCFloatRing,
        channels: Int,
        sampleRate: Double,
        inputSampleRate: Double,
        armed: [RecordArmedChannel],
        writers: [RecordWAVWriter],
        peaks: [RecordPeakCache],
        log: RecordLog,
        onDropouts: (@Sendable (Int) -> Void)?,
        onStall: (@Sendable (UInt64) -> Void)?
    ) {
        self.ring = ring
        self.channels = channels
        self.sampleRate = sampleRate
        self.inputSampleRate = inputSampleRate
        self.armed = armed
        self.writers = writers
        self.peaks = peaks
        self.log = log
        self.onDropouts = onDropouts
        self.onStall = onStall
        writeFailReported = [Bool](repeating: false, count: writers.count)
        committed = PPAtomicU64(0)
        stopFlag = PPAtomicU64(0)
        renderMisses = PPAtomicU64(0)
        wake = DispatchSemaphore(value: 0)
        done = DispatchSemaphore(value: 0)
        zeroScratch = .allocate(capacity: zeroFrames * channels)
        zeroScratch.initialize(repeating: 0, count: zeroFrames * channels)
        audioScratch = .allocate(capacity: scratchFrames * channels)
        audioScratch.initialize(repeating: 0, count: scratchFrames * channels)
        monoScratch = .allocate(capacity: scratchFrames)
        monoScratch.initialize(repeating: 0, count: scratchFrames)
        for (item, peak) in zip(armed, peaks) {
            peakByVoice[item.voiceIndex] = peak
        }
    }

    deinit {
        zeroScratch.deinitialize(count: zeroFrames * channels)
        zeroScratch.deallocate()
        audioScratch.deinitialize(count: scratchFrames * channels)
        audioScratch.deallocate()
        monoScratch.deinitialize(count: scratchFrames)
        monoScratch.deallocate()
    }

    func peak(voiceIndex: Int, from takeStart: Int, to takeEnd: Int) -> Float {
        guard let cache = peakByVoice[voiceIndex], takeEnd > takeStart, takeStart >= 0 else { return 0 }
        var peak: Float = 0
        cache.withPublished { ptr, count in
            if count <= 0 { return }
            let b0 = takeStart / RecordPeakCache.framesPerBin
            let b1 = (takeEnd - 1) / RecordPeakCache.framesPerBin
            if b0 >= count { return }
            let last = min(count - 1, b1)
            if last < b0 { return }
            for b in b0...last {
                peak = max(peak, ptr[b])
            }
        }
        return peak
    }

    func beginInputBuffer(sampleTime: Int64, sampleTimeValid: Bool, inputFrames: Int) -> RecordIngestPlan {
        if inputFrames <= 0 {
            return RecordIngestPlan(dropInputFrames: 0, zeroSessionFrames: 0, ignore: true)
        }
        if !timelineStarted {
            timelineStarted = true
            if sampleTimeValid {
                expected = sampleTime
                clockValid = true
            } else {
                clockValid = false
                noteInvalidClock()
                return RecordIngestPlan(dropInputFrames: 0, zeroSessionFrames: 0, ignore: false)
            }
        }
        if !sampleTimeValid || !clockValid {
            noteInvalidClock()
            clockValid = false
            return RecordIngestPlan(dropInputFrames: 0, zeroSessionFrames: 0, ignore: false)
        }
        let configs = configCount.load()
        if configs != anchoredConfig {
            anchoredConfig = configs
            if sampleTime != expected {
                log.push(type: .clockReset, frame: timeline, length: UInt64(sessionFrames(fromInput: abs(sampleTime - expected))), detail: 7)
                expected = sampleTime + Int64(inputFrames)
                return RecordIngestPlan(dropInputFrames: 0, zeroSessionFrames: 0, ignore: false)
            }
        }
        let oneSecond = Int64(max(1, inputSampleRate.rounded()))
        if expected - sampleTime > oneSecond {
            // Clock went backward (device restart / clock hiccup). Keep recording from here.
            log.push(type: .clockReset, frame: timeline, length: UInt64(sessionFrames(fromInput: expected - sampleTime)), detail: 3)
            expected = sampleTime + Int64(inputFrames)
            return RecordIngestPlan(dropInputFrames: 0, zeroSessionFrames: 0, ignore: false)
        }
        if sampleTime - expected > 10 * oneSecond {
            // Implausible forward jump: don't write minutes of silence.
            log.push(type: .clockReset, frame: timeline, length: UInt64(sessionFrames(fromInput: sampleTime - expected)), detail: 4)
            expected = sampleTime + Int64(inputFrames)
            return RecordIngestPlan(dropInputFrames: 0, zeroSessionFrames: 0, ignore: false)
        }
        if sampleTime > expected {
            let zeros = sessionFrames(fromInput: sampleTime - expected)
            log.push(type: .inputSkip, frame: timeline, length: UInt64(max(0, zeros)))
            expected = sampleTime + Int64(inputFrames)
            return RecordIngestPlan(dropInputFrames: 0, zeroSessionFrames: zeros, ignore: false)
        }
        if sampleTime < expected {
            if sampleTime + Int64(inputFrames) <= expected {
                let dropped = sessionFrames(fromInput: Int64(inputFrames))
                log.push(type: .inputOverlap, frame: timeline, length: UInt64(max(dropped, 0)))
                return RecordIngestPlan(dropInputFrames: inputFrames, zeroSessionFrames: 0, ignore: true)
            }
            let overlapIn = Int(expected - sampleTime)
            let drop = min(inputFrames, max(0, overlapIn))
            log.push(type: .inputOverlap, frame: timeline, length: UInt64(sessionFrames(fromInput: Int64(drop))))
            expected = sampleTime + Int64(inputFrames)
            return RecordIngestPlan(dropInputFrames: drop, zeroSessionFrames: 0, ignore: false)
        }
        expected = sampleTime + Int64(inputFrames)
        return RecordIngestPlan(dropInputFrames: 0, zeroSessionFrames: 0, ignore: false)
    }

    func writeZeros(_ frames: Int) {
        guard frames > 0 else { return }
        var left = frames
        while left > 0 {
            let chunk = min(left, zeroFrames)
            push(zeroScratch, frames: chunk)
            left -= chunk
        }
        publishTimeline()
    }

    func writeAudio(_ src: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        push(src, frames: frames)
        publishTimeline()
    }

    /// Producer side. While the ring is full, missing frames accumulate into ONE overflow run
    /// (one gap, one ringOverflow event) that is closed once a whole block fits again.
    private func push(_ src: UnsafePointer<Float>, frames: Int) {
        if overflowRun > 0 {
            if ring.availableToWrite >= frames {
                flushOverflowRun()
            } else {
                overflowRun += UInt64(frames)
                timeline += UInt64(frames)
                return
            }
        }
        let got = ring.write(src, frames: frames)
        timeline += UInt64(got)
        if got < frames {
            let missing = frames - got
            overflowRunAfter = ring.writeCursor
            overflowRunFrame = timeline
            overflowRun = UInt64(missing)
            overflowRunsStarted.fetchAdd(1)
            timeline += UInt64(missing)
        }
    }

    /// Producer side (or main thread after the tap is removed).
    func flushOverflowRun() {
        guard overflowRun > 0 else { return }
        let missing = overflowRun
        overflowRun = 0
        if !gaps.push(after: overflowRunAfter, count: missing) {
            // Queue full: the writer appends any shortfall at finalize.
        }
        pendingZeros.fetchAdd(missing)
        log.push(type: .ringOverflow, frame: overflowRunFrame, length: missing)
        wake.signal()
    }

    func noteChannelCountChange(channels: Int) {
        if channelOnce.fetchAdd(1) == 0 {
            log.push(type: .formatChange, frame: timeline, length: UInt64(max(0, channels)), detail: 5)
        }
    }

    func noteFormatChangeResample() {
        if formatOnce.fetchAdd(1) == 0 {
            log.push(type: .formatChange, frame: timeline, length: 0, detail: 1)
        }
    }

    func noteConfigChange() {
        configCount.fetchAdd(1)
    }

    func noteDeviceOverload() {
        overloadCount.fetchAdd(1)
    }

    func run() {
        var spinning = false
        while true {
            let progress = drainAudio()
            log.drain()
            pollSideChannels()
            maybeNotifyDropouts()
            let stopping = stopFlag.load() != 0
            if stopping && !progress && ring.availableToRead == 0 && gaps.isEmpty {
                if !spinning {
                    spinning = true
                } else {
                    break
                }
            } else {
                spinning = false
            }
            if !progress {
                _ = wake.wait(timeout: .now() + .milliseconds(10))
            }
        }
        _ = drainAudio()
        log.drain()
        let pending = pendingZeros.load()
        if pending > insertedZeros {
            writeGap(Int(pending - insertedZeros))
        }
        for writer in writers {
            writer.finalize()
        }
        checkWriteFailures()
        for peak in peaks {
            peak.finish()
        }
        log.framesWritten = diskFrames
        log.drain()
        let misses = Int(renderMisses.load())
        do {
            try log.writeFile(in: writers.first?.url.deletingLastPathComponent() ?? URL(fileURLWithPath: "/tmp"), renderLockMisses: misses)
        } catch {
            writeError = error
        }
        totals = log.totals
        maybeNotifyDropouts(force: true)
        done.signal()
    }

    private func drainAudio() -> Bool {
        var progress = false
        while true {
            var step = false
            while let gap = gaps.peek() {
                let stopping = stopFlag.load() != 0
                if gap.after <= audioRead || (stopping && ring.availableToRead == 0) {
                    writeGap(Int(gap.count))
                    gaps.pop()
                    step = true
                    continue
                }
                break
            }
            let n = ring.read(into: audioScratch, maxFrames: scratchFrames)
            if n > 0 {
                consume(frames: n)
                audioRead += UInt64(n)
                step = true
            }
            if !step { break }
            progress = true
        }
        return progress
    }

    private func consume(frames: Int) {
        for index in armed.indices {
            let hw = min(max(0, armed[index].hwChannel), channels - 1)
            for f in 0..<frames {
                monoScratch[f] = audioScratch[f * channels + hw]
            }
            writers[index].append(samples: monoScratch, frames: frames)
            peaks[index].add(samples: monoScratch, frames: frames)
        }
        noteDisk(UInt64(frames))
        checkWriteFailures()
    }

    private func checkWriteFailures() {
        for index in writers.indices where !writeFailReported[index] && writers[index].writeFailed {
            writeFailReported[index] = true
            log.appendDirect(type: .writeFailed, frame: diskFrames, length: UInt64(index), detail: 6)
        }
    }

    private func writeGap(_ frames: Int) {
        guard frames > 0 else { return }
        for index in writers.indices {
            writers[index].appendZeros(frames)
            peaks[index].addZeros(frames)
        }
        insertedZeros += UInt64(frames)
        noteDisk(UInt64(frames))
        checkWriteFailures()
    }

    private func noteDisk(_ frames: UInt64) {
        diskFrames += frames
        onStall?(diskFrames)
    }

    private func pollSideChannels() {
        let avail = ring.availableToRead
        if avail > ring.capacityFrames * 3 / 4 {
            if !wasLate {
                log.appendDirect(type: .writerLate, frame: diskFrames, length: UInt64(avail))
                wasLate = true
            }
        } else if avail < ring.capacityFrames / 4 {
            wasLate = false
        }
        let configs = configCount.load()
        if configs > loggedConfig {
            log.appendDirect(type: .configChange, frame: diskFrames, length: configs - loggedConfig)
            loggedConfig = configs
        }
        let overloads = overloadCount.load()
        if overloads > loggedOverload {
            log.appendDirect(type: .deviceOverload, frame: diskFrames, length: overloads - loggedOverload)
            loggedOverload = overloads
        }
    }

    private func maybeNotifyDropouts(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        if !force && lastNotify != 0 && now &- lastNotify < 250_000_000 { return }
        lastNotify = now
        // Red counter: only discontinuities in the take (skips + overflow runs). Render lock misses are logged, not counted.
        let n = log.totals.skips + max(log.totals.overflowEvents, Int(overflowRunsStarted.load()))
        onDropouts?(n)
    }

    private func publishTimeline() {
        committed.store(timeline)
        wake.signal()
    }

    private func noteInvalidClock() {
        if loggedInvalid { return }
        loggedInvalid = true
        log.push(type: .formatChange, frame: timeline, length: 0, detail: 2)
    }

    private func sessionFrames(fromInput n: Int64) -> Int {
        if n <= 0 { return 0 }
        if abs(inputSampleRate - sampleRate) < 0.5 { return Int(n) }
        return Int((Double(n) * sampleRate / inputSampleRate).rounded())
    }
}
