import CoreAudio
import Foundation

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

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
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
