import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

private let audioUnitInputCallback: AURenderCallback = {
    reference,
    actionFlags,
    timestamp,
    _,
    frameCount,
    _ in
    let capture = Unmanaged<AudioUnitInputCapture>
        .fromOpaque(reference)
        .takeUnretainedValue()
    return capture.render(
        actionFlags: actionFlags,
        timestamp: timestamp,
        frameCount: frameCount
    )
}

final class AudioUnitInputCapture: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private let audioUnit: AudioUnit
    private let buffer: AVAudioPCMBuffer
    private let bufferHandler: BufferHandler

    init(deviceID: AudioDeviceID, bufferHandler: @escaping BufferHandler) throws {
        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw AudioRecorderError.couldNotAccessInputAudioUnit
        }

        var createdAudioUnit: AudioUnit?
        let creationStatus = AudioComponentInstanceNew(component, &createdAudioUnit)
        guard creationStatus == noErr, let createdAudioUnit else {
            throw AudioRecorderError.couldNotConfigureInputAudioUnit(creationStatus)
        }

        var ownsUnassignedAudioUnit = true
        defer {
            if ownsUnassignedAudioUnit {
                AudioComponentInstanceDispose(createdAudioUnit)
            }
        }

        var inputEnabled: UInt32 = 1
        var status = AudioUnitSetProperty(
            createdAudioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &inputEnabled,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioRecorderError.couldNotConfigureInputAudioUnit(status)
        }

        var outputEnabled: UInt32 = 0
        status = AudioUnitSetProperty(
            createdAudioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &outputEnabled,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioRecorderError.couldNotConfigureInputAudioUnit(status)
        }

        var selectedDeviceID = deviceID
        status = AudioUnitSetProperty(
            createdAudioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioRecorderError.couldNotSelectInputDevice(status)
        }

        var hardwareDescription = AudioStreamBasicDescription()
        var hardwareDescriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            createdAudioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &hardwareDescription,
            &hardwareDescriptionSize
        )
        guard
            status == noErr,
            hardwareDescription.mSampleRate > 0,
            hardwareDescription.mChannelsPerFrame > 0,
            let clientFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardwareDescription.mSampleRate,
                channels: hardwareDescription.mChannelsPerFrame,
                interleaved: false
            )
        else {
            throw AudioRecorderError.couldNotReadInputFormat
        }

        var clientDescription = clientFormat.streamDescription.pointee
        status = AudioUnitSetProperty(
            createdAudioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &clientDescription,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioRecorderError.couldNotConfigureInputAudioUnit(status)
        }

        var maximumFramesPerSlice: UInt32 = 0
        var maximumFramesPerSliceSize = UInt32(MemoryLayout<UInt32>.size)
        status = AudioUnitGetProperty(
            createdAudioUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFramesPerSlice,
            &maximumFramesPerSliceSize
        )
        guard
            status == noErr,
            let captureBuffer = AVAudioPCMBuffer(
                pcmFormat: clientFormat,
                frameCapacity: max(4_096, maximumFramesPerSlice)
            )
        else {
            throw AudioRecorderError.couldNotCreateInputBuffer
        }

        audioUnit = createdAudioUnit
        buffer = captureBuffer
        self.bufferHandler = bufferHandler
        ownsUnassignedAudioUnit = false

        var callback = AURenderCallbackStruct(
            inputProc: audioUnitInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AudioRecorderError.couldNotConfigureInputAudioUnit(status)
        }

        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw AudioRecorderError.couldNotConfigureInputAudioUnit(status)
        }
    }

    deinit {
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
    }

    var format: AVAudioFormat { buffer.format }

    func start() throws {
        let status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            throw AudioRecorderError.couldNotStartInputAudioUnit(status)
        }
    }

    func stop() {
        AudioOutputUnitStop(audioUnit)
    }

    fileprivate func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard frameCount <= buffer.frameCapacity else {
            return kAudio_ParamError
        }

        buffer.frameLength = frameCount
        let status = AudioUnitRender(
            audioUnit,
            actionFlags,
            timestamp,
            1,
            frameCount,
            buffer.mutableAudioBufferList
        )
        guard status == noErr else { return status }

        bufferHandler(buffer)
        return noErr
    }
}
