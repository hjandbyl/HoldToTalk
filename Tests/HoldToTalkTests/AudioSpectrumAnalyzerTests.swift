import AVFoundation
import XCTest
@testable import HoldToTalk

final class AudioSpectrumAnalyzerTests: XCTestCase {
    func testQuietAndNormalMicrophonesHaveComparableDisplayLevelsAndSpectra() {
        let quiet = AudioSpectrumAnalyzer().analysis(from: [tone(amplitude: 0.008)])
        let normal = AudioSpectrumAnalyzer().analysis(from: [tone(amplitude: 0.08)])

        XCTAssertGreaterThan(quiet.level, 0.5)
        XCTAssertEqual(quiet.level, normal.level, accuracy: 0.01)
        for (quietBand, normalBand) in zip(quiet.spectrum, normal.spectrum) {
            XCTAssertEqual(quietBand, normalBand, accuracy: 0.01)
        }
    }

    func testEitherStereoChannelCanDriveTheWaveform() {
        let voice = tone(amplitude: 0.04)
        let silence = Array(repeating: Float(0), count: voice.count)
        let left = AudioSpectrumAnalyzer().analysis(from: [voice, silence])
        let right = AudioSpectrumAnalyzer().analysis(from: [silence, voice])

        XCTAssertGreaterThan(right.level, 0.5)
        XCTAssertEqual(left.level, right.level, accuracy: 0.0001)
        XCTAssertEqual(left.spectrum, right.spectrum)
    }

    func testDuplicateMonoAndOppositePhaseStereoPreserveDisplayEnergy() {
        let voice = tone(amplitude: 0.04)
        let mono = AudioSpectrumAnalyzer().analysis(from: [voice])
        let duplicate = AudioSpectrumAnalyzer().analysis(from: [voice, voice])
        let opposite = AudioSpectrumAnalyzer().analysis(from: [voice, voice.map { -$0 }])

        XCTAssertEqual(mono.level, duplicate.level, accuracy: 0.0001)
        XCTAssertEqual(mono.level, opposite.level, accuracy: 0.0001)
        for index in mono.spectrum.indices {
            XCTAssertEqual(mono.spectrum[index], duplicate.spectrum[index], accuracy: 0.0001)
            XCTAssertEqual(mono.spectrum[index], opposite.spectrum[index], accuracy: 0.0001)
        }
    }

    func testIndependentStereoSourcesBothAppearInTheSpectrum() {
        let result = AudioSpectrumAnalyzer().analysis(from: [
            tone(amplitude: 0.04, bin: 6),
            tone(amplitude: 0.04, bin: 86)
        ])

        XCTAssertGreaterThan(result.spectrum[0], 0.4)
        XCTAssertGreaterThan(result.spectrum[10], 0.4)
        XCTAssertLessThan(result.spectrum[5], 0.01)
    }

    func testBandIncludesEnergyBetweenThePreviouslySampledFFTBins() {
        let result = AudioSpectrumAnalyzer().analysis(from: [tone(amplitude: 0.04, bin: 6)])
        XCTAssertGreaterThan(result.spectrum[0], 0.5)
    }

    func testCompensationPreservesSyllableDynamics() {
        let analyzer = AudioSpectrumAnalyzer()
        let loud = analyzer.analysis(from: [tone(amplitude: 0.064)])
        let soft = analyzer.analysis(from: [tone(amplitude: 0.016)])

        XCTAssertGreaterThan(soft.level, 0)
        XCTAssertLessThan(soft.level, loud.level * 0.7)
        XCTAssertLessThan(soft.spectrum[0], loud.spectrum[0])
    }

    func testSilenceAndQuietNoiseStayQuietAndDoNotIncreaseGain() {
        let analyzer = AudioSpectrumAnalyzer()
        let speech = analyzer.analysis(from: [tone(amplitude: 0.016)])
        for _ in 0..<120 {
            let silence = analyzer.analysis(from: [Array(repeating: 0, count: 1_024)])
            let noise = analyzer.analysis(from: [tone(amplitude: 0.0002)])
            XCTAssertEqual(silence.level, 0)
            XCTAssertEqual(noise.level, 0)
            XCTAssertTrue(noise.spectrum.allSatisfy { $0 == 0 })
        }
        let resumedSpeech = analyzer.analysis(from: [tone(amplitude: 0.016)])
        XCTAssertEqual(speech.level, resumedSpeech.level, accuracy: 0.0001)
    }

    func testNewRecordingResetsGainAfterChangingMicrophones() {
        let analyzer = AudioSpectrumAnalyzer()
        _ = analyzer.analysis(from: [tone(amplitude: 0.5)])
        let beforeReset = analyzer.analysis(from: [tone(amplitude: 0.008)])
        analyzer.reset()
        let afterReset = analyzer.analysis(from: [tone(amplitude: 0.008)])

        XCTAssertGreaterThan(afterReset.level, beforeReset.level + 0.3)
        XCTAssertGreaterThan(afterReset.spectrum[0], beforeReset.spectrum[0])
    }

    func testCopiesEveryChannelInPlanarAndInterleavedPCMWithoutChangingCapture() throws {
        for commonFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [false, true] {
                let format = try XCTUnwrap(AVAudioFormat(commonFormat: commonFormat, sampleRate: 48_000,
                                                       channels: 2, interleaved: interleaved))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_100))
                buffer.frameLength = 1_100
                for channel in 0..<2 {
                    let value: Float = channel == 0 ? 0.5 : -0.25
                    for frame in 0..<Int(buffer.frameLength) {
                        let plane = interleaved ? 0 : channel
                        let index = interleaved ? frame * 2 + channel : frame
                        switch commonFormat {
                        case .pcmFormatFloat32: buffer.floatChannelData![plane][index] = value
                        case .pcmFormatInt16: buffer.int16ChannelData![plane][index] = Int16(value * 32_768)
                        case .pcmFormatInt32: buffer.int32ChannelData![plane][index] = Int32(value * 2_147_483_648)
                        default: XCTFail("Unexpected test format")
                        }
                    }
                }

                let copied = try XCTUnwrap(AudioSpectrumAnalyzer.samples(from: buffer))
                XCTAssertEqual(copied.count, 2)
                XCTAssertEqual(copied[0], Array(repeating: 0.5, count: AudioSpectrumAnalyzer.bufferSize))
                XCTAssertEqual(copied[1], Array(repeating: -0.25, count: AudioSpectrumAnalyzer.bufferSize))
                _ = AudioSpectrumAnalyzer().analysis(from: copied)
                XCTAssertEqual(AudioSpectrumAnalyzer.samples(from: buffer), copied)
                XCTAssertEqual(buffer.frameLength, 1_100)
            }
        }
    }

    func testEmptyInputHasNoAnalysisSamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        XCTAssertNil(AudioSpectrumAnalyzer.samples(from: buffer))
        let result = AudioSpectrumAnalyzer().analysis(from: [])
        XCTAssertEqual(result.level, 0)
        XCTAssertTrue(result.spectrum.allSatisfy { $0 == 0 })
    }

    private func tone(amplitude: Float, bin: Int = 6) -> [Float] {
        (0..<AudioSpectrumAnalyzer.bufferSize).map { frame in
            amplitude * Float(sin(2 * Double.pi * Double(bin * frame) / Double(AudioSpectrumAnalyzer.bufferSize)))
        }
    }
}
