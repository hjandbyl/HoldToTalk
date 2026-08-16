import AVFoundation
import Accelerate
import AudioToolbox
import Foundation

struct AudioInputAnalysis: Sendable {
    let level: Double
    let spectrum: [Double]
}

final class AudioRecorder: @unchecked Sendable {
    typealias StreamingChunkHandler = @Sendable (Data) -> Void
    typealias InputAnalysisHandler = @Sendable (AudioInputAnalysis) -> Void

    private let stateQueue = DispatchQueue(label: "HoldToTalk.AudioRecorder.state")
    private let spectrumAnalyzer = AudioSpectrumAnalyzer()
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var capturedFrames: AVAudioFramePosition = 0
    private var writeFailures = 0
    private var inputFormatDescription = L10n.tr("Unknown")
    private var voiceProcessingDescription = L10n.tr("voice processing not started")
    private var inputSampleRate: Double = 0
    private var streamingConverter: AVAudioConverter?
    private var streamingOutputFormat: AVAudioFormat?
    private var streamingChunkHandler: StreamingChunkHandler?
    private var inputAnalysisHandler: InputAnalysisHandler?
    private var pendingStreamingAudio = Data()

    private static let streamingChunkByteCount = 6_400
    static let spectrumBandCount = 25

    func captureSummary(heldDuration: TimeInterval) -> String {
        stateQueue.sync {
            return L10n.tr(
                "held %.2fs, captured %.2fs, write failures %d, format %@, %@",
                heldDuration,
                capturedDuration,
                writeFailures,
                inputFormatDescription,
                voiceProcessingDescription
            )
        }
    }

    private var capturedDuration: TimeInterval {
        guard inputSampleRate > 0 else { return 0 }
        return Double(capturedFrames) / inputSampleRate
    }

    func start(
        inputDeviceUID: String? = nil,
        streamingChunkHandler: StreamingChunkHandler? = nil,
        inputAnalysisHandler: InputAnalysisHandler? = nil
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoldToTalk-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        stateQueue.sync {
            audioFile = nil
            recordingURL = url
            capturedFrames = 0
            writeFailures = 0
            inputFormatDescription = L10n.tr("Unknown")
            inputSampleRate = 0
            self.streamingChunkHandler = streamingChunkHandler
            self.inputAnalysisHandler = inputAnalysisHandler
            pendingStreamingAudio.removeAll(keepingCapacity: true)
        }

        do {
            let engine = try configuredEngine(inputDeviceUID: inputDeviceUID)
            stateQueue.sync {
                self.engine = engine
            }
            try engine.start()
            return url
        } catch {
            _ = stop()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func configuredEngine(inputDeviceUID: String?) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let selectedInputFormat = try configureInputDevice(inputDeviceUID, on: inputNode)
        configureVoiceProcessing(on: inputNode)

        let inputFormat = selectedInputFormat ?? inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        let tapBufferSize: AVAudioFrameCount = AudioDeviceInspector.isBluetoothInputDevice(uid: inputDeviceUID)
            ? 512
            : 2_048
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.write(buffer)
        }

        engine.prepare()
        return engine
    }

