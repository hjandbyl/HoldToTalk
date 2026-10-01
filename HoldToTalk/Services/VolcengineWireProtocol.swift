import Foundation

enum VolcengineWireProtocol {
    static func fullClientRequest(language: TranscriptionLanguage) -> Data {
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

    static func audioRequest(payload: Data, isFinal: Bool) -> Data {
        packet(
            messageType: 0x2,
            flags: isFinal ? 0x2 : 0x0,
            serialization: 0x0,
            compression: 0x0,
            sequence: nil,
            payload: payload
        )
    }

    static func packet(
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

    static func parseServerResponse(_ data: Data) throws -> ParsedServerResponse? {
        guard data.count >= 8 else {
            throw VolcengineStreamingClientError.invalidResponse
        }

        let headerSize = Int(data[0] & 0x0f) * 4
        let messageType = data[1] >> 4
        let flags = data[1] & 0x0f
        let serialization = data[2] >> 4
        guard data[0] >> 4 == 1, data[2] & 0x0f == 0 else { throw VolcengineStreamingClientError.invalidResponse }

        guard headerSize >= 4, data.count >= headerSize + 4 else {
            throw VolcengineStreamingClientError.invalidResponse
        }

        var offset = headerSize
        if messageType == 0xf {
            guard data.count >= offset + 8 else { throw VolcengineStreamingClientError.invalidResponse }
            offset += 4 // Server error code precedes the payload length.
        }
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
            return ParsedServerResponse(update: nil, isFinalResponse: (flags & 0x2) != 0)
        }

        guard let text = result["text"] as? String else {
            return ParsedServerResponse(update: nil, isFinalResponse: (flags & 0x2) != 0)
        }

        let utterances = result["utterances"] as? [[String: Any]] ?? []
        let isDefinite = utterances.last?["definite"] as? Bool ?? false
        return ParsedServerResponse(
            update: RecognitionUpdate(text: text, isDefinite: isDefinite),
            isFinalResponse: (flags & 0x2) != 0
        )
    }
}

struct ParsedServerResponse {
    let update: RecognitionUpdate?
    let isFinalResponse: Bool
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
