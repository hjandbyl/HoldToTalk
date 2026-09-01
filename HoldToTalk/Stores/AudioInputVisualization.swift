import Combine
import Foundation

@MainActor
final class AudioInputVisualization: ObservableObject {
    struct Snapshot {
        let level: Double
        let spectrum: [Double]
    }

    @Published private(set) var snapshot = Snapshot(
        level: 0,
        spectrum: Array(repeating: 0, count: AudioRecorder.spectrumBandCount)
    )

    func update(with analysis: AudioInputAnalysis) {
        let clampedLevel = min(1, max(0, analysis.level))
        let levelSmoothing = clampedLevel > snapshot.level ? 0.65 : 0.24
        let smoothedLevel = snapshot.level * (1 - levelSmoothing) + clampedLevel * levelSmoothing

        let smoothedSpectrum = (0..<AudioRecorder.spectrumBandCount).map { index in
            let incoming = min(1, max(0, index < analysis.spectrum.count ? analysis.spectrum[index] : 0))
            let current = index < snapshot.spectrum.count ? snapshot.spectrum[index] : 0
            let smoothing = incoming > current ? 0.72 : 0.30
            return current * (1 - smoothing) + incoming * smoothing
        }

        snapshot = Snapshot(level: smoothedLevel, spectrum: smoothedSpectrum)
    }

    func reset() {
        guard snapshot.level != 0 || snapshot.spectrum.contains(where: { $0 != 0 }) else { return }
        snapshot = Snapshot(
            level: 0,
            spectrum: Array(repeating: 0, count: AudioRecorder.spectrumBandCount)
        )
    }
}

@MainActor
final class LiveTranscriptionState: ObservableObject {
    @Published private(set) var text = ""

    func update(_ newText: String) {
        guard text != newText else { return }
        text = newText
    }
}
