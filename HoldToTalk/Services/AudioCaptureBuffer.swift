import AVFoundation
import Foundation
import CSherpaOnnx

/// A fixed PCM pool. The producer never waits for disk, conversion, analysis, or a lock.
/// Atomic frame cursors protect the ring; only the serial consumer uses the processing buffer.
final class AudioCaptureBuffer: @unchecked Sendable {
    private let state: UnsafeMutableRawPointer
    private let queue = DispatchQueue(label: "HoldToTalk.capture.processing", qos: .userInitiated)
    private let source: DispatchSourceUserDataAdd
    private let overflow: DispatchSourceUserDataAdd
    private let storage: AVAudioPCMBuffer
    private let processing: AVAudioPCMBuffer
    private let consume: @Sendable (AVAudioPCMBuffer) -> Void
    private let firstFrame: @Sendable () -> Void
    private let failure: @Sendable (Error) -> Void

    init(format: AVAudioFormat, seconds: Double = 2,
         consume: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         failure: @escaping @Sendable (Error) -> Void, firstFrame: @escaping @Sendable () -> Void = {}) throws {
        guard format.sampleRate > 0, seconds > 0,
              let storage = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(format.sampleRate * seconds))),
              let processing = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048),
              let state = HTTAudioQueueCreate() else { throw AudioRecorderError.couldNotCreateInputBuffer }
        self.state = state
        self.storage = storage
        self.processing = processing
        storage.frameLength = storage.frameCapacity
        self.consume = consume
        self.failure = failure
        self.firstFrame = firstFrame
        source = DispatchSource.makeUserDataAddSource(queue: queue)
        overflow = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        overflow.setEventHandler { [weak self] in self?.failure(DictationError.bufferOverflow) }
        source.resume()
        overflow.resume()
    }

    deinit { source.cancel(); overflow.cancel(); HTTAudioQueueDestroy(state) }

    func append(_ input: AVAudioPCMBuffer) {
        guard input.frameLength > 0, !HTTAudioQueueClosed(state), !HTTAudioQueueFailed(state) else { return }
        let read = HTTAudioQueueRead(state)
        let write = HTTAudioQueueWrite(state)
        let capacity = UInt64(storage.frameCapacity)
        guard UInt64(input.frameLength) <= capacity - (write - read), input.format == storage.format else {
            if HTTAudioQueueFail(state) { overflow.add(data: 1) }
            return
        }
        let offset = AVAudioFrameCount(write % capacity)
        let first = min(input.frameLength, storage.frameCapacity - offset)
        copy(from: input, offset: 0, to: storage, destinationOffset: offset, frames: first)
        if first < input.frameLength {
            copy(from: input, offset: first, to: storage, destinationOffset: 0, frames: input.frameLength - first)
        }
        HTTAudioQueuePublish(state, write + UInt64(input.frameLength))
        if write == 0 { firstFrame() }
        source.add(data: 1)
    }

    private func drain() {
        var read = HTTAudioQueueRead(state)
        while true {
            let available = HTTAudioQueueWrite(state) - read
            guard available > 0 else { return }
            let frames = AVAudioFrameCount(min(available, UInt64(processing.frameCapacity)))
            let offset = AVAudioFrameCount(read % UInt64(storage.frameCapacity))
            let first = min(frames, storage.frameCapacity - offset)
            processing.frameLength = frames
            copy(from: storage, offset: offset, to: processing, destinationOffset: 0, frames: first)
            if first < frames { copy(from: storage, offset: 0, to: processing, destinationOffset: first, frames: frames - first) }
            read += UInt64(frames)
            HTTAudioQueueRelease(state, read)
            consume(processing)
        }
    }

    private func copy(from source: AVAudioPCMBuffer, offset: AVAudioFrameCount,
                      to destination: AVAudioPCMBuffer, destinationOffset: AVAudioFrameCount, frames: AVAudioFrameCount) {
        let inputs = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let outputs = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        let stride = Int(storage.format.streamDescription.pointee.mBytesPerFrame)
        for index in 0..<inputs.count {
            memcpy(outputs[index].mData!.advanced(by: Int(destinationOffset) * stride),
                   inputs[index].mData!.advanced(by: Int(offset) * stride), Int(frames) * stride)
        }
    }

    /// Called after the hardware producer has stopped.
    func close() throws {
        HTTAudioQueueClose(state)
        queue.sync { drain() }
        source.cancel()
        overflow.cancel()
        if HTTAudioQueueFailed(state) { throw DictationError.bufferOverflow }
    }

}

final class AudioCaptureService: RecordingCapture, @unchecked Sendable {
    private let queue = DispatchQueue(label: "HoldToTalk.capture.lifecycle", qos: .userInitiated)
    private let recorder = AudioRecorder()

    func start(inputDeviceUID: String?, audio: (@Sendable (Data) -> Void)?,
               analysis: @escaping @Sendable (AudioInputAnalysis) -> Void,
               failure: @escaping @Sendable (Error) -> Void,
               firstFrame: @escaping @Sendable () -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [recorder] in
                continuation.resume(with: Result {
                    try recorder.start(inputDeviceUID: inputDeviceUID, streamingChunkHandler: audio,
                        inputAnalysisHandler: analysis, failureHandler: failure, firstFrameHandler: firstFrame)
                })
            }
        }
    }

    func stop(heldDuration: TimeInterval) async -> CapturedRecording? {
        await withCheckedContinuation { continuation in
            queue.async { [recorder] in
                guard let url = recorder.stop() else { continuation.resume(returning: nil); return }
                continuation.resume(returning: CapturedRecording(url: url,
                    finalAudio: recorder.takePendingStreamingAudio(), summary: recorder.captureSummary(heldDuration: heldDuration), failure: recorder.failure))
            }
        }
    }
}
