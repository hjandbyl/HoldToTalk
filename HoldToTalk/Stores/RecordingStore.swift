import Foundation

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var pendingCount = 0
    @Published var statusMessage = L10n.tr("Starting...")
    @Published var lastTranscript = ""
    let inputVisualization = AudioInputVisualization()
    let liveTranscription = LiveTranscriptionState()

    var isTranscribing: Bool { pendingCount > 0 }
    var headerSystemImage: String {
        isRecording ? "mic.circle.fill" : isTranscribing ? "waveform.circle.fill" : "keyboard"
    }
    var menuBarIconAssetName: String {
        isRecording ? "MenuBarIconRecordingTemplate" : isTranscribing ? "MenuBarIconTranscribingTemplate" : "MenuBarIconIdleTemplate"
    }
    func update(recording: Bool, pending: Int) {
        if isRecording != recording { isRecording = recording }
        if pendingCount != pending { pendingCount = pending }
    }
}
