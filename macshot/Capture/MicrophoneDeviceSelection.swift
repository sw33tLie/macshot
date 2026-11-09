import AVFoundation
import CoreAudio

/// Default-device aggregates belong to one process and cannot be saved as a
/// microphone selection. Older builds could expose these in the device menu.
enum MicrophoneDeviceSelection {
    nonisolated static func isTemporaryDefaultDevice(_ id: String) -> Bool {
        id.hasPrefix("CADefaultDeviceAggregate")
    }

    nonisolated static func persistentDeviceID(_ id: String?) -> String? {
        guard let id, !id.isEmpty, !isTemporaryDefaultDevice(id) else { return nil }
        return id
    }

    /// Only legacy default aliases may fall back. A disconnected explicitly
    /// selected device must never silently record a different microphone.
    nonisolated static func resolve<Device>(savedID: String?, lookup: (String) -> Device?,
                                            defaultDevice: () -> Device?) -> Device? {
        if let id = persistentDeviceID(savedID) { return lookup(id) }
        return defaultDevice()
    }

    nonisolated static func captureDevice(savedID: String?) -> AVCaptureDevice? {
        resolve(savedID: savedID, lookup: { AVCaptureDevice(uniqueID: $0) },
                defaultDevice: { AVCaptureDevice.default(for: .audio) })
    }

    static func repairLegacyPreference(defaults: UserDefaults = .standard) {
        guard let id = defaults.string(forKey: "selectedMicDeviceUID"), isTemporaryDefaultDevice(id) else { return }
        defaults.removeObject(forKey: "selectedMicDeviceUID")
    }

    /// Select the same physical device for the level meter as for recording,
    /// without changing the system's default input device.
    static func configureLevelMeter(_ input: AVAudioInputNode, savedID: String?) -> Bool {
        guard let id = persistentDeviceID(savedID) else { return true }
        guard let unit = input.audioUnit else { return false }
        var uid = id as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafePointer(to: &uid) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return false }
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }
}
