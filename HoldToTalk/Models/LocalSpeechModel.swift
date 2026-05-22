import Foundation

enum LocalSpeechModelKind: String, Sendable {
    case senseVoice
    case fireRedAsr
    case fireRedAsrCtc
    case whisper
}

enum LocalSpeechModelFamily: String, CaseIterable, Identifiable, Sendable {
    case senseVoice
    case fireRedAsr
    case whisper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .senseVoice:
            return "SenseVoice"
        case .fireRedAsr:
            return "FireRedASR"
        case .whisper:
            return "Whisper"
        }
    }
}

struct LocalSpeechModel: Identifiable, Hashable, Sendable {
    let id: String
    let family: LocalSpeechModelFamily
    let kind: LocalSpeechModelKind
    let title: String
    let directoryName: String
    let archiveURL: URL
    let requiredFiles: [String]
    let sizeDescription: String
    let capabilitySummary: String
    let supportedLanguages: [TranscriptionLanguage]
    let punctuationSupport: LocalSpeechModelPunctuationSupport

    var displayTitle: String {
        "\(family.title) · \(title)"
    }

    var supportedLanguageSummary: String {
        let languages = supportedLanguages.filter { $0 != .auto }
        if languages.count > 6 {
            return L10n.tr("%d languages", languages.count)
        }

        return languages.map(\.title).joined(separator: ", ")
    }

    var punctuationSummary: String {
        punctuationSupport.title
    }

    var tokensFileName: String {
        requiredFiles.first { $0.hasSuffix("tokens.txt") } ?? "tokens.txt"
    }

    var whisperFileStem: String? {
        guard kind == .whisper else { return nil }
        return directoryName.replacingOccurrences(of: "sherpa-onnx-whisper-", with: "")
    }

    static let defaultModelID = "sensevoice-2024-07-17-int8"

