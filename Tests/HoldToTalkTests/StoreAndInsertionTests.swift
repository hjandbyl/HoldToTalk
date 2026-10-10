import XCTest
import AppKit
@testable import HoldToTalk

@MainActor
final class StoreAndInsertionTests: XCTestCase {
    func testCredentialsDebounceIndependentlyAndDoNotTouchRealKeychain() async {
        let clock = ManualClock()
        var keys: [RecognitionEngine: String] = [:]
        let store = CredentialStore(storage: CredentialStorage(read: { keys[$0] }, write: { keys[$0] = $1 }, delete: { keys[$0] = nil }), clock: clock)
        store.volcengineAPIKeyDraft = " first "
        store.qwenASRAPIKeyDraft = " second "
        await eventually { clock.sleeperCount == 2 }
        clock.advance(0.5)
        await eventually { store.hasVolcengineAPIKey && store.hasQwenASRAPIKey }
        XCTAssertEqual(keys[.volcengine], "first")
        XCTAssertEqual(keys[.qwenASR], "second")
        store.volcengineAPIKeyDraft = ""
        store.shutdown()
        XCTAssertNil(keys[.volcengine])
        XCTAssertEqual(keys[.qwenASR], "second")
    }

    func testKeychainFailureDoesNotReplacePreviouslySavedKey() {
        let store = CredentialStore(storage: CredentialStorage(read: { _ in "old" }, write: { _, _ in throw URLError(.unknown) }, delete: { _ in }))
        store.volcengineAPIKeyDraft = "new"
        store.save(.volcengine)
        XCTAssertEqual(store.apiKey(for: .volcengine), "old")
        XCTAssertFalse(store.needsVolcengineAPIKey)
        store.shutdown()
    }

    func testSettingsPreserveExistingDefaultsKeysAndDefaultPunctuation() {
        let name = "HoldToTalk-test-settings-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.removesTrailingSentencePeriod)
        store.removesTrailingSentencePeriod = false
        store.setLocalSpeechModel(LocalSpeechModel.all.last!)
        store.setHoldShortcut(.defaultShortcut)
        let restored = SettingsStore(defaults: defaults)
        XCTAssertFalse(restored.removesTrailingSentencePeriod)
        XCTAssertEqual(restored.selectedLocalSpeechModel, LocalSpeechModel.all.last!)
        XCTAssertNotNil(defaults.data(forKey: "HoldToTalk.holdShortcut"))
    }

    func testQwenModelSelectionPersistsAndPreservesLegacyLanguageChoice() {
        let name = "HoldToTalk-test-qwen-model-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.selectedQwenSpeechModel, .message)
        XCTAssertEqual(store.availableLanguages(for: .qwenASR), [.auto])
        var changes = 0
        store.configurationDidChange = { changes += 1 }
        store.setPreferredRecognitionEngine(.qwenASR)
        store.setQwenSpeechModel(.realtime)
        store.setLanguage(.zh)
        store.setQwenSpeechModel(.message)
        XCTAssertEqual(store.language(for: .qwenASR), .auto)
        store.setQwenSpeechModel(.realtime)
        XCTAssertEqual(store.language(for: .qwenASR), .zh)
        XCTAssertEqual(SettingsStore(defaults: defaults).selectedQwenSpeechModel, .realtime)
        XCTAssertEqual(changes, 5)
    }

    func testStaleDownloadProgressAndCompletionCannotOverwriteRestart() async {
        let downloads = ControlledDownloads()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "HoldToTalk-model-test-\(UUID())")!)
        let store = ModelLibraryStore(settings: settings, recognizer: FakeLocalRecognizer(), operations: ModelLibraryOperations(
            installed: { _ in false }, download: { _, progress in try await downloads.start(progress) }, delete: { _ in }))
        store.downloadSelectedLocalSpeechModel()
        await eventually { downloads.count == 1 }
        store.cancelLocalSpeechModelDownload()
        store.downloadSelectedLocalSpeechModel()
        await eventually { downloads.count == 2 }
        await downloads.progress(1, 0.7)
        await downloads.progress(0, 0.99)
        downloads.complete(0)
        await eventually { store.localSpeechModelDownloadProgress == 0.7 }
        XCTAssertTrue(store.isDownloadingLocalSpeechModel)
        downloads.complete(1)
        await eventually { !store.isDownloadingLocalSpeechModel }
        await store.shutdown()
    }

    func testModelInUseCannotBeDeleted() async {
        var deleted = false
        let box = BoolBox()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "HoldToTalk-model-test-\(UUID())")!)
        let store = ModelLibraryStore(settings: settings, recognizer: FakeLocalRecognizer(), operations: ModelLibraryOperations(
            installed: { _ in true }, download: { _, _ in }, delete: { _ in box.set() }))
        store.isInUse = { _ in true }
        store.deleteLocalSpeechModel(.defaultModel)
        await Task.yield()
        deleted = box.value
        XCTAssertFalse(deleted)
        XCTAssertTrue(store.deletingLocalSpeechModelIDs.isEmpty)
        await store.shutdown()
    }

    func testInstallationRejectsIncompleteStagingAndPreservesValidModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HoldToTalk-install-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model")
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("model.onnx"))
        XCTAssertThrowsError(try ModelInstallation.publish(extracted: staging, destination: destination, requiredFiles: ["model.onnx"], modelName: "test"))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("model.onnx")), "old")
        try Data("new".utf8).write(to: staging.appendingPathComponent("model.onnx"))
        try ModelInstallation.publish(extracted: staging, destination: destination, requiredFiles: ["model.onnx"], modelName: "test")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("model.onnx")), "old")
        try FileManager.default.removeItem(at: destination)
        try ModelInstallation.publish(extracted: staging, destination: destination, requiredFiles: ["model.onnx"], modelName: "test")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("model.onnx")), "new")
    }

    func testPasteboardSnapshotRestoresAllTypesAndProtectsUserCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        pasteboard.setData(Data([1, 2, 3]), forType: .png)
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("injection", forType: .string)
        XCTAssertTrue(snapshot.restoreIfUnchanged(to: pasteboard, expectedChangeCount: pasteboard.changeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(pasteboard.data(forType: .png), Data([1, 2, 3]))
        let changeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("user copied", forType: .string)
        XCTAssertFalse(snapshot.restoreIfUnchanged(to: pasteboard, expectedChangeCount: changeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "user copied")
    }

    func testMissingInsertionTargetFailsWithoutSendingEvents() async {
        do { _ = try await TextInjector().insert("test", target: nil); XCTFail("Expected unavailable target") } catch { }
    }
}

private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class ControlledDownloads: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var handlers: [@Sendable (Double) async -> Void] = []
    var count: Int { lock.withLock { continuations.count } }
    func start(_ progress: @escaping @Sendable (Double) async -> Void) async throws {
        // Deliberately ignores cancellation to simulate a late delegate callback.
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { continuations.append(continuation); handlers.append(progress) }
        }
    }
    func progress(_ index: Int, _ value: Double) async { await lock.withLock { handlers[index] }(value) }
    func complete(_ index: Int) { lock.withLock { continuations[index] }.resume() }
}
