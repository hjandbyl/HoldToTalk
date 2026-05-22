import Foundation

actor QwenASRStreamingClient {
    private static let endpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
    private static let model = "qwen3-asr-flash-realtime"

    struct RecognitionUpdate: Sendable {
        let text: String
        let isDefinite: Bool
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var latestText = ""
    private var latestDefiniteText = ""
    private var didReceiveSessionFinished = false
    private var updateHandler: (@Sendable (RecognitionUpdate) -> Void)?
    private var session: URLSession?
    private var delegate: QwenWebSocketOpenDelegate?
    private var isActiveSession = false
    private var sessionLanguage: TranscriptionLanguage?

    func prepare(language: TranscriptionLanguage) async throws {
        if webSocketTask != nil, sessionLanguage == language {
            return
        }

        cancel()
        try await openSession(language: language, updateHandler: nil, isActive: false)
    }

    func start(
        language: TranscriptionLanguage,
        updateHandler: @escaping @Sendable (RecognitionUpdate) -> Void
    ) async throws {
        if webSocketTask != nil {
            guard sessionLanguage == language else {
                cancel()
                try await openSession(language: language, updateHandler: updateHandler, isActive: true)
                return
            }

            guard !isActiveSession else {
                throw QwenASRStreamingClientError.sessionAlreadyStarted
            }

            self.updateHandler = updateHandler
            latestText = ""
            latestDefiniteText = ""
            didReceiveSessionFinished = false
            isActiveSession = true
            return
        }

        try await openSession(language: language, updateHandler: updateHandler, isActive: true)
    }

    private func openSession(
        language: TranscriptionLanguage,
        updateHandler: (@Sendable (RecognitionUpdate) -> Void)?,
        isActive: Bool
    ) async throws {
        guard let apiKey = Self.apiKey() else {
            throw QwenASRStreamingClientError.missingAPIKey
        }

        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            URLQueryItem(name: "model", value: Self.model)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let delegate = QwenWebSocketOpenDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let webSocketTask = session.webSocketTask(with: request)
        self.session = session
        self.delegate = delegate
        self.webSocketTask = webSocketTask
        self.updateHandler = updateHandler
        sessionLanguage = language
        isActiveSession = isActive
        latestText = ""
        latestDefiniteText = ""
        didReceiveSessionFinished = false

        webSocketTask.resume()
        do {
            try await delegate.waitUntilOpen()
            try await webSocketTask.send(.string(Self.sessionUpdateMessage(language: language)))
        } catch {
            reset()
            throw error
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendAudio(_ data: Data) async throws {
        guard let webSocketTask, isActiveSession else {
            throw QwenASRStreamingClientError.sessionNotStarted
        }

        guard !data.isEmpty else { return }

        let message = Self.audioAppendMessage(audio: data.base64EncodedString())
        try await webSocketTask.send(.string(message))
    }

    func finish(finalAudio: Data?) async throws -> String {
        guard let webSocketTask, isActiveSession else {
            throw QwenASRStreamingClientError.sessionNotStarted
        }

        if let finalAudio, !finalAudio.isEmpty {
            try await sendAudio(finalAudio)
        }

        try await webSocketTask.send(.string(Self.finishMessage()))

        for _ in 0..<50 where !didReceiveSessionFinished {
            try? await Task.sleep(for: .milliseconds(100))
        }
        webSocketTask.cancel(with: .normalClosure, reason: nil)
        receiveTask?.cancel()

        let finalText = latestDefiniteText.isEmpty ? latestText : latestDefiniteText
        reset()
        return finalText
    }

    func cancel() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        receiveTask?.cancel()
        reset()
    }

    private func receiveLoop() async {
        guard let webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await webSocketTask.receive()
                switch message {
                case .string(let string):
                    try handleServerMessage(string)
                case .data(let data):
                    if let string = String(data: data, encoding: .utf8) {
                        try handleServerMessage(string)
                    }
                @unknown default:
                    continue
                }
            } catch {
                if !isActiveSession {
                    reset()
                }
                return
            }
        }
    }

    private func handleServerMessage(_ string: String) throws {
        guard
            let data = string.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            throw QwenASRStreamingClientError.invalidResponse
        }

        switch type {
        case "conversation.item.input_audio_transcription.text":
            let text = ((json["text"] as? String) ?? "") + ((json["stash"] as? String) ?? "")
            guard !text.isEmpty else { return }
            latestText = text
            updateHandler?(RecognitionUpdate(text: text, isDefinite: false))

        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = json["transcript"] as? String else { return }
            latestText = transcript
            latestDefiniteText = transcript
            updateHandler?(RecognitionUpdate(text: transcript, isDefinite: true))

        case "session.finished":
            didReceiveSessionFinished = true

        case "error":
            let message = json["message"] as? String
                ?? (json["error"] as? [String: Any])?["message"] as? String
                ?? L10n.tr("Unknown error.")
            throw QwenASRStreamingClientError.serverError(message)

        default:
            return
        }
    }

    private func reset() {
        webSocketTask = nil
        receiveTask = nil
        latestText = ""
        latestDefiniteText = ""
        didReceiveSessionFinished = false
        updateHandler = nil
        isActiveSession = false
        sessionLanguage = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
    }

    private static func apiKey() -> String? {
        QwenASRCredentialStore.apiKey()
    }

    private static func sessionUpdateMessage(language: TranscriptionLanguage) -> String {
        var transcription: [String: Any] = [:]
        if let languageCode = language.qwenASRLanguageCode {
            transcription["language"] = languageCode
        }

        let session: [String: Any] = [
            "modalities": ["text"],
            "input_audio_format": "pcm",
            "sample_rate": 16_000,
            "input_audio_transcription": transcription,
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.0,
                "silence_duration_ms": 400
            ]
        ]

        return jsonString([
            "event_id": eventID(),
            "type": "session.update",
            "session": session
        ])
    }

    private static func audioAppendMessage(audio: String) -> String {
        jsonString([
            "event_id": eventID(),
            "type": "input_audio_buffer.append",
            "audio": audio
        ])
    }

    private static func finishMessage() -> String {
        jsonString([
            "event_id": eventID(),
            "type": "session.finish"
        ])
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private static func eventID() -> String {
        "event_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}

private final class QwenWebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func waitUntilOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }

            if let result {
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        resolve(.success(()))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }

        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

enum QwenASRStreamingClientError: LocalizedError {
    case missingAPIKey
    case sessionAlreadyStarted
    case sessionNotStarted
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L10n.tr("Qwen-ASR API key is missing.")
        case .sessionAlreadyStarted:
            return L10n.tr("Qwen-ASR streaming session is already running.")
        case .sessionNotStarted:
            return L10n.tr("Qwen-ASR streaming session has not started.")
        case .invalidResponse:
            return L10n.tr("Qwen-ASR returned an invalid streaming response.")
        case .serverError(let message):
            return L10n.tr("Qwen-ASR transcription failed: %@", message)
        }
    }
}
