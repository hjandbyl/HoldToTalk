import AVFoundation
import CSherpaOnnx
import Darwin
import Foundation

actor SherpaOnnxClient {
    private var recognizers: [String: OfflineSenseVoiceRecognizer] = [:]

    func preload() async throws {
        _ = try recognizer(language: "auto")
    }

    func transcribe(audioURL: URL, language: String) async throws -> String {
        let audio = try loadMonoSamples(from: audioURL)
        guard !audio.samples.isEmpty else { return "" }

        let recognizer = try recognizer(language: language)
        return try recognizer.transcribe(samples: audio.samples, sampleRate: audio.sampleRate)
    }

    private func recognizer(language: String) throws -> OfflineSenseVoiceRecognizer {
        let normalizedLanguage = normalizeLanguage(language)
        if let recognizer = recognizers[normalizedLanguage] {
            return recognizer
        }

        let modelFiles = try modelFiles()
        let recognizer = try OfflineSenseVoiceRecognizer(
            modelURL: modelFiles.model,
            tokensURL: modelFiles.tokens,
            language: normalizedLanguage
        )
        recognizers[normalizedLanguage] = recognizer
        return recognizer
    }

    private func normalizeLanguage(_ language: String) -> String {
        switch language {
        case "", "mixed_zh_en":
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

    private func modelFiles() throws -> (model: URL, tokens: URL) {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        if
            let modelPath = environment["SHERPA_ONNX_SENSEVOICE_MODEL"],
            let tokensPath = environment["SHERPA_ONNX_SENSEVOICE_TOKENS"],
            fileManager.fileExists(atPath: modelPath),
            fileManager.fileExists(atPath: tokensPath)
        {
            return (URL(fileURLWithPath: modelPath), URL(fileURLWithPath: tokensPath))
        }

        let modelDirectory: URL? =
            environment["SHERPA_ONNX_SENSEVOICE_DIR"].map(URL.init(fileURLWithPath:))
            ?? bundledModelDirectory()
            ?? projectRootURL()?
                .appendingPathComponent("models")
                .appendingPathComponent(Self.defaultModelDirectoryName)

        guard let modelDirectory else {
            throw SherpaOnnxClientError.modelNotFound
        }

        let int8Model = modelDirectory.appendingPathComponent("model.int8.onnx")
        let fp32Model = modelDirectory.appendingPathComponent("model.onnx")
        let tokens = modelDirectory.appendingPathComponent("tokens.txt")
        let model = fileManager.fileExists(atPath: int8Model.path) ? int8Model : fp32Model

        guard fileManager.fileExists(atPath: model.path), fileManager.fileExists(atPath: tokens.path) else {
            throw SherpaOnnxClientError.modelNotFound
        }

        return (model, tokens)
    }

    private func bundledModelDirectory() -> URL? {
        guard let resourcesURL = Bundle.main.resourceURL else { return nil }
        let url = resourcesURL.appendingPathComponent("models").appendingPathComponent(Self.defaultModelDirectoryName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func projectRootURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL

        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private static let defaultModelDirectoryName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
}

private final class OfflineSenseVoiceRecognizer: @unchecked Sendable {
    private let recognizer: OpaquePointer
    private let providerCString: CStringHandle
    private let tokensCString: CStringHandle
    private let modelCString: CStringHandle
    private let languageCString: CStringHandle
    private let decodingMethodCString: CStringHandle

    init(modelURL: URL, tokensURL: URL, language: String) throws {
        let providerCString = try CStringHandle("cpu")
        let tokensCString = try CStringHandle(tokensURL.path)
        let modelCString = try CStringHandle(modelURL.path)
        let languageCString = try CStringHandle(language)
        let decodingMethodCString = try CStringHandle("greedy_search")

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.num_threads = 4
        config.model_config.provider = providerCString.unsafePointer
        config.model_config.tokens = tokensCString.unsafePointer
        config.model_config.sense_voice.model = modelCString.unsafePointer
        config.model_config.sense_voice.language = languageCString.unsafePointer
        config.model_config.sense_voice.use_itn = 1
        config.decoding_method = decodingMethodCString.unsafePointer

        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw SherpaOnnxClientError.couldNotCreateRecognizer
        }

        self.providerCString = providerCString
        self.tokensCString = tokensCString
        self.modelCString = modelCString
        self.languageCString = languageCString
        self.decodingMethodCString = decodingMethodCString
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
    case modelNotFound
    case couldNotCreateRecognizer
    case couldNotCreateCString
    case couldNotCreateStream
    case couldNotReadResult
    case couldNotReadAudio
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "sherpa-onnx SenseVoice model was not found. Run ./scripts/setup_sherpa_onnx.sh first."
        case .couldNotCreateRecognizer:
            return "Could not create sherpa-onnx recognizer."
        case .couldNotCreateCString:
            return "Could not prepare sherpa-onnx recognizer configuration."
        case .couldNotCreateStream:
            return "Could not create sherpa-onnx recognition stream."
        case .couldNotReadResult:
            return "Could not read sherpa-onnx transcription result."
        case .couldNotReadAudio:
            return "Could not read the recorded audio."
        case .unsupportedAudioFormat:
            return "Unsupported recorded audio format."
        }
    }
}