    private func configureInputDevice(_ uid: String?, on inputNode: AVAudioInputNode) throws -> AVAudioFormat? {
        guard let uid, !uid.isEmpty else { return nil }
        guard let device = AudioDeviceInspector.inputDevice(uid: uid) else {
            throw AudioRecorderError.inputDeviceUnavailable
        }
        var deviceID = device.deviceID
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioRecorderError.couldNotAccessInputAudioUnit
        }

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw AudioRecorderError.couldNotSelectInputDevice(status)
        }

        guard let inputFormat = AudioDeviceInspector.inputCaptureFormat(deviceID: deviceID) else {
            throw AudioRecorderError.couldNotReadInputFormat
        }

        return inputFormat
    }

    private func configureVoiceProcessing(on inputNode: AVAudioInputNode) {
        if inputNode.isVoiceProcessingEnabled {
            try? inputNode.setVoiceProcessingEnabled(false)
        }

        stateQueue.sync {
            voiceProcessingDescription = L10n.tr("system mic mode %@", Self.microphoneModeDescription())
        }
    }

    func stop() -> URL? {
        let result = stateQueue.sync { () -> (url: URL?, engine: AVAudioEngine?) in
            let url = recordingURL
            audioFile = nil
            recordingURL = nil
            streamingChunkHandler = nil
            inputAnalysisHandler = nil
            streamingConverter = nil
            streamingOutputFormat = nil
            let runningEngine = engine
            self.engine = nil
            return (url, runningEngine)
        }

        result.engine?.inputNode.removeTap(onBus: 0)
        result.engine?.stop()
        return result.url
    }

    func takePendingStreamingAudio() -> Data {
        stateQueue.sync {
            defer { pendingStreamingAudio.removeAll(keepingCapacity: false) }
            return pendingStreamingAudio
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        let level = Self.audioLevel(from: buffer)
        let spectrum = spectrumAnalyzer.spectrum(from: buffer)

        stateQueue.sync {
            guard let recordingURL else { return }

            do {
                if audioFile == nil {
                    audioFile = try AVAudioFile(forWriting: recordingURL, settings: buffer.format.settings)
                    inputFormatDescription = "\(Int(buffer.format.sampleRate)) Hz, \(buffer.format.channelCount) ch"
                    inputSampleRate = buffer.format.sampleRate

                    if streamingChunkHandler != nil {
                        configureStreamingConverterLocked(inputFormat: buffer.format)
                    }
                }

                guard let audioFile else { return }
                try audioFile.write(from: buffer)
                capturedFrames += AVAudioFramePosition(buffer.frameLength)
                convertAndEmitStreamingAudioLocked(buffer)
                inputAnalysisHandler?(AudioInputAnalysis(level: level, spectrum: spectrum))
            } catch {
                writeFailures += 1
            }
        }
    }

    private static func audioLevel(from buffer: AVAudioPCMBuffer) -> Double {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        var sumSquares = 0.0
        var sampleCount = 0

        if let channels = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    let sample = Double(samples[frame])
                    sumSquares += sample * sample
                    sampleCount += 1
                }
            }
        } else if let channels = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    let sample = Double(samples[frame]) / Double(Int16.max)
                    sumSquares += sample * sample
                    sampleCount += 1
                }
            }
        } else if let channels = buffer.int32ChannelData {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    let sample = Double(samples[frame]) / Double(Int32.max)
                    sumSquares += sample * sample
                    sampleCount += 1
                }
            }
        }

        guard sampleCount > 0 else { return 0 }

        let rms = sqrt(sumSquares / Double(sampleCount))
        return min(1, max(0, sqrt(rms) * 2.6))
    }

    private func configureStreamingConverterLocked(inputFormat: AVAudioFormat) {
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        else {
            return
        }

        streamingOutputFormat = outputFormat
        streamingConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    private func convertAndEmitStreamingAudioLocked(_ buffer: AVAudioPCMBuffer) {
        guard
            let streamingConverter,
            let streamingOutputFormat,
            let streamingChunkHandler
        else {
            return
        }

        let ratio = streamingOutputFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: streamingOutputFormat,
            frameCapacity: max(1, outputCapacity)
        ) else {
            return
        }

        var hasProvidedInput = false
        var conversionError: NSError?
        streamingConverter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if hasProvidedInput {
                status.pointee = .noDataNow
                return nil
            }

            hasProvidedInput = true
            status.pointee = .haveData
            return buffer
        }

        guard
            conversionError == nil,
            outputBuffer.frameLength > 0,
            let samples = outputBuffer.int16ChannelData
        else {
            return
        }

        pendingStreamingAudio.append(
            Data(
                bytes: samples[0],
                count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
            )
        )

        while pendingStreamingAudio.count >= Self.streamingChunkByteCount {
            let chunk = pendingStreamingAudio.prefix(Self.streamingChunkByteCount)
            streamingChunkHandler(Data(chunk))
            pendingStreamingAudio.removeFirst(Self.streamingChunkByteCount)
        }
    }

    private static func microphoneModeDescription() -> String {
        if #available(macOS 12.0, *) {
            switch AVCaptureDevice.activeMicrophoneMode {
            case .standard:
                return L10n.tr("Standard")
            case .wideSpectrum:
                return L10n.tr("Wide Spectrum")
            case .voiceIsolation:
                return L10n.tr("Voice Isolation")
            @unknown default:
                return L10n.tr("Unknown")
            }
        }

        return L10n.tr("Unavailable")
    }
}

