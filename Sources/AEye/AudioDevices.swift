import CoreAudio
import Foundation

/// Picks the mic. Opening a Bluetooth headset's mic (AirPods etc.) flips it from A2DP into
/// call mode (HFP), which pauses or muffles your music — so when the default input is
/// Bluetooth we record from the built-in mic instead and leave the headphones alone.
enum AudioDevices {
    struct Device { let id: AudioDeviceID; let name: String; let transport: UInt32 }

    static func preferredInput() -> Device? {
        guard let def = defaultInput() else { return nil }
        guard def.transport == kAudioDeviceTransportTypeBluetooth
                || def.transport == kAudioDeviceTransportTypeBluetoothLE else { return def }
        return inputs().first { $0.transport == kAudioDeviceTransportTypeBuiltIn } ?? def
    }

    static func defaultInput() -> Device? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return nil }
        return device(id)
    }

    static func inputs() -> [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.filter(hasInput).compactMap(device)
    }

    private static func device(_ id: AudioDeviceID) -> Device? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyTransportType)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr = address(kAudioObjectPropertyName)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        return Device(id: id, name: name?.takeRetainedValue() as String? ?? "?", transport: transport)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
