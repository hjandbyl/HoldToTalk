import Foundation

enum QwenSpeechModel: String, CaseIterable, Identifiable, Sendable {
    case message = "qwen-audio-3.1-asr-flash-message"
    case realtime = "qwen3-asr-flash-realtime"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .message: return L10n.tr("Qwen-Audio 3.1 ASR Flash Message")
        case .realtime: return L10n.tr("Qwen3-ASR Flash Realtime")
        }
    }

    var supportedLanguages: [TranscriptionLanguage] {
        switch self {
        // Message's documented WebSocket parameters expose automatic detection,
        // not the legacy Realtime API's explicit language field.
        case .message: return [.auto]
        case .realtime: return TranscriptionLanguage.qwenASRLanguages
        }
    }
}
