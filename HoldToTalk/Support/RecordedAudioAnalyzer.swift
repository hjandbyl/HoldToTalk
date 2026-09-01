import AVFoundation
import Accelerate
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
    private static let analysisBufferFrameCount: AVAudioFrameCount = 16_384

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

        let bufferCapacity = AVAudioFrameCount(
            min(file.length, AVAudioFramePosition(analysisBufferFrameCount))
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: bufferCapacity
        ) else {
            return RecordedAudioStats(duration: duration, rms: 0, peak: 0, fileSize: fileSize(url: url))
        }

        var peak: Float = 0
        var sumSquares: Double = 0
        var sampleCount = 0

        while file.framePosition < file.length {
            let framesToRead = AVAudioFrameCount(
                min(file.length - file.framePosition, AVAudioFramePosition(buffer.frameCapacity))
            )
            try file.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else { break }

            let frameLength = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                var channelPeak: Float = 0
                var channelSumSquares: Float = 0
                vDSP_maxmgv(samples, 1, &channelPeak, vDSP_Length(frameLength))
                vDSP_svesq(samples, 1, &channelSumSquares, vDSP_Length(frameLength))

                peak = max(peak, channelPeak)
                sumSquares += Double(channelSumSquares)
                sampleCount += frameLength
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
