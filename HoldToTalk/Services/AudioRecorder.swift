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
    private let analysisQueue = DispatchQueue(
        label: "HoldToTalk.AudioRecorder.analysis",
        qos: .userInitiated
    )
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
            analysisFramesSinceLastEmission = 0
            hasEmittedInputAnalysis = false
            isInputAnalysisPending = false
            inputAnalysisGeneration &+= 1
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
            streamingOutputBuffer = nil
            isInputAnalysisPending = false
            inputAnalysisGeneration &+= 1
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
                writeFailures += 1
            }
        }

        guard
            let analysisRequest,
            let samples = Self.monoSamples(from: buffer, maximumCount: AudioSpectrumAnalyzer.bufferSize)
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

    private static func monoSamples(
        from buffer: AVAudioPCMBuffer,
        maximumCount: Int
    ) -> [Float]? {
        let frameCount = min(Int(buffer.frameLength), maximumCount)
        guard frameCount > 0 else { return nil }

        if let samples = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: samples, count: frameCount))
        }

        var result = [Float](repeating: 0, count: frameCount)
        if let samples = buffer.int16ChannelData?[0] {
            let scale = 1 / Float(Int16.max)
            for index in 0..<frameCount {
                result[index] = Float(samples[index]) * scale
            }
            return result
        }

        if let samples = buffer.int32ChannelData?[0] {
            let scale = 1 / Float(Int32.max)
            for index in 0..<frameCount {
                result[index] = Float(samples[index]) * scale
            }
            return result
        }

        return nil
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

private final class AudioSpectrumAnalyzer {
    static let bufferSize = 1_024
    private let sampleAmount = 144
    private let downsampleFactor = 8
    private let magnitudeLimit: Float = 80
    private let setup: OpaquePointer?
    private let window: [Float]
    private var realIn: [Float]
    private var imagIn: [Float]
    private var realOut: [Float]
    private var imagOut: [Float]
    private var magnitudes: [Float]

    init() {
        setup = vDSP_DFT_zop_CreateSetup(nil, UInt(Self.bufferSize), .FORWARD)
        var window = [Float](repeating: 0, count: Self.bufferSize)
        vDSP_hann_window(&window, UInt(Self.bufferSize), Int32(vDSP_HANN_NORM))
        self.window = window
        realIn = [Float](repeating: 0, count: Self.bufferSize)
        imagIn = [Float](repeating: 0, count: Self.bufferSize)
        realOut = [Float](repeating: 0, count: Self.bufferSize)
        imagOut = [Float](repeating: 0, count: Self.bufferSize)
        magnitudes = [Float](repeating: 0, count: sampleAmount)
    }

    deinit {
        if let setup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    func analysis(from inputSamples: [Float]) -> AudioInputAnalysis {
        guard let setup, !inputSamples.isEmpty else {
            return AudioInputAnalysis(level: 0, spectrum: Self.silence)
        }

        var rms: Float = 0
        inputSamples.withUnsafeBufferPointer { samples in
            guard let baseAddress = samples.baseAddress else { return }
            vDSP_rmsqv(baseAddress, 1, &rms, vDSP_Length(samples.count))
        }

        let level = min(1, max(0, sqrt(Double(rms)) * 2.6))
        let frameCount = min(inputSamples.count, Self.bufferSize)
        realIn.withUnsafeMutableBufferPointer { destination in
            destination.update(repeating: 0)
            inputSamples.withUnsafeBufferPointer { source in
                guard let sourceAddress = source.baseAddress else { return }
                destination.baseAddress?.update(from: sourceAddress, count: frameCount)
            }
        }
        realIn.withUnsafeMutableBufferPointer { samples in
            window.withUnsafeBufferPointer { window in
                vDSP_vmul(
                    samples.baseAddress!,
                    1,
                    window.baseAddress!,
                    1,
                    samples.baseAddress!,
                    1,
                    vDSP_Length(Self.bufferSize)
                )
            }
        }

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

        let magnitudeScale = log1p(magnitudeLimit)
        var result = Self.silence
        for band in 0..<AudioRecorder.spectrumBandCount {
            let magnitudeIndex = 2 + band * downsampleFactor
            guard magnitudeIndex < magnitudes.count else { break }
            let limited = min(max(magnitudes[magnitudeIndex], 0), magnitudeLimit)
            result[band] = Double(log1p(limited) / magnitudeScale)
        }
        return AudioInputAnalysis(level: level, spectrum: result)
    }

    private static let silence = Array(repeating: 0.0, count: AudioRecorder.spectrumBandCount)
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
