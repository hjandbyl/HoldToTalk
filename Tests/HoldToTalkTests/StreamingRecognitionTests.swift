import XCTest
@testable import HoldToTalk

/// Single receive loop, with producers and cancellation serialized by the lock.
private final class SocketInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [URLSessionWebSocketTask.Message] = []
    private var waiter: AsyncResult<URLSessionWebSocketTask.Message>?
    private var failure: Error?
    func next() async throws -> URLSessionWebSocketTask.Message {
        let result = AsyncResult<URLSessionWebSocketTask.Message>()
        lock.withLock {
            if !messages.isEmpty { result.resolve(.success(messages.removeFirst())) }
            else if let failure { result.resolve(.failure(failure)) }
            else { precondition(waiter == nil); waiter = result }
        }
        return try await result.value()
    }
    func feed(_ message: URLSessionWebSocketTask.Message) {
        lock.withLock {
            guard failure == nil else { return }
            if let waiter { self.waiter = nil; waiter.resolve(.success(message)) }
            else { messages.append(message) }
        }
    }
    func finish(_ error: Error) {
        lock.withLock {
            failure = error
            waiter?.resolve(.failure(error))
            waiter = nil
        }
    }
}

private final class FakeSocket: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let inbox = SocketInbox()
    private var messages: [URLSessionWebSocketTask.Message] = []
    private var _cancelled = false
    let sendGate: AsyncResult<Void>?
    let sendError: Error?
    let gateAfter: Int
    var sendCount: Int { lock.withLock { messages.count } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    init(sendGate: AsyncResult<Void>? = nil, sendError: Error? = nil, gateAfter: Int = 0) {
        self.sendGate = sendGate
        self.sendError = sendError
        self.gateAfter = gateAfter
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { messages.append(message) }
        if let sendError { throw sendError }
        if let sendGate, sendCount > gateAfter { try await sendGate.value() }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await inbox.next() }
    func cancel() {
        lock.withLock { _cancelled = true }
        sendGate?.resolve(.failure(CancellationError()))
        inbox.finish(CancellationError())
    }
    func feed(_ message: URLSessionWebSocketTask.Message) { inbox.feed(message) }
    func disconnect() { inbox.finish(URLError(.networkConnectionLost)) }
}

