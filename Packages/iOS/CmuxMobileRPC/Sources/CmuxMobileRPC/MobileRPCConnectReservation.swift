import Foundation

/// A single pre-publication reservation; concurrent callers wait without owning its lease.
final class MobileRPCConnectReservation: Sendable {
    let id = UUID()
    let completion: Task<Void, any Error>
    private let continuation: AsyncStream<Void>.Continuation
    init() {
        let channel = AsyncStream<Void>.makeStream()
        continuation = channel.continuation
        completion = Task { for await _ in channel.stream {} }
    }
    func finish() { continuation.finish() }
    deinit { continuation.finish() }
}
