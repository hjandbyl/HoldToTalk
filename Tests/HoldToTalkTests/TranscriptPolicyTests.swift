import XCTest
@testable import HoldToTalk

final class TranscriptPolicyTests: XCTestCase {
    func testOnlyOptionalTrailingChinesePeriodIsRemoved() {
        XCTAssertEqual(TranscriptPolicy.finalize(" 你好。\n", removingTrailingPeriod: true), "你好")
        XCTAssertEqual(TranscriptPolicy.finalize("Hello.", removingTrailingPeriod: true), "Hello.")
        XCTAssertEqual(TranscriptPolicy.finalize("你好。", removingTrailingPeriod: false), "你好。")
        XCTAssertEqual(TranscriptPolicy.finalize(" \n", removingTrailingPeriod: true), "")
    }

    func testShortTapDoesNotDiscardManualOrAlreadyRecognizedSpeech() {
        XCTAssertTrue(TranscriptPolicy.isShortTap(trigger: .shortcut("Fn"), duration: 0.1, partial: ""))
        XCTAssertFalse(TranscriptPolicy.isShortTap(trigger: .manual, duration: 0.1, partial: ""))
        XCTAssertFalse(TranscriptPolicy.isShortTap(trigger: .shortcut("Fn"), duration: 0.1, partial: "你好"))
        XCTAssertFalse(TranscriptPolicy.isShortTap(trigger: .shortcut("Fn"), duration: 0.22, partial: ""))
    }
}
