import AVFoundation
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
    private let analysisQueue = DispatchQueue(
        label: "HoldToTalk.AudioRecorder.analysis",
        qos: .userInitiated
    )
    private let spectrumAnalyzer = AudioSpectrumAnalyzer()
    private var captureBackend: AudioCaptureBackend?
    private var captureBuffer: AudioCaptureBuffer?
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var firstFrameHandler: (@Sendable () -> Void)?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var capturedFrames: AVAudioFramePosition = 0
    private var writeFailures = 0
    private var recordingFailure: Error?
    var failure: Error? { stateQueue.sync { recordingFailure } }
    private var inputFormatDescription = L10n.tr("Unknown")
    private var voiceProcessingDescription = L10n.tr("voice processing not started")
    private var inputSampleRate: Double = 0
    private var streamingConverter: AVAudioConverter?
    private var streamingOutputFormat: AVAudioFormat?
    private var streamingOutputBuffer: AVAudioPCMBuffer?
    private var streamingChunkHandler: StreamingChunkHandler?
    private var inputAnalysisHandler: InputAnalysisHandler?
    private var pendingStreamingAudio = Data()
    private var analysisFramesSinceLastEmission = 0.0
    private var hasEmittedInputAnalysis = false
    private var isInputAnalysisPending = false
    private var inputAnalysisGeneration: UInt64 = 0

    // 100 ms of 16 kHz, 16-bit mono PCM keeps cloud recognition close to live input.
    private static let streamingChunkByteCount = 3_200
    private static let inputAnalysisUpdatesPerSecond = 24.0
    static let spectrumBandCount = 18

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
        inputAnalysisHandler: InputAnalysisHandler? = nil,
        failureHandler: (@Sendable (Error) -> Void)? = nil,
        firstFrameHandler: (@Sendable () -> Void)? = nil
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoldToTalk-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        self.failureHandler = failureHandler
        self.firstFrameHandler = firstFrameHandler
        stateQueue.sync {
            audioFile = nil
            recordingURL = url
            capturedFrames = 0
            writeFailures = 0
            recordingFailure = nil
            inputFormatDescription = L10n.tr("Unknown")
            inputSampleRate = 0
            self.streamingChunkHandler = streamingChunkHandler
            self.inputAnalysisHandler = inputAnalysisHandler
            pendingStreamingAudio.removeAll(keepingCapacity: true)
            analysisFramesSinceLastEmission = 0
            hasEmittedInputAnalysis = false
            isInputAnalysisPending = false
            inputAnalysisGeneration &+= 1
        }

        // Reset on the same serial queue that owns the visualization analysis.
        analysisQueue.async { [weak self] in self?.spectrumAnalyzer.reset() }

        do {
            let captureBackend = try configuredCaptureBackend(inputDeviceUID: inputDeviceUID)
            stateQueue.sync {
                self.captureBackend = captureBackend
            }
            captureBuffer = try AudioCaptureBuffer(format: captureBackend.format, consume: { [weak self] buffer in
                self?.write(buffer)
            }, failure: { [weak self] error in self?.failureHandler?(error) }, firstFrame: { [weak self] in self?.firstFrameHandler?() })
            try captureBackend.start()
            return url
        } catch {
            _ = stop()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func configuredCaptureBackend(inputDeviceUID: String?) throws -> AudioCaptureBackend {
        guard let inputDeviceUID, !inputDeviceUID.isEmpty else {
            return .engine(try configuredDefaultEngine())
        }

        guard let device = AudioDeviceInspector.inputDevice(uid: inputDeviceUID) else {
            throw AudioRecorderError.inputDeviceUnavailable
        }

        stateQueue.sync {
            voiceProcessingDescription = L10n.tr("direct microphone capture")
        }

        return .audioUnit(
            try AudioUnitInputCapture(deviceID: device.deviceID) { [weak self] buffer in
                self?.captureBuffer?.append(buffer)
            }
        )
    }

    private func configuredDefaultEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        configureVoiceProcessing(on: inputNode)

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        let tapBufferSize: AVAudioFrameCount = AudioDeviceInspector.isBluetoothInputDevice(uid: nil)
            ? 512
            : 2_048
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.captureBuffer?.append(buffer)
        }

        engine.prepare()
        return engine
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
        let backend = stateQueue.sync { captureBackend }
        backend?.stop()
        do { try captureBuffer?.close() } catch { stateQueue.sync { recordingFailure = error } }
        captureBuffer = nil
        let result = stateQueue.sync { () -> (url: URL?, captureBackend: AudioCaptureBackend?) in
            let url = recordingURL
            audioFile = nil
            recordingURL = nil
            streamingChunkHandler = nil
            inputAnalysisHandler = nil
            streamingConverter = nil
            streamingOutputFormat = nil
            streamingOutputBuffer = nil
            isInputAnalysisPending = false
            inputAnalysisGeneration &+= 1
            let runningCaptureBackend = captureBackend
            self.captureBackend = nil
            return (url, runningCaptureBackend)
        }

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

        var analysisRequest: (handler: InputAnalysisHandler, generation: UInt64)?

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

                if let inputAnalysisHandler {
                    analysisFramesSinceLastEmission += Double(buffer.frameLength)
                    let analysisFrameInterval = max(
                        1,
                        buffer.format.sampleRate / Self.inputAnalysisUpdatesPerSecond
                    )

                    if (!hasEmittedInputAnalysis || analysisFramesSinceLastEmission >= analysisFrameInterval),
                       !isInputAnalysisPending {
                        hasEmittedInputAnalysis = true
                        analysisFramesSinceLastEmission.formTruncatingRemainder(dividingBy: analysisFrameInterval)
                        isInputAnalysisPending = true
                        analysisRequest = (inputAnalysisHandler, inputAnalysisGeneration)
                    }
                }
            } catch {
                recordingFailure = error
                writeFailures += 1
                if writeFailures == 1 { failureHandler?(error) }
            }
        }

        guard
            let analysisRequest,
            let samples = AudioSpectrumAnalyzer.samples(from: buffer)
        else {
            if analysisRequest != nil {
                stateQueue.sync {
                    if analysisRequest?.generation == inputAnalysisGeneration {
                        isInputAnalysisPending = false
                    }
                }
            }
            return
        }

        analysisQueue.async { [weak self] in
            guard let self else { return }
            let analysis = self.spectrumAnalyzer.analysis(from: samples)
            let shouldEmit = self.stateQueue.sync { () -> Bool in
                guard analysisRequest.generation == self.inputAnalysisGeneration else { return false }
                self.isInputAnalysisPending = false
                return self.inputAnalysisHandler != nil
            }

            if shouldEmit {
                analysisRequest.handler(analysis)
            }
        }
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

        let requiredCapacity = max(1, outputCapacity)
        if streamingOutputBuffer == nil || streamingOutputBuffer!.frameCapacity < requiredCapacity {
            streamingOutputBuffer = AVAudioPCMBuffer(
                pcmFormat: streamingOutputFormat,
                frameCapacity: requiredCapacity
            )
        }
        guard let outputBuffer = streamingOutputBuffer else { return }
        outputBuffer.frameLength = 0

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
            if conversionError != nil { recordingFailure = DictationError.captureFailed; failureHandler?(DictationError.captureFailed) }
            return
        }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        pendingStreamingAudio.append(
            UnsafeRawPointer(samples[0]).assumingMemoryBound(to: UInt8.self),
            count: byteCount
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

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case inputDeviceUnavailable
    case couldNotAccessInputAudioUnit
    case couldNotSelectInputDevice(OSStatus)
    case couldNotReadInputFormat
    case couldNotConfigureInputAudioUnit(OSStatus)
    case couldNotCreateInputBuffer
    case couldNotStartInputAudioUnit(OSStatus)

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
        case .couldNotConfigureInputAudioUnit(let status):
            return L10n.tr("Could not configure microphone input unit: %d", status)
        case .couldNotCreateInputBuffer:
            return L10n.tr("Could not create microphone input buffer.")
        case .couldNotStartInputAudioUnit(let status):
            return L10n.tr("Could not start microphone input unit: %d", status)
        }
    }
}

private enum AudioCaptureBackend {
    case engine(AVAudioEngine)
    case audioUnit(AudioUnitInputCapture)

    var format: AVAudioFormat {
        switch self {
        case .engine(let engine): return engine.inputNode.outputFormat(forBus: 0)
        case .audioUnit(let unit): return unit.format
        }
    }

    func start() throws {
        switch self {
        case .engine(let engine):
            try engine.start()
        case .audioUnit(let audioUnit):
            try audioUnit.start()
        }
    }

    func stop() {
        switch self {
        case .engine(let engine):
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        case .audioUnit(let audioUnit):
            audioUnit.stop()
        }
    }
}
