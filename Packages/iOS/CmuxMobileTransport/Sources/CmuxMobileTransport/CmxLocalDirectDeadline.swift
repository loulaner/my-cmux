import Foundation

/// A bounded race that never waits for a non-cooperative approval closure to finish.
actor CmxLocalDirectDeadline<Value: Sendable> {
    enum Failure: Error { case timedOut }
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func run(timeout: Duration, clock: any Clock<Duration>, body: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result); return }
                self.continuation = continuation
                operation = Task {
                    do { self.finish(.success(try await body())) }
                    catch { self.finish(.failure(error)) }
                }
                timer = Task {
                    do {
                        try await clock.sleep(for: timeout)
                        self.finish(.failure(Failure.timedOut))
                    } catch {}
                }
            }
        } onCancel: { Task { await self.finish(.failure(CancellationError())) } }
    }
    private func finish(_ value: Result<Value, any Error>) {
        guard result == nil else { return }
        result = value
        operation?.cancel()
        timer?.cancel()
        operation = nil
        timer = nil
        continuation?.resume(with: value)
        continuation = nil
    }
}
