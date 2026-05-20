import Foundation

enum RecognitionEngine: String, CaseIterable, Identifiable {
    case volcengine
    case sherpaOnnx

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volcengine:
            return L10n.tr("Doubao Streaming Speech Recognition 2.0")
        case .sherpaOnnx:
            return L10n.tr("sherpa-onnx Local")
        }
    }
}
