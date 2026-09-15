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
        let nextLevel = snapshot.level * (1 - levelSmoothing) + clampedLevel * levelSmoothing
        let smoothedLevel = nextLevel < 0.002 ? 0 : nextLevel

        var smoothedSpectrum = [Double]()
        smoothedSpectrum.reserveCapacity(AudioRecorder.spectrumBandCount)
        var maximumChange = abs(smoothedLevel - snapshot.level)
        for index in 0..<AudioRecorder.spectrumBandCount {
            let incoming = min(1, max(0, index < analysis.spectrum.count ? analysis.spectrum[index] : 0))
            let current = index < snapshot.spectrum.count ? snapshot.spectrum[index] : 0
            let smoothing = incoming > current ? 0.72 : 0.30
            let nextValue = current * (1 - smoothing) + incoming * smoothing
            let smoothedValue = nextValue < 0.002 ? 0 : nextValue
            smoothedSpectrum.append(smoothedValue)
            maximumChange = max(maximumChange, abs(smoothedValue - current))
        }

        guard maximumChange >= 0.001 else { return }
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