private final class AudioSpectrumAnalyzer {
    private let bufferSize = 2_048
    private let sampleAmount = 200
    private let downsampleFactor = 8
    private let magnitudeLimit: Float = 80
    private let setup: OpaquePointer?
    private let window: [Float]

    init() {
        setup = vDSP_DFT_zop_CreateSetup(nil, UInt(bufferSize), .FORWARD)
        var window = [Float](repeating: 0, count: bufferSize)
        vDSP_hann_window(&window, UInt(bufferSize), Int32(vDSP_HANN_NORM))
        self.window = window
    }

    deinit {
        if let setup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    func spectrum(from buffer: AVAudioPCMBuffer) -> [Double] {
        guard
            let setup,
            let channelData = buffer.floatChannelData?[0],
            buffer.frameLength > 0
        else {
            return Self.silence
        }

        let frameCount = min(Int(buffer.frameLength), bufferSize)
        var realIn = [Float](repeating: 0, count: bufferSize)
        realIn.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress?.update(from: channelData, count: frameCount)
        }
        vDSP.multiply(realIn, window, result: &realIn)

        var imagIn = [Float](repeating: 0, count: bufferSize)
        var realOut = [Float](repeating: 0, count: bufferSize)
        var imagOut = [Float](repeating: 0, count: bufferSize)
        var magnitudes = [Float](repeating: 0, count: sampleAmount)

        realIn.withUnsafeMutableBufferPointer { realInPtr in
            imagIn.withUnsafeMutableBufferPointer { imagInPtr in
                realOut.withUnsafeMutableBufferPointer { realOutPtr in
                    imagOut.withUnsafeMutableBufferPointer { imagOutPtr in
                        vDSP_DFT_Execute(
                            setup,
                            realInPtr.baseAddress!,
                            imagInPtr.baseAddress!,
                            realOutPtr.baseAddress!,
                            imagOutPtr.baseAddress!
                        )

                        var complex = DSPSplitComplex(
                            realp: realOutPtr.baseAddress!,
                            imagp: imagOutPtr.baseAddress!
                        )
                        vDSP_zvabs(&complex, 1, &magnitudes, 1, UInt(sampleAmount))
                    }
                }
            }
        }

        return magnitudes
            .dropFirst(2)
            .enumerated()
            .compactMap { index, value -> Double? in
                guard index.isMultiple(of: downsampleFactor) else { return nil }
                let limited = min(max(value, 0), magnitudeLimit)
                return Double(log1p(limited) / log1p(magnitudeLimit))
            }
            .prefix(AudioRecorder.spectrumBandCount)
            .map { min(1, max(0, $0)) }
            .paddingWithSilence(to: AudioRecorder.spectrumBandCount)
    }

    private static let silence = Array(repeating: 0.0, count: AudioRecorder.spectrumBandCount)
}

private extension Array where Element == Double {
    func paddingWithSilence(to count: Int) -> [Double] {
        guard self.count < count else { return Array(prefix(count)) }
        return self + Array(repeating: 0, count: count - self.count)
    }
}

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case inputDeviceUnavailable
    case couldNotAccessInputAudioUnit
    case couldNotSelectInputDevice(OSStatus)
    case couldNotReadInputFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return L10n.tr("No microphone input device is available.")
        case .inputDeviceUnavailable:
            return L10n.tr("Selected microphone is not available.")
        case .couldNotAccessInputAudioUnit:
            return L10n.tr("Could not access microphone input unit.")
        case .couldNotSelectInputDevice(let status):
            return L10n.tr("Could not select microphone input device: %d", status)
        case .couldNotReadInputFormat:
            return L10n.tr("Could not read the selected microphone format.")
        }
    }
}
