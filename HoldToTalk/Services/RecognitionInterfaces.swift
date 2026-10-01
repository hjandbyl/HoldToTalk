import Foundation

struct RecognitionUpdate: Sendable {
    let text: String
    let isDefinite: Bool
}

enum CloudRecognitionEvent: Sendable {
    case update(RecognitionUpdate)
    case failure(Error)
}

protocol CloudRecognizing: Sendable {
    func prepare(language: TranscriptionLanguage) async throws
    func start(language: TranscriptionLanguage, eventHandler: @escaping @Sendable (CloudRecognitionEvent) -> Void) async throws
    func sendAudio(_ data: Data) async throws
    func finish(finalAudio: Data?) async throws -> String
    func cancel() async
}

protocol LocalRecognizing: Sendable {
    func preload(model: LocalSpeechModel, language: String) async throws
    func transcribe(audioURL: URL, language: String, model: LocalSpeechModel) async throws -> String
    func clearCache() async
}

struct CapturedRecording: Sendable {
    let url: URL
    let finalAudio: Data
    let summary: String
    var failure: Error? = nil
}

protocol RecordingCapture: Sendable {
    func start(
        inputDeviceUID: String?,
        audio: (@Sendable (Data) -> Void)?,
        analysis: @escaping @Sendable (AudioInputAnalysis) -> Void,
        failure: @escaping @Sendable (Error) -> Void,
        firstFrame: @escaping @Sendable () -> Void
    ) async throws -> URL
    func stop(heldDuration: TimeInterval) async -> CapturedRecording?
}

enum InsertionOutcome: Sendable {
    case accessibilityWrite, keyboardEvents, pasteShortcut
}

@MainActor
protocol TextInserting {
    func insert(_ text: String, target: InsertionTarget?) async throws -> InsertionOutcome
}

/// The audio callback only pushes bytes. A single consumer owns all network sends.
/// Unbounded stream storage is explicitly constrained by byte accounting (including the in-flight chunk).
final class CloudAudioBuffer: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var bufferedBytes = 0
    private var peakBytes = 0
    private var closed = false
    private let limit: Int

    init(limit: Int = 16_000 * 2 * 10) {
        self.limit = limit
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    @discardableResult
    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        guard bufferedBytes + data.count <= limit else {
            closed = true
            continuation.finish(throwing: DictationError.bufferOverflow)
            return false
        }
        bufferedBytes += data.count
        peakBytes = max(peakBytes, bufferedBytes)
        continuation.yield(data)
        return true
    }

    func consumed(_ data: Data) {
        lock.lock()
        bufferedBytes -= data.count
        lock.unlock()
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        continuation.finish(throwing: error)
    }

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakBytes
    }
}
