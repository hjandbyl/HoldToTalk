import AVFoundation
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
}

enum AudioDeviceInspector {
    private static let coreAudioDefaultAggregatePrefix = "CADefaultDeviceAggregate"

    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs()
            .filter(hasInputStreams(deviceID:))
            .compactMap { deviceID in
                guard
                    let uid = inputDeviceUID(deviceID: deviceID),
                    let name = inputDeviceName(deviceID: deviceID),
                    isUserSelectableInputDevice(uid: uid, name: name)
                else {
                    return nil
                }

                return AudioInputDevice(id: uid, name: name, deviceID: deviceID)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func inputDevice(uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.id == uid }
    }

    static func inputCaptureFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &streamDescription
        )

        guard
            status == noErr,
            streamDescription.mSampleRate > 0,
            streamDescription.mChannelsPerFrame > 0
        else {
            return nil
        }

        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamDescription.mSampleRate,
            channels: streamDescription.mChannelsPerFrame,
            interleaved: false
        )
    }

    static func isUserSelectableInputDeviceUID(_ uid: String) -> Bool {
        !isCoreAudioDefaultAggregateIdentifier(uid)
    }

    static func defaultInputDeviceName() -> String {
        defaultInputDevice()?.name ?? L10n.tr("Unknown")
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        guard
            hasInputStreams(deviceID: deviceID),
            let uid = inputDeviceUID(deviceID: deviceID),
            let name = inputDeviceName(deviceID: deviceID)
        else {
            return nil
        }

        return AudioInputDevice(id: uid, name: name, deviceID: deviceID)
    }

    static func inputDeviceDisplayName(selectedUID: String) -> String {
        guard !selectedUID.isEmpty else {
            return L10n.tr("Auto (%@)", defaultInputDeviceName())
        }

        return inputDevice(uid: selectedUID)?.name ?? L10n.tr("Selected microphone unavailable")
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                buffer.baseAddress!
            )
        }

        guard status == noErr else { return [] }
        return deviceIDs
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }

        return size >= MemoryLayout<AudioStreamID>.size
    }

    private static func inputDeviceName(deviceID: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = withUnsafeMutablePointer(to: &name) { namePointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                namePointer
            )
        }

        guard status == noErr else {
            return nil
        }

        return name as String
    }

    private static func inputDeviceUID(deviceID: AudioDeviceID) -> String? {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                uidPointer
            )
        }

        guard status == noErr else {
            return nil
        }

        return uid as String
    }

    private static func isUserSelectableInputDevice(uid: String, name: String) -> Bool {
        !isCoreAudioDefaultAggregateIdentifier(uid)
            && !isCoreAudioDefaultAggregateIdentifier(name)
    }

    private static func isCoreAudioDefaultAggregateIdentifier(_ value: String) -> Bool {
        value.hasPrefix(coreAudioDefaultAggregatePrefix)
    }
}
