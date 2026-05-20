import AVFoundation
import CSherpaOnnx
import Darwin
import Foundation

actor SherpaOnnxClient {
    private var recognizers: [String: OfflineLocalSpeechRecognizer] = [:]

    func preload(model: LocalSpeechModel) async throws {
        _ = try recognizer(language: "auto", model: model)
    }

    func transcribe(audioURL: URL, language: String, model: LocalSpeechModel) async throws -> String {
        let audio = try loadMonoSamples(from: audioURL)
        guard !audio.samples.isEmpty else { return "" }

        let recognizer = try recognizer(language: language, model: model)
        return try recognizer.transcribe(samples: audio.samples, sampleRate: audio.sampleRate)
    }

    func clearCache() {
        recognizers.removeAll(keepingCapacity: true)
    }

    private func recognizer(language: String, model: LocalSpeechModel) throws -> OfflineLocalSpeechRecognizer {
        let normalizedLanguage = normalizeLanguage(language)
        let cacheKey = "\(model.id):\(normalizedLanguage)"
        if let recognizer = recognizers[cacheKey] {
            return recognizer
        }

        let modelDirectory = try modelDirectory(for: model)
        let recognizer = try OfflineLocalSpeechRecognizer(
            model: model,
            modelDirectory: modelDirectory,
            language: normalizedLanguage
        )
        recognizers[cacheKey] = recognizer
        return recognizer
    }

    private func normalizeLanguage(_ language: String) -> String {
        switch language {
        case "":
            return "auto"
        default:
            return language
        }
    }

    private func loadMonoSamples(from audioURL: URL) throws -> (samples: [Float], sampleRate: Int32) {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let inputFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw SherpaOnnxClientError.couldNotReadAudio
        }

        try audioFile.read(into: buffer)

        guard let floatData = buffer.floatChannelData else {
            throw SherpaOnnxClientError.unsupportedAudioFormat
        }

        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channelCount > 0, frames > 0 else {
            return ([], Int32(inputFormat.sampleRate))
        }

        if channelCount == 1 {
            return (Array(UnsafeBufferPointer(start: floatData[0], count: frames)), Int32(inputFormat.sampleRate))
        }

        var samples = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let channelSamples = UnsafeBufferPointer(start: floatData[channel], count: frames)
            for index in 0..<frames {
                samples[index] += channelSamples[index] / Float(channelCount)
            }
        }

        return (samples, Int32(inputFormat.sampleRate))
    }

    private func modelDirectory(for model: LocalSpeechModel) throws -> URL {
        guard let directory = LocalSpeechModelStore.installedDirectory(for: model) else {
            throw SherpaOnnxClientError.modelNotFound(model.displayTitle)
        }

        return directory
    }
}

private final class OfflineLocalSpeechRecognizer: @unchecked Sendable {
    private let recognizer: OpaquePointer
    private let cStrings: [CStringHandle]

    init(model: LocalSpeechModel, modelDirectory: URL, language: String) throws {
        var cStrings: [CStringHandle] = []
        func cString(_ string: String) throws -> UnsafePointer<CChar> {
            let handle = try CStringHandle(string)
            cStrings.append(handle)
            return handle.unsafePointer
        }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.num_threads = 4
        config.model_config.provider = try cString("cpu")
        config.model_config.tokens = try cString(modelDirectory.appendingPathComponent("tokens.txt").path)
        config.decoding_method = try cString("greedy_search")

        switch model.kind {
        case .senseVoice:
            config.model_config.sense_voice.model = try cString(modelDirectory.appendingPathComponent("model.int8.onnx").path)
            config.model_config.sense_voice.language = try cString(language)
            config.model_config.sense_voice.use_itn = 1
        case .fireRedAsr:
            config.model_config.fire_red_asr.encoder = try cString(modelDirectory.appendingPathComponent("encoder.int8.onnx").path)
            config.model_config.fire_red_asr.decoder = try cString(modelDirectory.appendingPathComponent("decoder.int8.onnx").path)
        case .fireRedAsrCtc:
            config.model_config.fire_red_asr_ctc.model = try cString(modelDirectory.appendingPathComponent("model.int8.onnx").path)
        }

        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw SherpaOnnxClientError.couldNotCreateRecognizer
        }

        self.cStrings = cStrings
        self.recognizer = recognizer
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    func transcribe(samples: [Float], sampleRate: Int32) throws -> String {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            throw SherpaOnnxClientError.couldNotCreateStream
        }
        defer {
            SherpaOnnxDestroyOfflineStream(stream)
        }

        samples.withUnsafeBufferPointer { pointer in
            SherpaOnnxAcceptWaveformOffline(stream, sampleRate, pointer.baseAddress, Int32(pointer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw SherpaOnnxClientError.couldNotReadResult
        }
        defer {
            SherpaOnnxDestroyOfflineRecognizerResult(result)
        }

        guard let text = result.pointee.text else { return "" }
        return String(cString: text)
    }
}

private final class CStringHandle: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<CChar>

    init(_ string: String) throws {
        guard let pointer = strdup(string) else {
            throw SherpaOnnxClientError.couldNotCreateCString
        }

        self.pointer = pointer
    }

    deinit {
        free(pointer)
    }

    var unsafePointer: UnsafePointer<CChar> {
        UnsafePointer(pointer)
    }
}

enum SherpaOnnxClientError: LocalizedError {
    case modelNotFound(String)
    case couldNotCreateRecognizer
    case couldNotCreateCString
    case couldNotCreateStream
    case couldNotReadResult
    case couldNotReadAudio
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let modelName):
            return L10n.tr("Local model %@ is not downloaded.", modelName)
        case .couldNotCreateRecognizer:
            return L10n.tr("Could not create sherpa-onnx recognizer.")
        case .couldNotCreateCString:
            return L10n.tr("Could not prepare sherpa-onnx recognizer configuration.")
        case .couldNotCreateStream:
            return L10n.tr("Could not create sherpa-onnx recognition stream.")
        case .couldNotReadResult:
            return L10n.tr("Could not read sherpa-onnx transcription result.")
        case .couldNotReadAudio:
            return L10n.tr("Could not read the recorded audio.")
        case .unsupportedAudioFormat:
            return L10n.tr("Unsupported recorded audio format.")
        }
    }
}
