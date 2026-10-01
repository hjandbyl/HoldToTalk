import Foundation

struct InsertionTarget: Sendable, Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let name: String
}

struct SessionConfiguration: Sendable {
    let engine: RecognitionEngine
    let language: TranscriptionLanguage
    let model: LocalSpeechModel
    let inputDeviceUID: String?
    let target: InsertionTarget?
    let trigger: RecordingTrigger
    let autoPaste: Bool
    let removesTrailingSentencePeriod: Bool
    let tailPadding: TimeInterval
    let retainDiagnosticAudio: Bool
}

enum RecordingTrigger: Sendable, Equatable {
    case shortcut(String)
    case manual

    var isManual: Bool { self == .manual }
    var title: String {
        switch self {
        case .manual: return L10n.tr("Manual")
        case .shortcut(let title): return title
        }
    }
}

enum DictationPhase: Sendable {
    case preparing, recording, stopping, recognizing, waitingForInsertion, completed, failed, cancelled
}

enum TranscriptPolicy {
    static func finalize(_ text: String, removingTrailingPeriod: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return removingTrailingPeriod && trimmed.last == "。" ? String(trimmed.dropLast()) : trimmed
    }

    static func isShortTap(trigger: RecordingTrigger, duration: TimeInterval, partial: String) -> Bool {
        !trigger.isManual && duration < 0.22 && partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum DictationError: LocalizedError {
    case busy, bufferOverflow, timedOut, incompleteResult, captureFailed, targetUnavailable, insertionFailed

    var errorDescription: String? {
        switch self {
        case .busy: return L10n.tr("Too many pending recordings. Try again shortly.")
        case .bufferOverflow: return L10n.tr("Audio processing could not keep up. Recording stopped.")
        case .timedOut: return L10n.tr("Recognition timed out. Please try again.")
        case .incompleteResult: return L10n.tr("Recognition ended without a confirmed final result.")
        case .captureFailed: return L10n.tr("Audio capture failed. Please check the microphone.")
        case .targetUnavailable: return L10n.tr("The original target app is no longer available.")
        case .insertionFailed: return L10n.tr("Could not send text to the target app.")
        }
    }
}

protocol DictationClock: Sendable {
    func now() -> TimeInterval
    func sleep(for seconds: TimeInterval) async throws
}

struct SystemDictationClock: DictationClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