    static let all: [LocalSpeechModel] = [
        LocalSpeechModel(
            id: "sensevoice-2024-07-17-int8",
            family: .senseVoice,
            kind: .senseVoice,
            title: "2024-07-17 int8",
            directoryName: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2")!,
            requiredFiles: ["model.int8.onnx", "tokens.txt"],
            sizeDescription: "~228 MB",
            capabilitySummary: "Chinese, Cantonese, English, Japanese, Korean. ITN can add punctuation.",
            supportedLanguages: [.auto, .zh, .yue, .en, .ja, .ko],
            punctuationSupport: .supported
        ),
        LocalSpeechModel(
            id: "sensevoice-2025-09-09-int8",
            family: .senseVoice,
            kind: .senseVoice,
            title: "2025-09-09 Cantonese int8",
            directoryName: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2")!,
            requiredFiles: ["model.int8.onnx", "tokens.txt"],
            sizeDescription: "~228 MB",
            capabilitySummary: "Cantonese-tuned SenseVoice. No built-in punctuation support.",
            supportedLanguages: [.auto, .yue],
            punctuationSupport: .notSupported
        ),
        LocalSpeechModel(
            id: "firered-asr2-ctc-2026-02-25-int8",
            family: .fireRedAsr,
            kind: .fireRedAsrCtc,
            title: "ASR2 CTC 2026-02-25 int8",
            directoryName: "sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25.tar.bz2")!,
            requiredFiles: ["model.int8.onnx", "tokens.txt"],
            sizeDescription: "~740 MB",
            capabilitySummary: "Chinese, English, and 20+ Chinese dialects. Fast CPU CTC model.",
            supportedLanguages: [.auto, .zh, .en],
            punctuationSupport: .notSupported
        ),
        LocalSpeechModel(
            id: "firered-asr2-aed-2026-02-26-int8",
            family: .fireRedAsr,
            kind: .fireRedAsr,
            title: "ASR2 AED 2026-02-26 int8",
            directoryName: "sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26.tar.bz2")!,
            requiredFiles: ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"],
            sizeDescription: "~1.2 GB",
            capabilitySummary: "Chinese, English, and 20+ Chinese dialects. More capable AED model.",
            supportedLanguages: [.auto, .zh, .en],
            punctuationSupport: .notSupported
        ),
        LocalSpeechModel(
            id: "firered-asr-large-2025-02-16-int8",
            family: .fireRedAsr,
            kind: .fireRedAsr,
            title: "ASR Large 2025-02-16 int8",
            directoryName: "sherpa-onnx-fire-red-asr-large-zh_en-2025-02-16",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-fire-red-asr-large-zh_en-2025-02-16.tar.bz2")!,
            requiredFiles: ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"],
            sizeDescription: "~1.7 GB",
            capabilitySummary: "Chinese and English. Older FireRedASR large model; slow on CPU.",
            supportedLanguages: [.auto, .zh, .en],
            punctuationSupport: .notSupported
        ),
        LocalSpeechModel(
            id: "whisper-tiny-int8",
            family: .whisper,
            kind: .whisper,
            title: "Tiny int8",
            directoryName: "sherpa-onnx-whisper-tiny",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.tar.bz2")!,
            requiredFiles: ["tiny-encoder.int8.onnx", "tiny-decoder.int8.onnx", "tiny-tokens.txt"],
            sizeDescription: "~150 MB",
            capabilitySummary: "Multilingual Whisper model. Fastest Whisper option; lower accuracy.",
            supportedLanguages: TranscriptionLanguage.whisperLanguages,
            punctuationSupport: .supported
        ),
        LocalSpeechModel(
            id: "whisper-base-int8",
            family: .whisper,
            kind: .whisper,
            title: "Base int8",
            directoryName: "sherpa-onnx-whisper-base",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-base.tar.bz2")!,
            requiredFiles: ["base-encoder.int8.onnx", "base-decoder.int8.onnx", "base-tokens.txt"],
            sizeDescription: "~290 MB",
            capabilitySummary: "Multilingual Whisper model. Balanced speed and accuracy.",
            supportedLanguages: TranscriptionLanguage.whisperLanguages,
            punctuationSupport: .supported
        ),
        LocalSpeechModel(
            id: "whisper-small-int8",
            family: .whisper,
            kind: .whisper,
            title: "Small int8",
            directoryName: "sherpa-onnx-whisper-small",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-small.tar.bz2")!,
            requiredFiles: ["small-encoder.int8.onnx", "small-decoder.int8.onnx", "small-tokens.txt"],
            sizeDescription: "~970 MB",
            capabilitySummary: "Multilingual Whisper model. Higher accuracy; slower on CPU.",
            supportedLanguages: TranscriptionLanguage.whisperLanguages,
            punctuationSupport: .supported
        ),
        LocalSpeechModel(
            id: "whisper-medium-int8",
            family: .whisper,
            kind: .whisper,
            title: "Medium int8",
            directoryName: "sherpa-onnx-whisper-medium",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-medium.tar.bz2")!,
            requiredFiles: ["medium-encoder.int8.onnx", "medium-decoder.int8.onnx", "medium-tokens.txt"],
            sizeDescription: "~2.9 GB",
            capabilitySummary: "Multilingual Whisper large local option. More accurate; slowest on CPU.",
            supportedLanguages: TranscriptionLanguage.whisperLanguages,
            punctuationSupport: .supported
        )
    ]

    static func model(id: String) -> LocalSpeechModel {
        all.first { $0.id == id } ?? defaultModel
    }

    static var defaultModel: LocalSpeechModel {
        all.first { $0.id == defaultModelID } ?? all[0]
    }
}

enum LocalSpeechModelPunctuationSupport: Sendable {
    case supported
    case notSupported

    var title: String {
        switch self {
        case .supported:
            return L10n.tr("Punctuation supported")
        case .notSupported:
            return L10n.tr("No punctuation")
        }
    }
}
