import XCTest
@testable import HoldToTalk

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    func testOverlappingRecordingsInsertInCaptureOrderAndUseSnapshots() async {
        let h = DictationHarness()
        h.coordinator.start(h.configuration(removePeriod: false))
        await eventually { h.captures[0].started }
        h.coordinator.release()
        await eventually { !h.recording.isRecording }
        h.coordinator.start(h.configuration(removePeriod: true))
        await eventually { h.captures[1].started }
        h.coordinator.release()
        await eventually { await h.local.hasRequest(h.captures[1].url) }
        await h.local.resolve(h.captures[1].url, .success("第二。"))
        await eventually { h.diagnostics.metrics.isEmpty && h.coordinator.outstandingCount == 2 }
        XCTAssertTrue(h.injector.texts.isEmpty)
        await h.local.resolve(h.captures[0].url, .success("第一。"))
        await eventually { h.coordinator.outstandingCount == 0 }
        XCTAssertEqual(h.injector.texts, ["第一。", "第二"])
        XCTAssertEqual(h.injector.targets.compactMap { $0?.processIdentifier }, [42, 42])
        for capture in h.captures { await eventually { !FileManager.default.fileExists(atPath: capture.url.path) } }
        await h.coordinator.shutdown()
    }

    func testFailedEarlierSegmentReleasesLaterResultWithoutFallback() async {
        let h = DictationHarness()
        for _ in 0..<2 {
            h.coordinator.start(h.configuration(engine: .qwenASR))
            await eventually { h.captures.last?.started == true }
            h.coordinator.release()
            await eventually { !h.recording.isRecording }
        }
        await eventually { await h.clouds[1].finished }
        await h.clouds[1].resolve("second")
        await h.clouds[0].cancel()
        await eventually { h.coordinator.outstandingCount == 0 }
        XCTAssertEqual(h.injector.texts, ["second"])
        let requests = await h.local.requests
        XCTAssertTrue(requests.isEmpty)
        await h.coordinator.shutdown()
    }

    func testLatePartialCannotChangeNewRecording() async {
        let h = DictationHarness()
        h.coordinator.start(h.configuration(engine: .volcengine))
        await eventually { h.captures[0].started }
        h.coordinator.release()
        await eventually { !h.recording.isRecording }
        h.coordinator.start(h.configuration(engine: .volcengine))
        await eventually { await h.clouds[1].started }
        await h.clouds[1].partial("new")
        await eventually { h.recording.liveTranscription.text == "new" }
        await h.clouds[0].partial("old")
        await h.clouds[0].resolve("old final")
        await eventually { h.coordinator.outstandingCount == 1 }
        XCTAssertEqual(h.recording.liveTranscription.text, "new")
        XCTAssertTrue(h.recording.isRecording)
        await h.coordinator.shutdown()
    }

    func testShortShortcutTapCancelsCloudAndDeletesFile() async {
        let h = DictationHarness()
        h.coordinator.start(h.configuration(engine: .volcengine, trigger: .shortcut("Fn")))
        await eventually { h.captures[0].started }
        h.clock.advance(0.1)
        h.coordinator.release()
        await eventually { h.coordinator.outstandingCount == 0 }
        XCTAssertTrue(h.injector.texts.isEmpty)
        let cancelled = await h.clouds[0].cancelled
        XCTAssertTrue(cancelled)
        await eventually { !FileManager.default.fileExists(atPath: h.captures[0].url.path) }
        await h.coordinator.shutdown()
    }

    func testBluetoothTailIsCancellableAndStopIsIdempotent() async {
        let h = DictationHarness()
        let config = h.configuration(tail: 0.35)
        h.coordinator.start(config)
        await eventually { h.captures[0].started }
        h.coordinator.release()
        h.coordinator.release()
        await eventually { h.clock.sleeperCount > 0 }
        h.coordinator.start(config)
        h.clock.advance(1)
        XCTAssertTrue(h.recording.isRecording)
        XCTAssertEqual(h.captures[0].stopCount, 0)
        h.coordinator.release()
        await eventually { h.clock.sleeperCount > 0 }
        h.clock.advance(0.36)
        await eventually { !h.recording.isRecording }
        XCTAssertEqual(h.captures[0].stopCount, 1)
        await h.coordinator.shutdown()
    }

    func testPressAndReleaseDuringHardwareStopStartsNextSegment() async {
        let h = DictationHarness()
        let capture = FakeCapture()
        capture.stopGate = AsyncResult<Void>()
        h.nextCapture = capture
        h.coordinator.start(h.configuration())
        await eventually { capture.started }
        h.coordinator.release()
        await Task.yield()
        h.coordinator.start(h.configuration())
        h.coordinator.release()
        capture.stopGate?.resolve(.success(()))
        await eventually { h.captures.count == 2 }
        await eventually { !h.recording.isRecording }
        XCTAssertEqual(h.captures[1].stopCount, 1)
        await h.coordinator.shutdown()
    }

    func testFailureDuringReleaseStopsHardwareOnce() async {
        let h = DictationHarness()
        let capture = FakeCapture()
        capture.stopGate = AsyncResult<Void>()
        h.nextCapture = capture
        h.coordinator.start(h.configuration())
        await eventually { capture.started }
        h.coordinator.release()
        await Task.yield()
        capture.fail()
        await Task.yield()
        capture.stopGate?.resolve(.success(()))
        await eventually { h.coordinator.outstandingCount == 0 }
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertTrue(h.injector.texts.isEmpty)
        await h.coordinator.shutdown()
    }

    func testShutdownDuringStartupDeletesFileAndNeverInserts() async {
        let h = DictationHarness()
        h.coordinator.start(h.configuration(engine: .volcengine))
        await h.coordinator.shutdown()
        XCTAssertEqual(h.coordinator.outstandingCount, 0)
        XCTAssertFalse(h.recording.isRecording)
        XCTAssertTrue(h.injector.texts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.captures[0].url.path))
    }

    func testAdmissionLimitDoesNotStartNinthCapture() async {
        let h = DictationHarness()
        for _ in 0..<8 {
            h.coordinator.start(h.configuration())
            await eventually { h.captures.last?.started == true }
            h.coordinator.release()
            await eventually { !h.recording.isRecording }
        }
        h.coordinator.start(h.configuration())
        XCTAssertEqual(h.captures.count, 8)
        XCTAssertEqual(h.coordinator.outstandingCount, 8)
        XCTAssertFalse(h.recording.isRecording)
        await h.coordinator.shutdown()
        XCTAssertEqual(h.coordinator.outstandingCount, 0)
        XCTAssertTrue(h.injector.texts.isEmpty)
    }

    func testCaptureFailureStopsOnlyThatSession() async {
        let h = DictationHarness()
        h.coordinator.start(h.configuration(engine: .volcengine))
        await eventually { h.captures[0].started }
        h.captures[0].fail()
        h.captures[0].fail()
        await eventually { h.coordinator.outstandingCount == 0 }
        XCTAssertEqual(h.captures[0].stopCount, 1)
        XCTAssertTrue(h.injector.texts.isEmpty)
        await eventually { !FileManager.default.fileExists(atPath: h.captures[0].url.path) }
        await h.coordinator.shutdown()
    }

    func testStartFailureDoesNotLeaveMicrophoneOrCloudSession() async {
        let h = DictationHarness()
        let capture = FakeCapture()
        capture.startError = DictationError.captureFailed
        h.nextCapture = capture
        h.coordinator.start(h.configuration(engine: .volcengine))
        await eventually { h.coordinator.outstandingCount == 0 }
        XCTAssertFalse(h.recording.isRecording)
        let cancelled = await h.clouds[0].cancelled
        XCTAssertTrue(cancelled)
        await h.coordinator.shutdown()
    }

    func testInsertionFailurePreservesTranscriptButCleansAudio() async {
        let h = DictationHarness()
        h.injector.error = DictationError.targetUnavailable
        h.coordinator.start(h.configuration())
        await eventually { h.captures[0].started }
        h.coordinator.release()
        await eventually { await h.local.hasRequest(h.captures[0].url) }
        await h.local.resolve(h.captures[0].url, .success("keep text"))
        await eventually { h.coordinator.outstandingCount == 0 }
        XCTAssertEqual(h.recording.lastTranscript, "keep text")
        XCTAssertEqual(h.diagnostics.metrics.last?.outcome, "failed")
        await h.coordinator.shutdown()
    }

    func testHundredSegmentsReleaseAllSessionResources() async {
        let h = DictationHarness()
        for index in 0..<100 {
            h.coordinator.start(h.configuration())
            await eventually { h.captures.last?.started == true }
            let url = h.captures.last!.url
            h.clock.advance(0.5)
            h.coordinator.release()
            await eventually { await h.local.hasRequest(url) }
            await h.local.resolve(url, .success("\(index)"))
            await eventually { h.coordinator.outstandingCount == 0 }
        }
        XCTAssertEqual(h.injector.texts.count, 100)
        XCTAssertEqual(h.diagnostics.metrics.count, 100)
        XCTAssertFalse(h.recording.isTranscribing)
        for capture in h.captures { await eventually { !FileManager.default.fileExists(atPath: capture.url.path) } }
        await h.coordinator.shutdown()
    }
}
