import CoreAudio
import Foundation

struct MixerOutputDevice: Hashable {
    var uid: String
    var name: String
    var nominalSampleRate: Double?
}

struct MixerInputDevice: Identifiable, Hashable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var inputChannels: Int
    /// Device clock from Audio MIDI / the interface, not a Mixer default.
    var nominalSampleRate: Double?
}

enum MixerInputDevices {
    static func list() -> [MixerInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        var result: [MixerInputDevice] = []
        for id in deviceIDs {
            let channels = inputChannelCount(id)
            guard channels > 0 else { continue }
            result.append(
                MixerInputDevice(
                    id: id,
                    uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                    name: stringProperty(id, kAudioDevicePropertyDeviceNameCFString) ?? "Input \(id)",
                    inputChannels: channels,
                    nominalSampleRate: nominalSampleRate(id)
                )
            )
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Default output device (playback clock). Separate from the input list, which skips output-only boxes.
    static func defaultOutputDevice() -> MixerOutputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0
        else { return nil }
        return MixerOutputDevice(
            uid: stringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? "\(deviceID)",
            name: stringProperty(deviceID, kAudioDevicePropertyDeviceNameCFString) ?? "Output",
            nominalSampleRate: nominalSampleRate(deviceID)
        )
    }

    static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    static func device(uid: String, in devices: [MixerInputDevice]) -> MixerInputDevice? {
        devices.first { $0.uid == uid }
    }

    /// Interface sample rate for a UID, else the default input, else the first input box.
    static func nominalSampleRate(uid: String?, in devices: [MixerInputDevice]? = nil) -> Double? {
        let list = devices ?? Self.list()
        if let uid, let rate = device(uid: uid, in: list)?.nominalSampleRate, rate > 0 {
            return rate
        }
        if let fallbackUID = defaultInputUID(),
           let rate = device(uid: fallbackUID, in: list)?.nominalSampleRate,
           rate > 0 {
            return rate
        }
        return list.first(where: { ($0.nominalSampleRate ?? 0) > 0 })?.nominalSampleRate
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else {
            return nil
        }
        return rate
    }

    /// Output channels on the box itself. The built-in mic is 0; Dante is not.
    static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        streamChannelCount(id, scope: kAudioDevicePropertyScopeOutput)
    }

    /// Private aggregate: chosen input + default output. Clock follows the input so a
    /// 48 kHz mic stays 48 kHz. Caller destroys the device when the engine stops.
    static func makePrivateAggregate(inputUID: String, outputUID: String, clockUID: String) -> AudioDeviceID? {
        let inputSub: [String: Any] = [
            kAudioSubDeviceUIDKey: inputUID,
            kAudioSubDeviceDriftCompensationKey: clockUID == inputUID ? 0 : 1,
        ]
        let outputSub: [String: Any] = [
            kAudioSubDeviceUIDKey: outputUID,
            kAudioSubDeviceDriftCompensationKey: clockUID == outputUID ? 0 : 1,
        ]
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TheDecks Input",
            kAudioAggregateDeviceUIDKey: "com.cougarcalc.thedecks.input.\(UUID().uuidString)",
            kAudioAggregateDeviceSubDeviceListKey: [inputSub, outputSub],
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
        ]
        var aggregate = AudioDeviceID()
        let status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate)
        guard status == noErr, aggregate != 0 else { return nil }
        return aggregate
    }

    static func destroyPrivateAggregate(_ id: AudioDeviceID) {
        guard id != 0 else { return }
        AudioHardwareDestroyAggregateDevice(id)
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        streamChannelCount(id, scope: kAudioDevicePropertyScopeInput)
    }

    private static func streamChannelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, raw) == noErr else {
            return 0
        }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var channels = 0
        for buf in buffers {
            channels += Int(buf.mNumberChannels)
        }
        return channels
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
        let ptr = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        ptr.initialize(to: nil)
        var sz = size
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &sz, ptr) == noErr else { return nil }
        return ptr.pointee as String?
    }
}

/// How TheDecks attaches the chosen INPUT to the playback engine.
enum MixerInputAttachPlan: Equatable {
    /// The interface already has outputs (Dante, a full-duplex box). Set it directly.
    case useInputDevice
    /// Input-only (built-in mic). A private aggregate keeps speakers alive and the mic as IN 1.
    case privateAggregate(clockUID: String, outputUID: String)

    static func plan(inputOutputChannels: Int, inputUID: String, outputUID: String?) -> MixerInputAttachPlan {
        guard inputOutputChannels == 0, let outputUID, !outputUID.isEmpty, outputUID != inputUID else {
            return .useInputDevice
        }
        return .privateAggregate(clockUID: inputUID, outputUID: outputUID)
    }
}

/// Strip IN numbers are 1-based. Hardware channels are 0-based. A mono device's only channel is IN 1.
enum MixerHardwareInput {
    static func channelIndex(forInputNumber number: Int) -> Int {
        max(0, number - 1)
    }

    static func isPresent(hwChannel: Int, channelCount: Int) -> Bool {
        channelCount > 0 && hwChannel >= 0 && hwChannel < channelCount
    }

    /// IN 1 on a 1-channel device is channel 0. IN 2 on that device is absent.
    static func hardwareChannel(inputNumber: Int, channelCount: Int) -> Int? {
        let hw = channelIndex(forInputNumber: inputNumber)
        return isPresent(hwChannel: hw, channelCount: channelCount) ? hw : nil
    }
}
