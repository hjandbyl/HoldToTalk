import XCTest
import AVFoundation
@testable import HoldToTalk

@MainActor
final class ConcurrencyPrimitiveTests: XCTestCase {
    func testOneShotResolvesOnceAndCancelledWaiterDoesNotStealResult() async throws {
        let result = AsyncResult<Int>()
        let cancelled = Task { try await result.value() }
        await Task.yield()
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertTrue(result.resolve(.success(42)))
        XCTAssertFalse(result.resolve(.success(99)))
        let value = try await result.value()
        XCTAssertEqual(value, 42)
    }

    func testCloudBufferIsBoundedAndDeliversFailure() async {
        let buffer = CloudAudioBuffer(limit: 4)
        XCTAssertTrue(buffer.append(Data([1, 2, 3, 4])))
        XCTAssertFalse(buffer.append(Data([5])))
        XCTAssertEqual(buffer.peak, 4)
        do {
            for try await chunk in buffer.stream { buffer.consumed(chunk) }
            XCTFail("Expected overflow")
        } catch { XCTAssertTrue(error is DictationError) }
    }

    func testFiveMinutesOfPCMThroughSingleConsumerRetainsOrder() async throws {
        let buffer = CloudAudioBuffer()
        let received = Task.detached { () throws -> Int in
            var count = 0
            for try await chunk in buffer.stream {
                XCTAssertEqual(chunk.count, 3_200)
                XCTAssertEqual(chunk.first, UInt8(count % 251))
                count += 1
                buffer.consumed(chunk)
            }
            return count
        }
        // 3,000 x 100 ms represents five minutes of 16 kHz mono PCM, without microphone access.
        for index in 0..<3_000 {
            XCTAssertTrue(buffer.append(Data(repeating: UInt8(index % 251), count: 3_200)))
            if index % 20 == 0 { try await Task.sleep(for: .milliseconds(1)) }
        }
        buffer.finish()
        let count = try await received.value
        XCTAssertEqual(count, 3_000)
        XCTAssertLessThanOrEqual(buffer.peak, 320_000)
    }

    func testCapturePoolCopiesReusableHardwareBufferAndDrainsTail() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3_000)!
        input.frameLength = 3_000
        for channel in 0..<2 {
            for frame in 0..<3_000 { input.floatChannelData![channel][frame] = Float(channel * 3_000 + frame) }
        }
        let sink = AudioSampleSink()
        let pool = try AudioCaptureBuffer(format: format, consume: { sink.consume($0) }, failure: { _ in XCTFail("Unexpected overflow") })
        pool.append(input)
        for channel in 0..<2 { input.floatChannelData![channel].initialize(repeating: -1, count: 3_000) }
        try pool.close()
        XCTAssertEqual(sink.channels[0], (0..<3_000).map(Float.init))
        XCTAssertEqual(sink.channels[1], (3_000..<6_000).map(Float.init))
    }

    func testRingWrapAndInterleavedPCMRemainOrdered() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 2, interleaved: true)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_000)!
        input.frameLength = 2_000
        let output = InterleavedSink()
        let pool = try AudioCaptureBuffer(format: format, seconds: 0.2, consume: { output.consume($0) }, failure: { _ in XCTFail("Unexpected overflow") })
        for chunk in 0..<10 {
            for sample in 0..<4_000 { input.int16ChannelData![0][sample] = Int16((chunk * 4_000 + sample) % 30_000) }
            pool.append(input)
            await eventually { output.count == (chunk + 1) * 4_000 }
        }
        try pool.close()
        XCTAssertEqual(output.values, (0..<40_000).map { Int16($0 % 30_000) })
    }

    func testCaptureOverflowIsExplicitAtClose() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        input.frameLength = 4_096
        let pool = try AudioCaptureBuffer(format: format, seconds: 0.01, consume: { _ in }, failure: { _ in })
        pool.append(input)
        XCTAssertThrowsError(try pool.close())
    }
}

private final class AudioSampleSink: @unchecked Sendable {
    var channels: [[Float]] = [[], []] // Written only by the PCM consumer; read after close drains it.
    func consume(_ buffer: AVAudioPCMBuffer) {
        for channel in 0..<2 {
            channels[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
        }
    }
}

private final class InterleavedSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []
    var count: Int { lock.withLock { samples.count } }
    var values: [Int16] { lock.withLock { samples } }
    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { samples.append(contentsOf: UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2)) }
    }
}
