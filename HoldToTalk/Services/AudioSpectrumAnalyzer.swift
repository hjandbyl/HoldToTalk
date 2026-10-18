import AVFoundation
import Accelerate
import Foundation

/// Display-only processing. Never modifies capture buffers or recognition audio.
/// Owned exclusively by AudioRecorder's serial analysis queue.
final class AudioSpectrumAnalyzer {
    static let bufferSize = 1_024
    private static let binsPerBand = 8
    private let sampleAmount = 2 + AudioRecorder.spectrumBandCount * binsPerBand
    private let magnitudeLimit: Float = 80
    private let setup: OpaquePointer?
    private let window: [Float]
    private var realIn: [Float]
    private var imagIn: [Float]
    private var realOut: [Float]
    private var imagOut: [Float]
    private var magnitudes: [Float]
    private var referenceRMS: Double?

    // Bound compensation to 24 dB and keep very quiet input from becoming full-height noise.
    private let maximumDisplayGain = 16.0
    private let targetRMS = 0.06
    private let noiseFloor = 0.001

    init() {
        setup = vDSP_DFT_zop_CreateSetup(nil, UInt(Self.bufferSize), .FORWARD)
        var window = [Float](repeating: 0, count: Self.bufferSize)
        vDSP_hann_window(&window, UInt(Self.bufferSize), Int32(vDSP_HANN_NORM))
        self.window = window
        realIn = [Float](repeating: 0, count: Self.bufferSize)
        imagIn = [Float](repeating: 0, count: Self.bufferSize)
        realOut = [Float](repeating: 0, count: Self.bufferSize)
        imagOut = [Float](repeating: 0, count: Self.bufferSize)
        magnitudes = [Float](repeating: 0, count: sampleAmount)
    }

    deinit {
        if let setup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    func reset() {
        referenceRMS = nil
    }

    /// Copy every channel, respecting planar/interleaved PCM and leaving the source intact.
    static func samples(from buffer: AVAudioPCMBuffer) -> [[Float]]? {
        let frameCount = min(Int(buffer.frameLength), bufferSize)
        guard frameCount > 0, buffer.format.channelCount > 0 else { return nil }
        if let channels = buffer.floatChannelData {
            return copyChannels(channels, from: buffer, frameCount: frameCount) { $0 }
        }
        if let channels = buffer.int16ChannelData {
            return copyChannels(channels, from: buffer, frameCount: frameCount) { Float($0) / 32_768 }
        }
        if let channels = buffer.int32ChannelData {
            return copyChannels(channels, from: buffer, frameCount: frameCount) { Float($0) / 2_147_483_648 }
        }
        return nil
    }

    private static func copyChannels<Sample>(
        _ channels: UnsafePointer<UnsafeMutablePointer<Sample>>,
        from buffer: AVAudioPCMBuffer,
        frameCount: Int,
        normalize: (Sample) -> Float
    ) -> [[Float]] {
        (0..<Int(buffer.format.channelCount)).map { channel in
            let samples = buffer.format.isInterleaved ? channels[0].advanced(by: channel) : channels[channel]
            return (0..<frameCount).map { normalize(samples[$0 * buffer.stride]) }
        }
    }

    func analysis(from channels: [[Float]]) -> AudioInputAnalysis {
        let channels = channels.filter { !$0.isEmpty }
        guard let setup, !channels.isEmpty else {
            return AudioInputAnalysis(level: 0, spectrum: Self.silence)
        }

        // Average channel powers, not waveforms: duplicate mono keeps its level and
        // independent or opposite-phase stereo channels cannot cancel one another.
        var meanSquare = 0.0
        for channel in channels {
            var rms: Float = 0
            channel.withUnsafeBufferPointer { samples in
                vDSP_rmsqv(samples.baseAddress!, 1, &rms, vDSP_Length(samples.count))
            }
            meanSquare += Double(rms) * Double(rms) / Double(channels.count)
        }
        let rms = sqrt(meanSquare)
        guard rms.isFinite, rms > noiseFloor else {
            return AudioInputAnalysis(level: 0, spectrum: Self.silence)
        }

        // Follow louder speech immediately and release slowly, preserving syllable dynamics.
        // Silence never increases gain; each new recording starts with a fresh reference.
        referenceRMS = max(rms, (referenceRMS ?? rms) * 0.98)
        let gain = min(maximumDisplayGain, max(1, targetRMS / referenceRMS!))
        let gatePosition = min(1, (rms - noiseFloor) / (2 * noiseFloor))
        let gate = gatePosition * gatePosition * (3 - 2 * gatePosition)
        let displayScale = Float(gain * gate)
        let level = min(1, max(0, sqrt(rms * Double(displayScale)) * 2.6))

        var powers = [Float](repeating: 0, count: sampleAmount)
        for channel in channels {
            analyzeChannel(channel, setup: setup, displayScale: displayScale)
            for index in powers.indices {
                powers[index] += magnitudes[index] / Float(channels.count)
            }
        }

        let magnitudeScale = log1p(magnitudeLimit)
        var result = Self.silence
        for band in result.indices {
            let firstBin = 2 + band * Self.binsPerBand
            let bandPower = powers[firstBin..<(firstBin + Self.binsPerBand)].reduce(0, +)
            let limited = min(sqrt(max(bandPower, 0)), magnitudeLimit)
            result[band] = Double(log1p(limited) / magnitudeScale)
        }
        return AudioInputAnalysis(level: level, spectrum: result)
    }

    private func analyzeChannel(_ inputSamples: [Float], setup: OpaquePointer, displayScale: Float) {
        let frameCount = min(inputSamples.count, Self.bufferSize)
        realIn.withUnsafeMutableBufferPointer { destination in
            destination.update(repeating: 0)
            inputSamples.withUnsafeBufferPointer { source in
                guard let sourceAddress = source.baseAddress else { return }
                destination.baseAddress?.update(from: sourceAddress, count: frameCount)
            }
        }
        realIn.withUnsafeMutableBufferPointer { samples in
            window.withUnsafeBufferPointer { window in
                vDSP_vmul(
                    samples.baseAddress!,
                    1,
                    window.baseAddress!,
                    1,
                    samples.baseAddress!,
                    1,
                    vDSP_Length(Self.bufferSize)
                )
            }
            var scale = displayScale
            vDSP_vsmul(samples.baseAddress!, 1, &scale, samples.baseAddress!, 1, vDSP_Length(Self.bufferSize))
        }

        realIn.withUnsafeMutableBufferPointer { realInPtr in
            imagIn.withUnsafeMutableBufferPointer { imagInPtr in
                realOut.withUnsafeMutableBufferPointer { realOutPtr in
                    imagOut.withUnsafeMutableBufferPointer { imagOutPtr in
                        vDSP_DFT_Execute(
                            setup,
                            realInPtr.baseAddress!,
                            imagInPtr.baseAddress!,
                            realOutPtr.baseAddress!,
                            imagOutPtr.baseAddress!
                        )

                        var complex = DSPSplitComplex(
                            realp: realOutPtr.baseAddress!,
                            imagp: imagOutPtr.baseAddress!
                        )
                        vDSP_zvmags(&complex, 1, &magnitudes, 1, UInt(sampleAmount))
                    }
                }
            }
        }
    }

    private static let silence = Array(repeating: 0.0, count: AudioRecorder.spectrumBandCount)
}
