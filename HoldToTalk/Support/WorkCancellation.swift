import Foundation

final class WorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

final class ArchiveExtraction: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false

    static func extract(_ archive: URL, into directory: URL) async throws {
        let operation = ArchiveExtraction()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try operation.run(archive, directory: directory) })
                }
            }
        } onCancel: { operation.cancel() }
    }
    private func run(_ archive: URL, directory: URL) throws {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", directory.path]
        // Avoid a full stderr pipe blocking tar while the parent waits for exit.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        process.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else { throw LocalSpeechModelStoreError.extractFailed("") }
    }
    private func cancel() {
        lock.lock()
        cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
    }
}


enum ModelInstallation {
    static func publish(extracted: URL, destination: URL, requiredFiles: [String], modelName: String) throws {
        let files = FileManager.default
        func valid(_ directory: URL) -> Bool {
            requiredFiles.allSatisfy { files.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
        guard valid(extracted) else { throw LocalSpeechModelStoreError.extractedModelMissingFiles(modelName) }
        if valid(destination) { return }
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: extracted, to: destination)
    }
}
