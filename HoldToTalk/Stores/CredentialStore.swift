import Foundation

struct CredentialStorage {
    var read: (RecognitionEngine) -> String?
    var write: (RecognitionEngine, String) throws -> Void
    var delete: (RecognitionEngine) throws -> Void
    static var keychain: CredentialStorage { CredentialStorage(read: { engine in
        engine == .volcengine ? VolcengineCredentialStore.apiKey() : QwenASRCredentialStore.apiKey()
    }, write: { engine, key in
        if engine == .volcengine { try VolcengineCredentialStore.saveAPIKey(key) }
        else { try QwenASRCredentialStore.saveAPIKey(key) }
    }, delete: { engine in
        if engine == .volcengine { try VolcengineCredentialStore.deleteAPIKey() }
        else { try QwenASRCredentialStore.deleteAPIKey() }
    }) }
}

@MainActor
final class CredentialStore: ObservableObject {
    @Published var volcengineAPIKeyDraft: String { didSet { schedule(.volcengine) } }
    @Published var qwenASRAPIKeyDraft: String { didSet { schedule(.qwenASR) } }
    @Published private(set) var volcengineAPIKeyStatusText = L10n.tr("Not set")
    @Published private(set) var qwenASRAPIKeyStatusText = L10n.tr("Not set")
    @Published private(set) var hasVolcengineAPIKey: Bool
    @Published private(set) var hasQwenASRAPIKey: Bool
    var needsVolcengineAPIKey: Bool { !hasVolcengineAPIKey }
    var needsQwenASRAPIKey: Bool { !hasQwenASRAPIKey }
    var didSave: ((RecognitionEngine) -> Void)?
    private let storage: CredentialStorage
    private let clock: any DictationClock
    private var tasks: [RecognitionEngine: Task<Void, Never>] = [:]
    private var saved: [RecognitionEngine: String] = [:]
    private var applying = false

    init(storage: CredentialStorage = .keychain, clock: any DictationClock = SystemDictationClock()) {
        self.storage = storage
        self.clock = clock
        let volc = storage.read(.volcengine) ?? ""
        let qwen = storage.read(.qwenASR) ?? ""
        volcengineAPIKeyDraft = volc
        qwenASRAPIKeyDraft = qwen
        hasVolcengineAPIKey = !volc.isEmpty
        hasQwenASRAPIKey = !qwen.isEmpty
        saved = [.volcengine: volc, .qwenASR: qwen]
        refreshStatus()
    }
    func apiKey(for engine: RecognitionEngine) -> String { saved[engine] ?? "" }
    func needsAPIKey(for engine: RecognitionEngine) -> Bool { engine.isCloud && apiKey(for: engine).isEmpty }
    func refreshStatus() {
        volcengineAPIKeyStatusText = hasVolcengineAPIKey ? L10n.tr("Saved in Keychain") : L10n.tr("Not set")
        qwenASRAPIKeyStatusText = hasQwenASRAPIKey ? L10n.tr("Saved in Keychain") : L10n.tr("Not set")
    }
    private func schedule(_ engine: RecognitionEngine) {
        guard !applying else { return }
        tasks[engine]?.cancel()
        tasks[engine] = Task { [weak self] in
            do {
                try await self?.clock.sleep(for: 0.45)
                try Task.checkCancellation()
                self?.save(engine)
            } catch { }
        }
    }
    func save(_ engine: RecognitionEngine) {
        let key = (engine == .volcengine ? volcengineAPIKeyDraft : qwenASRAPIKeyDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != saved[engine] else { return }
        do {
            if key.isEmpty { try storage.delete(engine) } else { try storage.write(engine, key) }
            saved[engine] = key
            applying = true
            if engine == .volcengine { volcengineAPIKeyDraft = key; hasVolcengineAPIKey = !key.isEmpty }
            else { qwenASRAPIKeyDraft = key; hasQwenASRAPIKey = !key.isEmpty }
            applying = false
            refreshStatus()
            didSave?(engine)
        } catch {
            let message = L10n.tr("Could not save API key: %@", error.localizedDescription)
            if engine == .volcengine { volcengineAPIKeyStatusText = message } else { qwenASRAPIKeyStatusText = message }
        }
    }
    func shutdown() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        save(.volcengine)
        save(.qwenASR)
    }
}
