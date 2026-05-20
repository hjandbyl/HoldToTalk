import Foundation

actor VolcengineStreamingClient {
    private static let endpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    private static let resourceID = "volc.seedasr.sauc.duration"

    struct RecognitionUpdate: Sendable {
        let text: String
        let isDefinite: Bool
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var latestText = ""
    private var latestDefiniteText = ""
    private var didReceiveFinalResponse = false
    private var updateHandler: (@Sendable (RecognitionUpdate) -> Void)?
    private var session: URLSession?
    private var delegate: WebSocketOpenDelegate?
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
                throw VolcengineStreamingClientError.sessionAlreadyStarted
            }

            self.updateHandler = updateHandler
            latestText = ""
            latestDefiniteText = ""
            didReceiveFinalResponse = false
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
            throw VolcengineStreamingClientError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(Self.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let delegate = WebSocketOpenDelegate()
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
        didReceiveFinalResponse = false

        webSocketTask.resume()
        do {
            try await delegate.waitUntilOpen()
            try await webSocketTask.send(.data(Self.fullClientRequest(language: language)))
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
            throw VolcengineStreamingClientError.sessionNotStarted
        }

        guard !data.isEmpty else { return }

        try await webSocketTask.send(.data(Self.audioRequest(payload: data, isFinal: false)))
    }

    func finish(finalAudio: Data?) async throws -> String {
        guard let webSocketTask, isActiveSession else {
            throw VolcengineStreamingClientError.sessionNotStarted
        }

        let payload = finalAudio ?? Data()
        try await webSocketTask.send(.data(Self.audioRequest(payload: payload, isFinal: true)))

        for _ in 0..<20 where !didReceiveFinalResponse {
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
                case .data(let data):
                    if let response = try Self.parseServerResponse(data) {
                        didReceiveFinalResponse = response.isFinalResponse

                        if let update = response.update {
                            latestText = update.text
                            if update.isDefinite {
                                latestDefiniteText = update.text
                            }
                            updateHandler?(update)
                        }
                    }
                case .string:
                    continue
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

    private func reset() {
        webSocketTask = nil
        receiveTask = nil
        latestText = ""
        latestDefiniteText = ""
        didReceiveFinalResponse = false
        updateHandler = nil
        isActiveSession = false
        sessionLanguage = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
    }

    private static func apiKey() -> String? {
        VolcengineCredentialStore.apiKey()
    }

    private static func fullClientRequest(language: TranscriptionLanguage) -> Data {
        var audio: [String: Any] = [
            "format": "pcm",
            "codec": "raw",
            "rate": 16_000,
            "bits": 16,
            "channel": 1
        ]
        if let languageCode = language.volcengineLanguageCode {
            audio["language"] = languageCode
        }

        let request: [String: Any] = [
            "user": [
                "uid": Host.current().localizedName ?? "macOS"
            ],
            "audio": audio,
            "request": [
                "model_name": "bigmodel",
                // Direct ASR equivalent of AibotCreate StreamMode = 2:
                // bigmodel_async streams partial text and enable_nonstream returns optimized final segments.
                "enable_nonstream": true,
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": true,
                "show_utterances": true
            ]
        ]

        let payload = try! JSONSerialization.data(withJSONObject: request)
        return packet(
            messageType: 0x1,
            flags: 0x0,
            serialization: 0x1,
            compression: 0x0,
            sequence: nil,
            payload: payload
        )
    }

    private static func audioRequest(payload: Data, isFinal: Bool) -> Data {
        packet(
            messageType: 0x2,
            flags: isFinal ? 0x2 : 0x0,
            serialization: 0x0,
            compression: 0x0,
            sequence: nil,
            payload: payload
        )
    }

    private static func packet(
        messageType: UInt8,
        flags: UInt8,
        serialization: UInt8,
        compression: UInt8,
        sequence: Int32?,
        payload: Data
    ) -> Data {
        var data = Data([
            0x11,
            (messageType << 4) | flags,
            (serialization << 4) | compression,
            0x00
        ])

        if let sequence {
            data.append(contentsOf: sequence.bigEndianBytes)
        }

        data.append(contentsOf: UInt32(payload.count).bigEndianBytes)
        data.append(payload)
        return data
    }

    private static func parseServerResponse(_ data: Data) throws -> ParsedServerResponse? {
        guard data.count >= 8 else {
            throw VolcengineStreamingClientError.invalidResponse
        }

        let headerSize = Int(data[0] & 0x0f) * 4
        let messageType = data[1] >> 4
        let flags = data[1] & 0x0f
        let serialization = data[2] >> 4

        guard headerSize >= 4, data.count >= headerSize + 4 else {
            throw VolcengineStreamingClientError.invalidResponse
        }

        var offset = headerSize
        if flags == 0x1 || flags == 0x3 {
            guard data.count >= offset + 8 else {
                throw VolcengineStreamingClientError.invalidResponse
            }
            offset += 4
        }

        let payloadSize = Int(UInt32(bigEndianBytes: data[offset..<(offset + 4)]))
        offset += 4

        guard data.count >= offset + payloadSize else {
            throw VolcengineStreamingClientError.invalidResponse
        }

        let payload = data[offset..<(offset + payloadSize)]

        if messageType == 0xf {
            let message = String(data: payload, encoding: .utf8) ?? L10n.tr("Unknown error.")
            throw VolcengineStreamingClientError.serverError(message)
        }

        guard messageType == 0x9, serialization == 0x1 else {
            return nil
        }

        let jsonObject = try JSONSerialization.jsonObject(with: payload)
        guard
            let json = jsonObject as? [String: Any],
            let result = json["result"] as? [String: Any]
        else {
            return ParsedServerResponse(update: nil, isFinalResponse: flags == 0x3)
        }

        guard let text = result["text"] as? String else {
            return ParsedServerResponse(update: nil, isFinalResponse: flags == 0x3)
        }

        let utterances = result["utterances"] as? [[String: Any]] ?? []
        let isDefinite = utterances.last?["definite"] as? Bool ?? false
        return ParsedServerResponse(
            update: RecognitionUpdate(text: text, isDefinite: isDefinite),
            isFinalResponse: flags == 0x3
        )
    }
}

private struct ParsedServerResponse {
    let update: VolcengineStreamingClient.RecognitionUpdate?
    let isFinalResponse: Bool
}

private final class WebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
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

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian, Array.init)
    }
}

private extension UInt32 {
    init(bigEndianBytes bytes: Data.SubSequence) {
        self = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

enum VolcengineStreamingClientError: LocalizedError {
    case missingAPIKey
    case sessionAlreadyStarted
    case sessionNotStarted
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L10n.tr("Volcengine API key is missing.")
        case .sessionAlreadyStarted:
            return L10n.tr("Volcengine streaming session is already running.")
        case .sessionNotStarted:
            return L10n.tr("Volcengine streaming session has not started.")
        case .invalidResponse:
            return L10n.tr("Volcengine returned an invalid streaming response.")
        case .serverError(let message):
            return L10n.tr("Volcengine transcription failed: %@", message)
        }
    }
}
