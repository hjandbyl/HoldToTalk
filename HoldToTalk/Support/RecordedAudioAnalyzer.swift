import AVFoundation
import Foundation

struct RecordedAudioStats {
    let duration: TimeInterval
    let rms: Double
    let peak: Double
    let fileSize: Int64

    var summary: String {
        let durationText = String(format: "%.2fs", duration)
        let peakText = String(format: "%.2f%%", peak * 100)
        let rmsText = String(format: "%.2f%%", rms * 100)
        return L10n.tr("%@, peak %@, rms %@", durationText, peakText, rmsText)
    }
}

enum RecordedAudioAnalyzer {
    static func analyze(url: URL) throws -> RecordedAudioStats {
        let file = try AVAudioFile(forReading: url)
        let duration = file.fileFormat.sampleRate > 0
            ? Double(file.length) / file.fileFormat.sampleRate
            : 0

        guard file.length > 0 else {
            return RecordedAudioStats(duration: duration, rms: 0, peak: 0, fileSize: fileSize(url: url))
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.fileFormat.sampleRate,
            channels: file.fileFormat.channelCount,
            interleaved: false
        ) else {
            return RecordedAudioStats(duration: duration, rms: 0, peak: 0, fileSize: fileSize(url: url))
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            return RecordedAudioStats(duration: duration, rms: 0, peak: 0, fileSize: fileSize(url: url))
        }

        try file.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            return RecordedAudioStats(duration: duration, rms: 0, peak: 0, fileSize: fileSize(url: url))
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var peak: Float = 0
        var sumSquares: Double = 0
        var sampleCount = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]

            for frame in 0..<frameLength {
                let sample = samples[frame]
                peak = max(peak, abs(sample))
                sumSquares += Double(sample * sample)
                sampleCount += 1
            }
        }

        let rms = sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
        return RecordedAudioStats(duration: duration, rms: rms, peak: Double(peak), fileSize: fileSize(url: url))
    }

    private static func fileSize(url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }
}
