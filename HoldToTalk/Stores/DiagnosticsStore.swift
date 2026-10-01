import Foundation
import OSLog

struct SessionMetrics: Sendable {
    let id: UUID
    let engine: RecognitionEngine
    let firstFrameMilliseconds: Double?
    let resultMilliseconds: Double?
    let insertionMilliseconds: Double?
    let bufferedBytes: Int
    let outcome: String
    let reason: String
    let remainingSessions: Int

    var formattedTimings: String {
        func milliseconds(_ value: Double?) -> String {
            guard let value else { return L10n.tr("Not measured") }
            return L10n.tr("%.0f ms", value)
        }
        return L10n.tr("First frame %@, result %@, insertion %@", milliseconds(firstFrameMilliseconds), milliseconds(resultMilliseconds), milliseconds(insertionMilliseconds))
    }
}

@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published var shortcutEventText = L10n.tr("No shortcut event yet.")
    @Published var lastRecordingInfo = L10n.tr("No recording yet.")
    @Published var targetAppText = L10n.tr("No target app yet.")
    @Published private(set) var metrics: [SessionMetrics] = []
    @Published var retainDiagnosticAudio: Bool {
        didSet {
            retentionAuthorization?.cancel()
            retentionAuthorization = retainDiagnosticAudio ? WorkCancellation() : nil
            defaults.set(retainDiagnosticAudio, forKey: "HoldToTalk.retainDiagnosticAudio")
            if !retainDiagnosticAudio { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("HoldToTalk-last.wav")) }
        }
    }
    private(set) var retentionAuthorization: WorkCancellation?
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.local.HoldToTalk", category: "Dictation")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        retainDiagnosticAudio = defaults.bool(forKey: "HoldToTalk.retainDiagnosticAudio")
        retentionAuthorization = retainDiagnosticAudio ? WorkCancellation() : nil
    }

    func record(_ metric: SessionMetrics) {
        metrics.append(metric)
        if metrics.count > 100 { metrics.removeFirst(metrics.count - 100) }
        logger.info("session=\(metric.id.uuidString, privacy: .public) engine=\(metric.engine.rawValue, privacy: .public) outcome=\(metric.outcome, privacy: .public) firstFrameMs=\(metric.firstFrameMilliseconds ?? -1) resultMs=\(metric.resultMilliseconds ?? -1) insertionMs=\(metric.insertionMilliseconds ?? -1) peakBytes=\(metric.bufferedBytes) reason=\(metric.reason, privacy: .public) remaining=\(metric.remainingSessions)")
    }
}
