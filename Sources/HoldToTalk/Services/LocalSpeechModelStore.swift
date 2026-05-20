import Foundation

enum LocalSpeechModelStore {
    static func installedDirectory(for model: LocalSpeechModel) -> URL? {
        searchDirectories(for: model).first { hasRequiredFiles(for: model, in: $0) }
    }

    static func isInstalled(_ model: LocalSpeechModel) -> Bool {
        isUserInstalled(model)
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

        try? FileManager.default.removeItem(at: destination)
        try extractArchive(temporaryArchive, into: baseDirectory)
        await progressHandler?(1)

        guard hasRequiredFiles(for: model, in: destination) else {
            throw LocalSpeechModelStoreError.extractedModelMissingFiles(model.displayTitle)
        }
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

    private static func extractArchive(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", directory.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8) ?? ""
            throw LocalSpeechModelStoreError.extractFailed(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private final class DownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressHandler: (@Sendable (Double) async -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(progressHandler: (@Sendable (Double) async -> Void)?) {
        self.progressHandler = progressHandler
    }

    static func download(
        from url: URL,
        progressHandler: (@Sendable (Double) async -> Void)?
    ) async throws -> URL {
        let operation = DownloadOperation(progressHandler: progressHandler)
        return try await operation.start(url: url)
    }

    private func start(url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.default
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            self.session?.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        Task {
            await progressHandler?(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoldToTalk-download-\(UUID().uuidString).tar.bz2")
        do {
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            continuation?.resume(returning: temporaryURL)
            continuation = nil
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, continuation != nil else { return }
        continuation?.resume(throwing: error)
        continuation = nil
        session.invalidateAndCancel()
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
