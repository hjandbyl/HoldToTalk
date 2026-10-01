import Foundation

enum QwenWireProtocol {
    static func parseServerResponse(_ string: String) throws -> ParsedServerResponse? {
        guard let data = string.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { throw QwenASRStreamingClientError.invalidResponse }
        switch type {
        case "conversation.item.input_audio_transcription.text":
            let text = ((json["text"] as? String) ?? "") + ((json["stash"] as? String) ?? "")
            return ParsedServerResponse(update: RecognitionUpdate(text: text, isDefinite: false), isFinalResponse: false)
        case "conversation.item.input_audio_transcription.completed":
            guard let text = json["transcript"] as? String else { throw QwenASRStreamingClientError.invalidResponse }
            return ParsedServerResponse(update: RecognitionUpdate(text: text, isDefinite: true), isFinalResponse: false)
        case "session.finished": return ParsedServerResponse(update: nil, isFinalResponse: true)
        case "error":
            throw QwenASRStreamingClientError.serverError(json["message"] as? String
                ?? (json["error"] as? [String: Any])?["message"] as? String ?? L10n.tr("Unknown error."))
        default: return nil
        }
    }
    static func sessionUpdateMessage(language: TranscriptionLanguage) -> String {
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

    static func audioAppendMessage(audio: String) -> String {
        jsonString([
            "event_id": eventID(),
            "type": "input_audio_buffer.append",
            "audio": audio
        ])
    }

    static func finishMessage() -> String {
        jsonString([
            "event_id": eventID(),
            "type": "session.finish"
        ])
    }

    static func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    static func eventID() -> String {
        "event_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
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
