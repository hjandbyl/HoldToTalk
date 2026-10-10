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
    var sentMessages: [URLSessionWebSocketTask.Message] { lock.withLock { messages } }
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
    func testQwenMessageWaitsForAcknowledgementAndSendsBinaryPCM() async throws {
        let socket = FakeSocket()
        let updates = RecognitionUpdates()
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", makeTransport: { request in
            XCTAssertEqual(request.url?.absoluteString, "wss://dashscope.aliyuncs.com/api-ws/v1/inference")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
            XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
            return socket
        })
        var ready = false
        let opening = Task {
            try await session.start(language: .auto) { event in
                if case .update(let update) = event { updates.append(update) }
            }
            ready = true
        }
        await eventually { socket.sendCount == 1 }
        XCTAssertFalse(ready)
        let request = try messageJSON(socket.sentMessages[0])
        let header = try XCTUnwrap(request["header"] as? [String: Any])
        let taskID = try XCTUnwrap(header["task_id"] as? String)
        XCTAssertEqual(taskID.count, 32)
        XCTAssertEqual(header["action"] as? String, "run-task")
        XCTAssertEqual(header["streaming"] as? String, "duplex")
        let payload = try XCTUnwrap(request["payload"] as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "qwen-audio-3.1-asr-flash-message")
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(parameters["format"] as? String, "pcm")
        XCTAssertEqual(parameters["intermediate_result_enabled"] as? Bool, true)
        XCTAssertEqual(parameters["keep_dialect"] as? Bool, true)
        XCTAssertEqual(parameters["disfluency_removal_enabled"] as? Bool, false)
        socket.feed(messageEvent("task-started", taskID: taskID))
        try await opening.value
        let audio = Data([1, 0, 2, 0])
        try await session.sendAudio(audio)
        let tail = Data([3, 0])
        var finished = false
        let finish = Task { let text = try await session.finish(finalAudio: tail); finished = true; return text }
        await eventually { socket.sendCount == 4 }
        XCTAssertEqual(try binaryData(socket.sentMessages[1]), audio)
        XCTAssertEqual(try binaryData(socket.sentMessages[2]), tail)
        let finishRequest = try messageJSON(socket.sentMessages[3])
        let finishHeader = try XCTUnwrap(finishRequest["header"] as? [String: Any])
        XCTAssertEqual(finishHeader["task_id"] as? String, taskID)
        XCTAssertEqual(finishHeader["action"] as? String, "finish-task")
        socket.feed(messageEvent("result-generated", taskID: taskID, sentence: [
            "sentence_id": 1, "text": "你好。", "sentence_end": true
        ]))
        await eventually { updates.values.count == 1 }
        XCTAssertFalse(finished)
        socket.feed(messageEvent("task-finished", taskID: taskID))
        let text = try await finish.value
        XCTAssertEqual(text, "你好。")
        XCTAssertTrue(socket.cancelled)
    }

    func testQwenMessageRevisionsKeepAllSentencesWithoutDuplicatingFinals() async throws {
        let socket = FakeSocket()
        let updates = RecognitionUpdates()
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", makeTransport: { _ in socket })
        let opening = Task { try await session.start(language: .auto) { event in
            if case .update(let update) = event { updates.append(update) }
        } }
        await eventually { socket.sendCount == 1 }
        let taskID = try sentTaskID(socket)
        socket.feed(messageEvent("task-started", taskID: taskID))
        try await opening.value
        socket.feed(messageEvent("result-generated", taskID: taskID, sentence: [
            "heartbeat": true, "sentence_id": 0
        ]))
        for sentence: [String: Any] in [
            ["sentence_id": 2, "text": "世", "sentence_end": false],
            ["sentence_id": 1, "text": "你", "sentence_end": false],
            ["sentence_id": 1, "text": "你好。", "sentence_end": true],
            ["sentence_id": 1, "text": "旧的中间结果", "sentence_end": false],
            ["sentence_id": 2, "text": "世界。", "sentence_end": true],
            ["sentence_id": 2, "text": "世界。", "sentence_end": true]
        ] { socket.feed(messageEvent("result-generated", taskID: taskID, sentence: sentence)) }
        await eventually { updates.values.count == 5 }
        XCTAssertEqual(updates.values.map(\.text), ["世", "你世", "你好。世", "你好。世界。", "你好。世界。"])
        XCTAssertEqual(updates.values.map(\.isDefinite), [false, false, false, true, true])
        let finish = Task { try await session.finish(finalAudio: nil) }
        await eventually { socket.sendCount == 2 }
        let completion = messageEvent("task-finished", taskID: taskID)
        if case .string(let json) = completion { socket.feed(.data(Data(json.utf8))) }
        let text = try await finish.value
        XCTAssertEqual(text, "你好。世界。")
    }

    func testQwenMessageFinishedTaskRejectsUnconfirmedTrailingSentence() async throws {
        let socket = FakeSocket()
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", makeTransport: { _ in socket })
        let opening = Task { try await session.start(language: .auto) { _ in } }
        await eventually { socket.sendCount == 1 }
        let taskID = try sentTaskID(socket)
        socket.feed(messageEvent("task-started", taskID: taskID))
        try await opening.value
        let finish = Task { try await session.finish(finalAudio: nil) }
        await eventually { socket.sendCount == 2 }
        socket.feed(messageEvent("result-generated", taskID: taskID, sentence: [
            "sentence_id": 1, "text": "确认的前半句。", "sentence_end": true
        ]))
        socket.feed(messageEvent("result-generated", taskID: taskID, sentence: [
            "sentence_id": 2, "text": "未确认的后半句", "sentence_end": false
        ]))
        socket.feed(messageEvent("task-finished", taskID: taskID))
        do { _ = try await finish.value; XCTFail("Expected incomplete result") }
        catch { XCTAssertEqual(DictationError.category(error), "incompleteResult") }
        XCTAssertTrue(socket.cancelled)
    }

    func testQwenMessageServerFailureDuringHandshakeClosesTransport() async throws {
        let socket = FakeSocket()
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", makeTransport: { _ in socket })
        let opening = Task { try await session.prepare(language: .auto) }
        await eventually { socket.sendCount == 1 }
        socket.feed(messageEvent("task-failed", taskID: try sentTaskID(socket), errorMessage: "quota exhausted"))
        do { try await opening.value; XCTFail("Expected server failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("quota exhausted")) }
        XCTAssertTrue(socket.cancelled)
    }

    func testQwenMessageHandshakeTimeoutAndCancellationReleaseWaiters() async {
        for cancel in [false, true] {
            let clock = ManualClock()
            let socket = FakeSocket()
            let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", clock: clock, makeTransport: { _ in socket })
            let opening = Task { try await session.prepare(language: .auto) }
            await eventually { socket.sendCount == 1 && clock.hasDeadline(in: 5) }
            if cancel { await session.cancel() } else { clock.advance(5.1) }
            do { try await opening.value; XCTFail("Expected handshake failure") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(DictationError.category(error), "timeout") }
            }
            XCTAssertTrue(socket.cancelled)
        }
    }

    func testQwenMessageFinalTimeoutAndServerFailureNeverReturnPartial() async throws {
        for serverFailure in [false, true] {
            let clock = ManualClock()
            let socket = FakeSocket()
            let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", clock: clock, makeTransport: { _ in socket })
            let opening = Task { try await session.start(language: .auto) { _ in } }
            await eventually { socket.sendCount == 1 }
            let taskID = try sentTaskID(socket)
            socket.feed(messageEvent("task-started", taskID: taskID))
            try await opening.value
            let finish = Task { try await session.finish(finalAudio: nil) }
            await eventually { socket.sendCount == 2 && clock.hasDeadline(in: 5) }
            socket.feed(messageEvent("result-generated", taskID: taskID, sentence: [
                "sentence_id": 1, "text": "partial", "sentence_end": false
            ]))
            if serverFailure { socket.feed(messageEvent("task-failed", taskID: taskID, errorMessage: "quota exhausted")) }
            else { clock.advance(5.1) }
            do { _ = try await finish.value; XCTFail("Expected final failure") } catch { }
            XCTAssertTrue(socket.cancelled)
        }
    }

    func testQwenMessageProtocolRejectsWrongTaskAndMalformedSentence() throws {
        XCTAssertThrowsError(try QwenMessageWireProtocol.parseServerResponse(
            #"{"header":{"task_id":"other","event":"task-started"},"payload":{}}"#, taskID: "expected"))
        XCTAssertThrowsError(try QwenMessageWireProtocol.parseServerResponse(
            #"{"header":{"task_id":"expected","event":"result-generated"},"payload":{"output":{"sentence":{"text":"missing id","sentence_end":true}}}}"#,
            taskID: "expected"))
        XCTAssertNil(try QwenMessageWireProtocol.parseServerResponse(
            #"{"header":{"task_id":"expected","event":"result-generated"},"payload":{"output":{"sentence":{"heartbeat":true,"sentence_id":0}}}}"#,
            taskID: "expected"))
    }

    func testIdlePrewarmFailureInvalidatesThePreparedConnection() async throws {
        let failure = AsyncResult<Void>()
        let socket = FakeSocket()
        let cloud = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", qwenModel: .realtime,
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
            let cloud = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", qwenModel: .realtime, makeTransport: { _ in socket })
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
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", qwenModel: .realtime, makeTransport: { request in
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
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", qwenModel: .realtime, makeTransport: { _ in socket })
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
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", qwenModel: .realtime, makeTransport: { _ in socket })
        do { try await session.start(language: .auto) { _ in }; XCTFail("Expected send failure") } catch { }
        XCTAssertTrue(socket.cancelled)
    }

    func testAudioSendTimeoutClosesConnectionAndReleasesSender() async throws {
        let clock = ManualClock()
        let socket = FakeSocket(sendGate: AsyncResult<Void>(), gateAfter: 1)
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", qwenModel: .realtime, clock: clock, makeTransport: { _ in socket })
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
        let session = StreamingRecognitionSession(engine: .qwenASR, apiKey: "test", qwenModel: .realtime, makeTransport: { _ in socket })
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

private final class RecognitionUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [RecognitionUpdate] = []
    var values: [RecognitionUpdate] { lock.withLock { updates } }
    func append(_ update: RecognitionUpdate) { lock.withLock { updates.append(update) } }
}

private func messageJSON(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
    guard case .string(let string) = message,
          let json = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else {
        throw QwenASRStreamingClientError.invalidResponse
    }
    return json
}

private func binaryData(_ message: URLSessionWebSocketTask.Message) throws -> Data {
    guard case .data(let data) = message else { throw QwenASRStreamingClientError.invalidResponse }
    return data
}

private func sentTaskID(_ socket: FakeSocket) throws -> String {
    let json = try messageJSON(XCTUnwrap(socket.sentMessages.first))
    return try XCTUnwrap((json["header"] as? [String: Any])?["task_id"] as? String)
}

private func messageEvent(_ event: String, taskID: String, sentence: [String: Any]? = nil,
                          errorMessage: String? = nil) -> URLSessionWebSocketTask.Message {
    var header: [String: Any] = ["task_id": taskID, "event": event]
    if let errorMessage { header["error_code"] = "CLIENT_ERROR"; header["error_message"] = errorMessage }
    let payload: [String: Any] = sentence.map { ["output": ["sentence": $0]] } ?? [:]
    return .string(QwenWireProtocol.jsonString(["header": header, "payload": payload]))
}
