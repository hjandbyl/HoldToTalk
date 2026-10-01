import Foundation

struct ModelLibraryOperations: Sendable {
    var installed: @Sendable (LocalSpeechModel) -> Bool
    var download: @Sendable (LocalSpeechModel, @escaping @Sendable (Double) async -> Void) async throws -> Void
    var delete: @Sendable (LocalSpeechModel) async throws -> Void
    static let live = ModelLibraryOperations(installed: { LocalSpeechModelStore.isInstalled($0) }, download: {
        try await LocalSpeechModelStore.download($0, progressHandler: $1)
    }, delete: { model in
        try await Task.detached(priority: .utility) { try LocalSpeechModelStore.delete(model) }.value
    })
}

@MainActor
final class ModelLibraryStore: ObservableObject {
    @Published private(set) var installedLocalSpeechModelIDs: Set<String> = []
    @Published private(set) var downloadingLocalSpeechModelID: String?
    @Published private(set) var deletingLocalSpeechModelIDs: Set<String> = []
    @Published private(set) var localSpeechModelDownloadProgress = 0.0
    @Published private(set) var localSpeechModelStatusText = L10n.tr("Not downloaded")
    var isDownloadingLocalSpeechModel: Bool { downloadingLocalSpeechModelID != nil }
    var isInUse: ((LocalSpeechModel) -> Bool)?
    var didChange: (() -> Void)?
    var reportStatus: ((String) -> Void)?
    private let operations: ModelLibraryOperations
    private let settings: SettingsStore
    private let recognizer: any LocalRecognizing
    private var operationID: UUID?
    private var task: Task<Void, Never>?
    private var downloads: [UUID: Task<Void, Never>] = [:]
    private var deletingTasks: [String: Task<Void, Never>] = [:]

    init(settings: SettingsStore, recognizer: any LocalRecognizing, operations: ModelLibraryOperations = .live) {
        self.settings = settings
        self.recognizer = recognizer
        self.operations = operations
        refreshLocalSpeechModelStatus()
    }
    var isSelectedLocalSpeechModelInstalled: Bool { isLocalSpeechModelInstalled(settings.selectedLocalSpeechModel) }
    func isLocalSpeechModelInstalled(_ model: LocalSpeechModel) -> Bool { installedLocalSpeechModelIDs.contains(model.id) }
    func refreshLocalSpeechModelStatus() {
        let installed = Set(LocalSpeechModel.all.filter(operations.installed).map(\.id))
        if installed != installedLocalSpeechModelIDs { installedLocalSpeechModelIDs = installed }
        if !isDownloadingLocalSpeechModel { localSpeechModelStatusText = isSelectedLocalSpeechModelInstalled ? L10n.tr("Downloaded") : L10n.tr("Not downloaded") }
    }
    func downloadSelectedLocalSpeechModel() { downloadLocalSpeechModel(settings.selectedLocalSpeechModel) }
    func downloadLocalSpeechModel(_ model: LocalSpeechModel) {
        guard task == nil, deletingLocalSpeechModelIDs.isEmpty else { return }
        settings.setLocalSpeechModel(model)
        let id = UUID()
        operationID = id
        downloadingLocalSpeechModelID = model.id
        localSpeechModelDownloadProgress = 0
        localSpeechModelStatusText = L10n.tr("Downloading %@...", model.displayTitle)
        let operations = operations
        task = Task { [weak self] in
            defer { self?.downloads[id] = nil }
            do {
                try await operations.download(model) { [weak self] progress in
                    await self?.updateProgress(progress, operationID: id)
                }
                try Task.checkCancellation()
                guard let self, self.operationID == id else { return }
                self.finishDownload()
                self.reportStatus?(L10n.tr("Downloaded %@.", model.displayTitle))
                self.didChange?()
            } catch {
                guard let self, self.operationID == id else { return }
                self.finishDownload()
                self.reportStatus?(error is CancellationError ? L10n.tr("Download canceled.") : error.localizedDescription)
            }
        }
        downloads[id] = task
    }
    private func updateProgress(_ progress: Double, operationID id: UUID) {
        guard operationID == id else { return }
        localSpeechModelDownloadProgress = progress
    }
    private func finishDownload() {
        task = nil
        operationID = nil
        downloadingLocalSpeechModelID = nil
        localSpeechModelDownloadProgress = 0
        refreshLocalSpeechModelStatus()
    }
    func cancelLocalSpeechModelDownload() {
        task?.cancel()
        finishDownload()
        reportStatus?(L10n.tr("Download canceled."))
    }
    func deleteLocalSpeechModel(_ model: LocalSpeechModel) {
        guard isInUse?(model) != true, !deletingLocalSpeechModelIDs.contains(model.id) else { return }
        if downloadingLocalSpeechModelID == model.id { cancelLocalSpeechModelDownload() }
        deletingLocalSpeechModelIDs.insert(model.id)
        let operations = operations
        let recognizer = recognizer
        deletingTasks[model.id] = Task { [weak self] in
            defer { self?.deletingLocalSpeechModelIDs.remove(model.id); self?.deletingTasks[model.id] = nil }
            do {
                await recognizer.clearCache()
                try Task.checkCancellation()
                try await operations.delete(model)
                self?.refreshLocalSpeechModelStatus()
                self?.reportStatus?(L10n.tr("Deleted %@.", model.displayTitle))
            } catch { self?.reportStatus?(error.localizedDescription) }
        }
    }
    func shutdown() async {
        for task in downloads.values { task.cancel() }
        for task in downloads.values { await task.value }
        downloads.removeAll()
        task = nil
        for task in deletingTasks.values { task.cancel() }
        for task in deletingTasks.values { await task.value }
    }
}
