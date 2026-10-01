import Foundation

/// A cancellation-safe, single-assignment result. All continuations are removed before resuming.
final class AsyncResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume(with: result) }
        return true
    }

    func value() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.lock.lock()
            let waiter = self.waiters.removeValue(forKey: id)
            self.lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
    }
}

func withDictationTimeout<T: Sendable>(
    seconds: TimeInterval,
    clock: any DictationClock = SystemDictationClock(),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.sleep(for: seconds)
            throw DictationError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
