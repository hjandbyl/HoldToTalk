import XCTest
import AVFoundation
@testable import HoldToTalk

final class ManualClock: DictationClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 100
    private var sleepers: [UUID: (Double, AsyncResult<Void>)] = [:]
    func now() -> TimeInterval { lock.withLock { time } }
    func hasDeadline(in seconds: Double) -> Bool { lock.withLock { sleepers.values.contains { abs($0.0 - time - seconds) < 0.001 } } }
    var sleeperCount: Int { lock.withLock { sleepers.count } }
    func sleep(for seconds: TimeInterval) async throws {
        let id = UUID()
        let result = AsyncResult<Void>()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            lock.withLock { sleepers[id] = (time + seconds, result) }
            defer { _ = lock.withLock { sleepers.removeValue(forKey: id) } }
            try await result.value()
        } onCancel: {
            result.resolve(.failure(CancellationError()))
        }
    }
    func advance(_ seconds: Double) {
        let ready = lock.withLock { () -> [AsyncResult<Void>] in
            time += seconds
            let ready = sleepers.filter { $0.value.0 <= time }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return ready.values.map(\.1)
        }
        ready.forEach { $0.resolve(.success(())) }
    }
}

final class FakeCapture: RecordingCapture, @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("HoldToTalk-test-\(UUID()).wav")
    private let lock = NSLock()
    private var _started = false
    private var _stopCount = 0
    private var audio: (@Sendable (Data) -> Void)?
    private var failure: (@Sendable (Error) -> Void)?
    var startError: Error?
    var stopGate: AsyncResult<Void>?
    var capturedError: Error?
    var started: Bool { lock.withLock { _started } }
    var stopCount: Int { lock.withLock { _stopCount } }
    func start(inputDeviceUID: String?, audio: (@Sendable (Data) -> Void)?, analysis: @escaping @Sendable (AudioInputAnalysis) -> Void,
               failure: @escaping @Sendable (Error) -> Void, firstFrame: @escaping @Sendable () -> Void) async throws -> URL {
        if let startError { throw startError }
        try Data("test audio".utf8).write(to: url)
        lock.withLock { self.audio = audio; self.failure = failure; _started = true }
        firstFrame()
        return url
    }
    func stop(heldDuration: TimeInterval) async -> CapturedRecording? {
        if let stopGate { _ = try? await stopGate.value() }
        return lock.withLock {
            _stopCount += 1
            guard _started else { return nil }
            _started = false
            return CapturedRecording(url: url, finalAudio: Data([1, 2]), summary: "test", failure: capturedError)
        }
    }
    func emit(_ data: Data) { lock.withLock { audio }?(data) }
    func fail() { lock.withLock { failure }?(DictationError.captureFailed) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

actor FakeLocalRecognizer: LocalRecognizing {
    var requests: [URL: AsyncResult<String>] = [:]
    func preload(model: LocalSpeechModel, language: String) async throws { }
    func clearCache() async { }
    func transcribe(audioURL: URL, language: String, model: LocalSpeechModel) async throws -> String {
        let result = AsyncResult<String>()
        requests[audioURL] = result
        return try await result.value()
    }
    func hasRequest(_ url: URL) -> Bool { requests[url] != nil }
    func resolve(_ url: URL, _ result: Result<String, Error>) { requests[url]?.resolve(result) }
}

actor FakeCloudRecognizer: CloudRecognizing {
    let finalResult = AsyncResult<String>()
    var handler: (@Sendable (CloudRecognitionEvent) -> Void)?
    var started = false
    var finished = false
    var cancelled = false
    var chunks: [Data] = []
    var startError: Error?
    func setStartError(_ error: Error) { startError = error }
    func prepare(language: TranscriptionLanguage) async throws { }
    func start(language: TranscriptionLanguage, eventHandler: @escaping @Sendable (CloudRecognitionEvent) -> Void) async throws {
        if let startError { throw startError }
        handler = eventHandler
        started = true
    }
    func sendAudio(_ data: Data) async throws {
        if cancelled { throw CancellationError() }
        chunks.append(data)
    }
    func finish(finalAudio: Data?) async throws -> String {
        finished = true
        return try await finalResult.value()
    }
    func cancel() { cancelled = true; finalResult.resolve(.failure(CancellationError())) }
    func resolve(_ text: String) { finalResult.resolve(.success(text)) }
    func partial(_ text: String) { handler?(.update(RecognitionUpdate(text: text, isDefinite: false))) }
}

@MainActor
final class FakeInjector: TextInserting {
    var texts: [String] = []
    var targets: [InsertionTarget?] = []
    var error: Error?
    func insert(_ text: String, target: InsertionTarget?) async throws -> InsertionOutcome {
        try Task.checkCancellation()
        if let error { throw error }
        texts.append(text)
        targets.append(target)
        return .keyboardEvents
    }
}

@MainActor
final class DictationHarness {
    let clock = ManualClock()
    let recording = RecordingStore()
    let diagnostics: DiagnosticsStore
    let local = FakeLocalRecognizer()
    let injector = FakeInjector()
    var captures: [FakeCapture] = []
    var clouds: [FakeCloudRecognizer] = []
    var nextCapture: FakeCapture?
    var nextCloud: FakeCloudRecognizer?
    var overlayEvents: [OverlayEvent] = []
    lazy var coordinator = DictationCoordinator(recording: recording, diagnostics: diagnostics,
        makeCapture: { [unowned self] in
            let capture = self.nextCapture ?? FakeCapture(); self.nextCapture = nil
            self.captures.append(capture); return capture
        }, makeCloud: { [unowned self] _ in
            let cloud = self.nextCloud ?? FakeCloudRecognizer(); self.nextCloud = nil
            self.clouds.append(cloud); return cloud
        }, local: local, injector: injector, clock: clock)
    init() {
        let defaults = UserDefaults(suiteName: "HoldToTalk-tests-\(UUID())")!
        diagnostics = DiagnosticsStore(defaults: defaults)
    }
    func configuration(engine: RecognitionEngine = .sherpaOnnx, trigger: RecordingTrigger = .manual,
                       tail: Double = 0, autoPaste: Bool = true, removePeriod: Bool = true) -> SessionConfiguration {
        SessionConfiguration(engine: engine, language: .auto, model: .defaultModel, inputDeviceUID: "test-device",
            target: InsertionTarget(processIdentifier: 42, bundleIdentifier: "test", name: "Test"), trigger: trigger,
            autoPaste: autoPaste, removesTrailingSentencePeriod: removePeriod, tailPadding: tail, retainDiagnosticAudio: false)
    }
}

@MainActor
func eventually(_ description: String = "condition", file: StaticString = #filePath, line: UInt = #line,
                _ predicate: () async -> Bool) async {
    for _ in 0..<2_000 {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Timed out: \(description)", file: file, line: line)
}
