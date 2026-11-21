import Foundation

/// Bridges PhotoKit callbacks without leaking a request when cancellation wins
/// before its request ID is returned. Completion is delivered at most once.
final class CompanionPhotoRequest<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var cancellation: (@Sendable () -> Void)?

    func value(start: @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> (@Sendable () -> Void)) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard begin(continuation) else { return }
                let cancel = start { [self] in finish($0) }
                installCancellation(cancel)
            }
        } onCancel: { self.cancel() }
    }

    private func begin(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        cancellation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func installCancellation(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        let wasCancelled: Bool
        if case .failure(let error) = result { wasCancelled = error is CancellationError }
        else { wasCancelled = false }
        if result == nil { cancellation = cancel }
        lock.unlock()
        if wasCancelled { cancel() }
    }

    private func cancel() {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .failure(CancellationError())
        let continuation = self.continuation
        let cancel = cancellation
        self.continuation = nil
        cancellation = nil
        lock.unlock()
        cancel?()
        continuation?.resume(throwing: CancellationError())
    }
}