@MainActor
final class StreamingRecognitionTests: XCTestCase {
    func testIdlePrewarmFailureInvalidatesThePreparedConnection() async throws {
        let failure = AsyncResult<Void>()
        let socket = FakeSocket()
        let cloud = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test",
            idleFailureHandler: { failure.resolve(.success(())) }, makeTransport: { _ in socket })
        try await cloud.prepare(language: .auto)
        socket.disconnect()
        try await withDictationTimeout(seconds: 2) { try await failure.value() }
        XCTAssertTrue(socket.cancelled)
    }

    func testReceiveFailuresStopCaptureWithoutWaitingForMoreAudioOrRelease() async {
        for disconnect in [false, true] {
            let harness = DictationHarness()
            let capture = FakeCapture()
            let socket = FakeSocket()
            let cloud = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", makeTransport: { _ in socket })
            let coordinator = DictationCoordinator(recording: harness.recording, diagnostics: harness.diagnostics,
                makeCapture: { capture }, makeCloud: { _ in cloud }, local: harness.local,
                injector: harness.injector, clock: harness.clock)
            coordinator.start(harness.configuration(engine: .qwenASR))
            await eventually { capture.started && socket.sendCount == 1 }
            if disconnect { socket.disconnect() }
            else { socket.feed(.string(#"{"type":"error","error":{"message":"quota exhausted"}}"#)) }
            await eventually { coordinator.outstandingCount == 0 }
            XCTAssertFalse(harness.recording.isRecording)
            XCTAssertEqual(capture.stopCount, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: capture.url.path))
            XCTAssertTrue(harness.injector.texts.isEmpty)
            XCTAssertTrue(socket.cancelled)
            await coordinator.shutdown()
        }
    }

    func testQwenWaitsForSessionFinishedAndReturnsConfirmedText() async throws {
        let socket = FakeSocket()
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", makeTransport: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "realtime=v1")
            return socket
        })
        try await session.start(language: .auto) { _ in }
        let finish = Task { try await session.finish(finalAudio: Data([1, 2])) }
        socket.feed(.string(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"hello"}"#))
        socket.feed(.string(#"{"type":"session.finished"}"#))
        let text = try await finish.value
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(socket.sendCount, 3) // configuration, final PCM, session.finish
        XCTAssertTrue(socket.cancelled)
    }

    func testServerErrorFailsInsteadOfReturningPartial() async throws {
        let socket = FakeSocket()
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", makeTransport: { _ in socket })
        try await session.start(language: .auto) { _ in }
        let finish = Task { try await session.finish(finalAudio: nil) }
        socket.feed(.string(#"{"type":"conversation.item.input_audio_transcription.text","text":"partial"}"#))
        socket.feed(.string(#"{"type":"error","error":{"message":"quota exhausted"}}"#))
        do { _ = try await finish.value; XCTFail("Expected server failure") } catch { }
        XCTAssertTrue(socket.cancelled)
    }

    func testReceiveDisconnectWakesFinalWaiter() async throws {
        let socket = FakeSocket()
        let session = StreamingRecognitionSession(engine: .volcengine, apiKey: "test", makeTransport: { _ in socket })
        try await session.start(language: .auto) { _ in }
        let finish = Task { try await session.finish(finalAudio: nil) }
        socket.disconnect()
        do { _ = try await finish.value; XCTFail("Expected disconnection") } catch { }
        XCTAssertTrue(socket.cancelled)
    }

    func testFinalTimeoutDoesNotAcceptPartialText() async throws {
        let clock = ManualClock()
        let socket = FakeSocket()
        let session = StreamingRecognitionSession(engine: .volcengine, apiKey: "test", clock: clock, makeTransport: { _ in socket })
        try await session.start(language: .auto) { _ in }
        let finish = Task { try await session.finish(finalAudio: nil) }
        await eventually { socket.sendCount == 2 && clock.hasDeadline(in: 2) }
        clock.advance(2.1)
        do { _ = try await finish.value; XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error is DictationError) }
        XCTAssertTrue(socket.cancelled)
    }

    func testConnectionTimeoutCancelsTransport() async {
        let clock = ManualClock()
        let socket = FakeSocket(sendGate: AsyncResult<Void>())
        let session = StreamingRecognitionSession(engine: .volcengine, apiKey: "test", clock: clock, makeTransport: { _ in socket })
        let opening = Task { try await session.prepare(language: .auto) }
        await eventually { clock.sleeperCount > 0 }
        clock.advance(5.1)
        do { try await opening.value; XCTFail("Expected timeout") } catch { }
        XCTAssertTrue(socket.cancelled)
    }

    func testSendFailureIsPropagated() async {
        let socket = FakeSocket(sendError: URLError(.cannotConnectToHost))
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", makeTransport: { _ in socket })
        do { try await session.start(language: .auto) { _ in }; XCTFail("Expected send failure") } catch { }
        XCTAssertTrue(socket.cancelled)
    }

    func testAudioSendTimeoutClosesConnectionAndReleasesSender() async throws {
        let clock = ManualClock()
        let socket = FakeSocket(sendGate: AsyncResult<Void>(), gateAfter: 1)
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", clock: clock, makeTransport: { _ in socket })
        try await session.start(language: .auto) { _ in }
        let send = Task { try await session.sendAudio(Data([1, 2])) }
        await eventually { socket.sendCount == 2 && clock.hasDeadline(in: 5) }
        clock.advance(5.1)
        do { try await send.value; XCTFail("Expected send timeout") }
        catch { XCTAssertTrue(error is DictationError) }
        XCTAssertTrue(socket.cancelled)
    }

    func testCancelWhileWaitingForFinalDoesNotHang() async throws {
        let socket = FakeSocket()
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", makeTransport: { _ in socket })
        try await session.start(language: .auto) { _ in }
        let finish = Task { try await session.finish(finalAudio: nil) }
        await eventually { socket.sendCount == 2 }
        await session.cancel()
        do { _ = try await finish.value; XCTFail("Expected cancellation") } catch { }
    }

    func testVolcengineGoldenFinalAndErrorPackets() throws {
        let payload = Data(#"{"result":{"text":"你好","utterances":[{"definite":true}]}}"#.utf8)
        var final = Data([0x11, 0x93, 0x10, 0, 0xff, 0xff, 0xff, 0xff])
        final.append(contentsOf: [0, 0, 0, UInt8(payload.count)])
        final.append(payload)
        let response = try VolcengineWireProtocol.parseServerResponse(final)
        XCTAssertEqual(response?.update?.text, "你好")
        XCTAssertEqual(response?.isFinalResponse, true)
        var error = Data([0x11, 0xf0, 0x10, 0, 0, 0, 1, 0x93, 0, 0, 0, 6])
        error.append(Data("denied".utf8))
        XCTAssertThrowsError(try VolcengineWireProtocol.parseServerResponse(error))
        XCTAssertThrowsError(try VolcengineWireProtocol.parseServerResponse(final.prefix(9)))
    }
}
