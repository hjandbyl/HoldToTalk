import Foundation

enum QwenMessageEvent {
    case started
    case sentence(QwenMessageSentence)
    case finished
}

struct QwenMessageSentence {
    let id: Int
    let text: String
    let isDefinite: Bool
}

enum QwenMessageWireProtocol {
    static let endpoint = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!

    static func startMessage(taskID: String) -> String {
        QwenWireProtocol.jsonString([
            "header": header(action: "run-task", taskID: taskID),
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": QwenSpeechModel.message.rawValue,
                "parameters": [
                    "format": "pcm",
                    "sample_rate": 16_000,
                    "intermediate_result_enabled": true,
                    "keep_dialect": true,
                    "disfluency_removal_enabled": false,
                    "vad_model": "near_meeting_16k",
                    "max_sentence_silence": 400,
                    "heartbeat": true
                ],
                "input": [:]
            ]
        ])
    }

    static func finishMessage(taskID: String) -> String {
        QwenWireProtocol.jsonString([
            "header": header(action: "finish-task", taskID: taskID),
            "payload": ["input": [:]]
        ])
    }

    private static func header(action: String, taskID: String) -> [String: String] {
        ["action": action, "task_id": taskID, "streaming": "duplex"]
    }

    static func parseServerResponse(_ string: String, taskID: String) throws -> QwenMessageEvent? {
        guard let data = string.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["header"] as? [String: Any],
              header["task_id"] as? String == taskID,
              let event = header["event"] as? String else {
            throw QwenASRStreamingClientError.invalidResponse
        }
        switch event {
        case "task-started": return .started
        case "task-finished": return .finished
        case "task-failed":
            let message = header["error_message"] as? String ?? L10n.tr("Unknown error.")
            let code = header["error_code"] as? String
            throw QwenASRStreamingClientError.serverError(code.map { "\($0): \(message)" } ?? message)
        case "result-generated":
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else {
                throw QwenASRStreamingClientError.invalidResponse
            }
            if sentence["heartbeat"] as? Bool == true { return nil }
            guard let id = sentence["sentence_id"] as? Int, id > 0,
                  let text = sentence["text"] as? String,
                  let isDefinite = sentence["sentence_end"] as? Bool else {
                throw QwenASRStreamingClientError.invalidResponse
            }
            return .sentence(QwenMessageSentence(id: id, text: text, isDefinite: isDefinite))
        default: return nil
        }
    }
}

/// Revisions replace the same sentence; confirmed sentences survive later partials.
struct QwenMessageTranscript {
    private var sentences: [Int: QwenMessageSentence] = [:]

    mutating func update(_ sentence: QwenMessageSentence) -> RecognitionUpdate? {
        if sentences[sentence.id]?.isDefinite == true, !sentence.isDefinite { return nil }
        sentences[sentence.id] = sentence
        return RecognitionUpdate(text: text, isDefinite: sentences.values.allSatisfy(\.isDefinite))
    }

    private var text: String {
        sentences.keys.sorted().compactMap { sentences[$0]?.text }.joined()
    }

    func finalText() throws -> String {
        guard sentences.values.allSatisfy({ $0.isDefinite || $0.text.isEmpty }) else {
            throw DictationError.incompleteResult
        }
        return text
    }
}
