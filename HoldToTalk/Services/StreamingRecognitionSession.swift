import Foundation

protocol WebSocketTransport: Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel()
}

final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: request)
        socket.resume()
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await withTaskCancellationHandler {
            try await socket.send(message)
        } onCancel: { self.cancel() }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withTaskCancellationHandler {
            try await socket.receive()
        } onCancel: { self.cancel() }
    }
    func cancel() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Single-use connection, transferred from prewarming to exactly one dictation session.
actor StreamingRecognitionSession: CloudRecognizing {
    private let engine: RecognitionEngine
    private let apiKey: String
    private let qwenModel: QwenSpeechModel
    private let qwenTaskID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let qwenTaskStarted = AsyncResult<Void>()
    private var qwenStarted = false
    private var qwenFinishRequested = false
    private var qwenTranscript = QwenMessageTranscript()
    private let clock: any DictationClock
    private let makeTransport: @Sendable (URLRequest) -> any WebSocketTransport
    private let idleFailureHandler: @Sendable () -> Void
    private var transport: (any WebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var openingTask: Task<Void, Error>?
    private let finalResult = AsyncResult<String>()
    private var terminalError: Error?
    private var latestText = ""
    private var latestDefiniteText = ""
    private var handler: (@Sendable (CloudRecognitionEvent) -> Void)?
    private var closed = false
    private var active = false
    private var language: TranscriptionLanguage?

    init(engine: RecognitionEngine, apiKey: String, qwenModel: QwenSpeechModel = .message,
         clock: any DictationClock = SystemDictationClock(),
         idleFailureHandler: @escaping @Sendable () -> Void = {},
         makeTransport: @escaping @Sendable (URLRequest) -> any WebSocketTransport = { URLSessionWebSocketTransport(request: $0) }) {
        self.engine = engine
        self.apiKey = apiKey
        self.qwenModel = qwenModel
        self.clock = clock
        self.makeTransport = makeTransport
        self.idleFailureHandler = idleFailureHandler
    }

    private var isQwenMessage: Bool { engine == .qwenASR && qwenModel == .message }

    func prepare(language: TranscriptionLanguage) async throws {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        guard !closed else { throw CancellationError() }
        if let openingTask { try await openingTask.value; return }
        self.language = language
        var request: URLRequest
        if engine == .volcengine {
            request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!)
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            request.setValue("volc.seedasr.sauc.duration", forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        } else if isQwenMessage {
            request = URLRequest(url: QwenMessageWireProtocol.endpoint)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            request = URLRequest(url: URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        }
        let transport = makeTransport(request)
        self.transport = transport
        let initial: URLSessionWebSocketTask.Message
        if engine == .volcengine {
            initial = .data(VolcengineWireProtocol.fullClientRequest(language: language))
        } else if isQwenMessage {
            initial = .string(QwenMessageWireProtocol.startMessage(taskID: qwenTaskID))
        } else {
            initial = .string(QwenWireProtocol.sessionUpdateMessage(language: language))
        }
        let clock = clock
        let needsAcknowledgement = isQwenMessage
        let acknowledgement = qwenTaskStarted
        let opening = Task {
            try await withDictationTimeout(seconds: 5, clock: clock) {
                try await transport.send(initial)
                if needsAcknowledgement { try await acknowledgement.value() }
            }
        }
        openingTask = opening
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await transport.receive()
                    guard let self else { return }
                    if try await self.handle(message) { return }
                } catch {
                    await self?.fail(error)
                    return
                }
            }
        }
        do {
            try await opening.value
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
        } catch { fail(error); throw terminalError ?? error }
    }

    func start(language: TranscriptionLanguage, eventHandler: @escaping @Sendable (CloudRecognitionEvent) -> Void) async throws {
        guard !active else { throw DictationError.incompleteResult }
        handler = eventHandler
        try await prepare(language: language)
        guard self.language == language, !closed else { throw CancellationError() }
        if let terminalError { throw terminalError }
        active = true
    }

    func sendAudio(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        if engine == .volcengine {
            try await send(.data(VolcengineWireProtocol.audioRequest(payload: data, isFinal: false)))
        } else if isQwenMessage {
            try await send(.data(data))
        } else {
            try await send(.string(QwenWireProtocol.audioAppendMessage(audio: data.base64EncodedString())))
        }
    }

    func finish(finalAudio: Data?) async throws -> String {
        do {
            if engine == .volcengine {
                try await send(.data(VolcengineWireProtocol.audioRequest(payload: finalAudio ?? Data(), isFinal: true)))
            } else {
                if let finalAudio { try await sendAudio(finalAudio) }
                if isQwenMessage {
                    qwenFinishRequested = true
                    try await send(.string(QwenMessageWireProtocol.finishMessage(taskID: qwenTaskID)))
                } else {
                    try await send(.string(QwenWireProtocol.finishMessage()))
                }
            }
            let finalResult = finalResult
            let text = try await withDictationTimeout(seconds: engine == .volcengine ? 2 : 5, clock: clock) {
                try await finalResult.value()
            }
            try Task.checkCancellation()
            if let terminalError { throw terminalError }
            closeTransport()
            return text
        } catch { fail(error); throw error }
    }

    func cancel() {
        fail(CancellationError())
    }

    private func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        guard active, !closed, let transport else { throw DictationError.incompleteResult }
        do {
            try await withDictationTimeout(seconds: 5, clock: clock) { try await transport.send(message) }
            if let terminalError { throw terminalError }
        } catch { fail(error); throw error }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws -> Bool {
        guard !closed else { return true }
        if isQwenMessage { return try handleQwenMessage(message) }
        let response: ParsedServerResponse?
        switch (engine, message) {
        case (.volcengine, .data(let data)): response = try VolcengineWireProtocol.parseServerResponse(data)
        case (.qwenASR, .string(let text)): response = try QwenWireProtocol.parseServerResponse(text)
        case (.qwenASR, .data(let data)):
            guard let text = String(data: data, encoding: .utf8) else { throw QwenASRStreamingClientError.invalidResponse }
            response = try QwenWireProtocol.parseServerResponse(text)
        default: response = nil
        }
        if let update = response?.update {
            latestText = update.text
            if update.isDefinite { latestDefiniteText = update.text }
            handler?(.update(update))
        }
        if response?.isFinalResponse == true {
            finalResult.resolve(.success(latestDefiniteText.isEmpty ? latestText : latestDefiniteText))
            return true
        }
        return false
    }

    private func handleQwenMessage(_ message: URLSessionWebSocketTask.Message) throws -> Bool {
        let text: String
        switch message {
        case .string(let string): text = string
        case .data(let data):
            guard let string = String(data: data, encoding: .utf8) else { throw QwenASRStreamingClientError.invalidResponse }
            text = string
        @unknown default: throw QwenASRStreamingClientError.invalidResponse
        }
        guard let event = try QwenMessageWireProtocol.parseServerResponse(text, taskID: qwenTaskID) else { return false }
        switch event {
        case .started:
            qwenStarted = true
            qwenTaskStarted.resolve(.success(()))
        case .sentence(let sentence):
            guard qwenStarted else { throw QwenASRStreamingClientError.invalidResponse }
            if let update = qwenTranscript.update(sentence) { handler?(.update(update)) }
        case .finished:
            guard qwenStarted, qwenFinishRequested else { throw DictationError.incompleteResult }
            finalResult.resolve(.success(try qwenTranscript.finalText()))
            return true
        }
        return false
    }

    private func fail(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        qwenTaskStarted.resolve(.failure(error))
        let eventHandler = handler
        closeTransport()
        finalResult.resolve(.failure(error))
        if !(error is CancellationError) { eventHandler?(.failure(error)) }
        if !active { idleFailureHandler() }
    }

    private func closeTransport() {
        closed = true
        openingTask?.cancel()
        receiveTask?.cancel()
        transport?.cancel()
        openingTask = nil
        receiveTask = nil
        transport = nil
        handler = nil
    }
}
