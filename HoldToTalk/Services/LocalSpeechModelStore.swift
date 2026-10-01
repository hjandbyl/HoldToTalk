import Foundation

enum LocalSpeechModelStore {
    static func installedDirectory(for model: LocalSpeechModel) -> URL? {
        searchDirectories(for: model).first { hasRequiredFiles(for: model, in: $0) }
    }

    static func isInstalled(_ model: LocalSpeechModel) -> Bool {
        installedDirectory(for: model) != nil
    }

    static func isUserInstalled(_ model: LocalSpeechModel) -> Bool {
        guard let userDirectory = try? userModelDirectory(for: model) else { return false }
        return hasRequiredFiles(for: model, in: userDirectory)
    }

    static func delete(_ model: LocalSpeechModel) throws {
        let userDirectory = try userModelDirectory(for: model)
        if FileManager.default.fileExists(atPath: userDirectory.path) {
            try FileManager.default.removeItem(at: userDirectory)
        }
    }

    static func download(
        _ model: LocalSpeechModel,
        progressHandler: (@Sendable (Double) async -> Void)? = nil
    ) async throws {
        let destination = try userModelDirectory(for: model)
        if hasRequiredFiles(for: model, in: destination) {
            await progressHandler?(1)
            return
        }

        let baseDirectory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let downloadedArchive = try await DownloadOperation.download(from: model.archiveURL, progressHandler: progressHandler)
        let temporaryArchive = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(model.directoryName)-\(UUID().uuidString).tar.bz2")
        try? FileManager.default.removeItem(at: temporaryArchive)
        try FileManager.default.moveItem(at: downloadedArchive, to: temporaryArchive)
        defer { try? FileManager.default.removeItem(at: temporaryArchive) }

        let staging = baseDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation()
        try await ArchiveExtraction.extract(temporaryArchive, into: staging)
        try Task.checkCancellation()
        let extracted = staging.appendingPathComponent(model.directoryName, isDirectory: true)
        try ModelInstallation.publish(extracted: extracted, destination: destination,
            requiredFiles: model.requiredFiles, modelName: model.displayTitle)
        await progressHandler?(1)
    }

    static func userModelsBaseDirectory() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return applicationSupport
            .appendingPathComponent("HoldToTalk", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    static func userModelDirectory(for model: LocalSpeechModel) throws -> URL {
        try userModelsBaseDirectory().appendingPathComponent(model.directoryName, isDirectory: true)
    }

    private static func searchDirectories(for model: LocalSpeechModel) -> [URL] {
        var directories: [URL] = []

        if let userDirectory = try? userModelDirectory(for: model) {
            directories.append(userDirectory)
        }

        if let projectRoot = projectRootURL() {
            directories.append(
                projectRoot
                    .appendingPathComponent("models", isDirectory: true)
                    .appendingPathComponent(model.directoryName, isDirectory: true)
            )
        }

        return directories
    }

    private static func projectRootURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private static func hasRequiredFiles(for model: LocalSpeechModel, in directory: URL) -> Bool {
        model.requiredFiles.allSatisfy { relativePath in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(relativePath).path)
        }
    }


}

private final class DownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progressHandler: (@Sendable (Double) async -> Void)?
    private let result = AsyncResult<URL>()
    private var session: URLSession?
    private var cancelled = false
    private var downloadedURL: URL?
    private var lastProgressUpdateTime: TimeInterval = 0 // serial URLSession delegate queue

    init(progressHandler: (@Sendable (Double) async -> Void)?) { self.progressHandler = progressHandler }
    static func download(from url: URL, progressHandler: (@Sendable (Double) async -> Void)?) async throws -> URL {
        try await DownloadOperation(progressHandler: progressHandler).start(url: url)
    }
    private func start(url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let task = try lock.withLock { () throws -> URLSessionDownloadTask in
                if cancelled { throw CancellationError() }
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                self.session = session
                return session.downloadTask(with: url)
            }
            task.resume()
            return try await result.value()
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        let session = lock.withLock { () -> URLSession? in
            cancelled = true
            let session = self.session
            self.session = nil
            if let downloadedURL { try? FileManager.default.removeItem(at: downloadedURL) }
            downloadedURL = nil
            return session
        }
        result.resolve(.failure(CancellationError()))
        session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        let now = ProcessInfo.processInfo.systemUptime
        guard progress >= 1 || now - lastProgressUpdateTime >= 0.25 else { return }
        lastProgressUpdateTime = now
        Task { await progressHandler?(progress) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("HoldToTalk-download-\(UUID().uuidString).tar.bz2")
        do {
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                try FileManager.default.moveItem(at: location, to: temporaryURL)
                downloadedURL = temporaryURL
                if !result.resolve(.success(temporaryURL)) { try? FileManager.default.removeItem(at: temporaryURL) }
            }
        } catch { result.resolve(.failure(error)) }
        lock.withLock { self.session = nil }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { result.resolve(.failure(error)) }
        lock.withLock { self.session = nil }
        session.finishTasksAndInvalidate()
    }
}

enum LocalSpeechModelStoreError: LocalizedError {
    case extractFailed(String)
    case extractedModelMissingFiles(String)

    var errorDescription: String? {
        switch self {
        case .extractFailed(let details):
            if details.isEmpty {
                return L10n.tr("Could not extract the local speech model.")
            }
            return L10n.tr("Could not extract the local speech model: %@", details)
        case .extractedModelMissingFiles(let modelName):
            return L10n.tr("Downloaded model %@ is missing required files.", modelName)
        }
    }
}
