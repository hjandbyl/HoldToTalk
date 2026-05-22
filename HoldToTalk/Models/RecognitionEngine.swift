import Foundation

enum RecognitionEngine: String, CaseIterable, Identifiable {
    case volcengine
    case qwenASR
    case sherpaOnnx

    var id: String { rawValue }

    var isCloud: Bool {
        self != .sherpaOnnx
    }

    var title: String {
        switch self {
        case .volcengine:
            return L10n.tr("Doubao Streaming Speech Recognition 2.0")
        case .qwenASR:
            return L10n.tr("Qwen3-ASR Flash Realtime")
        case .sherpaOnnx:
            return L10n.tr("sherpa-onnx Local")
        }
    }
}
